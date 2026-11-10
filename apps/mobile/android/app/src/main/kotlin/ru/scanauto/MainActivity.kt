package ru.scanauto

import android.Manifest
import android.content.Context
import android.content.Intent
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    private var bluetooth: BluetoothSpp? = null

    private val connectivity: ConnectivityManager
        get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bluetooth = BluetoothSpp(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ru.scanauto/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Повторный start обновляет текст уведомления.
                    "start" -> {
                        askNotifications()
                        val intent = Intent(this, RecordingService::class.java)
                            .putExtra(RecordingService.EXTRA_TEXT, call.argument<String>("text"))
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            RecordingService.lastError = "${e.javaClass.simpleName}: ${e.message}"
                            result.error("start_failed", RecordingService.lastError, null)
                        }
                    }
                    "status" -> result.success(serviceStatus())
                    "requestBatteryExemption" -> {
                        result.success(requestBatteryExemption())
                    }
                    "openAppSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, RecordingService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ru.scanauto/wifi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bind" -> bindToWifi(result)
                    "release" -> {
                        releaseWifi()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * У сети Wi-Fi адаптера ELM327 нет интернета, и при включённых мобильных данных
     * Android оставляет сетью по умолчанию мобильную: соединение с 192.168.0.10 уходит
     * не туда. Запрос сети Wi-Fi держит её подключённой, а привязка процесса направляет
     * в неё все сокеты приложения — до [releaseWifi].
     */
    private fun bindToWifi(result: MethodChannel.Result) {
        releaseWifi()
        var replied = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val bound = connectivity.bindProcessToNetwork(network)
                runOnUiThread {
                    if (!replied) {
                        replied = true
                        result.success(bound)
                    }
                }
            }
        }
        wifiCallback = callback
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.requestNetwork(request, callback)
    }

    private fun releaseWifi() {
        connectivity.bindProcessToNetwork(null)
        wifiCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        wifiCallback = null
    }

    /** Всё, что нужно, чтобы понять по журналу, почему приложение замерзало в фоне. */
    private fun serviceStatus(): Map<String, Any?> {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        val notifications = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return mapOf(
            "running" to RecordingService.running,
            "error" to RecordingService.lastError,
            "notifications" to notifications.areNotificationsEnabled(),
            "batteryExempt" to power.isIgnoringBatteryOptimizations(packageName),
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
        )
    }

    /**
     * Системный запрос «не ограничивать работу в фоне». Без него прошивки Xiaomi,
     * Honor, Samsung и других замораживают приложение даже со службой.
     */
    private fun requestBatteryExemption(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (power.isIgnoringBatteryOptimizations(packageName)) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
            false
        } catch (e: Exception) {
            // Нет такого экрана в прошивке — открываем общий список.
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            false
        }
    }

    /** Android 13+: без разрешения служба работает, но уведомление не видно. */
    private fun askNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (bluetooth?.onPermissionResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, RecordingService::class.java))
        bluetooth?.close()
        releaseWifi()
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATIONS_REQUEST = 4102
    }
}
