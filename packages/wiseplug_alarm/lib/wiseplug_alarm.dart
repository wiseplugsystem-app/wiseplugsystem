/// WisePlug's own Android countdown alarm (see README.md). Every call is
/// safe on other platforms and in tests: without the Android side it does
/// nothing and returns the "not available" value.
library;

import 'package:flutter/services.dart';

class WiseplugAlarm {
  static const _channel = MethodChannel('wiseplug/alarm');

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Rings [eventId] on [outlet] ('A'/'B') until [endsAt] (the plug's
  /// cut-off). An event rings once. True when the alarm was started.
  static Future<bool> start({
    required String eventId,
    required String outlet,
    required String appliance,
    required DateTime endsAt,
    bool test = false,
  }) async =>
      await _call<bool>('start', {
        'eventId': eventId,
        'outlet': outlet,
        'appliance': appliance,
        'endsAt': endsAt.millisecondsSinceEpoch,
        'test': test,
      }) ??
      false;

  /// Stops [eventId]'s or [outlet]'s alarm; both null: every alarm.
  static Future<void> stop({String? eventId, String? outlet}) =>
      _call<void>('stop', {'eventId': eventId, 'outlet': outlet});

  /// The backup alarm for [outlet] at [deadline] (the run [sessionId]):
  /// it checks Firebase [path] before ringing.
  static Future<void> scheduleBackup({
    required String outlet,
    required DateTime deadline,
    required String sessionId,
    required String appliance,
    required String path,
    required String databaseUrl,
  }) => _call<void>('scheduleBackup', {
    'outlet': outlet,
    'deadline': deadline.millisecondsSinceEpoch,
    'sessionId': sessionId,
    'appliance': appliance,
    'path': path,
    'databaseUrl': databaseUrl,
  });

  static Future<void> cancelBackup(String outlet) =>
      _call<void>('cancelBackup', {'outlet': outlet});

  /// The phone's alarm settings (null when not on Android).
  static Future<Map<String, Object?>?> status() async {
    final m = await _call<Map<Object?, Object?>>('status');
    return m == null ? null : {for (final e in m.entries) '${e.key}': e.value};
  }

  /// Opens a settings page ('notifications', 'battery', 'exactAlarms',
  /// 'fullScreen', 'sound', 'dnd', 'autostart', 'brandBattery',
  /// 'brandPermissions', 'appInfo'); falls back to the app's settings.
  static Future<bool> open(String page) async =>
      await _call<bool>('open', {'page': page}) ?? false;

  static Future<bool> raiseAlarmVolume() async =>
      await _call<bool>('raiseAlarmVolume') ?? false;

  static Future<bool> getFlag(String name) async =>
      await _call<bool>('getFlag', {'name': name}) ?? false;

  static Future<void> setFlag(String name, bool value) =>
      _call<void>('setFlag', {'name': name, 'value': value});
}
