package dev.sonara.sonara

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.InetAddress
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.sonara/receiver")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val invitation = (arguments?.get("invitation") as? String)?.trim()
                        if (invitation.isNullOrBlank()) {
                            result.error("empty_invitation", "Invitation cannot be empty", null)
                        } else if (!invitation.startsWith("sonara1:")) {
                            result.error("invalid_invitation", "Expected a sonara1 invitation", null)
                        } else {
                            val trust = arguments?.get("trust") as? Boolean ?: false
                            startReceiver(invitation, trust)
                            result.success(true)
                        }
                    }
                    "stop" -> {
                        SonaraService.markStopping()
                        stopService(Intent(this, SonaraService::class.java))
                        SonaraService.markStopped()
                        result.success(true)
                    }
                    "ensureLocalNetworkAccess" -> ensureLocalNetworkAccess(result)
                    "scanLocalNetwork" -> scanLocalNetwork(result)
                    "status" -> result.success(SonaraService.lastStatus)
                    "trustState" -> result.success(
                        mapOf(
                            "auto_reconnect" to preferences.getBoolean(KEY_AUTO_RECONNECT, true),
                            "fingerprints" to preferences.getStringSet(KEY_TRUSTED, emptySet())!!.toList(),
                        ),
                    )
                    "setAutoReconnect" -> {
                        val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                        if (enabled == null) {
                            result.error("arguments", "Missing enabled value", null)
                        } else {
                            preferences.edit().putBoolean(KEY_AUTO_RECONNECT, enabled).apply()
                            result.success(enabled)
                        }
                    }
                    "forgetTrusted" -> {
                        val fingerprint = (call.arguments as? Map<*, *>)?.get("fingerprint") as? String
                        val trusted = preferences.getStringSet(KEY_TRUSTED, emptySet())!!.toMutableSet()
                        trusted.remove(fingerprint)
                        preferences.edit().putStringSet(KEY_TRUSTED, trusted).apply()
                        if (fingerprint != null && fingerprint == SonaraService.activeHostFingerprint) {
                            stopService(Intent(this, SonaraService::class.java))
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        intent.getStringExtra(EXTRA_INVITATION)?.let { startReceiver(it, false) }
    }

    private fun scanLocalNetwork(result: MethodChannel.Result) {
        if (!discoveryScanRunning.compareAndSet(false, true)) {
            result.success(emptyList<Map<String, Any>>())
            return
        }
        Thread({
            val announcements = mutableListOf<Map<String, Any>>()
            try {
                DatagramSocket().use { socket ->
                    socket.broadcast = true
                    val probe = DISCOVERY_PROBE.toByteArray(Charsets.UTF_8)
                    for (target in localProbeAddresses()) {
                        val packet = DatagramPacket(
                            probe,
                            probe.size,
                            InetAddress.getByName(target),
                            DISCOVERY_PORT,
                        )
                        socket.send(packet)
                    }

                    val deadline = System.currentTimeMillis() + DISCOVERY_RESPONSE_WINDOW_MS
                    val seen = mutableSetOf<String>()
                    while (System.currentTimeMillis() < deadline) {
                        socket.soTimeout = maxOf(
                            1,
                            (deadline - System.currentTimeMillis()).toInt(),
                        )
                        val buffer = ByteArray(4096)
                        val packet = DatagramPacket(buffer, buffer.size)
                        try {
                            socket.receive(packet)
                        } catch (_: SocketTimeoutException) {
                            break
                        }
                        val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                        val key = "${packet.address.hostAddress}:${data.contentHashCode()}"
                        if (seen.add(key)) {
                            announcements.add(
                                mapOf(
                                    "address" to packet.address.hostAddress,
                                    "data" to data,
                                ),
                            )
                        }
                    }
                }
                runOnUiThread { result.success(announcements) }
            } catch (error: Exception) {
                Log.w("SonaraDiscovery", "Native LAN scan failed", error)
                runOnUiThread {
                    result.error("lan_scan", "Could not scan the local network", error.message)
                }
            } finally {
                discoveryScanRunning.set(false)
            }
        }, "sonara-discovery").start()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(EXTRA_INVITATION)?.let { startReceiver(it, false) }
    }

    private fun ensureLocalNetworkAccess(result: MethodChannel.Result) {
        // Android 16 uses NEARBY_WIFI_DEVICES while Local Network Protection is
        // being introduced. Older releases grant LAN sockets through INTERNET.
        val usesCompatibilityGrant = applicationInfo.targetSdkVersion < 36
        val granted = Build.VERSION.SDK_INT < 36 || usesCompatibilityGrant ||
            checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted && !usesCompatibilityGrant) {
            requestPermissions(
                arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES),
                REQUEST_LOCAL_NETWORK,
            )
        }
        // Do not hold a platform-channel reply while an OEM permission UI is
        // open. The periodic probe begins working as soon as access is granted.
        result.success(
            mapOf(
                "granted" to granted,
                "probe_addresses" to localProbeAddresses(),
            ),
        )
    }

    private fun localProbeAddresses(): List<String> {
        val addresses = try {
            Collections.list(NetworkInterface.getNetworkInterfaces())
                .filter { it.isUp && !it.isLoopback }
                .flatMap { networkInterface -> networkInterface.interfaceAddresses }
                .flatMap { interfaceAddress ->
                    val address = interfaceAddress.address
                    val broadcast = interfaceAddress.broadcast
                    if (address !is Inet4Address || broadcast !is Inet4Address) {
                        return@flatMap emptyList()
                    }
                    val prefix = interfaceAddress.networkPrefixLength.toInt()
                    if (prefix !in 1..30) return@flatMap listOf(broadcast.hostAddress)

                    // A bounded unicast sweep handles Android/OEM stacks that
                    // filter broadcasts. On very broad networks, start with the
                    // device's own /24 rather than flooding the whole prefix.
                    val scanPrefix = maxOf(prefix, 24)
                    val addressBits = ByteBuffer.wrap(address.address).int.toLong() and 0xffffffffL
                    val mask = (0xffffffffL shl (32 - scanPrefix)) and 0xffffffffL
                    val networkBits = addressBits and mask
                    val broadcastBits = networkBits or (mask.inv() and 0xffffffffL)
                    buildList {
                        add(broadcast.hostAddress)
                        for (candidate in (networkBits + 1) until broadcastBits) {
                            if (candidate == addressBits) continue
                            add(
                                InetAddress.getByAddress(
                                    ByteBuffer.allocate(Int.SIZE_BYTES)
                                        .putInt(candidate.toInt())
                                        .array(),
                                ).hostAddress,
                            )
                        }
                    }
                }
                .distinct()
        } catch (error: Exception) {
            Log.w("SonaraDiscovery", "Could not enumerate local probe targets", error)
            emptyList()
        }
        Log.i("SonaraDiscovery", "Local discovery targets: ${addresses.size}")
        return addresses
    }

    private fun startReceiver(invitation: String, trust: Boolean) {
        val service = Intent(this, SonaraService::class.java)
            .putExtra(EXTRA_INVITATION, invitation)
            .putExtra(EXTRA_HOST_FINGERPRINT, invitationFingerprint(invitation))
            .putExtra(EXTRA_TRUST_REQUESTED, trust)
            .putExtra(EXTRA_AUTO_RECONNECT, preferences.getBoolean(KEY_AUTO_RECONNECT, true))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(service)
        } else {
            startService(service)
        }
    }

    private val preferences by lazy {
        getSharedPreferences(PREFERENCES, MODE_PRIVATE)
    }

    private fun invitationFingerprint(invitation: String): String? = try {
        val body = invitation.removePrefix("sonara1:")
        val decoded = Base64.decode(body, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        JSONObject(String(decoded, Charsets.UTF_8)).optString("host_fingerprint").takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        null
    }

    companion object {
        const val EXTRA_INVITATION = "sonara_invitation"
        const val EXTRA_AUTO_RECONNECT = "sonara_auto_reconnect"
        const val EXTRA_HOST_FINGERPRINT = "sonara_host_fingerprint"
        const val EXTRA_TRUST_REQUESTED = "sonara_trust_requested"
        internal const val PREFERENCES = "sonara_trust"
        internal const val KEY_TRUSTED = "trusted_fingerprints"
        private const val KEY_AUTO_RECONNECT = "auto_reconnect"
        private const val REQUEST_LOCAL_NETWORK = 4101
        private const val DISCOVERY_PORT = 49_813
        private const val DISCOVERY_PROBE = "SONARA_DISCOVER/1"
        private const val DISCOVERY_RESPONSE_WINDOW_MS = 700L
        private val discoveryScanRunning = AtomicBoolean(false)
    }
}
