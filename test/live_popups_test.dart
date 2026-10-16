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
    'legacy reconnect prompts again without a session or start time',
    (tester) async {
      final device = PopupDevice();
      await mount(tester, device);
      OutletReading legacy(String status) => OutletReading.fromMap('A', {
        'status': status,
        'appliance': 'Fan',
        'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
      });
      device.profiles.add([
        LearnedAppliance.fromMap('A', 'sig', {'name': 'Fan'}),
      ]);
      device.readings.add({'A': legacy('Active')});
      await tester.pumpAndSettle();
      await tester.tap(find.text('No, Disregard'));
      await tester.pumpAndSettle();
      device.readings.add({'A': legacy('Active')});
      await tester.pumpAndSettle();
      expect(find.text('New Appliance Detected'), findsNothing);
      device.readings.add({'A': legacy('Idle')});
      await tester.pumpAndSettle();
      device.readings.add({'A': legacy('Active')});
      await tester.pumpAndSettle();
      expect(find.text('New Appliance Detected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );

  testWidgets(
    'named firmware appliance prompts when its catalog arrives late',
    (tester) async {
      final device = PopupDevice();
      await mount(tester, device);
      await tester.tap(find.text('Profiles').last);
      device.readings.add({'A': reading()});
      device.profiles.add([]);
      await tester.pumpAndSettle();
      expect(find.text('New Appliance Detected'), findsNothing);
      device.profiles.add([
        LearnedAppliance.fromMap('A', 'signature', {'name': 'Fan'}),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('New Appliance Detected'), findsOneWidget);
      await tester.tap(find.text('Yes, Register'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Study Fan');
      await tester.tap(find.text('Save Profile'));
      await tester.pumpAndSettle();
      expect(find.text('Study Fan'), findsOneWidget);
      expect(find.text('New Appliance Detected'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );

  testWidgets('a profile failure does not hide valid power on one outlet', (
    tester,
  ) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.profiles.addError(StateError('permission-denied'));
    device.readings.add({'A': reading()});
    await tester.pumpAndSettle();
    expect(find.text('42.0 W'), findsOneWidget);
    expect(
      find.textContaining('Cannot load appliance profiles'),
      findsOneWidget,
    );
    expect(find.textContaining('Cannot load ESP32 readings'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('metadata errors do not silently suppress appliance detection', (
    tester,
  ) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.readings.add({'A': reading()});
    device.profiles.add([
      LearnedAppliance.fromMap('A', 'signature', {
        'name': 'UNNAMED_DEVICE_1',
        'registrationMetadataAvailable': false,
      }),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New Appliance Detected'), findsOneWidget);
    expect(
      find.textContaining('Saved registration could not be checked'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('disregard is per use and registration persists into profiles', (
    tester,
  ) async {
    final device = PopupDevice();
    await mount(tester, device);
    final first = reading();
    device.readings.add({'A': first});
    device.profiles.add([
      LearnedAppliance.fromMap('A', 'signature', {'name': 'UNNAMED_DEVICE_1'}),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New Appliance Detected'), findsOneWidget);
    await tester.tap(find.text('No, Disregard'));
    await tester.pumpAndSettle();
    device.readings.add({'A': first});
    await tester.pumpAndSettle();
    expect(find.text('New Appliance Detected'), findsNothing);
    device.readings.add({'A': reading(session: 2)});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, Register'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Bedroom Fan');
    await tester.tap(find.text('Save Profile'));
    await tester.pumpAndSettle();
    expect(device.savedName, 'Bedroom Fan');
    await tester.tap(find.text('Profiles').last);
    await tester.pumpAndSettle();
    expect(find.text('Bedroom Fan'), findsOneWidget);
    device.readings.add({'A': reading(session: 3)});
    await tester.pumpAndSettle();
    expect(find.text('New Appliance Detected'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('saving registration does not dismiss a newer safety warning', (
    tester,
  ) async {
    final device = PopupDevice()..registrationGate = Completer<void>();
    final alarm = FakeAlarm();
    await mount(tester, device, alarm: alarm);
    device.readings.add({'A': reading()});
    device.profiles.add([
      LearnedAppliance.fromMap('A', 'signature', {'name': 'UNNAMED_DEVICE_1'}),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, Register'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Bedroom Fan');
    await tester.tap(find.text('Save Profile'));
    await tester.pump();
    device.readings.add({'A': reading(state: 'WARNING')});
    device.gadget.add(status(triggered: true));
    await tester.pumpAndSettle();
    expect(find.text('WARNING'), findsOneWidget);
    device.registrationGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('WARNING'), findsOneWidget);
    expect(alarm.playing, isTrue);
    expect(
      find.text('Appliance Registration', skipOffstage: false),
      findsNothing,
    );
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('WARNING'), findsNothing);
    expect(alarm.playing, isFalse);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

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

  testWidgets('a name already used by another appliance is refused', (
    tester,
  ) async {
    final device = PopupDevice();
    await mount(tester, device);
    device.readings.add({'A': reading()});
    device.profiles.add([
      LearnedAppliance.fromMap('A', 'signature', {'name': 'UNNAMED_DEVICE_1'}),
      LearnedAppliance.fromMap('B', 'fan', {
        'name': 'Bedroom Fan',
        'registered': true,
      }),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, Register'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, ' bedroom fan ');
    await tester.tap(find.text('Save Profile'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'An appliance with this name already exists. Please choose a unique name.',
      ),
      findsOneWidget,
    );
    expect(device.savedName, isNull);
    await tester.enterText(find.byType(TextField).first, 'Desk lamp');
    await tester.tap(find.text('Save Profile'));
    await tester.pumpAndSettle();
    expect(device.savedName, 'Desk lamp');
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('the countdown is the focus and override extends 15 minutes', (
    tester,
  ) async {
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
    expect(device.lastFields, {'alertID': 'alert-1', 'extensionDuration': 900});
    await tester.tap(find.text('Dismiss'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });
}
