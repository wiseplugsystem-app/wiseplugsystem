package com.example.wiseplug

import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createSafetyChannel()
    }

    // Safety pushes play WisePlug's own warning tone (res/raw/wiseplug_warning.wav,
    // CC0, see assets/sounds/LICENSE.md) even when the app is closed: the
    // Supabase sender names this channel. Android fixes a channel's sound when it
    // is first created, so a different tone needs a new channel id.
    private fun createSafetyChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val tone = Uri.parse("android.resource://$packageName/${R.raw.wiseplug_warning}")
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
        const val SAFETY_CHANNEL = "wiseplug_safety"
    }
}
