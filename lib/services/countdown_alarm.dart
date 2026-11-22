import 'package:flutter/foundation.dart';
import 'package:wiseplug_alarm/wiseplug_alarm.dart';

import '../models/esp32_data.dart';
import 'esp32_service.dart';

/// The safety countdown alarm on Android phones (packages/wiseplug_alarm):
/// the warning sound loops on the ALARM volume and a notification counts down
/// to the plug's real cut-off, whether the app is open, in the background,
/// closed or the phone is locked. Started three ways, one sound per event:
///  1. app open: the safety pop-up ([startForReadings]);
///  2. app closed: the RUNTIME_WARNING push ([startFromPush], main.dart);
///  3. backup: an exact alarm at the outlet's deadline ([syncBackups]), for
///     when no push arrives (it checks the outlet in Firebase first).
/// The web (and every other platform) keeps its own sound: nothing here runs.
class CountdownAlarm {
  CountdownAlarm._();

  /// Only the Android app has the native alarm.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The plug's warning, deadline to cut-off (safety_state.h WARNING_MS).
  static const warning = Duration(milliseconds: 63000);

  /// 'outlet_1' / 'outlet_2' (Supabase, pushes) -> 'A' / 'B'.
  static String letter(String? outlet) =>
      outlet == 'outlet_2' || outlet == 'B' ? 'B' : 'A';

  /// The plug's cut-off for a warning [r]: its countdownExpiry, else the
  /// seconds it has left.
  static DateTime endsAt(OutletReading r, DateTime now) =>
      r.countdownExpiry ?? now.add(Duration(seconds: r.secondsRemaining(now)));

  /// App open: rings every outlet whose safe time is up (each event once).
  /// False when the native alarm is not available.
  static Future<bool> startForReadings(Iterable<OutletReading> warnings) async {
    if (!supported) return false;
    final now = DateTime.now();
    var any = false;
    for (final r in warnings) {
      if (!r.isWarning || r.alertID.isEmpty) continue;
      final started = await WiseplugAlarm.start(
        eventId: r.alertID,
        outlet: letter(r.outlet),
        appliance: r.appliance,
        endsAt: endsAt(r, now),
      );
      // Already rang or was stopped counts as handled too: no second sound.
      any = started || any || await _available();
    }
    return any;
  }

  /// The app's warning sound is playing on this alarm (SafetyAlarmManager).
  static bool ringing = false;

  /// While it rings: an outlet that goes into warning later rings too (each
  /// outlet has its own alarm).
  static Future<void> ringNewWarnings(Iterable<OutletReading> warnings) async {
    if (ringing) await startForReadings(warnings);
  }

  static bool? _isAvailable;
  static Future<bool> _available() async =>
      _isAvailable ??= (await WiseplugAlarm.status()) != null;

  /// Every countdown alarm stops (the warning is over, answered or silenced).
  static Future<void> stopAll() async {
    if (supported) await WiseplugAlarm.stop();
  }

  /// App closed: the plug's RUNTIME_WARNING push rings until its cut-off
  /// (data endsAt, else occurredAt + the warning). False when it could not
  /// (an older server, a late push, or not Android): the old sound plays.
  static Future<bool> startFromPush(Map<String, dynamic> data) async {
    if (!supported || data['type'] != 'RUNTIME_WARNING') return false;
    final occurred = int.tryParse('${data['occurredAt'] ?? ''}');
    final ends =
        int.tryParse('${data['endsAt'] ?? ''}') ??
        (occurred == null ? null : occurred + warning.inMilliseconds);
    final eventId = '${data['eventId'] ?? ''}';
    if (ends == null || eventId.isEmpty) return false;
    final at = DateTime.fromMillisecondsSinceEpoch(ends);
    if (!at.isAfter(DateTime.now().add(const Duration(seconds: 2)))) {
      return false;
    }
    final name = '${data['applianceName'] ?? ''}';
    return WiseplugAlarm.start(
      eventId: eventId,
      outlet: letter('${data['outlet']}'),
      appliance: name.isEmpty ? 'An appliance' : name,
      endsAt: at,
    );
  }

  /// The power was cut (LOCKED_OUT push): that outlet's alarm stops.
  static Future<void> stopFromPush(Map<String, dynamic> data) async {
    if (!supported || data['type'] != 'LOCKED_OUT') return;
    await WiseplugAlarm.stop(outlet: letter('${data['outlet']}'));
  }

  /// The backup alarm each outlet has now ("session|deadline"), so the
  /// native side is only called when it changes.
  static final _backups = <String, String>{};

  /// Keeps one backup alarm per running appliance, at its safety deadline.
  /// Fresh readings decide: running with a deadline ahead -> scheduled;
  /// off, finished or in its warning -> cancelled. A plug that stopped
  /// reporting keeps its alarm (that is when the backup matters).
  static Future<void> syncBackups(Map<String, OutletReading> readings) async {
    if (!supported) return;
    final now = DateTime.now();
    for (final r in readings.values) {
      final outlet = letter(r.outlet);
      if (!r.isFresh(now)) continue;
      final deadline = r.safetyDeadline;
      final running =
          r.isActive &&
          r.switchedOn &&
          !r.isWarning &&
          r.sessionID.isNotEmpty &&
          deadline != null &&
          deadline.isAfter(now);
      if (running) {
        final key = '${r.sessionID}|${deadline.millisecondsSinceEpoch}';
        if (_backups[outlet] == key) continue;
        _backups[outlet] = key;
        await WiseplugAlarm.scheduleBackup(
          outlet: outlet,
          deadline: deadline,
          sessionId: r.sessionID,
          appliance: r.appliance,
          path: 'telemetry_logs/outlet_$outlet',
          databaseUrl: Esp32Service.databaseUrl,
        );
      } else if (!r.isWarning && _backups[outlet] != '') {
        _backups[outlet] = '';
        await WiseplugAlarm.cancelBackup(outlet);
      }
    }
  }
}
