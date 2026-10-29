import 'esp32_data.dart';

/// The two hardware channels. Firmware outlet A is `outlet_1`, B is `outlet_2`.
enum OutletChannel {
  outlet1('outlet_1', 'A'),
  outlet2('outlet_2', 'B');

  const OutletChannel(this.key, this.firmwareOutlet);
  final String key;
  final String firmwareOutlet;

  String get label => this == outlet1 ? 'Outlet 1' : 'Outlet 2';
  static OutletChannel? fromKey(Object? key) =>
      values.where((c) => c.key == key).firstOrNull;
}

/// Same limits as the firmware's addLiveTelemetry(): below [noiseWatts]
/// nothing is running; a frequency outside [minHz]..[maxHz] is a bad read.
const noiseWatts = 0.5, minHz = 45.0, maxHz = 65.0;

double? _nonNegative(Object? v) {
  final n = sensorNumber(v);
  return n != null && n >= 0 ? n : null;
}

/// One outlet's live reading at `devices/gadget-1/live_telemetry/<outlet>`,
/// written by the ESP32 every 3 s. Parsing sanitizes again, so malformed or
/// implausible values never reach the UI: a meter that is not reporting is
/// [isValid] false with null values, never fake zeros.
class TelemetryReading {
  final String deviceId;
  final OutletChannel channel;
  final DateTime? timestamp; // UTC
  final bool relayOn;
  final String
  state; // IDLE | SAMPLING | ACTIVE | WARNING | LOCKED_OUT | DISABLED
  final String appliance;
  final bool isValid;
  final double? voltage, current, power, powerFactor, frequency;

  /// The meter's lifetime energy counter, in Wh.
  final double? energyWh;

  const TelemetryReading({
    required this.deviceId,
    required this.channel,
    required this.timestamp,
    required this.relayOn,
    required this.state,
    required this.appliance,
    required this.isValid,
    this.voltage,
    this.current,
    this.power,
    this.powerFactor,
    this.frequency,
    this.energyWh,
  });

  /// Older than 30 s: the plug stopped reporting (offline or powered off).
  bool isFresh(DateTime now) =>
      timestamp != null &&
      now.difference(timestamp!) <= const Duration(seconds: 30) &&
      now.difference(timestamp!) >= const Duration(seconds: -10);

  bool get isRunning => const ['SAMPLING', 'ACTIVE', 'WARNING'].contains(state);
  bool get needsAttention => state == 'WARNING' || state == 'LOCKED_OUT';

  factory TelemetryReading.fromMap(OutletChannel channel, Object? value) {
    final m = databaseMap(value);
    final ms = sensorNumber(m['timestamp_ms']);
    final voltage = _nonNegative(m['voltage_V']);
    var current = _nonNegative(m['current_A']);
    var power = _nonNegative(m['power_W']);
    var pf = _nonNegative(m['powerFactor']);
    final ok =
        m['status'] == 'OK' &&
        voltage != null &&
        voltage > 0 &&
        current != null &&
        power != null &&
        pf != null &&
        pf <= 1;
    if (ok && power < noiseWatts) power = current = pf = 0;
    final hz = sensorNumber(m['frequency_Hz']);
    return TelemetryReading(
      deviceId: m['deviceId']?.toString() ?? 'gadget-1',
      channel: channel,
      timestamp: ms != null && ms > 0
          ? DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true)
          : deviceTime(m['timestamp']),
      relayOn: m['relayOn'] == true,
      state: m['state']?.toString() ?? 'IDLE',
      appliance: m['appliance']?.toString() ?? 'None',
      isValid: ok,
      voltage: ok ? voltage : null,
      current: ok ? current : null,
      power: ok ? power : null,
      powerFactor: ok ? pf : null,
      frequency: ok && hz != null && hz >= minHz && hz <= maxHz ? hz : null,
      energyWh: ok ? _nonNegative(m['energy_Wh']) : null,
    );
  }

  /// The firmware's wire format; absent values are left out.
  Map<String, Object?> toMap() => {
    'deviceId': deviceId,
    'outlet': channel.key,
    'timestamp': timestamp?.toUtc().toIso8601String(),
    'timestamp_ms': timestamp?.millisecondsSinceEpoch ?? 0,
    'relayOn': relayOn,
    'state': state,
    'appliance': appliance,
    'status': isValid ? 'OK' : 'NO_SIGNAL',
    'voltage_V': ?voltage,
    'current_A': ?current,
    'power_W': ?power,
    'powerFactor': ?powerFactor,
    'frequency_Hz': ?frequency,
    'energy_Wh': ?energyWh,
  };
}

/// Both outlets' live readings (`devices/gadget-1/live_telemetry`).
class OutletTelemetry {
  final Map<OutletChannel, TelemetryReading> readings;
  const OutletTelemetry(this.readings);

  factory OutletTelemetry.fromMap(Object? value) {
    final m = databaseMap(value);
    return OutletTelemetry({
      for (final c in OutletChannel.values)
        if (m[c.key] is Map) c: TelemetryReading.fromMap(c, m[c.key]),
    });
  }

  TelemetryReading? operator [](OutletChannel c) => readings[c];

  /// Combined draw of the outlets with fresh, valid readings.
  double totalPower(DateTime now) => readings.values
      .where((r) => r.isValid && r.isFresh(now))
      .fold(0.0, (sum, r) => sum + r.power!);

  Map<String, Object?> toMap() => {
    for (final e in readings.entries) e.key.key: e.value.toMap(),
  };
}
