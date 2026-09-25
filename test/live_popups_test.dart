import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';
import 'package:wiseplug/services/esp32_service.dart';

class PopupDevice extends Fake implements Esp32Service {
  final readings = StreamController<Map<String, OutletReading>>.broadcast();
  final profiles = StreamController<List<LearnedAppliance>>.broadcast();
  final commands = <String>[];
  String? savedName;
  Completer<void>? registrationGate;
  @override
  Stream<Map<String, OutletReading>> streamOutlets() => readings.stream;
  @override
  Stream<List<LearnedAppliance>> streamProfiles() => profiles.stream;
  @override
  Stream<Map<String, dynamic>> streamPreferences() => Stream.value({});
  @override
  Future<void> registerProfile(
    LearnedAppliance profile,
    String name,
    String type,
  ) async {
    if (registrationGate != null) await registrationGate!.future;
    savedName = name;
    profiles.add([
      LearnedAppliance.fromMap(profile.outlet, profile.profileID, {
        'name': name,
        'applianceType': type,
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
  }

  Future<void> close() async {
    await readings.close();
    await profiles.close();
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

Future<void> mount(WidgetTester tester, PopupDevice device) async {
  await tester.binding.setSurfaceSize(const Size(430, 930));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Esp32LiveView(
        service: device,
        darkMode: false,
        onDarkModeChanged: (_) {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('legacy reconnect prompts again without a session or start time', (tester) async {
    final device = PopupDevice();
    await mount(tester, device);
    OutletReading legacy(String status) => OutletReading.fromMap('A', {
      'status': status,
      'appliance': 'Fan',
      'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
    });
    device.profiles.add([LearnedAppliance.fromMap('A', 'sig', {'name': 'Fan'})]);
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
  });

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

  testWidgets('saving registration does not dismiss a newer safety warning', (
    tester,
  ) async {
    final device = PopupDevice()..registrationGate = Completer<void>();
    await mount(tester, device);
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
    await tester.pumpAndSettle();
    expect(find.text('WARNING'), findsOneWidget);
    device.registrationGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('WARNING'), findsOneWidget);
    expect(
      find.text('Appliance Registration', skipOffstage: false),
      findsNothing,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
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

  testWidgets(
    'warning uses remaining deadline and sends OFF, with override deferred',
    (tester) async {
      final device = PopupDevice();
      await mount(tester, device);
      device.profiles.add([]);
      device.readings.add({'A': reading(state: 'WARNING')});
      await tester.pumpAndSettle();
      expect(find.text('WARNING'), findsOneWidget);
      expect(find.text('45'), findsOneWidget);
      final override = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Yes, Override'),
      );
      expect(override.onPressed, isNull);
      await tester.tap(find.text('Turn Off Now'));
      await tester.pumpAndSettle();
      expect(device.commands, ['TURN_OFF']);
      device.readings.add({'A': reading(state: 'LOCKED_OUT')});
      await tester.pumpAndSettle();
      expect(
        find.text('Outlet locked. Use its physical reset button.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );
}
