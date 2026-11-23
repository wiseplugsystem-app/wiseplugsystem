package com.example.wiseplug_alarm

import android.app.Activity
import android.app.Application
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
import android.os.Bundle
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
 * Whether WisePlug is on the screen (one of its activities is started). The
 * countdown notification is shown only while it is NOT: with the app open,
 * the app's own pop-up handles the countdown.
 */
internal object AppVisibility {
    private var started = 0
    private var registered = false

    val visible get() = started > 0

    fun register(app: Application) {
        if (registered) return
        registered = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                started++
                if (started == 1) CountdownAlarmService.visibilityChanged()
            }

            override fun onActivityStopped(activity: Activity) {
                started = (started - 1).coerceAtLeast(0)
                if (started == 0) CountdownAlarmService.visibilityChanged()
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }
}

/**
 * The safety countdown alarm (the safe time is up; only that event):
 *  - the warning sound loops on the ALARM volume (silent or vibrate mode does
 *    not mute it), with vibration; it is the app's warning sound too;
 *  - while WisePlug is NOT on the screen (background, closed, locked): an
 *    ongoing notification counts down to the plug's cut-off, names the
 *    appliance and the outlet, and has one button, "Open WisePlug" (tapping
 *    the notification does the same). It cannot be swiped away or cleared;
 *    if Android 14+ lets the user dismiss it anyway, it is shown again at
 *    once. With WisePlug open, it is removed (the sound goes on);
 *  - it stops only when the warning is over: the plug's cut-off time, the
 *    outlet in Firebase no longer in its warning (the app's "Turn off now" /
 *    "Keep it on", or the appliance is off), the cut-off push, or the app
 *    saying so on the screen. Opening the app, its button, locking the phone
 *    or closing the app do not stop it.
 * Outlets A and B have one alarm each; one event rings once (AlarmStore). If
 * Android refuses to start the service, a notification on a sound channel
 * with the "insistent" flag repeats the sound instead ([postInsistent]).
 */
class CountdownAlarmService : Service() {
    private class Alarm(
        val eventId: String,
        val appliance: String,
        val endsAt: Long,
        val path: String,
        val databaseUrl: String,
    ) {
        /** The outlet was seen in its warning in Firebase. */
        var seenWarning = false
        var stopWatching: (() -> Unit)? = null
    }

    private val alarms = linkedMapOf<String, Alarm>() // by outlet letter
    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var vibrating = false

    /** The service is in the foreground (its notification is showing). */
    private var isForeground = false

    /** Events whose notification already filled the lock screen once. */
    private val fullScreenShown = mutableSetOf<String>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Started with startForegroundService(): Android needs startForeground() now.
        if (intent?.getBooleanExtra(EXTRA_FG, false) == true && !isForeground) promote(intent)
        when (intent?.action) {
            ACTION_START -> start(intent)
            ACTION_STOP -> stop(intent.getStringExtra(EXTRA_EVENT), intent.getStringExtra(EXTRA_OUTLET))
            ACTION_STOP_ALL -> stopAll()
            else -> if (alarms.isEmpty()) finish()
        }
        return START_NOT_STICKY
    }

    /** The first startForeground(), with the notification of the alarm being started. */
    private fun promote(intent: Intent) {
        val outlet = intent.getStringExtra(EXTRA_OUTLET) ?: "A"
        val eventId = intent.getStringExtra(EXTRA_EVENT) ?: ""
        val n = buildNotification(
            this, outlet, intent.getStringExtra(EXTRA_APPLIANCE) ?: "An appliance",
            intent.getLongExtra(EXTRA_ENDS_AT, 0L), eventId, CHANNEL, fullScreenShown.add(eventId),
        )
        foreground(outlet, n)
    }

    private fun foreground(outlet: String, n: Notification): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(notificationId(outlet), n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(notificationId(outlet), n)
        }
        isForeground = true
        true
    } catch (e: Exception) {
        Log.w(TAG, "startForeground refused: $e")
        false
    }

    private fun start(intent: Intent) {
        val eventId = intent.getStringExtra(EXTRA_EVENT) ?: return finishIfIdle()
        val outlet = intent.getStringExtra(EXTRA_OUTLET) ?: "A"
        val endsAt = intent.getLongExtra(EXTRA_ENDS_AT, 0L)
        if (endsAt <= System.currentTimeMillis() || AlarmStore.isDone(this, eventId)) return finishIfIdle()
        if (alarms[outlet]?.eventId == eventId) return // already ringing for this event
        alarms[outlet]?.stopWatching?.invoke()
        val a = Alarm(
            eventId,
            intent.getStringExtra(EXTRA_APPLIANCE) ?: "An appliance",
            endsAt,
            intent.getStringExtra(EXTRA_PATH) ?: "",
            intent.getStringExtra(EXTRA_DATABASE_URL) ?: "",
        )
        alarms[outlet] = a
        // The push's own notification (same event) is replaced by this one.
        getSystemService(NotificationManager::class.java).cancel(eventId, 0)
        handler.postDelayed({ expire(outlet, eventId) }, endsAt - System.currentTimeMillis())
        watch(outlet, a)
        play()
        showOrHide()
    }

    /**
     * WisePlug on the screen: no notification (the pop-up handles it, the
     * sound goes on). Not on the screen: every alarm's notification.
     */
    private fun showOrHide() {
        val nm = getSystemService(NotificationManager::class.java)
        if (alarms.isEmpty()) return
        if (AppVisibility.visible) {
            if (isForeground) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                isForeground = false
            }
            for (o in listOf("A", "B")) nm.cancel(notificationId(o))
            return
        }
        var first = true
        for ((o, a) in alarms) {
            // The lock screen is filled once per event, not each time the app is left.
            val full = fullScreenShown.add(a.eventId)
            val n = buildNotification(this, o, a.appliance, a.endsAt, a.eventId, CHANNEL, full)
            if (first) {
                first = false
                if (foreground(o, n)) continue
            }
            try {
                nm.notify(notificationId(o), n)
            } catch (e: SecurityException) {
                Log.w(TAG, "Notifications not allowed: $e")
            }
        }
    }

    /**
     * The outlet's live data in Firebase: the alarm stops when the outlet is
     * no longer in its warning (after it was seen in it: "Keep it on", or
     * turned off), or when it is off or locked out. Old data (the plug is
     * offline) never stops it.
     */
    private fun watch(outlet: String, a: Alarm) {
        if (a.path.isEmpty()) return
        try {
            val db = if (a.databaseUrl.isNotEmpty()) {
                com.google.firebase.database.FirebaseDatabase.getInstance(a.databaseUrl)
            } else {
                com.google.firebase.database.FirebaseDatabase.getInstance()
            }
            val ref = db.getReference(a.path)
            val listener = object : com.google.firebase.database.ValueEventListener {
                override fun onDataChange(snapshot: com.google.firebase.database.DataSnapshot) {
                    val m = snapshot.value as? Map<*, *> ?: return
                    handler.post { check(outlet, a, m) }
                }

                override fun onCancelled(error: com.google.firebase.database.DatabaseError) {
                    Log.w(TAG, "Outlet watch cancelled: ${error.message}")
                }
            }
            ref.addValueEventListener(listener)
            a.stopWatching = { ref.removeEventListener(listener) }
        } catch (e: Throwable) {
            Log.w(TAG, "Could not watch the outlet: $e")
        }
    }

    private fun check(outlet: String, a: Alarm, m: Map<*, *>) {
        if (alarms[outlet] !== a) return
        val state = m["currentState"]?.toString() ?: ""
        if (state == "WARNING") {
            a.seenWarning = true
            return
        }
        val updated = (m["last_updated_ms"] as? Number)?.toLong() ?: 0L
        val age = System.currentTimeMillis() - updated
        if (updated <= 0L || age !in -10_000L..30_000L) return // the plug is not reporting
        if (state == "DISABLED" || m["lockedOut"] == true || a.seenWarning) remove(outlet)
    }

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
        a.stopWatching?.invoke()
        AlarmStore.markDone(this, a.eventId)
        getSystemService(NotificationManager::class.java).cancel(notificationId(outlet))
        if (alarms.isEmpty()) finish() else showOrHide()
    }

    private fun finishIfIdle() {
        if (alarms.isEmpty()) finish()
    }

    private fun finish() {
        handler.removeCallbacksAndMessages(null)
        alarms.values.forEach { it.stopWatching?.invoke() }
        silence()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        isForeground = false
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

    private fun vibrator(): Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        getSystemService(VibratorManager::class.java)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    private fun vibrate() {
        val vibrator = vibrator() ?: return
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
            vibrator()?.cancel()
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app away keeps the alarm: it still ends at the cut-off.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        if (current === this) current = null
        handler.removeCallbacksAndMessages(null)
        alarms.values.forEach { it.stopWatching?.invoke() }
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
        const val EXTRA_PATH = "path"
        const val EXTRA_DATABASE_URL = "databaseUrl"

        /** Started with startForegroundService() (WisePlug not on the screen). */
        private const val EXTRA_FG = "foreground"

        /** Set on the intent that opens the app from the alarm (lock screen). */
        const val EXTRA_OPEN_OUTLET = "wiseplug_alarm_outlet"

        /** The countdown notification: silent itself, the service plays the sound. */
        const val CHANNEL = "wiseplug_countdown"

        /** The fallback notification: it plays the sound itself, repeated. */
        const val SOUND_CHANNEL = "wiseplug_countdown_sound"

        fun notificationId(outlet: String) = if (outlet == "B") 7102 else 7101

        @Volatile
        private var current: CountdownAlarmService? = null

        /** Whether the service is running in this process. */
        @Volatile
        var running = false
            private set

        /** WisePlug came onto, or left, the screen: show or hide the notification. */
        fun visibilityChanged() {
            val s = current ?: return
            s.handler.post { s.showOrHide() }
        }

        /** The notification was dismissed (Android 14+ allows it): show it again. */
        fun repost() = visibilityChanged()

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

        /** Dismissed anyway (Android 14+): the receiver shows it again. */
        private fun repostIntent(context: Context, outlet: String, eventId: String, appliance: String, endsAt: Long, fallback: Boolean) =
            PendingIntent.getBroadcast(
                context,
                notificationId(outlet) + if (fallback) 40 else 20,
                Intent(context, CountdownBackupReceiver::class.java)
                    .setAction(CountdownBackupReceiver.ACTION_REPOST)
                    .putExtra(EXTRA_EVENT, eventId)
                    .putExtra(EXTRA_OUTLET, outlet)
                    .putExtra(EXTRA_APPLIANCE, appliance)
                    .putExtra(EXTRA_ENDS_AT, endsAt)
                    .putExtra(CountdownBackupReceiver.EXTRA_FALLBACK, fallback),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        fun buildNotification(
            context: Context,
            outlet: String,
            appliance: String,
            endsAt: Long,
            eventId: String,
            channel: String,
            fullScreen: Boolean,
        ): Notification {
            createChannels(context)
            val open = openIntent(context, outlet)
            val at = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(endsAt))
            val title = "Safe time is up: $appliance"
            val text = "Outlet $outlet turns off at $at. Open WisePlug to keep it on or turn it off."
            val builder = NotificationCompat.Builder(context, channel)
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
                // Not swipeable, not removed by "Clear all", not closed by a tap.
                .setOngoing(true)
                .setAutoCancel(false)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(open)
                .setDeleteIntent(repostIntent(context, outlet, eventId, appliance, endsAt, channel == SOUND_CHANNEL))
                .addAction(0, "Open WisePlug", open)
            if (fullScreen) builder.setFullScreenIntent(open, true)
            return builder.build().apply { flags = flags or Notification.FLAG_NO_CLEAR or Notification.FLAG_ONGOING_EVENT }
        }

        /** Fallback: a notification that repeats its own sound ("insistent") until the cut-off. */
        fun postInsistent(context: Context, eventId: String, outlet: String, appliance: String, endsAt: Long, fullScreen: Boolean = true) {
            if (endsAt <= System.currentTimeMillis() || AlarmStore.isDone(context, eventId)) return
            val n = buildNotification(context, outlet, appliance, endsAt, eventId, SOUND_CHANNEL, fullScreen)
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
         * was stopped does not ring again). [path] / [databaseUrl]: the
         * outlet's live data in Firebase, watched to stop it. False when it
         * was not started.
         */
        fun start(
            context: Context,
            eventId: String,
            outlet: String,
            appliance: String,
            endsAt: Long,
            path: String = "",
            databaseUrl: String = "",
        ): Boolean {
            if (endsAt <= System.currentTimeMillis()) return false
            if (AlarmStore.isDone(context, eventId)) return false
            val visible = AppVisibility.visible
            val intent = Intent(context, CountdownAlarmService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_EVENT, eventId)
                .putExtra(EXTRA_OUTLET, outlet)
                .putExtra(EXTRA_APPLIANCE, appliance)
                .putExtra(EXTRA_ENDS_AT, endsAt)
                .putExtra(EXTRA_PATH, path)
                .putExtra(EXTRA_DATABASE_URL, databaseUrl)
                .putExtra(EXTRA_FG, !visible)
            return try {
                // On the screen: a plain service (no notification); otherwise
                // a foreground service with its notification.
                if (visible) context.startService(intent) else ContextCompat.startForegroundService(context, intent)
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
            val s = current ?: return
            s.handler.post {
                if (eventId == null && outlet == null) s.stopAll() else s.stop(eventId, outlet)
            }
        }
    }
}
