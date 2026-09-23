package com.tiptoe.tiptoe

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.tiptoe/wifi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "join" -> {
                        val ssid = call.argument<String>("ssid")
                        val pass = call.argument<String>("pass")
                        if (ssid.isNullOrEmpty() || pass.isNullOrEmpty()) {
                            result.success(false)
                        } else {
                            join(ssid, pass, result)
                        }
                    }
                    "leave" -> {
                        leave()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun connectivity(): ConnectivityManager =
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private fun join(ssid: String, pass: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("wifi", "This Android version cannot join a chosen network from the app.", null)
            return
        }
        leave()
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(pass)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        var finished = false
        val next = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (finished) return
                finished = true
                connectivity().bindProcessToNetwork(network)
                result.success(true)
            }

            override fun onUnavailable() {
                if (finished) return
                finished = true
                result.success(false)
            }
        }
        callback = next
        connectivity().requestNetwork(request, next, 30_000)
    }

    private fun leave() {
        val current = callback ?: return
        callback = null
        try {
            connectivity().unregisterNetworkCallback(current)
        } catch (_: Exception) {
        }
        connectivity().bindProcessToNetwork(null)
    }

    override fun onDestroy() {
        leave()
        super.onDestroy()
    }
}
