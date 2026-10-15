import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';
import 'package:wiseplug/services/esp32_service.dart';

/// Payload shapes copied from what wiseplug_esp32.ino publishes.
Map<String, dynamic> outlet(
  String state, {
  double watts = 0,
  bool valid = true,
  String profile = '',
}) => {
  'status': state == 'IDLE' ? 'Idle' : 'Active',
  'currentState': state,
  'sessionID': '949bf6920469f276',
  'revision': 3,
  'appliance': profile.isEmpty ? 'None' : profile,
  'profileID': profile,
  'sensor_valid': valid,
  'power_W': watts,
  'voltage_V': valid ? 237.3 : 0.0,
  'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
  'start_time': state == 'IDLE'
      ? 'N/A'
      : DateTime.now().toUtc().toIso8601String(),
  'safetyDeadline': 'N/A',
  'alertID': '',
  'countdownExpiry': 'N/A',
};

void main() {
  const id = 'UNNAMED_DEVICE_1792049550000_0a1b2c3d';
  final catalog = {
    'OUTLET_B': {
      id: {
        'name': id,
        'steadyPower_W': 45.2,
        'peakPower_W': 48.0,
        'current_A': 0.21,
        'voltage_V': 237.3,
        'powerFactor': 0.91,
        'maxRunTime': 1800,
        'safetyCeilingDuration': 1800,
        'totalSessions': 1,
        'registered_at': '2026-10-15T07:40:00Z',
      },
    },
  };

  test('meter failure is reported, not mistaken for an idle outlet', () {
    final readings = parseOutlets({'outlet_A': outlet('IDLE', valid: false)});
    final a = readings['A']!;
    expect(a.isFresh(DateTime.now()), isTrue);
    expect(a.sensorValid, isFalse);
    expect(a.hasConnectedAppliance(DateTime.now()), isFalse);
  });

  test('appliance on/off follows the firmware state machine', () {
    final now = DateTime.now();
    final on = parseOutlets({
      'outlet_B': outlet('ACTIVE', watts: 45.2, profile: id),
    })['B']!;
    final sampling = parseOutlets({
      'outlet_B': outlet('SAMPLING', watts: 45),
    })['B']!;
    final off = parseOutlets({'outlet_B': outlet('IDLE')})['B']!;
    expect(on.hasConnectedAppliance(now), isTrue);
    expect(on.activePower, 45.2);
    expect(sampling.hasConnectedAppliance(now), isTrue);
    expect(off.hasConnectedAppliance(now), isFalse);
  });

  test(
    'a new signature needs registration, then shows as Active/Idle',
    () async {
      final unregistered = await combineProfileStreams(
        Stream.value(catalog),
        Stream.value(<String, dynamic>{}),
      ).first;
      final reading = parseOutlets({
        'outlet_B': outlet('ACTIVE', watts: 45.2, profile: id),
      })['B']!;
      final profile = connectedProfile(reading, unregistered);
      expect(profile?.profileID, id);
      expect(
        profile!.needsRegistration,
        isTrue,
        reason: 'this is what opens the popup',
      );

      final registered = await combineProfileStreams(
        Stream.value(catalog),
        Stream.value({
          'OUTLET_B': {
            id: {'name': 'Desk fan'}, // name only: no appliance type
          },
        }),
      ).first;
      final fan = registered.single;
      expect(fan.needsRegistration, isFalse);
      expect(fan.name, 'Desk fan');
      expect(fan.safetyCeilingDuration, 1800);
      final now = DateTime.now();
      expect(profileStatus(fan, reading, registered, now), 'Active');
      final idle = parseOutlets({'outlet_B': outlet('IDLE')})['B']!;
      expect(profileStatus(fan, idle, registered, now), 'Idle');
    },
  );
}
