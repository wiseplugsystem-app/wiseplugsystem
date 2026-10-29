import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/telemetry.dart';
import 'package:wiseplug/services/supabase_backend.dart';

final t0 = DateTime.utc(2026, 10, 22, 8);

Map<String, Object?> live({
  String status = 'OK',
  Object? voltage = 229.8,
  Object? current = 0.452,
  Object? power = 100.2,
  Object? pf = 0.98,
  Object? hz = 60.0,
}) => {
  'deviceId': 'gadget-1',
  'outlet': 'outlet_1',
  'timestamp': '2026-10-22T08:00:00Z',
  'timestamp_ms': t0.millisecondsSinceEpoch,
  'relayOn': true,
  'state': 'ACTIVE',
  'appliance': 'Rice Cooker',
  'status': status,
  'voltage_V': voltage,
  'current_A': current,
  'power_W': power,
  'powerFactor': pf,
  'frequency_Hz': hz,
  'energy_Wh': 12345.0,
};

void main() {
  group('live telemetry', () {
    test('parses a valid reading and round-trips the firmware format', () {
      final r = TelemetryReading.fromMap(OutletChannel.outlet1, live());
      expect(r.isValid, isTrue);
      expect(r.timestamp, t0);
      expect(r.isRunning, isTrue);
      expect(r.energyWh, 12345.0);
      final back = TelemetryReading.fromMap(OutletChannel.outlet1, r.toMap());
      expect(back.toMap(), r.toMap());
    });

    test('a meter that is not reporting has no values, not fake zeros', () {
      for (final bad in [
        live(status: 'NO_SIGNAL'),
        live(voltage: 0),
        live(current: -1),
        live(pf: 1.3),
        live(power: null),
      ]) {
        final r = TelemetryReading.fromMap(OutletChannel.outlet1, bad);
        expect(r.isValid, isFalse);
        expect(r.power, isNull);
        expect(r.toMap().containsKey('power_W'), isFalse);
      }
    });

    test('noise reads as 0 W and a bad frequency is dropped alone', () {
      final r = TelemetryReading.fromMap(
        OutletChannel.outlet1,
        live(power: 0.3, current: 0.01, hz: 120),
      );
      expect(r.power, 0);
      expect(r.current, 0);
      expect(r.frequency, isNull);
      expect(r.voltage, 229.8);
    });

    test('total power counts both outlets only when fresh and valid', () {
      final both = OutletTelemetry.fromMap({
        'outlet_1': live(),
        'outlet_2': {...live(power: 50.0), 'outlet': 'outlet_2'},
      });
      expect(both.totalPower(t0.add(const Duration(seconds: 3))), 150.2);
      expect(both.totalPower(t0.add(const Duration(minutes: 2))), 0);
    });
  });

  group('Supabase rows', () {
    test('a session row parses per outlet', () {
      final s = UsageSession.fromRow({
        'outlet': 'outlet_2',
        'appliance_name': 'Electric Fan',
        'profile_id': 'UNNAMED_DEVICE_1',
        'started_at': '2026-10-22T08:00:00+00:00',
        'ended_at': '2026-10-22T08:10:00+00:00',
        'duration_s': 600,
        'energy_wh': '8.500', // numeric arrives as text
        'peak_current_a': '0.330',
        'peak_power_w': '62.00',
        'avg_power_w': '51.00',
        'end_reason': 'TURNED_OFF',
        'counts_toward_learning': true,
        'learning_use': 3,
      });
      expect(s.outlet, OutletChannel.outlet2);
      expect(s.energyWh, 8.5);
      expect(s.energyKWh, 0.0085);
      expect(s.learningUse, 3);
    });

    test('a match reply carries confidence, scores and the outlet', () {
      final m = SignatureMatch.fromJson({
        'status': 'learning',
        'outlet': 'outlet_2',
        'confidence': 98.3,
        'threshold': 88,
        'scores': {
          'power': 99.1,
          'current': 97.0,
          'pf': 99.6,
          'reactive': null,
        },
        'appliance': {'name': 'Rice Cooker'},
      });
      expect(m.recognized, isTrue);
      expect(m.outlet, OutletChannel.outlet2);
      expect(m.confidence, 98.3);
      expect(m.scores['reactive'], isNull);
      expect(m.applianceName, 'Rice Cooker');
      final unknown = SignatureMatch.fromJson({
        'status': 'unrecognized_device',
        'confidence': 39.1,
        'appliance': null,
      });
      expect(unknown.recognized, isFalse);
      expect(unknown.isUnrecognized, isTrue);
      expect(
        SignatureMatch.fromJson({'status': 'duplicate'}).recognized,
        isFalse,
      );
    });
  });
}
