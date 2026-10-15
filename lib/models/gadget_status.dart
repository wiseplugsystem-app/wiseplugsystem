import 'esp32_data.dart';

/// Device-level summary published by the ESP32 at devices/gadget-1/status.
class GadgetStatus {
  /// The ESP32 cannot write "Offline" when it loses power, so a status that
  /// has not been refreshed within this window is treated as offline.
  static const staleAfter = Duration(seconds: 30);

  final bool outletA, outletB, safetyTriggered;
  final double powerDraw;
  final String connectionStatus;

  /// Seconds before the earliest safety deadline; null when nothing is
  /// running and no limit applies.
  final double? remainingLimit;
  final DateTime? lastSeen;

  const GadgetStatus({
    this.outletA = false,
    this.outletB = false,
    this.powerDraw = 0,
    this.connectionStatus = 'Offline',
    this.remainingLimit,
    this.safetyTriggered = false,
    this.lastSeen,
  });

  factory GadgetStatus.fromMap(Map<String, dynamic> map) => GadgetStatus(
    outletA: map['outletA'] == true,
    outletB: map['outletB'] == true,
    powerDraw: sensorNumber(map['powerDraw']) ?? 0,
    connectionStatus: map['connectionStatus']?.toString() ?? 'Offline',
    remainingLimit: sensorNumber(map['remainingLimit']),
    safetyTriggered: map['safetyTriggered'] == true,
    lastSeen: deviceTime(map['lastSeen']),
  );

  bool isOnline(DateTime now) =>
      connectionStatus == 'Online' &&
      lastSeen != null &&
      now.difference(lastSeen!) <= staleAfter;

  bool outlet(String key) => key == 'A' ? outletA : outletB;

  int get activeOutlets => (outletA ? 1 : 0) + (outletB ? 1 : 0);

  /// The only conditions that may raise the safety alert.
  bool get needsSafetyAlert =>
      safetyTriggered || (remainingLimit != null && remainingLimit! <= 0);
}
