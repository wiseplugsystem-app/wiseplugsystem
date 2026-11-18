// User tests for the safe time, step by step as a user lives it:
//   running (card bar fills) -> safe time up (pop-up opens on that same
//   update, card bar full) -> Turn off now / Keep it on / no answer ->
//   "Turned off for safety" -> Reset Safety -> idle.
// Plus the situations where no pop-up may appear (another kind of alert, the
// plug offline) and where it must (a reading older than 30 s).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';

import 'live_popups_test.dart'
    show FakeAlarm, PopupDevice, inDialog, mount, status;

OutletReading _a(
  String state, {
  String alert = 'SAFETY_CEILING_EXCEEDED',
  int left = 60,
  Duration ran = const Duration(minutes: 29),
  Duration? deadlineIn,
  Duration age = Duration.zero,
}) {
  final now = DateTime.now();
  return OutletReading.fromMap('A', {
    'alertType': state == 'ACTIVE' ? '' : alert,
    'status': state == 'LOCKED_OUT'
        ? 'LOCKED_OUT'
        : state == 'IDLE'
        ? 'Idle'
        : 'Active',
    'currentState': state,
    'lockedOut': state == 'LOCKED_OUT',
    'sessionID': 'boot',
    'profileID': 'fan-1',
    'appliance': 'Fan',
    'sensor_valid': true,
    'power_W': 57,
    'start_time': now.subtract(ran).millisecondsSinceEpoch,
    'last_updated_ms': now.subtract(age).millisecondsSinceEpoch,
    'alertID': state == 'WARNING' || state == 'LOCKED_OUT' ? 'alert-1' : '',
    'countdownExpiry': state == 'WARNING'
        ? now.add(Duration(seconds: left)).millisecondsSinceEpoch
        : 'N/A',
    'safetyDeadline': deadlineIn == null
        ? 'N/A'
        : now.add(deadlineIn).millisecondsSinceEpoch,
  });
}

Future<void> _frame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('1. running: no pop-up; the bar shows the time used so far', (
    tester,
  ) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.add([]);
    device.gadget.add(status());
    // 29 of 30 minutes used.
    final r = _a('ACTIVE', deadlineIn: const Duration(minutes: 1));
    expect(r.safeTimeProgress(DateTime.now()), closeTo(29 / 30, 0.01));
    device.readings.add({'A': r});
    await _frame(tester);
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('2. safe time up: the pop-up opens on that same update, the '
      'sound plays, the card bar is full', (tester) async {
    final device = PopupDevice();
    final alarm = FakeAlarm();
    await mount(tester, device, alarm: alarm);
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    final warning = _a('WARNING', left: 60);
    device.readings.add({'A': warning});
    await _frame(tester); // no waiting: the first frame after the update
    expect(inDialog(find.text('Safe time is up')), findsOneWidget);
    expect(inDialog(find.text('Still using the Fan?')), findsOneWidget);
    expect(inDialog(find.text('60')), findsOneWidget);
    expect(alarm.playing, isTrue);
    expect(warning.safeTimeProgress(DateTime.now()), 1.0);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('safety-countdown-bar')),
    );
    expect(bar.value, closeTo(1.0, 0.02));
    // The bar is exactly the seconds shown, out of 60, at every update.
    device.readings.add({'A': _a('WARNING', left: 15)});
    await _frame(tester);
    expect(inDialog(find.text('15')), findsOneWidget);
    final later = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('safety-countdown-bar')),
    );
    expect(later.value, closeTo(15 / 60, 0.02));
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('3. "Turn off now": the command is sent and the sound stops', (
    tester,
  ) async {
    final device = PopupDevice();
    final alarm = FakeAlarm();
    await mount(tester, device, alarm: alarm);
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({'A': _a('WARNING', left: 40)});
    await _frame(tester);
    await tester.tap(inDialog(find.text('Turn off now')));
    await _frame(tester);
    expect(device.commands, ['TURN_OFF']);
    expect(alarm.playing, isFalse);
    // The plug reports it off: the pop-up closes.
    device.readings.add({'A': _a('DISABLED', alert: '')});
    device.gadget.add(status());
    await _frame(tester);
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('4. "Keep it on": the extra time is sent and the pop-up closes', (
    tester,
  ) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({'A': _a('WARNING', left: 30)});
    await _frame(tester);
    await tester.tap(inDialog(find.text('Keep it on')));
    await _frame(tester);
    expect(device.commands, ['SMART_OVERRIDE']);
    expect(device.lastFields['alertID'], 'alert-1');
    expect(device.lastFields['extensionDuration'], greaterThanOrEqualTo(60));
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('5. no answer: "Turned off for safety", then Reset Safety, '
      'then the pop-up closes', (tester) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({'A': _a('WARNING', left: 1)});
    await _frame(tester);
    device.readings.add({'A': _a('LOCKED_OUT')});
    await _frame(tester);
    expect(inDialog(find.text('Turned off for safety')), findsOneWidget);
    await tester.tap(inDialog(find.text('Reset Safety')));
    await _frame(tester);
    expect(device.commands, ['RESET_SAFETY']);
    device.readings.add({'A': _a('DISABLED', alert: '')});
    device.gadget.add(status());
    await _frame(tester);
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('6. "Turned off for safety" stays while the plug is slow to '
      'update (2 min), and the countdown survives a 40 s gap', (tester) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({
      'A': _a('WARNING', left: 20, age: const Duration(seconds: 40)),
    });
    await _frame(tester);
    expect(inDialog(find.text('seconds until it turns off')), findsOneWidget);
    device.readings.add({
      'A': _a('LOCKED_OUT', age: const Duration(minutes: 2)),
    });
    await _frame(tester);
    expect(inDialog(find.text('Turned off for safety')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('7. another kind of alert (meter silent): no pop-up', (
    tester,
  ) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({'A': _a('WARNING', alert: 'SENSOR_UNAVAILABLE')});
    await _frame(tester);
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('8. the plug offline: no pop-up from old data', (tester) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.add([]);
    device.gadget.add(
      status(
        triggered: true,
        lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    );
    device.readings.add({'A': _a('LOCKED_OUT')});
    await _frame(tester);
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });
}
