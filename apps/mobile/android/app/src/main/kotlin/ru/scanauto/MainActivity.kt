package ru.scanauto

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

    private val connectivity: ConnectivityManager
        get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

    override fun onDestroy() {
        releaseWifi()
        super.onDestroy()
    }
}
