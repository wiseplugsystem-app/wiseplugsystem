import 'esp32_data.dart';

enum ActivityCategory { safety, newAppliance, appliance, power }

/// One entry of the persistent history the ESP32 writes to activity_log.
class ActivityEvent {
  final String id, type, outlet, profileID, detail;
  final DateTime? time;

  ActivityEvent.fromMap(this.id, Map<String, dynamic> map)
    : type = map['type']?.toString() ?? '',
      outlet = map['outlet']?.toString() ?? '',
      profileID = map['profileID']?.toString() ?? '',
      detail = map['detail']?.toString() ?? '',
      time = deviceTime(map['time']);

  ActivityCategory get category => switch (type) {
    'SAFETY_WARNING' ||
    'LOCKED_OUT' ||
    'SAFETY_RESET' ||
    'OVERRIDE' => ActivityCategory.safety,
    'NEW_APPLIANCE' => ActivityCategory.newAppliance,
    'APPLIANCE_ON' ||
    'APPLIANCE_OFF' ||
    'APPLIANCE_DELETED' => ActivityCategory.appliance,
    _ => ActivityCategory.power,
  };

  /// Human-readable summary; [name] is the registered appliance name, if any.
  String title(String? name) {
    final appliance = name ?? 'An unrecognized appliance';
    final how = switch (detail) {
      'app' => ' from the app',
      'button' => ' with its button',
      _ => '',
    };
    return switch (type) {
      'APPLIANCE_ON' => '$appliance turned on',
      'APPLIANCE_OFF' => '$appliance turned off',
      'NEW_APPLIANCE' => 'New appliance detected — tap Profiles to register it',
      'SAFETY_WARNING' =>
        detail == 'SENSOR_UNAVAILABLE'
            ? 'Power meter stopped responding'
            : 'Safety limit reached${name == null ? '' : ' — $name'}',
      'LOCKED_OUT' => 'Outlet $outlet locked, power cut',
      'SAFETY_RESET' => 'Safety reset, outlet $outlet back on',
      'OVERRIDE' => 'Runtime extended${name == null ? '' : ' for $name'}',
      'OUTLET_ON' => 'Outlet $outlet switched on$how',
      'OUTLET_OFF' => 'Outlet $outlet switched off$how',
      'APPLIANCE_DELETED' => 'Appliance deleted',
      _ => type,
    };
  }
}

List<ActivityEvent> parseActivity(Object? value) =>
    [
      for (final entry in databaseMap(value).entries)
        if (entry.value is Map)
          ActivityEvent.fromMap(entry.key, databaseMap(entry.value)),
    ]..sort(
      (a, b) => (b.time?.millisecondsSinceEpoch ?? 0).compareTo(
        a.time?.millisecondsSinceEpoch ?? 0,
      ),
    );

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Oct 16, 2:30 PM" in local time.
String formatEventTime(DateTime? time) {
  if (time == null) return 'Time unknown';
  final t = time.toLocal();
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  return '${_months[t.month - 1]} ${t.day}, $hour:$minute ${t.hour < 12 ? 'AM' : 'PM'}';
}
