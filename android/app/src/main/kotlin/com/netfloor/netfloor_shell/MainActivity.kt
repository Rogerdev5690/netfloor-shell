package com.netfloor.netfloor_shell

import android.content.Context
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Diagnóstico Wi-Fi nativo usado pela aba "NetFloor Diagnostic": varredura de
 * redes, RSSI/velocidade PHY da conexão atual e ping. Cada método devolve uma
 * string JSON; o Dart do Shell repassa o resultado ao app web via ponte JS.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "netfloor/diag")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scan" -> runAsync(result) { scanNetworks() }
                    "linkInfo" -> runAsync(result) { linkInfo() }
                    "ping" -> {
                        val host = call.argument<String>("host") ?: ""
                        runAsync(result) { ping(host) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> String) {
        Thread {
            val out = try {
                block()
            } catch (e: Throwable) {
                JSONObject().put("error", e.toString()).toString()
            }
            runOnUiThread { result.success(out) }
        }.start()
    }

    private fun wifiManager(): WifiManager =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    @Suppress("DEPRECATION")
    private fun scanNetworks(): String {
        val wm = wifiManager()
        val root = JSONObject()
        try {
            // O Android limita as varreduras; se for barrada, getScanResults devolve o cache.
            root.put("scanStarted", wm.startScan())
        } catch (e: SecurityException) {
            root.put("scanStarted", false)
        }

        val connectedBssid = try {
            wm.connectionInfo?.bssid?.lowercase()
        } catch (e: SecurityException) {
            null
        }

        val results: List<ScanResult> = try {
            wm.scanResults ?: emptyList()
        } catch (e: SecurityException) {
            root.put("error", "Permissão negada: ${e.message}")
            emptyList()
        }

        val networks = JSONArray()
        for (sr in results) {
            var width = 20
            var center = sr.frequency
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                width = when (sr.channelWidth) {
                    ScanResult.CHANNEL_WIDTH_40MHZ -> 40
                    ScanResult.CHANNEL_WIDTH_80MHZ -> 80
                    ScanResult.CHANNEL_WIDTH_160MHZ, ScanResult.CHANNEL_WIDTH_80MHZ_PLUS_MHZ -> 160
                    else -> 20
                }
                if (sr.centerFreq0 > 0) center = sr.centerFreq0
            }
            val bssid = sr.BSSID ?: ""
            networks.put(
                JSONObject()
                    .put("ssid", sr.SSID ?: "")
                    .put("bssid", bssid)
                    .put("frequency", sr.frequency)
                    .put("centerFreq", center)
                    .put("widthMhz", width)
                    .put("level", sr.level)
                    .put("connected", connectedBssid != null && bssid.lowercase() == connectedBssid)
            )
        }
        root.put("networks", networks)
        return root.toString()
    }

    @Suppress("DEPRECATION")
    private fun linkInfo(): String {
        val wm = wifiManager()
        val out = JSONObject()
        val info = wm.connectionInfo
        if (info == null || info.rssi <= -127 || info.linkSpeed <= 0) {
            return out.put("connected", false).toString()
        }
        val dhcp = wm.dhcpInfo
        return out
            .put("connected", true)
            .put("ssid", (info.ssid ?: "").trim('"'))
            .put("bssid", info.bssid ?: "")
            .put("rssi", info.rssi)
            .put("linkSpeed", info.linkSpeed)
            .put("frequency", info.frequency)
            .put("gateway", if (dhcp != null) intToIp(dhcp.gateway) else "")
            .put("ip", if (dhcp != null) intToIp(dhcp.ipAddress) else "")
            .toString()
    }

    private fun intToIp(v: Int): String =
        if (v == 0) "" else "${v and 0xff}.${(v shr 8) and 0xff}.${(v shr 16) and 0xff}.${(v shr 24) and 0xff}"

    private fun ping(host: String): String {
        val out = JSONObject()
        if (!Regex("^[A-Za-z0-9.\\-]{1,253}$").matches(host)) {
            return out.put("error", "host inválido").toString()
        }

        var ms: Double? = null
        var processRan = false
        try {
            val process = ProcessBuilder("/system/bin/ping", "-c", "1", "-W", "2", host)
                .redirectErrorStream(true)
                .start()
            processRan = true
            val text = process.inputStream.bufferedReader().readText()
            process.waitFor()
            ms = Regex("time[=<]\\s*([0-9.]+)").find(text)?.groupValues?.get(1)?.toDoubleOrNull()
        } catch (e: Exception) {
            // sem binário de ping utilizável: usa o teste TCP abaixo
        }
        if (ms == null && !processRan) ms = tcpRtt(host)

        return out.put("ms", ms ?: JSONObject.NULL).toString()
    }

    /** Fallback sem ICMP: mede o tempo de um connect TCP (conexão recusada também prova alcance). */
    private fun tcpRtt(host: String): Double? {
        for (port in intArrayOf(53, 80)) {
            val start = System.nanoTime()
            try {
                Socket().use { it.connect(InetSocketAddress(host, port), 1500) }
                return (System.nanoTime() - start) / 1e6
            } catch (e: ConnectException) {
                if (e.message?.contains("refused", ignoreCase = true) == true) {
                    return (System.nanoTime() - start) / 1e6
                }
            } catch (e: Exception) {
                // tenta a próxima porta
            }
        }
        return null
    }
}
