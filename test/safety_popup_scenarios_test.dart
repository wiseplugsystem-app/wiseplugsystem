// The safe-time pop-up in every scenario: one outlet (countdown, then the
// "turned off" sentence), and two outlets at once (both counting down, one
// off and one counting down, both off), each with its own buttons.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';

import 'live_popups_test.dart' show PopupDevice, FakeAlarm, mount, status, inDialog;

OutletReading on(String outlet, String state, String appliance, {int left = 45}) =>
    OutletReading.fromMap(outlet, {
      'alertType': 'SAFETY_CEILING_EXCEEDED',
      'status': state == 'LOCKED_OUT' ? 'LOCKED_OUT' : 'Active',
      'currentState': state,
      'lockedOut': state == 'LOCKED_OUT',
      'sessionID': 'boot',
      'revision': 3,
      'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
      'sensor_valid': true,
      'appliance': appliance,
      'alertID': 'alert-$outlet',
      'countdownExpiry': DateTime.now().add(Duration(seconds: left)).millisecondsSinceEpoch,
    });

void main() {
  testWidgets('one outlet: countdown, "turning off" at 0, then what happened', (tester) async {
    final device = PopupDevice();
    await mount(tester, device, alarm: FakeAlarm());
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({'B': on('B', 'WARNING', 'efan')});
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDialog(find.text('Still using the efan?')), findsOneWidget);
    expect(inDialog(find.text('seconds until it turns off')), findsOneWidget);
    // 0 s left, the plug has not reported the cutoff yet: no stuck "0".
    device.readings.add({'B': on('B', 'WARNING', 'efan', left: 0)});
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDialog(find.textContaining('turning it off now')), findsOneWidget);
    // Turned off: one plain sentence, then Reset Safety.
    device.readings.add({'B': on('B', 'LOCKED_OUT', 'efan')});
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDialog(find.text('Turned off for safety')), findsOneWidget);
    expect(
      inDialog(find.text('The efan on Outlet B reached its safe time, so WisePlug turned it off.')),
      findsOneWidget,
    );
    expect(inDialog(find.text('Reset Safety')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('two outlets counting down: one row each, its own countdown and buttons', (tester) async {
    final device = PopupDevice();
    await mount(tester, device, alarm: FakeAlarm());
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({
      'A': on('A', 'WARNING', 'efan', left: 40),
      'B': on('B', 'WARNING', 'black fan', left: 25),
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDialog(find.text('Two appliances reached their safe time.')), findsOneWidget);
    expect(inDialog(find.text('efan · Outlet A')), findsOneWidget);
    expect(inDialog(find.text('black fan · Outlet B')), findsOneWidget);
    expect(inDialog(find.textContaining('Turns off in')), findsNWidgets(2));
    expect(inDialog(find.text('Keep it on')), findsNWidgets(2));
    // Keep only the efan on: the pop-up stays for the black fan.
    await tester.tap(inDialog(find.text('Keep it on')).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(device.commands, ['SMART_OVERRIDE']);
    expect(find.byType(Dialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('one turned off, the other still counting down', (tester) async {
    final device = PopupDevice();
    await mount(tester, device, alarm: FakeAlarm());
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({
      'A': on('A', 'LOCKED_OUT', 'efan'),
      'B': on('B', 'WARNING', 'black fan', left: 30),
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDialog(find.text('Reached its safe time: turned off')), findsOneWidget);
    expect(inDialog(find.textContaining('Turns off in')), findsOneWidget);
    expect(inDialog(find.text('Reset Safety')), findsOneWidget); // for the efan only
    expect(inDialog(find.text('Turn off')), findsOneWidget);     // for the black fan
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('both turned off: one sentence, Reset both', (tester) async {
    final device = PopupDevice();
    await mount(tester, device, alarm: FakeAlarm());
    device.profiles.add([]);
    device.gadget.add(status(triggered: true));
    device.readings.add({
      'A': on('A', 'LOCKED_OUT', 'efan'),
      'B': on('B', 'LOCKED_OUT', 'black fan'),
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      inDialog(find.text('Both appliances reached their safe time, so WisePlug turned them off.')),
      findsOneWidget,
    );
    expect(inDialog(find.text('Reached its safe time: turned off')), findsNWidgets(2));
    expect(inDialog(find.text('Reset both')), findsOneWidget);
    expect(inDialog(find.text('Close')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });
}
