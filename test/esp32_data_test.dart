import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/screens/esp32_dashboard.dart';

void main() {
  test(
    'canonical catalog uses seconds and takes precedence over legacy paths',
    () {
      final profiles = parseLearnedAppliances({
        'OUTLET_A': {
          'device': {
            'name': 'Fan',
            'maxRunTime': 30,
            'safetyCeilingDuration': 60,
          },
        },
        'OUTLET A': {
          'old': {'name': 'Old fan'},
        },
      });
      expect(profiles.single.name, 'Fan');
      expect(profiles.single.maxRunTime, 30);
      expect(profiles.single.safetyCeilingDuration, 60);
    },
  );
  test('countdown uses device expiry and lockout rejects remote control', () {
    final now = DateTime.utc(2026, 9, 9);
    final data = {
      'currentState': 'WARNING',
      'sessionID': 'boot1',
      'revision': 2,
      'last_updated_ms': now.millisecondsSinceEpoch,
      'countdownExpiry': now.add(const Duration(seconds: 60)).toIso8601String(),
    };
    final reading = OutletReading.fromMap('A', data);
    expect(reading.secondsRemaining(now), 60);
    expect(reading.secondsRemaining(now.add(const Duration(seconds: 59))), 1);
    expect(reading.secondsRemaining(now.add(const Duration(seconds: 60))), 0);
    expect(reading.canCommand(now.add(const Duration(seconds: 31))), false);
    expect(
      OutletReading.fromMap('A', {
        ...data,
        'currentState': 'LOCKED_OUT',
      }).canCommand(now),
      false,
    );
    expect(
      OutletReading.fromMap('A', {...data, 'sessionID': ''}).canCommand(now),
      false,
    );
  });
  testWidgets('locked outlet instructs physical reset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Esp32OutletCard(
            outlet: 'A',
            now: DateTime.utc(2026),
            reading: OutletReading.fromMap('A', {'currentState': 'LOCKED_OUT'}),
          ),
        ),
      ),
    );
    expect(find.textContaining('physical button'), findsOneWidget);
  });
  test('maps original Arduino field names and UTC+8 local timestamps', () {
    final readings = parseOutlets({
      'outlet_A': {
        'appliance': 'Fan',
        'status': 'Active',
        'power_W': 42.5,
        'voltage_V': 230,
        'current_A': 0.2,
        'power_factor': 0.92,
        'peak_power_W': 65,
        'start_time': '2026-09-08 12:00:00',
        'last_updated': '2026-09-08 12:00:03',
      },
    });
    expect(readings['A']!.activePower, 42.5);
    expect(readings['A']!.voltage, 230);
    expect(readings['A']!.current, 0.2);
    expect(readings['A']!.startTime, DateTime.utc(2026, 9, 8, 4));
    expect(readings['A']!.lastUpdated, DateTime.utc(2026, 9, 8, 4, 0, 3));
    expect(readings.containsKey('B'), false);
  });
  test('prefers server timestamp and rejects invalid sensor numbers', () {
    final time = DateTime.utc(2026, 9, 8);
    final reading = OutletReading.fromMap('B', {
      'last_updated_ms': time.millisecondsSinceEpoch,
      'last_updated': 'Time Sync Error',
      'power_W': 'NaN',
      'voltage_V': double.infinity,
      'sensor_valid': false,
    });
    expect(reading.lastUpdated, time);
    expect(reading.activePower, isNull);
    expect(reading.voltage, isNull);
    expect(reading.isFresh(time.add(const Duration(seconds: 31))), false);
    expect(reading.sensorValid, false);
  });
  test('parses nested learned profiles with spaces in outlet keys', () {
    final profiles = parseLearnedAppliances({
      'OUTLET B': {
        'Rice_cooker': {
          'name': 'Rice cooker',
          'steadyPower_W': 600,
          'peakPower_W': 680,
          'current_A': 2.6,
          'voltage_V': 230,
          'powerFactor': 0.99,
        },
      },
    });
    expect(profiles.single.outlet, 'B');
    expect(profiles.single.baselineWattage, 600);
    expect(profiles.single.name, 'Rice cooker');
    expect(parseOutlets(null), isEmpty);
    expect(parseLearnedAppliances(null), isEmpty);
    expect(deviceTime('N/A'), isNull);
  });
  testWidgets('outlet card hides measurements and flags stale data', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Esp32OutletCard(
            outlet: 'A',
            now: DateTime.utc(2026, 9, 8, 1),
            reading: OutletReading.fromMap('A', {
              'appliance': 'Fan',
              'status': 'Active',
              'power_W': 42.5,
              'voltage_V': 230,
              'current_A': 0.2,
              'last_updated': '2026-09-08T00:00:00Z',
            }),
          ),
        ),
      ),
    );
    expect(find.text('Power: 42.5 W'), findsNothing);
    expect(find.text('Voltage: 230.0 V'), findsNothing);
    expect(find.text('Current: 0.200 A'), findsNothing);
    expect(find.textContaining('stale'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
  });
}
