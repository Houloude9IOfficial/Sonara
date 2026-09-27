package dev.sonara.sonara

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                            startReceiver(invitation)
                            result.success(true)
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, SonaraService::class.java))
                        result.success(true)
                    }
                    "status" -> result.success(SonaraService.lastStatus)
                    else -> result.notImplemented()
                }
            }
        intent.getStringExtra(EXTRA_INVITATION)?.let(::startReceiver)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(EXTRA_INVITATION)?.let(::startReceiver)
    }

    private fun startReceiver(invitation: String) {
        val service = Intent(this, SonaraService::class.java)
            .putExtra(EXTRA_INVITATION, invitation)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(service)
        } else {
            startService(service)
        }
    }

    companion object {
        const val EXTRA_INVITATION = "sonara_invitation"
    }
}
