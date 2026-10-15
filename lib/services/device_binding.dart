import 'package:shared_preferences/shared_preferences.dart';

/// Enforces the 1 app = 1 gadget rule. The app only ever talks to
/// [gadgetId]; the binding is persisted so it survives restarts, and any
/// other stored value (for example from an older build) is replaced.
class DeviceBinding {
  static const gadgetId = 'gadget-1';
  static const prefsKey = 'boundDeviceId';

  static String get statusPath => 'devices/$gadgetId/status';
  static String get wifiConfigPath => 'devices/$gadgetId/wifiConfig';

  /// Call once at startup before any database access.
  static Future<String> ensureBound([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    if (store.getString(prefsKey) != gadgetId) {
      await store.setString(prefsKey, gadgetId);
    }
    return gadgetId;
  }
}
