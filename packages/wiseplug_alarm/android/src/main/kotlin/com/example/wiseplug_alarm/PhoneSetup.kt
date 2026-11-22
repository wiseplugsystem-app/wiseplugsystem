package com.example.wiseplug_alarm

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat

/**
 * What the countdown alarm needs from the phone, and the settings pages that
 * switch it on. Android lets an app READ only some of these; brand pages
 * (Auto-start, background pop-ups…) can only be opened, never read or changed.
 */
internal object PhoneSetup {
    fun status(context: Context): Map<String, Any?> {
        val nm = context.getSystemService(NotificationManager::class.java)
        val pm = context.getSystemService(PowerManager::class.java)
        val am = context.getSystemService(AudioManager::class.java)
        val activity = context.getSystemService(ActivityManager::class.java)
        CountdownAlarmService.createChannels(context)
        val channelOn = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            (nm.getNotificationChannel(CountdownAlarmService.CHANNEL)?.importance ?: NotificationManager.IMPORTANCE_HIGH) !=
            NotificationManager.IMPORTANCE_NONE
        // Do Not Disturb: "Total silence" blocks alarms; "Priority only" blocks
        // them only if its policy does not allow alarms.
        val dndBlocksAlarms = when (nm.currentInterruptionFilter) {
            NotificationManager.INTERRUPTION_FILTER_NONE -> true
            NotificationManager.INTERRUPTION_FILTER_PRIORITY ->
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                    (nm.notificationPolicy.priorityCategories and NotificationManager.Policy.PRIORITY_CATEGORY_ALARMS) == 0
            else -> false
        }
        return mapOf(
            "manufacturer" to Build.MANUFACTURER.lowercase(),
            "brand" to Build.BRAND.lowercase(),
            "model" to Build.MODEL,
            "sdk" to Build.VERSION.SDK_INT,
            "notifications" to (NotificationManagerCompat.from(context).areNotificationsEnabled() && channelOn),
            "batteryUnrestricted" to pm.isIgnoringBatteryOptimizations(context.packageName),
            "backgroundRestricted" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && activity.isBackgroundRestricted),
            "powerSaveMode" to pm.isPowerSaveMode,
            "exactAlarms" to CountdownBackupReceiver.canScheduleExact(context),
            "fullScreen" to (Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent()),
            "alarmVolume" to am.getStreamVolume(AudioManager.STREAM_ALARM),
            "alarmVolumeMax" to am.getStreamMaxVolume(AudioManager.STREAM_ALARM),
            "dndBlocksAlarms" to dndBlocksAlarms,
        )
    }

    /** Alarm volume to 80 % (allowed without a permission, unless Do Not Disturb forbids it). */
    fun raiseAlarmVolume(context: Context): Boolean = try {
        val am = context.getSystemService(AudioManager::class.java)
        val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
        am.setStreamVolume(AudioManager.STREAM_ALARM, (max * 0.8).toInt().coerceAtLeast(1), AudioManager.FLAG_SHOW_UI)
        true
    } catch (_: Exception) {
        false
    }

    /**
     * Opens settings page [page]; tries each brand page in turn and falls back
     * to the app's own settings page. True when a page opened.
     */
    fun open(context: Context, page: String): Boolean {
        val pkg = context.packageName
        val app = Uri.parse("package:$pkg")
        val candidates = mutableListOf<Intent>()
        when (page) {
            "notifications" -> candidates += Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, pkg)
            "battery" -> {
                // "Ignore battery optimization": Android's own question.
                candidates += Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, app)
                candidates += Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            }
            "exactAlarms" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                candidates += Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, app)
            }
            "fullScreen" -> if (Build.VERSION.SDK_INT >= 34) {
                candidates += Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, app)
            }
            "sound" -> candidates += Intent(Settings.ACTION_SOUND_SETTINGS)
            "dnd" -> candidates += Intent(Settings.ACTION_ZEN_MODE_PRIORITY_SETTINGS)
            "autostart" -> candidates += autostartPages(pkg)
            "brandBattery" -> candidates += brandBatteryPages(pkg)
            "brandPermissions" -> candidates += brandPermissionPages(pkg)
            "appInfo" -> {}
        }
        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, app)
        for (intent in candidates) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
                return true
            } catch (_: Exception) {
                // Not on this phone: try the next page.
            }
        }
        return false
    }

    private fun component(pkg: String, cls: String) = Intent().setComponent(ComponentName(pkg, cls))

    /** Auto-start / "allow background activity" pages of each brand. */
    private fun autostartPages(pkg: String) = listOf(
        // Xiaomi, Redmi, POCO (MIUI / HyperOS)
        component("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        // Oppo, Realme, OnePlus (ColorOS / realme UI / OxygenOS 12+)
        component("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        component("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
        component("com.oplus.safecenter", "com.oplus.safecenter.startupapp.StartupAppListActivity"),
        component("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
        component("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
        // Vivo, iQOO (Funtouch / OriginOS)
        component("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
        component("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
        component("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
        // Huawei, Honor (EMUI / MagicOS)
        component("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        component("com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"),
        component("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        component("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        // Infinix, Tecno, itel (XOS / HiOS / itel OS: Phone Master)
        component("com.transsion.phonemaster", "com.cyin.himgr.autostart.AutoStartActivity"),
        // Asus
        component("com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"),
    )

    /** Each brand's own battery page for this app ("No restrictions"). */
    private fun brandBatteryPages(pkg: String) = listOf(
        // Samsung: Device care > Battery
        component("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
        component("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
        component("com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity"),
        // Xiaomi: battery saver for this app
        component("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
            .putExtra("package_name", pkg).putExtra("package_label", "WisePlug"),
        // Huawei / Honor: app launch
        component("com.huawei.systemmanager", "com.huawei.systemmanager.power.ui.HwPowerManagerActivity"),
        // Vivo: high background power use
        component("com.vivo.abe", "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"),
        // Oppo / Realme / OnePlus
        component("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"),
        // Transsion: Phone Master power saving
        component("com.transsion.phonemaster", "com.cyin.himgr.powermanager.views.activity.PowerManagerActivity"),
    )

    /** Xiaomi's "Other permissions" (lock screen, pop-ups in the background). */
    private fun brandPermissionPages(pkg: String) = listOf(
        Intent("miui.intent.action.APP_PERM_EDITOR")
            .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
            .putExtra("extra_pkgname", pkg),
        Intent("miui.intent.action.APP_PERM_EDITOR")
            .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.AppPermissionsEditorActivity")
            .putExtra("extra_pkgname", pkg),
    )
}
