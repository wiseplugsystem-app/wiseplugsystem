package com.example.wiseplug_alarm

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The backup alarm. While the app is open and an appliance runs, the app
 * schedules an exact alarm at that outlet's safety deadline (+ a few seconds,
 * so the plug has reported its warning). If the warning push never arrives
 * (no internet on the plug or the phone), this still rings.
 *
 * Before ringing it reads the outlet in Firebase, so it does not ring for an
 * appliance that was already turned off or given more time:
 *  - the plug reports WARNING              -> ring (its own event id and cut-off);
 *  - fresh reading, same run, later deadline -> schedule again for the new one;
 *  - fresh reading, no warning               -> nothing (turned off / new run);
 *  - no fresh reading (plug or phone offline)-> ring: safety first, the plug
 *    cuts the power by itself anyway.
 */
class CountdownBackupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_FIRE -> {
                val outlet = intent.getStringExtra(CountdownAlarmService.EXTRA_OUTLET) ?: return
                val pending = goAsync()
                Thread {
                    try {
                        fire(context.applicationContext, outlet)
                    } catch (e: Exception) {
                        Log.w(TAG, "Backup alarm failed: $e")
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
            ACTION_REPOST -> {
                // The countdown notification was dismissed anyway (Android 14+
                // lets users swipe ongoing ones): shown again while it rings.
                if (intent.getBooleanExtra(EXTRA_FALLBACK, false)) {
                    CountdownAlarmService.postInsistent(
                        context,
                        intent.getStringExtra(CountdownAlarmService.EXTRA_EVENT) ?: return,
                        intent.getStringExtra(CountdownAlarmService.EXTRA_OUTLET) ?: "A",
                        intent.getStringExtra(CountdownAlarmService.EXTRA_APPLIANCE) ?: "An appliance",
                        intent.getLongExtra(CountdownAlarmService.EXTRA_ENDS_AT, 0L),
                        fullScreen = false,
                    )
                } else {
                    CountdownAlarmService.repost()
                }
            }
        }
    }

    private fun fire(context: Context, outlet: String) {
        val b = AlarmStore.backup(context, outlet) ?: return
        AlarmStore.clearBackup(context, outlet)
        val deadline = b.optLong("deadline")
        val session = b.optString("sessionId")
        val appliance = b.optString("appliance", "An appliance")
        val now = System.currentTimeMillis()
        val reading = readOutlet(b.optString("databaseUrl"), b.optString("path"))
        if (reading != null) {
            val state = reading["currentState"]?.toString() ?: ""
            val updated = number(reading["last_updated_ms"]) ?: 0L
            val fresh = updated > 0 && now - updated in -10_000L..30_000L
            val sameRun = (reading["sessionID"]?.toString() ?: "") == session
            if (state == "WARNING") {
                val eventId = reading["alertID"]?.toString()?.ifEmpty { null } ?: "backup_${session}_$outlet"
                val endsAt = number(reading["countdownExpiry"]) ?: (deadline + WARNING_MS)
                CountdownAlarmService.start(
                    context, eventId, outlet, reading["appliance"]?.toString() ?: appliance, endsAt,
                    b.optString("path"), b.optString("databaseUrl"),
                )
                return
            }
            if (fresh) {
                val newDeadline = number(reading["safetyDeadline"])
                if (sameRun && newDeadline != null && newDeadline > now && state != "DISABLED") {
                    b.put("deadline", newDeadline)
                    schedule(context, outlet, b)
                }
                return // turned off, given more time, or another run
            }
            if (!sameRun) return
        }
        // No answer, or the plug is offline: the plug still cuts off by itself,
        // so the phone warns.
        val endsAt = deadline + WARNING_MS
        if (endsAt > now) {
            CountdownAlarmService.start(
                context, "backup_${session}_$outlet", outlet, appliance, endsAt,
                b.optString("path"), b.optString("databaseUrl"),
            )
        }
    }

    /** The outlet's live data in Firebase (signed in as the app's user), or null. */
    private fun readOutlet(databaseUrl: String, path: String): Map<*, *>? {
        if (path.isEmpty()) return null
        return try {
            val db = if (databaseUrl.isNotEmpty()) {
                com.google.firebase.database.FirebaseDatabase.getInstance(databaseUrl)
            } else {
                com.google.firebase.database.FirebaseDatabase.getInstance()
            }
            val snapshot = com.google.android.gms.tasks.Tasks.await(db.getReference(path).get(), 8, TimeUnit.SECONDS)
            snapshot.value as? Map<*, *>
        } catch (e: Throwable) {
            Log.w(TAG, "Could not read the outlet: $e")
            null
        }
    }

    private fun number(v: Any?): Long? = when (v) {
        is Number -> v.toLong()
        is String -> v.toLongOrNull()
        else -> null
    }

    companion object {
        private const val TAG = "WisePlugAlarm"
        const val ACTION_FIRE = "com.example.wiseplug_alarm.BACKUP_FIRE"
        const val ACTION_REPOST = "com.example.wiseplug_alarm.REPOST"
        const val EXTRA_FALLBACK = "fallback"

        /** The plug's warning: 63 s from the deadline to the cut-off (safety_state.h WARNING_MS). */
        const val WARNING_MS = 63_000L

        /** Rings this long after the deadline, so the plug has reported its warning. */
        private const val AFTER_DEADLINE_MS = 4_000L

        private fun fireIntent(context: Context, outlet: String) = PendingIntent.getBroadcast(
            context,
            CountdownAlarmService.notificationId(outlet) + 30,
            Intent(context, CountdownBackupReceiver::class.java)
                .setAction(ACTION_FIRE)
                .putExtra(CountdownAlarmService.EXTRA_OUTLET, outlet),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        fun canScheduleExact(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

        /** Saves [backup] (path, deadline, sessionId, appliance, databaseUrl) and sets the alarm. */
        fun schedule(context: Context, outlet: String, backup: JSONObject) {
            AlarmStore.saveBackup(context, outlet, backup)
            val at = backup.optLong("deadline") + AFTER_DEADLINE_MS
            val am = context.getSystemService(AlarmManager::class.java)
            val pi = fireIntent(context, outlet)
            try {
                if (canScheduleExact(context)) {
                    // Alarm-clock alarms are the most reliable: Doze and most
                    // battery savers let them through on time.
                    val show = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                        PendingIntent.getActivity(context, 7199, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    }
                    am.setAlarmClock(AlarmManager.AlarmClockInfo(at, show), pi)
                } else {
                    // Not allowed exact alarms: Android may ring a little late.
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                }
            } catch (e: SecurityException) {
                Log.w(TAG, "Backup alarm not allowed: $e")
            }
        }

        fun cancel(context: Context, outlet: String) {
            AlarmStore.clearBackup(context, outlet)
            context.getSystemService(AlarmManager::class.java).cancel(fireIntent(context, outlet))
        }

        /** After a restart: the backup alarms still ahead are set again. */
        fun restoreAll(context: Context) {
            for (outlet in listOf("A", "B")) {
                val b = AlarmStore.backup(context, outlet) ?: continue
                if (b.optLong("deadline") + WARNING_MS > System.currentTimeMillis()) {
                    schedule(context, outlet, b)
                } else {
                    AlarmStore.clearBackup(context, outlet)
                }
            }
        }
    }
}

/** Sets the backup alarms again after the phone restarts or the app is updated. */
class CountdownBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CountdownBackupReceiver.restoreAll(context)
    }
}
