package com.example.wiseplug_alarm

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject

/**
 * The "wiseplug/alarm" channel, available in the app AND in the background
 * engine that runs the push handler (a plugin is registered in every engine).
 */
class WiseplugAlarmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.NewIntentListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "wiseplug/alarm")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> result.success(
                    CountdownAlarmService.start(
                        context,
                        call.argument<String>("eventId") ?: "",
                        call.argument<String>("outlet") ?: "A",
                        call.argument<String>("appliance") ?: "An appliance",
                        (call.argument<Number>("endsAt") ?: 0).toLong(),
                        call.argument<Boolean>("test") ?: false,
                    ),
                )
                "stop" -> {
                    CountdownAlarmService.stop(context, call.argument("eventId"), call.argument("outlet"))
                    result.success(null)
                }
                "scheduleBackup" -> {
                    val outlet = call.argument<String>("outlet") ?: "A"
                    CountdownBackupReceiver.schedule(
                        context,
                        outlet,
                        JSONObject()
                            .put("deadline", (call.argument<Number>("deadline") ?: 0).toLong())
                            .put("sessionId", call.argument<String>("sessionId") ?: "")
                            .put("appliance", call.argument<String>("appliance") ?: "An appliance")
                            .put("path", call.argument<String>("path") ?: "")
                            .put("databaseUrl", call.argument<String>("databaseUrl") ?: ""),
                    )
                    result.success(null)
                }
                "cancelBackup" -> {
                    CountdownBackupReceiver.cancel(context, call.argument<String>("outlet") ?: "A")
                    result.success(null)
                }
                "status" -> result.success(PhoneSetup.status(context))
                "open" -> result.success(PhoneSetup.open(activity ?: context, call.argument<String>("page") ?: "appInfo"))
                "raiseAlarmVolume" -> result.success(PhoneSetup.raiseAlarmVolume(context))
                "getFlag" -> result.success(AlarmStore.flag(context, call.argument<String>("name") ?: ""))
                "setFlag" -> {
                    AlarmStore.setFlag(context, call.argument<String>("name") ?: "", call.argument<Boolean>("value") ?: false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("alarm", e.toString(), null)
        }
    }

    // Opened from the alarm (full-screen alert or a tap): shown over the lock
    // screen and the screen turned on, for that launch only.
    private fun showOverLockScreen(intent: Intent?) {
        val a = activity ?: return
        if (intent?.hasExtra(CountdownAlarmService.EXTRA_OPEN_OUTLET) != true) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            a.setShowWhenLocked(true)
            a.setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            a.window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    override fun onNewIntent(intent: Intent): Boolean {
        showOverLockScreen(intent)
        return false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addOnNewIntentListener(this)
        showOverLockScreen(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        binding?.removeOnNewIntentListener(this)
        binding = null
        activity = null
    }
}
