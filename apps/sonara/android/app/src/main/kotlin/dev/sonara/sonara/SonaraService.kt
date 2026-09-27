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
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

class SonaraService : Service() {
    private val polling = AtomicBoolean(false)
    private var statusThread: Thread? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

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
        nativeStart(invitation)
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
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun beginStatusPolling() {
        if (!polling.compareAndSet(false, true)) return
        statusThread = Thread({
            while (polling.get()) {
                lastStatus = platformStatus()
                Log.i("SonaraReceiver", lastStatus)
                val state = Regex("\\\"state\\\":\\\"([^\\\"]+)\\\"")
                    .find(lastStatus)?.groupValues?.get(1) ?: "receiving"
                getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, notification("Receiver: $state"))
                if (state == "stopped") {
                    stopSelf()
                    break
                }
                try {
                    Thread.sleep(500)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }, "sonara-status").also { it.start() }
    }

    @Suppress("DEPRECATION")
    private fun acquirePerformanceLocks() {
        val wifi = applicationContext.getSystemService(WifiManager::class.java)
        wifiLock = wifi.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            "Sonara:low-latency-wifi",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        val power = getSystemService(PowerManager::class.java)
        wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Sonara:receiver-cpu",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun platformStatus(): String {
        val status = JSONObject(nativeStatus())
        status.put("platform_manufacturer", Build.MANUFACTURER)
        status.put("platform_model", Build.MODEL)
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

        @Volatile
        var lastStatus: String = "{\"state\":\"idle\"}"
            private set

        init {
            System.loadLibrary("sonara_audio")
            System.loadLibrary("sonara_android")
        }

        @JvmStatic private external fun nativeStart(invitation: String): Boolean
        @JvmStatic private external fun nativeStop()
        @JvmStatic private external fun nativeStatus(): String
    }
}
