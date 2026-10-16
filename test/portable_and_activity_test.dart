import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/activity_event.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';

void main() {
  test('an appliance learned on outlet A is recognized on outlet B', () {
    final fan = LearnedAppliance.fromMap('A', 'UNNAMED_DEVICE_1_ab', {
      'name': 'Desk fan',
      'registered': true,
      'range': {'powerMin_W': 38.25, 'powerMax_W': 51.75},
    });
    final onB = OutletReading.fromMap('B', {
      'currentState': 'ACTIVE',
      'status': 'Active',
      'profileID': 'UNNAMED_DEVICE_1_ab',
      'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
    });
    expect(connectedProfile(onB, [fan])?.name, 'Desk fan');
    expect(profileStatus(fan, onB, [fan], DateTime.now()), 'Active');
    expect(fan.powerMin, 38.25);
    expect(fan.powerMax, 51.75);
  });

  test('legacy name matching stays on its own outlet', () {
    final fan = LearnedAppliance.fromMap('A', 'p1', {'name': 'Fan'});
    final onB = OutletReading.fromMap('B', {'appliance': 'Fan'});
    expect(connectedProfile(onB, [fan]), isNull);
  });

  test('activity entries parse newest first with readable titles', () {
    final at = DateTime(2026, 10, 16, 14, 30).millisecondsSinceEpoch;
    final events = parseActivity({
      '-a': {
        'type': 'APPLIANCE_ON',
        'outlet': 'B',
        'profileID': 'fan',
        'time': at,
      },
      '-b': {
        'type': 'OUTLET_OFF',
        'outlet': 'A',
        'detail': 'app',
        'time': at + 60000,
      },
      '-c': {'type': 'SAFETY_WARNING', 'outlet': 'A', 'time': at - 60000},
    });
    expect(events.map((e) => e.id), ['-b', '-a', '-c']);
    expect(events[0].title(null), 'Outlet A switched off from the app');
    expect(events[1].title('Desk fan'), 'Desk fan turned on');
    expect(events[1].title(null), 'An unrecognized appliance turned on');
    expect(events[2].category, ActivityCategory.safety);
    expect(formatEventTime(events[1].time), 'Oct 16, 2:30 PM');
    expect(formatEventTime(DateTime(2026, 1, 2, 0, 5)), 'Jan 2, 12:05 AM');
  });

  test('learning fields: backstop while learning, learned limit after', () {
    final learning = LearnedAppliance.fromMap('A', 'fan', {
      'name': 'Fan',
      'registered': true,
      'safetyCeilingDuration': 14400,
      'sessionCount': 3,
      'sessionHistory': [1200, 1500, 1350],
      'isLearningComplete': false,
      'learnedLimit': 14400,
    });
    expect(learning.isLearningComplete, isFalse);
    expect(learning.sessionHistory, [1200, 1500, 1350]);
    expect(learning.learningUsesLeft, 4);
    expect(learning.effectiveLimit, 14400); // only the backstop applies

    final learned = LearnedAppliance.fromMap('A', 'fan', {
      'name': 'Fan',
      'registered': true,
      'safetyCeilingDuration': 14400,
      'sessionCount': 9,
      'baselineAverage': 1800,
      'isLearningComplete': true,
      'learnedLimit': 2700, // 1800 s x 1.5
    });
    expect(learned.learningUsesLeft, 0);
    expect(learned.effectiveLimit, 2700);
    expect(learned.baselineAverage, 1800);
  });

  test('learning completion appears in the activity history', () {
    final event = ActivityEvent.fromMap('x', {
      'type': 'LEARNING_COMPLETE',
      'outlet': 'A',
      'profileID': 'fan',
    });
    expect(event.category, ActivityCategory.appliance);
    expect(
      event.title('Fan'),
      contains('Learned how long Fan is usually used'),
    );
  });
}
