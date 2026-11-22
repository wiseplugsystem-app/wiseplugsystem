package com.example.wiseplug_alarm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.text.DateFormat
import java.util.Date

/**
 * The safety countdown alarm, the same whether the app is open, in the
 * background, closed or the phone is locked:
 *  - the warning sound loops on the ALARM volume (like an alarm clock: silent
 *    or vibrate mode does not mute it), with vibration;
 *  - an ongoing notification counts down to the plug's real cut-off time and
 *    names the appliance and the outlet, with "Stop alarm" and "Open
 *    WisePlug", and a full-screen alert on the lock screen;
 *  - it stops by itself at the cut-off time, on "Stop alarm", or when the app
 *    says the warning is over. Outlets A and B have one alarm each; one event
 *    rings once (AlarmStore).
 * If Android refuses to start the service (a background-start limit), a
 * notification on a sound channel with the "insistent" flag repeats the sound
 * instead ([postInsistent]).
 */
class CountdownAlarmService : Service() {
    private data class Alarm(val eventId: String, val appliance: String, val endsAt: Long, val test: Boolean)

    private val alarms = linkedMapOf<String, Alarm>() // by outlet letter
    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var vibrating = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> start(intent)
            ACTION_STOP -> stop(intent.getStringExtra(EXTRA_EVENT), intent.getStringExtra(EXTRA_OUTLET))
            ACTION_STOP_ALL -> stopAll()
            else -> if (alarms.isEmpty()) finish()
        }
        return START_NOT_STICKY
    }

    private fun start(intent: Intent) {
        val eventId = intent.getStringExtra(EXTRA_EVENT) ?: return finishIfIdle()
        val outlet = intent.getStringExtra(EXTRA_OUTLET) ?: "A"
        val appliance = intent.getStringExtra(EXTRA_APPLIANCE) ?: "An appliance"
        val endsAt = intent.getLongExtra(EXTRA_ENDS_AT, 0L)
        val test = intent.getBooleanExtra(EXTRA_TEST, false)
        val notification = buildNotification(this, outlet, appliance, endsAt, eventId, CHANNEL, test)
        // Android requires startForeground() soon after startForegroundService().
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(notificationId(outlet), notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(notificationId(outlet), notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground refused: $e")
            postInsistent(this, eventId, outlet, appliance, endsAt)
            return finishIfIdle()
        }
        if (endsAt <= System.currentTimeMillis() || (!test && AlarmStore.isDone(this, eventId))) {
            return finishIfIdle()
        }
        val current = alarms[outlet]
        if (current?.eventId == eventId) return // already ringing for this event
        alarms[outlet] = Alarm(eventId, appliance, endsAt, test)
        // The push's own notification (same event) is replaced by this one.
        getSystemService(NotificationManager::class.java).cancel(eventId, 0)
        for ((o, a) in alarms) {
            if (o != outlet) notify(o, a)
        }
        handler.postDelayed({ expire(outlet, eventId) }, endsAt - System.currentTimeMillis())
        play()
    }

    private fun notify(outlet: String, a: Alarm) =
        getSystemService(NotificationManager::class.java)
            .notify(notificationId(outlet), buildNotification(this, outlet, a.appliance, a.endsAt, a.eventId, CHANNEL, a.test))

    /** The cut-off time came: the plug has switched the outlet off. */
    private fun expire(outlet: String, eventId: String) {
        if (alarms[outlet]?.eventId == eventId) remove(outlet)
    }

    private fun stop(eventId: String?, outlet: String?) {
        val keys = alarms.filter { (o, a) -> (eventId != null && a.eventId == eventId) || (outlet != null && o == outlet) }.keys.toList()
        if (eventId != null) AlarmStore.markDone(this, eventId)
        keys.forEach { remove(it) }
        if (alarms.isEmpty()) finish()
    }

    private fun stopAll() {
        alarms.keys.toList().forEach { remove(it) }
        finish()
    }

    private fun remove(outlet: String) {
        val a = alarms.remove(outlet) ?: return
        if (!a.test) AlarmStore.markDone(this, a.eventId)
        getSystemService(NotificationManager::class.java).cancel(notificationId(outlet))
        if (alarms.isEmpty()) {
            finish()
        } else {
            // The foreground notification must belong to an alarm still going.
            val (o, next) = alarms.entries.first().let { it.key to it.value }
            try {
                startForeground(notificationId(o), buildNotification(this, o, next.appliance, next.endsAt, next.eventId, CHANNEL, next.test))
            } catch (_: Exception) {
            }
        }
    }

    private fun finishIfIdle() {
        if (alarms.isEmpty()) finish()
    }

    private fun finish() {
        handler.removeCallbacksAndMessages(null)
        silence()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun play() {
        if (player != null) return
        try {
            player = MediaPlayer().apply {
                setAudioAttributes(alarmAttributes())
                setDataSource(this@CountdownAlarmService, soundUri(this@CountdownAlarmService))
                isLooping = true
                setWakeMode(this@CountdownAlarmService, PowerManager.PARTIAL_WAKE_LOCK)
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not play the warning sound: $e")
            player?.release()
            player = null
        }
        vibrate()
    }

    private fun vibrate() {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        } ?: return
        val pattern = longArrayOf(0, 700, 500)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0), alarmAttributes())
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, 0)
            }
            vibrating = true
        } catch (_: Exception) {
        }
    }

    private fun silence() {
        player?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
        if (vibrating) {
            vibrating = false
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            vibrator?.cancel()
        }
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacksAndMessages(null)
        silence()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "WisePlugAlarm"
        const val ACTION_START = "com.example.wiseplug_alarm.START"
        const val ACTION_STOP = "com.example.wiseplug_alarm.STOP"
        const val ACTION_STOP_ALL = "com.example.wiseplug_alarm.STOP_ALL"
        const val EXTRA_EVENT = "eventId"
        const val EXTRA_OUTLET = "outlet"
        const val EXTRA_APPLIANCE = "appliance"
        const val EXTRA_ENDS_AT = "endsAt"
        const val EXTRA_TEST = "test"

        /** Set on the intent that opens the app from the alarm (lock screen). */
        const val EXTRA_OPEN_OUTLET = "wiseplug_alarm_outlet"

        /** The countdown notification: silent itself, the service plays the sound. */
        const val CHANNEL = "wiseplug_countdown"

        /** The fallback notification: it plays the sound itself, repeated. */
        const val SOUND_CHANNEL = "wiseplug_countdown_sound"

        fun notificationId(outlet: String) = if (outlet == "B") 7102 else 7101

        fun alarmAttributes(): AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        /** The app's warning sound (res/raw/wiseplug_alert.mp3), else the phone's alarm sound. */
        fun soundUri(context: Context): Uri {
            val id = context.resources.getIdentifier("wiseplug_alert", "raw", context.packageName)
            return if (id != 0) {
                Uri.parse("android.resource://${context.packageName}/$id")
            } else {
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            }
        }

        fun createChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Safety countdown", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "The countdown before WisePlug switches an appliance off for safety, with its alarm."
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setBypassDnd(true)
                },
            )
            nm.createNotificationChannel(
                NotificationChannel(SOUND_CHANNEL, "Safety countdown (sound)", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Used when the phone does not let the countdown alarm start: the notification rings itself."
                    setSound(soundUri(context), alarmAttributes())
                    enableVibration(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setBypassDnd(true)
                },
            )
        }

        private fun smallIcon(context: Context): Int {
            val own = context.resources.getIdentifier("ic_notification", "drawable", context.packageName)
            return if (own != 0) own else context.applicationInfo.icon
        }

        private fun openIntent(context: Context, outlet: String): PendingIntent {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent().setPackage(context.packageName)
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            launch.putExtra(EXTRA_OPEN_OUTLET, outlet)
            return PendingIntent.getActivity(
                context,
                notificationId(outlet),
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun buildNotification(
            context: Context,
            outlet: String,
            appliance: String,
            endsAt: Long,
            eventId: String,
            channel: String,
            test: Boolean = false,
        ): Notification {
            createChannels(context)
            val open = openIntent(context, outlet)
            val stop = if (channel == CHANNEL) {
                PendingIntent.getService(
                    context,
                    notificationId(outlet) + 10,
                    Intent(context, CountdownAlarmService::class.java)
                        .setAction(ACTION_STOP)
                        .putExtra(EXTRA_EVENT, eventId)
                        .putExtra(EXTRA_OUTLET, outlet),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            } else {
                PendingIntent.getBroadcast(
                    context,
                    notificationId(outlet) + 20,
                    Intent(context, CountdownBackupReceiver::class.java)
                        .setAction(CountdownBackupReceiver.ACTION_DISMISS)
                        .putExtra(EXTRA_EVENT, eventId)
                        .putExtra(EXTRA_OUTLET, outlet),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            val at = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(endsAt))
            val title = if (test) "Test alarm: WisePlug" else "Safe time is up: $appliance"
            val text = if (test) {
                "This is how the safety countdown sounds. It stops by itself."
            } else {
                "Outlet $outlet turns off at $at. Open WisePlug to keep it on or turn it off."
            }
            return NotificationCompat.Builder(context, channel)
                .setSmallIcon(smallIcon(context))
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setSubText("Outlet $outlet")
                .setWhen(endsAt)
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setTimeoutAfter((endsAt - System.currentTimeMillis()).coerceAtLeast(1000L) + 1000L)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setContentIntent(open)
                .setFullScreenIntent(open, true)
                .addAction(0, "Stop alarm", stop)
                .addAction(0, "Open WisePlug", open)
                .build()
        }

        /** Fallback: a notification that repeats its own sound ("insistent") until the cut-off. */
        fun postInsistent(context: Context, eventId: String, outlet: String, appliance: String, endsAt: Long) {
            if (endsAt <= System.currentTimeMillis()) return
            val n = buildNotification(context, outlet, appliance, endsAt, eventId, SOUND_CHANNEL)
            n.flags = n.flags or Notification.FLAG_INSISTENT
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.cancel(eventId, 0)
            try {
                nm.notify(notificationId(outlet), n)
            } catch (e: SecurityException) {
                Log.w(TAG, "Notifications not allowed: $e")
            }
        }

        /**
         * Starts the alarm for [eventId] (once: an event that already rang or
         * was stopped does not ring again). False when it was not started.
         */
        fun start(context: Context, eventId: String, outlet: String, appliance: String, endsAt: Long, test: Boolean = false): Boolean {
            if (endsAt <= System.currentTimeMillis()) return false
            if (!test && AlarmStore.isDone(context, eventId)) return false
            val intent = Intent(context, CountdownAlarmService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_EVENT, eventId)
                .putExtra(EXTRA_OUTLET, outlet)
                .putExtra(EXTRA_APPLIANCE, appliance)
                .putExtra(EXTRA_ENDS_AT, endsAt)
                .putExtra(EXTRA_TEST, test)
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (e: Exception) {
                // Android 12+: a foreground service may not start from the background here.
                Log.w(TAG, "Countdown service not allowed to start: $e")
                postInsistent(context, eventId, outlet, appliance, endsAt)
                true
            }
        }

        /** Stops [eventId]'s or [outlet]'s alarm (both null: all of them). */
        fun stop(context: Context, eventId: String?, outlet: String?) {
            if (eventId != null) AlarmStore.markDone(context, eventId)
            // The fallback notification, if that was used.
            val nm = context.getSystemService(NotificationManager::class.java)
            if (outlet != null) {
                nm.cancel(notificationId(outlet))
            } else if (eventId == null) {
                nm.cancel(notificationId("A"))
                nm.cancel(notificationId("B"))
            }
            if (!running) return
            val intent = Intent(context, CountdownAlarmService::class.java)
                .setAction(if (eventId == null && outlet == null) ACTION_STOP_ALL else ACTION_STOP)
                .putExtra(EXTRA_EVENT, eventId)
                .putExtra(EXTRA_OUTLET, outlet)
            try {
                context.startService(intent)
            } catch (_: Exception) {
            }
        }

        /** Whether the service is running in this process (set in onCreate/onDestroy). */
        @Volatile
        var running = false
            private set
    }

    override fun onCreate() {
        super.onCreate()
        running = true
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app away keeps the alarm: it still ends at the cut-off.
        super.onTaskRemoved(rootIntent)
    }
}
