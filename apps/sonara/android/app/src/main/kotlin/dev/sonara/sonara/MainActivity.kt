package dev.sonara.sonara

import android.content.Intent
import android.os.Build
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
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
                        stopService(Intent(this, SonaraService::class.java))
                        result.success(true)
                    }
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(EXTRA_INVITATION)?.let { startReceiver(it, false) }
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
    }
}
