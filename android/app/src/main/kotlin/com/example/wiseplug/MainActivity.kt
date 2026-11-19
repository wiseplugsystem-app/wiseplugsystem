package com.example.wiseplug

import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createSafetyChannel()
    }

    // Wi-Fi setup and Pair talk to the plug on "wisewp", which has no
    // internet, so Android sends the app's traffic over mobile data instead.
    // "bindWifi" makes this app use the Wi-Fi; "unbindWifi" goes back to
    // Android's normal choice (lib/services/local_provisioning.dart).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_CHANNEL).setMethodCallHandler { call, result ->
            val cm = getSystemService(ConnectivityManager::class.java)
            when (call.method) {
                "bindWifi" -> {
                    @Suppress("DEPRECATION")
                    val wifi = cm.allNetworks.firstOrNull {
                        cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                    }
                    result.success(wifi != null && cm.bindProcessToNetwork(wifi))
                }
                "unbindWifi" -> {
                    cm.bindProcessToNetwork(null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Safety pushes play the same warning sound as the app (res/raw/wiseplug_alert.mp3,
    // see assets/sounds/LICENSE.md) even when the app is closed: the Supabase
    // sender names this channel. Android fixes a channel's sound when it is first
    // created, so the new sound has a new channel id; the old channel (with the
    // old beeps) is removed.
    private fun createSafetyChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).deleteNotificationChannel(OLD_SAFETY_CHANNEL)
        val tone = Uri.parse("android.resource://$packageName/${R.raw.wiseplug_alert}")
        val channel = NotificationChannel(
            SAFETY_CHANNEL,
            "Safety warnings",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "When an appliance is about to be switched off, or was switched off, for safety."
            setSound(
                tone,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            enableVibration(true)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        const val SAFETY_CHANNEL = "wiseplug_safety_v2"
        const val OLD_SAFETY_CHANNEL = "wiseplug_safety"
        const val WIFI_CHANNEL = "wiseplug/wifi"
    }
}
