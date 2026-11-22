package com.example.wiseplug_alarm

import android.content.Context
import org.json.JSONObject

/**
 * What the countdown alarm remembers on the phone:
 *  - the safety events that already rang (or were stopped), so one event
 *    never rings twice, whichever way it arrives (app open, push, backup);
 *  - the backup alarm of each outlet (its deadline and run);
 *  - the phone-setup steps the user ticked ("I allowed Auto-start").
 */
internal object AlarmStore {
    private const val PREFS = "wiseplug_alarm"
    private const val DONE = "done_events"
    private const val MAX_DONE = 100

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Event ids that rang or were stopped, newest last. */
    private fun doneList(context: Context): MutableList<String> =
        (prefs(context).getString(DONE, "") ?: "").split('\n').filter { it.isNotEmpty() }.toMutableList()

    fun isDone(context: Context, eventId: String) = doneList(context).contains(eventId)

    fun markDone(context: Context, eventId: String) {
        val list = doneList(context)
        if (list.contains(eventId)) return
        list.add(eventId)
        while (list.size > MAX_DONE) list.removeAt(0)
        prefs(context).edit().putString(DONE, list.joinToString("\n")).apply()
    }

    fun saveBackup(context: Context, outlet: String, backup: JSONObject) =
        prefs(context).edit().putString("backup_$outlet", backup.toString()).apply()

    fun backup(context: Context, outlet: String): JSONObject? =
        prefs(context).getString("backup_$outlet", null)?.let {
            try {
                JSONObject(it)
            } catch (_: Exception) {
                null
            }
        }

    fun clearBackup(context: Context, outlet: String) =
        prefs(context).edit().remove("backup_$outlet").apply()

    fun flag(context: Context, name: String) = prefs(context).getBoolean("flag_$name", false)

    fun setFlag(context: Context, name: String, value: Boolean) =
        prefs(context).edit().putBoolean("flag_$name", value).apply()
}
