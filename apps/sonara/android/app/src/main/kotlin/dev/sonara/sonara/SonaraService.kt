package dev.sonara.sonara

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

class SonaraService : Service() {
    private val polling = AtomicBoolean(false)
    private var statusThread: Thread? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var activeInvitation: String? = null
    private var autoReconnect = true
    private var reconnectDeadlineMs = 0L
    private var retryIndex = 0
    private var trustRequested = false
    private var trustPersisted = false

    override fun onCreate() {
        super.onCreate()
        acquirePerformanceLocks()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, notification("Connecting to host"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val invitation = intent?.getStringExtra(MainActivity.EXTRA_INVITATION)
        if (invitation.isNullOrBlank()) {
            lastStatus = "{\"state\":\"error\",\"error\":\"Missing invitation\"}"
            stopSelf()
            return START_NOT_STICKY
        }
        activeInvitation = invitation
        activeHostFingerprint = intent.getStringExtra(MainActivity.EXTRA_HOST_FINGERPRINT)
        trustRequested = intent.getBooleanExtra(MainActivity.EXTRA_TRUST_REQUESTED, false)
        trustPersisted = false
        autoReconnect = intent.getBooleanExtra(MainActivity.EXTRA_AUTO_RECONNECT, true)
        reconnectDeadlineMs = System.currentTimeMillis() + 60_000L
        retryIndex = 0
        nativeStart(invitation, deviceDisplayName())
        beginStatusPolling()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        polling.set(false)
        nativeStop()
        statusThread?.interrupt()
        statusThread = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        activeHostFingerprint = null
        markStopped()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun beginStatusPolling() {
        if (!polling.compareAndSet(false, true)) return
        statusThread = Thread({
            var notificationState = ""
            var telemetryTick = 0
            while (polling.get()) {
                lastStatus = platformStatus()
                val state = Regex("\\\"state\\\":\\\"([^\\\"]+)\\\"")
                    .find(lastStatus)?.groupValues?.get(1) ?: "receiving"
                if (state != notificationState) {
                    notificationState = state
                    getSystemService(NotificationManager::class.java)
                        .notify(NOTIFICATION_ID, notification("Receiver: $state"))
                }
                if (telemetryTick++ % 5 == 0) Log.i("SonaraReceiver", lastStatus)
                if (state == "stopped") {
                    stopSelf()
                    break
                }
                if (state == "playing") {
                    retryIndex = 0
                    persistTrustAfterAuthentication()
                }
                if (state == "error") {
                    val error = JSONObject(lastStatus).optString("error")
                    val permanent = error.contains("expired", ignoreCase = true) ||
                        error.contains("invalid invitation", ignoreCase = true) ||
                        error.contains("rejected", ignoreCase = true) ||
                        error.contains("authorization", ignoreCase = true)
                    val invitation = activeInvitation
                    if (!autoReconnect || permanent || invitation == null ||
                        System.currentTimeMillis() >= reconnectDeadlineMs
                    ) {
                        stopSelf()
                        break
                    }
                    val baseDelay = RETRY_DELAYS_MS[minOf(retryIndex, RETRY_DELAYS_MS.lastIndex)]
                    val jitterWindow = maxOf(1L, baseDelay / 5L)
                    val jitter = (System.nanoTime() % (jitterWindow * 2L + 1L)) - jitterWindow
                    val delay = maxOf(100L, baseDelay + jitter)
                    retryIndex++
                    getSystemService(NotificationManager::class.java)
                        .notify(NOTIFICATION_ID, notification("Reconnecting in ${delay / 1000.0}s"))
                    try {
                        Thread.sleep(delay)
                    } catch (_: InterruptedException) {
                        break
                    }
                    nativeStart(invitation, deviceDisplayName())
                    continue
                }
                try {
                    Thread.sleep(100)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }, "sonara-status").also { it.start() }
    }

    private fun persistTrustAfterAuthentication() {
        if (!trustRequested || trustPersisted) return
        val fingerprint = activeHostFingerprint?.takeIf { it.isNotBlank() } ?: return
        val preferences = getSharedPreferences(MainActivity.PREFERENCES, MODE_PRIVATE)
        val trusted = preferences.getStringSet(MainActivity.KEY_TRUSTED, emptySet())!!.toMutableSet()
        trusted.add(fingerprint)
        preferences.edit().putStringSet(MainActivity.KEY_TRUSTED, trusted).apply()
        trustPersisted = true
    }

    @Suppress("DEPRECATION")
    private fun acquirePerformanceLocks() {
        try {
            val wifi = applicationContext.getSystemService(WifiManager::class.java)
            wifiLock = wifi.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "Sonara:low-latency-wifi",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: SecurityException) {
            wifiLock = null
            Log.w("SonaraReceiver", "Wi-Fi performance lock unavailable", error)
        }
        try {
            val power = getSystemService(PowerManager::class.java)
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Sonara:receiver-cpu",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: SecurityException) {
            wakeLock = null
            Log.w("SonaraReceiver", "CPU wake lock unavailable", error)
        }
    }

    private fun platformStatus(): String {
        val status = JSONObject(nativeStatus())
        status.put("platform_manufacturer", Build.MANUFACTURER)
        status.put("platform_model", Build.MODEL)
        status.put("device_name", deviceDisplayName())
        status.put("platform_sdk", Build.VERSION.SDK_INT)
        status.put("platform_abis", JSONArray(Build.SUPPORTED_ABIS.toList()))

        val manager = getSystemService(AudioManager::class.java)
        val routes = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val requestedId = status.optInt("output_device_id", -1)
        val selected = routes.firstOrNull { it.id == requestedId }
            ?: if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) manager.communicationDevice else null
        if (selected != null) {
            status.put("output_route", selected.productName.toString())
            status.put("output_route_type", routeType(selected.type))
        } else {
            status.put("output_route", "Platform default")
            status.put("output_route_type", "default")
        }
        status.put(
            "available_output_routes",
            JSONArray(routes.map { "${it.productName} (${routeType(it.type)})" }),
        )
        return status.toString()
    }

    private fun deviceDisplayName(): String {
        val configured = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)?.trim()
        } else {
            null
        }
        val manufacturer = Build.MANUFACTURER.trim().replaceFirstChar {
            if (it.isLowerCase()) it.titlecase() else it.toString()
        }
        val model = Build.MODEL.trim()
        val base = configured?.takeIf { it.isNotEmpty() } ?: model
        return when {
            base.isEmpty() -> "Android device"
            manufacturer.isEmpty() -> base
            base.startsWith(manufacturer, ignoreCase = true) -> base
            else -> "$manufacturer $base"
        }
    }

    private fun routeType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "built-in speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired headphones"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired headset"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "USB audio"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB headset"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth A2DP"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth SCO"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "Bluetooth LE headset"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "Bluetooth LE speaker"
        AudioDeviceInfo.TYPE_HDMI -> "HDMI"
        AudioDeviceInfo.TYPE_HDMI_ARC -> "HDMI ARC"
        AudioDeviceInfo.TYPE_HDMI_EARC -> "HDMI eARC"
        else -> "platform route $type"
    }

    private fun notification(text: String): Notification {
        val launch = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Sonara receiver")
            .setContentText(text)
            .setContentIntent(launch)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Audio receiving",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    companion object {
        private const val CHANNEL_ID = "sonara_receiver"
        private const val NOTIFICATION_ID = 1
        private val RETRY_DELAYS_MS = longArrayOf(500, 1_000, 2_000, 4_000, 8_000)

        @Volatile
        var lastStatus: String = "{\"state\":\"idle\"}"
            private set

        @Volatile
        var activeHostFingerprint: String? = null
            private set

        fun markStopping() {
            markState("stopping")
        }

        fun markStopped() {
            markState("stopped")
        }

        private fun markState(state: String) {
            lastStatus = try {
                JSONObject(lastStatus).put("state", state).toString()
            } catch (_: Exception) {
                "{\"state\":\"$state\"}"
            }
        }

        init {
            System.loadLibrary("sonara_audio")
            System.loadLibrary("sonara_android")
        }

        @JvmStatic private external fun nativeStart(invitation: String, receiverName: String): Boolean
        @JvmStatic private external fun nativeStop()
        @JvmStatic private external fun nativeStatus(): String
    }
}
