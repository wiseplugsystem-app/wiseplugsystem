import 'package:shared_preferences/shared_preferences.dart';

/// Enforces the 1 app = 1 gadget rule. The app only ever talks to
/// [gadgetId]; the binding is persisted so it survives restarts, and any
/// other stored value (for example from an older build) is replaced.
class DeviceBinding {
  static const gadgetId = 'gadget-1';
  static const prefsKey = 'boundDeviceId';

  /// What people see, like a product label: product name, model and unit
  /// code. The unit code comes from [gadgetId] (gadget-1 -> WP-001), so the
  /// next plug (gadget-2) shows WP-002. Change the names here only.
  static const productName = 'WisePlug';
  static const modelCode = 'WP-2';
  static const modelText = 'Model $modelCode (2 outlets)';
  static String get unitCode =>
      'WP-${gadgetId.split('-').last.padLeft(3, '0')}';
  static String get displayName => '$productName $unitCode';

  static String get statusPath => 'devices/$gadgetId/status';
  static String get wifiConfigPath => 'devices/$gadgetId/wifiConfig';
  static String get liveTelemetryPath => 'devices/$gadgetId/live_telemetry';

  /// Call once at startup before any database access.
  static Future<String> ensureBound([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    if (store.getString(prefsKey) != gadgetId) {
      await store.setString(prefsKey, gadgetId);
    }
    return gadgetId;
  }
}
