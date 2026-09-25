import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/screens/esp32_dashboard.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';
import 'package:wiseplug/services/esp32_service.dart';

class TestDevice extends Fake implements Esp32Service {
  final readings = StreamController<Map<String, OutletReading>>.broadcast();
  final profiles = StreamController<List<LearnedAppliance>>.broadcast();
  Map<String, bool>? saved;
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
      device.readings.add(readings(321));
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
      expect(find.text('p1'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('500.0 W'), findsNothing);
      expect(find.text('Peak power'), findsNothing);
      device.profiles.add([
        LearnedAppliance.fromMap('A', 'p1', {
          'name': 'Renamed by device',
          'safetyCeilingDuration': 1800,
        }),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Renamed by device'), findsWidgets);
      expect(find.text('30 min'), findsOneWidget);
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
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Connect the ESP32'), findsOneWidget);
      expect(device.commands, isEmpty);
      for (final state in ['IDLE', 'DISABLED']) {
        device.readings.add({
          'A': OutletReading.fromMap('A', {
            'currentState': state,
            'sessionID': 'boot',
            'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
          }),
        });
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(Switch).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();
      }
      expect(device.commands, ['A:TURN_OFF', 'A:TURN_ON']);
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      expect(find.text('Waiting for ESP32 connection'), findsOneWidget);
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
}
