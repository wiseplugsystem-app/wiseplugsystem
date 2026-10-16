import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/activity_event.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/models/gadget_status.dart';
import 'package:wiseplug/screens/activity_screen.dart';
import 'package:wiseplug/screens/auth_gate.dart';
import 'package:wiseplug/screens/esp32_dashboard.dart';
import 'package:wiseplug/screens/wifi_config_screen.dart';
import 'package:wiseplug/services/esp32_service.dart';
import 'package:wiseplug/services/safety_alarm_manager.dart';
import 'package:wiseplug/widgets/safety_alert_listener.dart';

class SilentAlarm implements SafetyAlarmManager {
  @override
  Future<void> playSafetyAlarm() async {}
  @override
  Future<void> stopAlarm() async {}
}

/// A plausible live device: one appliance running, a safety warning on B.
class SmallScreenDevice extends Fake implements Esp32Service {
  final bool online, warning;
  SmallScreenDevice({this.online = true, this.warning = false});
  int get _now => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<bool> claimDevice() async => true;
  @override
  Stream<Map<String, dynamic>> streamPreferences() => Stream.value({});
  @override
  Stream<Map<String, dynamic>> streamWifiConfig() =>
      Stream.value({'ssid': 'A very long home network name 5G'});
  @override
  Stream<GadgetStatus> streamGadgetStatus() => Stream.value(
    GadgetStatus(
      outletA: true,
      outletB: true,
      powerDraw: 1234.5,
      connectionStatus: 'Online',
      lastSeen: online
          ? DateTime.now()
          : DateTime.now().subtract(const Duration(hours: 1)),
      safetyTriggered: warning,
      wifiSSID: 'A very long home network name',
    ),
  );
  @override
  Stream<Map<String, OutletReading>> streamOutlets() => Stream.value({
    'A': OutletReading.fromMap('A', {
      'currentState': 'ACTIVE',
      'status': 'Active',
      'sessionID': 'boot',
      'profileID': 'kettle',
      'appliance': 'UNNAMED',
      'power_W': 1234.5,
      'sensor_valid': true,
      'last_updated_ms': _now,
      'start_time': _now - 600000,
      'safetyDeadline': _now + 1200000,
    }),
    'B': OutletReading.fromMap('B', {
      'currentState': warning ? 'WARNING' : 'IDLE',
      'status': warning ? 'Active' : 'Idle',
      'sessionID': 'boot',
      'sensor_valid': true,
      'last_updated_ms': _now,
      'alertID': 'a1',
      'countdownExpiry': _now + 42000,
    }),
  });
  @override
  Stream<List<LearnedAppliance>> streamProfiles() => Stream.value([
    LearnedAppliance.fromMap('A', 'kettle', {
      'name': 'Electric kettle in the kitchen corner',
      'registered': true,
      'safetyCeilingDuration': 1800,
      'maxRunTime': 1800,
      'totalSessions': 12,
    }),
    LearnedAppliance.fromMap('B', 'fan', {
      'name': 'Bedroom ceiling fan',
      'registered': true,
    }),
    LearnedAppliance.fromMap('B', 'UNNAMED_DEVICE_1', {
      'name': 'UNNAMED_DEVICE_1',
    }),
  ]);
  @override
  Stream<List<ActivityEvent>> streamActivity({int limit = 100}) =>
      Stream.value([
        ActivityEvent.fromMap('1', {
          'type': 'SAFETY_WARNING',
          'outlet': 'B',
          'profileID': 'fan',
          'time': _now,
        }),
        ActivityEvent.fromMap('2', {
          'type': 'OUTLET_OFF',
          'outlet': 'A',
          'detail': 'button',
          'time': _now - 60000,
        }),
      ]);
}

Future<void> show(WidgetTester tester, Widget home) async {
  await tester.binding.setSurfaceSize(const Size(320, 568));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(
        size: Size(320, 568),
        textScaler: TextScaler.linear(1.3),
      ),
      child: MaterialApp(home: home),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Fails the test on any layout overflow reported while [body] runs.
Future<void> noOverflow(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  expect(errors, isEmpty, reason: errors.join('\n'));
}

void main() {
  Widget dashboard(SmallScreenDevice device) => Esp32Dashboard(
    service: device,
    darkMode: false,
    onDarkModeChanged: (_) {},
  );

  testWidgets('home, profiles and settings fit a small phone', (tester) async {
    await noOverflow(tester, () async {
      await show(tester, dashboard(SmallScreenDevice()));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await tester.pump();
      await tester.tap(find.text('Profiles'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Electric kettle in the kitchen corner'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -2000));
      await tester.pump();
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

  testWidgets('offline banner and settings fit a small phone', (tester) async {
    await noOverflow(tester, () async {
      await show(tester, dashboard(SmallScreenDevice(online: false)));
      expect(find.text('Your WisePlug is offline'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await tester.pump();
    });
  });

  testWidgets('safety countdown dialog fits a small phone', (tester) async {
    final device = SmallScreenDevice(warning: true);
    await noOverflow(tester, () async {
      await show(
        tester,
        SafetyAlertListener(
          service: device,
          alarm: SilentAlarm(),
          child: const Scaffold(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('seconds'), findsOneWidget);
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sign-in, Wi-Fi and activity screens fit a small phone', (
    tester,
  ) async {
    final device = SmallScreenDevice();
    await noOverflow(tester, () async {
      await show(tester, const SignInScreen());
      await show(tester, WifiConfigScreen(service: device));
      await show(
        tester,
        ActivityScreen(service: device, nameFor: (_) => 'Bedroom ceiling fan'),
      );
      expect(find.textContaining('Safety limit reached'), findsOneWidget);
    });
  });

  testWidgets('registration form and Wi-Fi progress dialogs fit', (
    tester,
  ) async {
    final device = SmallScreenDevice();
    final profile = LearnedAppliance.fromMap(
      'A',
      'UNNAMED_DEVICE_1792049550000_0a1b2c3d',
      {},
    );
    final reading = OutletReading.fromMap('A', {});
    await noOverflow(tester, () async {
      for (final registration in [true, false]) {
        await show(
          tester,
          Scaffold(
            body: Esp32ProfileEditor(
              service: device,
              reading: reading,
              profile: profile,
              registration: registration,
            ),
          ),
        );
      }
      await show(
        tester,
        Scaffold(
          body: WifiProvisioningDialog(
            ssid: 'A very long home network name',
            updates: Stream.value(
              const WifiProvisionUpdate(
                WifiProvisionStage.rolledBack,
                network: 'Another long network name',
              ),
            ),
          ),
        ),
      );
    });
  });
}
