package ru.scanauto

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Bluetooth Classic (SPP) до адаптера ELM327. Свой модуль вместо плагина: клоны ведут себя
 * по-разному, и порядок попыток подключения нужно держать под контролем.
 *
 * Канал `ru.scanauto/bt` — команды, `ru.scanauto/bt/input` — байты от адаптера.
 * Обрыв связи приходит в поток ошибкой с кодом `disconnected`.
 */
class BluetoothSpp(private val activity: Activity, messenger: BinaryMessenger) {
    private val method = MethodChannel(messenger, "ru.scanauto/bt")
    private val events = EventChannel(messenger, "ru.scanauto/bt/input")
    private val main = Handler(Looper.getMainLooper())

    /** Подключение и запись — в одном фоновом потоке, по порядку. */
    private val io = Executors.newSingleThreadExecutor()

    private var sink: EventChannel.EventSink? = null
    private var socket: BluetoothSocket? = null
    private var reader: Thread? = null
    private var pendingPermission: MethodChannel.Result? = null

    init {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "ensurePermission" -> ensurePermission(result)
                "bondedDevices" -> bondedDevices(result)
                "connect" -> connect(call.argument<String>("address")!!, result)
                "write" -> write(call.argument<ByteArray>("bytes")!!, result)
                "disconnect" -> {
                    close()
                    result.success(null)
                }
                "openSettings" -> {
                    activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    /** Android 12+: BLUETOOTH_CONNECT спрашивается во время работы. Раньше — только манифест. */
    private fun ensurePermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN),
            PERMISSION_REQUEST,
        )
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
        return true
    }

    @SuppressLint("MissingPermission")
    private fun bondedDevices(result: MethodChannel.Result) {
        val a = adapter ?: return result.error("no_bluetooth", "На телефоне нет Bluetooth", null)
        if (!a.isEnabled) return result.error("bluetooth_off", "Bluetooth выключен", null)
        result.success(
            a.bondedDevices.map { mapOf("name" to (it.name ?: ""), "address" to it.address) },
        )
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String, result: MethodChannel.Result) {
        close()
        io.execute {
            try {
                val a = adapter ?: throw IOException("На телефоне нет Bluetooth")
                if (!a.isEnabled) throw IOException("Bluetooth выключен")
                // Поиск устройств сильно замедляет и рвёт подключение.
                a.cancelDiscovery()
                val (s, how) = openSocket(a.getRemoteDevice(address))
                socket = s
                startReader(s)
                main.post { result.success(how) }
            } catch (e: Exception) {
                main.post { result.error("connect_failed", e.message ?: e.toString(), null) }
            }
        }
    }

    /**
     * Стандартный SPP-сокет. Часть клонов отвечает только на «небезопасный» сокет
     * или на канал 1, открытый через скрытый метод. Возвращает, какой способ сработал, — для лога.
     */
    @SuppressLint("MissingPermission")
    private fun openSocket(device: BluetoothDevice): Pair<BluetoothSocket, String> {
        val attempts = listOf<Pair<String, () -> BluetoothSocket>>(
            "secure" to { device.createRfcommSocketToServiceRecord(SPP) },
            "insecure" to { device.createInsecureRfcommSocketToServiceRecord(SPP) },
            "channel1" to {
                device.javaClass
                    .getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                    .invoke(device, 1) as BluetoothSocket
            },
        )
        val errors = mutableListOf<String>()
        for ((name, open) in attempts) {
            var s: BluetoothSocket? = null
            try {
                s = open()
                s.connect()
                return s to name
            } catch (e: Exception) {
                errors += "$name: ${e.message ?: e.javaClass.simpleName}"
                runCatching { s?.close() }
            }
        }
        throw IOException(errors.joinToString("; "))
    }

    private fun startReader(s: BluetoothSocket) {
        reader = Thread {
            val buffer = ByteArray(1024)
            try {
                val input = s.inputStream
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    val chunk = buffer.copyOf(n)
                    main.post { sink?.success(chunk) }
                }
                disconnected(s, "адаптер закрыл соединение")
            } catch (e: IOException) {
                disconnected(s, e.message ?: "ошибка чтения")
            }
        }.apply {
            isDaemon = true
            start()
        }
    }

    /** Сообщаем об обрыве, только если это не мы сами закрыли сокет. */
    private fun disconnected(s: BluetoothSocket, reason: String) {
        main.post {
            if (socket === s) {
                socket = null
                sink?.error("disconnected", reason, null)
            }
        }
    }

    private fun write(bytes: ByteArray, result: MethodChannel.Result) {
        val s = socket ?: return result.error("not_connected", "Адаптер не подключён", null)
        io.execute {
            try {
                s.outputStream.write(bytes)
                s.outputStream.flush()
                main.post { result.success(null) }
            } catch (e: IOException) {
                main.post { result.error("write_failed", e.message, null) }
            }
        }
    }

    fun close() {
        val s = socket
        socket = null
        runCatching { s?.close() }
        reader = null
    }

    companion object {
        private val SPP: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private const val PERMISSION_REQUEST = 4101
    }
}
