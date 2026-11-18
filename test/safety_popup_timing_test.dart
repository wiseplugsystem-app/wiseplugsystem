// The safety pop-up opens when the safe time is up, and stays while the
// warning or the lock-out lasts, even when the plug's last update is older
// than 30 s or its clock is not synced. The progress bars match it: the
// card's bar is full exactly when the pop-up opens; the pop-up's own bar
// empties with its 60-second countdown.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';

import 'live_popups_test.dart'
    show FakeAlarm, PopupDevice, inDialog, mount, status;

OutletReading _reading({
  required String state,
  int? lastUpdatedMs,
  Object? countdownExpiry,
  int? countdownRemaining,
  DateTime? start,
  DateTime? deadline,
}) => OutletReading.fromMap('A', {
  'alertType': 'SAFETY_CEILING_EXCEEDED',
  'status': state == 'LOCKED_OUT' ? 'LOCKED_OUT' : 'Active',
  'currentState': state,
  'lockedOut': state == 'LOCKED_OUT',
  'sessionID': 'boot',
  'profileID': 'signature',
  'start_time': (start ?? DateTime.now().subtract(const Duration(minutes: 30)))
      .millisecondsSinceEpoch,
  'last_updated_ms': lastUpdatedMs ?? DateTime.now().millisecondsSinceEpoch,
  'sensor_valid': true,
  'power_W': 42,
  'appliance': 'Fan',
  'alertID': 'alert-1',
  'countdownExpiry':
      countdownExpiry ??
      DateTime.now().add(const Duration(seconds: 45)).millisecondsSinceEpoch,
  'countdownRemaining': ?countdownRemaining,
  if (deadline != null) 'safetyDeadline': deadline.millisecondsSinceEpoch,
});

void main() {
  group('the pop-up is not hidden by an old or unsynced update', () {
    final now = DateTime.now();
    test('a lock-out last updated 5 minutes ago is still current', () {
      final r = _reading(
        state: 'LOCKED_OUT',
        lastUpdatedMs: now
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      );
      expect(r.isFresh(now), isFalse);
      expect(r.isCurrentForAlert(now), isTrue);
    });
    test('a warning 40 s old with its countdown still running is current', () {
      final r = _reading(
        state: 'WARNING',
        lastUpdatedMs: now
            .subtract(const Duration(seconds: 40))
            .millisecondsSinceEpoch,
      );
      expect(r.isFresh(now), isFalse);
      expect(r.isCurrentForAlert(now), isTrue);
    });
    test('the plug clock not synced (last_updated 0): still current', () {
      final r = _reading(
        state: 'WARNING',
        lastUpdatedMs: 0,
        countdownExpiry: 'N/A',
        countdownRemaining: 50,
      );
      expect(r.isCurrentForAlert(now), isTrue);
      // The countdown comes from the plug's own seconds, not 0.
      expect(r.secondsRemaining(DateTime.now()), inInclusiveRange(49, 50));
    });
    test('a warning whose countdown ended long ago is not current', () {
      final r = _reading(
        state: 'WARNING',
        lastUpdatedMs: now
            .subtract(const Duration(minutes: 10))
            .millisecondsSinceEpoch,
        countdownExpiry: now
            .subtract(const Duration(minutes: 9))
            .millisecondsSinceEpoch,
      );
      expect(r.isCurrentForAlert(now), isFalse);
    });
  });

  group('the card bar is full exactly when the pop-up opens', () {
    test('halfway through the safe time: 50 %', () {
      final now = DateTime.now();
      final r = _reading(
        state: 'ACTIVE',
        start: now.subtract(const Duration(minutes: 15)),
        deadline: now.add(const Duration(minutes: 15)),
      );
      expect(r.safeTimeProgress(now), closeTo(0.5, 0.001));
      expect(
        r.safeTimeProgress(now.add(const Duration(minutes: 15))),
        closeTo(1.0, 0.001),
      );
    });
    test('warning (pop-up open) and lock-out: 100 %', () {
      final now = DateTime.now();
      expect(_reading(state: 'WARNING').safeTimeProgress(now), 1.0);
      expect(_reading(state: 'LOCKED_OUT').safeTimeProgress(now), 1.0);
    });
  });

  testWidgets('a warning whose last update is 40 s old still opens the '
      'pop-up, with its 60-second bar', (tester) async {
    final device = PopupDevice();
    final alarm = FakeAlarm();
    await mount(tester, device, alarm: alarm);
    device.profiles.add([]);
    device.readings.add({
      'A': _reading(
        state: 'WARNING',
        lastUpdatedMs: DateTime.now()
            .subtract(const Duration(seconds: 40))
            .millisecondsSinceEpoch,
        countdownExpiry: DateTime.now()
            .add(const Duration(seconds: 30))
            .millisecondsSinceEpoch,
      ),
    });
    device.gadget.add(status(triggered: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDialog(find.text('seconds until it turns off')), findsOneWidget);
    expect(alarm.playing, isTrue);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('safety-countdown-bar')),
    );
    expect(bar.value, closeTo(30 / 60, 0.03));
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('a lock-out not updated for minutes still shows "Turned off '
      'for safety"', (tester) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.add([]);
    device.readings.add({
      'A': _reading(
        state: 'LOCKED_OUT',
        lastUpdatedMs: DateTime.now()
            .subtract(const Duration(minutes: 3))
            .millisecondsSinceEpoch,
      ),
    });
    device.gadget.add(status(triggered: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDialog(find.text('Turned off for safety')), findsOneWidget);
    expect(inDialog(find.text('Reset Safety')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });
}
