import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/models/gadget_status.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';
import 'package:wiseplug/services/esp32_service.dart';
import 'package:wiseplug/services/safety_alarm_manager.dart';
import 'package:wiseplug/widgets/safety_alert_listener.dart';

class PopupDevice extends Fake implements Esp32Service {
  final readings = StreamController<Map<String, OutletReading>>.broadcast();
  final profiles = StreamController<List<LearnedAppliance>>.broadcast();
  final gadget = StreamController<GadgetStatus>.broadcast();
  @override
  Stream<GadgetStatus> streamGadgetStatus() => gadget.stream;
  final commands = <String>[];
  Map<String, Object?> lastFields = const {};
  String? savedName;
  Completer<void>? registrationGate;
  @override
  Stream<Map<String, OutletReading>> streamOutlets() => readings.stream;
  @override
  Stream<List<LearnedAppliance>> streamProfiles() => profiles.stream;
  @override
  Stream<Map<String, dynamic>> streamPreferences() => Stream.value({});
  @override
  Future<void> registerProfile(LearnedAppliance profile, String name) async {
    if (registrationGate != null) await registrationGate!.future;
    savedName = name;
    profiles.add([
      LearnedAppliance.fromMap(profile.outlet, profile.profileID, {
        'name': name,
        'registered': true,
      }),
    ]);
  }

  @override
  Future<void> command(
    OutletReading reading,
    String type, {
    Map<String, Object?> fields = const {},
  }) async {
    commands.add(type);
    lastFields = fields;
  }

  @override
  Future<void> resetSafety(OutletReading reading) async {
    commands.add('RESET_SAFETY');
  }

  Future<void> close() async {
    await readings.close();
    await profiles.close();
    await gadget.close();
  }
}

OutletReading reading({String state = 'ACTIVE', int session = 1}) =>
    OutletReading.fromMap('A', {
      'status': 'Active',
      'currentState': state,
      'sessionID': 'boot',
      'profileID': 'signature',
      'start_time': DateTime.now()
          .subtract(Duration(minutes: session))
          .millisecondsSinceEpoch,
      'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
      'sensor_valid': true,
      'power_W': 42,
      'appliance': 'UNNAMED_DEVICE_1',
      'alertID': 'alert-1',
      'countdownExpiry': DateTime.now()
          .add(const Duration(seconds: 45))
          .millisecondsSinceEpoch,
    });

class FakeAlarm implements SafetyAlarmManager {
  bool playing = false;
  int plays = 0;
  @override
  Future<void> playSafetyAlarm() async {
    if (playing) return;
    playing = true;
    plays++;
  }

  @override
  Future<void> stopAlarm() async => playing = false;
}

GadgetStatus status({
  bool triggered = false,
  double? remaining,
  DateTime? lastSeen,
}) => GadgetStatus(
  outletA: true,
  powerDraw: 42,
  connectionStatus: 'Online',
  safetyTriggered: triggered,
  remainingLimit: remaining,
  lastSeen: lastSeen ?? DateTime.now(),
);

Finder inDialog(Finder finder) =>
    find.descendant(of: find.byType(Dialog), matching: finder);

Future<void> mount(
  WidgetTester tester,
  PopupDevice device, {
  FakeAlarm? alarm,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 930));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: SafetyAlertListener(
        service: device,
        alarm: alarm ?? FakeAlarm(),
        child: Esp32LiveView(
          service: device,
          darkMode: false,
          onDarkModeChanged: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'safety alert triggers only on safetyTriggered or no limit left',
    (tester) async {
      final device = PopupDevice();
      final alarm = FakeAlarm();
      await mount(tester, device, alarm: alarm);
      device.profiles.add([]);
      device.readings.add({'A': reading()});
      device.gadget.add(status(remaining: 120));
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsNothing);
      expect(alarm.plays, 0);
      // Stale data from an offline gadget never raises the alarm.
      device.gadget.add(
        status(
          triggered: true,
          lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsNothing);
      device.gadget.add(status(remaining: 0));
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsOneWidget);
      expect(alarm.playing, isTrue);
      device.gadget.add(status(remaining: 30));
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsNothing);
      expect(alarm.playing, isFalse);
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );

  testWidgets(
    'turn off silences, reset clears, dismiss holds until next event',
    (tester) async {
      final device = PopupDevice();
      final alarm = FakeAlarm();
      await mount(tester, device, alarm: alarm);
      device.profiles.add([]);
      device.readings.add({'A': reading(state: 'WARNING')});
      device.gadget.add(status(triggered: true));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('Seconds Remaining')), findsOneWidget);
      expect(
        inDialog(find.text('Are you still using the Appliance?')),
        findsOneWidget,
      );
      await tester.tap(find.text('Turn Off Now'));
      await tester.pumpAndSettle();
      expect(device.commands, ['TURN_OFF']);
      expect(alarm.playing, isFalse);
      device.readings.add({'A': reading(state: 'LOCKED_OUT')});
      device.gadget.add(status(triggered: true));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('Power cut')), findsOneWidget);
      expect(find.text('Turn Off Now'), findsNothing);
      await tester.tap(find.text('Reset Safety'));
      await tester.pumpAndSettle();
      expect(device.commands, ['TURN_OFF', 'RESET_SAFETY']);
      device.readings.add({'A': reading(state: 'IDLE')});
      device.gadget.add(status());
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsNothing);

      device.gadget.add(status(triggered: true));
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      device.gadget.add(status(triggered: true));
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsNothing);
      device.gadget.add(status());
      device.gadget.add(status(triggered: true));
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsOneWidget);
      expect(alarm.plays, 3);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );

  testWidgets(
    'the countdown is the focus and override closes it with a 20% buffer',
    (tester) async {
      final device = PopupDevice();
      await mount(tester, device);
      device.profiles.add([]);
      device.readings.add({'A': reading(state: 'WARNING')});
      device.gadget.add(status(triggered: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The reading's countdown expires ~45 s from now.
      final number = tester.widget<Text>(
        inDialog(find.textContaining(RegExp(r'^\d{1,2}$'))),
      );
      expect(int.parse(number.data!), inInclusiveRange(43, 45));
      expect(number.style!.fontSize, greaterThanOrEqualTo(80));
      await tester.tap(find.text('Yes, Override'));
      await tester.pump();
      expect(device.commands, ['SMART_OVERRIDE']);
      // Ran 1 min: 20% is 12 s, so the 1 min minimum applies.
      expect(device.lastFields, {
        'alertID': 'alert-1',
        'extensionDuration': 60,
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // Accepted: the 60-second window closes and a notice says why.
      expect(find.text('Yes, Override'), findsNothing);
      expect(find.textContaining('near its limit'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );
}
