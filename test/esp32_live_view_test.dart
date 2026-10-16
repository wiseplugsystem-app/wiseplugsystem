import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/models/gadget_status.dart';
import 'package:wiseplug/screens/esp32_dashboard.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';
import 'package:wiseplug/services/esp32_service.dart';

class TestDevice extends Fake implements Esp32Service {
  final readings = StreamController<Map<String, OutletReading>>.broadcast();
  final profiles = StreamController<List<LearnedAppliance>>.broadcast();
  final gadget = StreamController<GadgetStatus>.broadcast();
  @override
  Stream<GadgetStatus> streamGadgetStatus() => gadget.stream;
  Map<String, bool>? saved;
  bool owner = true;
  final deleted = <String>[];
  @override
  Future<void> deleteProfile(
    OutletReading reading,
    LearnedAppliance profile,
  ) async => deleted.add(profile.profileID);
  @override
  Future<bool> claimDevice() async => owner;
  final commands = <String>[];
  @override
  Future<void> command(
    OutletReading reading,
    String type, {
    Map<String, Object?> fields = const {},
  }) async {
    commands.add('${reading.outlet}:$type');
  }

  @override
  Future<void> resetSafety(OutletReading reading) async =>
      commands.add('${reading.outlet}:RESET_SAFETY');

  @override
  Stream<Map<String, OutletReading>> streamOutlets() => readings.stream;
  @override
  Stream<List<LearnedAppliance>> streamProfiles() => profiles.stream;
  @override
  Stream<Map<String, dynamic>> streamPreferences() => Stream.value({});
  @override
  Future<void> savePreferences(Map<String, bool> preferences) async {
    saved = preferences;
  }

  Future<void> close() async {
    await readings.close();
    await profiles.close();
    await gadget.close();
  }
}

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_GUI')) {
      final font = File('C:/Windows/Fonts/arial.ttf');
      if (await font.exists()) {
        final loader = FontLoader('Roboto')
          ..addFont(
            font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  test('profile identity takes precedence over duplicate appliance names', () {
    final profiles = [
      for (final id in ['one', 'two'])
        LearnedAppliance.fromMap('A', id, {'name': 'Fan'}),
    ];
    expect(
      connectedProfile(
        OutletReading.fromMap('A', {'appliance': 'Fan'}),
        profiles,
      ),
      isNull,
    );
    expect(
      connectedProfile(
        OutletReading.fromMap('A', {'appliance': 'Fan', 'profileID': 'two'}),
        profiles,
      )?.profileID,
      'two',
    );
    expect(profiles.first.totalSessions, isNull);
    expect(profiles.first.hasSafetyLimit, false);
  });

  testWidgets(
    'live dashboard updates, filters and profile details use device data',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 920));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final device = TestDevice();
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: capture,
            child: Esp32Dashboard(
              service: device,
              darkMode: false,
              onDarkModeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(); // let the ownership claim finish
      final now = DateTime.now();
      final profiles = [
        LearnedAppliance.fromMap('A', 'p1', {
          'name': 'Live appliance',
          'applianceType': 'Rice cooker',
          'safetyCeilingDuration': 7200,
          'totalSessions': 7,
          'peakPower_W': 500,
        }),
        LearnedAppliance.fromMap('A', 'p2', {
          'name': 'Stored fan',
          'applianceType': 'Electric Fan',
        }),
      ];
      Map<String, OutletReading> readings(double watts) => {
        'A': OutletReading.fromMap('A', {
          'appliance': 'Live appliance',
          'profileID': 'p1',
          'currentState': 'ACTIVE',
          'status': 'Active',
          'sessionID': 'boot',
          'power_W': watts,
          'last_updated_ms': now.millisecondsSinceEpoch,
          'start_time': now
              .subtract(const Duration(minutes: 30))
              .millisecondsSinceEpoch,
          'safetyDeadline': now
              .add(const Duration(minutes: 90))
              .millisecondsSinceEpoch,
        }),
        'B': OutletReading.fromMap('B', {
          'appliance': 'None',
          'currentState': 'IDLE',
          'sessionID': 'boot',
          'power_W': 0,
          'last_updated_ms': now.millisecondsSinceEpoch,
        }),
      };
      device.profiles.add(profiles);
      GadgetStatus online(double watts) => GadgetStatus(
        outletA: true,
        powerDraw: watts,
        connectionStatus: 'Online',
        lastSeen: DateTime.now(),
      );
      device.readings.add(readings(321));
      device.gadget.add(online(321));
      await tester.pumpAndSettle();
      expect(find.text('321 W'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_GUI')) {
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final picture = await boundary.toImage(pixelRatio: 2);
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('build/gui-home.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
      }
      device.readings.add(readings(654));
      device.gadget.add(online(654));
      await tester.pumpAndSettle();
      expect(find.text('654 W'), findsOneWidget);
      await tester.tap(find.text('Profiles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Idle').first);
      await tester.pumpAndSettle();
      expect(find.text('Stored fan'), findsOneWidget);
      expect(find.text('Live appliance'), findsNothing);
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Live appliance'));
      await tester.pumpAndSettle();
      expect(find.text('p1'), findsNothing); // the internal ID stays hidden
      expect(find.text('Saved name'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('500.0 W'), findsNothing);
      expect(find.text('Peak power'), findsNothing);
      device.profiles.add([
        LearnedAppliance.fromMap('A', 'p1', {
          'name': 'Renamed by device',
          'safetyCeilingDuration': 14400,
          // Learned: typical use 20 min, so the limit is 30 min (x1.5).
          'isLearningComplete': true,
          'baselineAverage': 1200,
          'learnedLimit': 1800,
        }),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Renamed by device'), findsWidgets);
      expect(find.text('30 min'), findsOneWidget);
      expect(find.text('20 min'), findsOneWidget); // typical use
      expect(find.text('Not available'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );

  testWidgets(
    'offline toggles explain connection and live toggles send commands',
    (tester) async {
      final device = TestDevice();
      await tester.pumpWidget(
        MaterialApp(
          home: Esp32Dashboard(
            service: device,
            darkMode: false,
            onDarkModeChanged: (_) {},
          ),
        ),
      );
      await tester.pump(); // let the ownership claim finish
      device.readings.add({
        'A': OutletReading.fromMap('A', {
          'appliance': 'Old fan',
          'status': 'Active',
          'currentState': 'ACTIVE',
          'last_updated_ms': DateTime.now()
              .subtract(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
        }),
      });
      device.profiles.add([]);
      await tester.pumpAndSettle();
      expect(find.textContaining('Old fan'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('— / 2'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('— / 2'), findsOneWidget);
      expect(find.text('847 W'), findsNothing);
      await tester.scrollUntilVisible(
        find.byType(Switch).first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(Switch), findsNWidgets(2));
      expect(find.text('Measurements'), findsNothing);
      await tester.pumpAndSettle();
      bool switchEnabled() =>
          tester.widget<Switch>(find.byType(Switch).first).onChanged != null;
      // Stale data: no appliance is known to be running, so nothing to switch.
      expect(switchEnabled(), isFalse);
      expect(device.commands, isEmpty);
      for (final (state, enabled) in [
        ('IDLE', false), // on, nothing plugged in
        ('ACTIVE', true), // appliance running: can be switched off
        ('DISABLED', true), // off: must stay switchable to turn back on
      ]) {
        device.readings.add({
          'A': OutletReading.fromMap('A', {
            'currentState': state,
            'status': state == 'ACTIVE' ? 'Active' : 'Idle',
            'sessionID': 'boot',
            'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
          }),
        });
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(Switch).first);
        await tester.pumpAndSettle();
        expect(switchEnabled(), enabled, reason: state);
        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();
      }
      expect(device.commands, ['A:TURN_OFF', 'A:TURN_ON']);
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      expect(find.text('gadget-1 · Offline'), findsOneWidget);
      await tester.tap(find.text('Alert Types'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New devices').last);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(device.saved?['newDevices'], false);
      await tester.pumpWidget(const SizedBox());
      await device.close();
    },
  );

  testWidgets('a device owned by another account is not opened', (
    tester,
  ) async {
    final device = TestDevice()..owner = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Esp32Dashboard(
          service: device,
          darkMode: false,
          onDarkModeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('already linked to another account'),
      findsOneWidget,
    );
    expect(find.byType(Esp32LiveView), findsNothing);
    await device.close();
  });

  testWidgets('outlets active counts running appliances, not relays', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final device = TestDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: Esp32Dashboard(
          service: device,
          darkMode: false,
          onDarkModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    final now = DateTime.now().millisecondsSinceEpoch;
    // Both relays on, meter A dead, outlet B idle: nothing is running.
    device.profiles.add([]);
    device.readings.add({
      'A': OutletReading.fromMap('A', {
        'currentState': 'IDLE',
        'status': 'Idle',
        'sensor_valid': false,
        'last_updated_ms': now,
      }),
      'B': OutletReading.fromMap('B', {
        'currentState': 'IDLE',
        'status': 'Idle',
        'sensor_valid': true,
        'power_W': 0,
        'last_updated_ms': now,
      }),
    });
    device.gadget.add(
      GadgetStatus(
        outletA: true,
        outletB: true,
        connectionStatus: 'Online',
        lastSeen: DateTime.now(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 / 2'), findsOneWidget);
    expect(find.text('2 / 2'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('power control shows the registered appliance name', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final device = TestDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: Esp32Dashboard(
          service: device,
          darkMode: false,
          onDarkModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    final now = DateTime.now().millisecondsSinceEpoch;
    device.profiles.add([
      LearnedAppliance.fromMap('B', 'sig-1', {
        'name': 'Desk fan',
        'registered': true,
      }),
    ]);
    device.readings.add({
      'B': OutletReading.fromMap('B', {
        'currentState': 'ACTIVE',
        'status': 'Active',
        'sessionID': 'boot',
        'profileID': 'sig-1',
        'appliance': 'UNNAMED_DEVICE_1',
        'power_W': 45,
        'last_updated_ms': now,
      }),
    });
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Outlet B · On · monitoring enabled'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Summary card and Power Control row both use the registered name.
    expect(find.text('Desk fan'), findsNWidgets(2));
    expect(find.text('UNNAMED_DEVICE_1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('a locked outlet can be reset from power control', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final device = TestDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: Esp32Dashboard(
          service: device,
          darkMode: false,
          onDarkModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    device.profiles.add([]);
    device.readings.add({
      'B': OutletReading.fromMap('B', {
        'currentState': 'LOCKED_OUT',
        'status': 'LOCKED_OUT',
        'sessionID': 'boot',
        'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    });
    await tester.pumpAndSettle();
    final reset = find.widgetWithText(FilledButton, 'Reset Safety');
    await tester.scrollUntilVisible(
      reset,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    // Confirms first: the user should inspect the appliance.
    expect(find.text('Reset safety?'), findsOneWidget);
    expect(device.commands, isEmpty);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Reset Safety'),
      ),
    );
    await tester.pumpAndSettle();
    expect(device.commands, ['B:RESET_SAFETY']);
    expect(find.text('Outlet B is back on.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('idle appliances show no fixed outlet and can be deleted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final device = TestDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: Esp32Dashboard(
          service: device,
          darkMode: false,
          onDarkModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    final now = DateTime.now().millisecondsSinceEpoch;
    device.profiles.add([
      LearnedAppliance.fromMap('A', 'kettle', {
        'name': 'Old kettle',
        'registered': true,
      }),
    ]);
    device.readings.add({
      'A': OutletReading.fromMap('A', {
        'currentState': 'IDLE',
        'status': 'Idle',
        'sessionID': 'boot',
        'last_updated_ms': now,
      }),
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profiles'));
    await tester.pumpAndSettle();
    expect(find.text('Old kettle'), findsOneWidget);
    expect(find.textContaining('Outlet A'), findsNothing);
    await tester.tap(find.byTooltip('Delete appliance'));
    await tester.pumpAndSettle();
    expect(find.text('Delete appliance?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(device.deleted, ['kettle']);
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });

  testWidgets('only the power switch turns green when on, live', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final device = TestDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: Esp32Dashboard(
          service: device,
          darkMode: false,
          onDarkModeChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    device.profiles.add([]);
    Switch firstSwitch() => tester.widget<Switch>(find.byType(Switch).first);
    Map<String, OutletReading> outletA(String state) => {
      'A': OutletReading.fromMap('A', {
        'currentState': state,
        'status': state == 'ACTIVE' ? 'Active' : 'Idle',
        'sessionID': 'boot',
        'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    };
    device.readings.add(outletA('ACTIVE'));
    await tester.pumpAndSettle();
    expect(firstSwitch().value, isTrue);
    Color? track(Set<WidgetState> states) =>
        firstSwitch().trackColor!.resolve(states);
    expect(track({WidgetState.selected}), const Color(0xFF00B744)); // green
    expect(find.text('Plug in an appliance to use this switch.'), findsNothing);
    expect(
      find.ancestor(
        of: find.byType(Switch).first,
        matching: find.byType(AnimatedContainer),
      ),
      findsNothing,
      reason: 'the card itself stays neutral',
    );
    device.readings.add(outletA('DISABLED'));
    await tester.pumpAndSettle();
    expect(firstSwitch().value, isFalse); // grey track
    expect(
      firstSwitch().onChanged,
      isNotNull,
      reason: 'off: can be switched on',
    );
    // On but empty: disabled, dimmed, and explained.
    device.readings.add(outletA('IDLE'));
    await tester.pumpAndSettle();
    expect(firstSwitch().onChanged, isNull);
    expect(
      find.text('Plug in an appliance to use this switch.'),
      findsOneWidget,
    );
    expect(
      track({WidgetState.selected, WidgetState.disabled})!.a,
      lessThan(1),
      reason: 'disabled switch is dimmed',
    );
    await tester.pumpWidget(const SizedBox());
    await device.close();
  });
}
