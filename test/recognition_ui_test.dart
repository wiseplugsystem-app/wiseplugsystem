// The app side of rule-based recognition: the registration state machine,
// the recognition prompts, the guided registration and the Profiles tab.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/esp32_data.dart';
import 'package:wiseplug/models/gadget_status.dart';
import 'package:wiseplug/models/recognition.dart';
import 'package:wiseplug/screens/esp32_live_view.dart';
import 'package:wiseplug/screens/registration_dialog.dart';
import 'package:wiseplug/services/esp32_service.dart';

import 'fake_recognition.dart';

class Device extends Fake implements Esp32Service {
  final readings = StreamController<Map<String, OutletReading>>.broadcast();
  @override
  Stream<Map<String, OutletReading>> streamOutlets() => readings.stream;
  @override
  Stream<GadgetStatus> streamGadgetStatus() => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> streamPreferences() => Stream.value({});
}

OutletReading running(
  String outlet, {
  String appliance = 'Unknown appliance',
}) => OutletReading.fromMap(outlet, {
  'status': 'Active',
  'currentState': 'ACTIVE',
  'sessionID': 'boot',
  'appliance': appliance,
  'power_W': 57,
  'sensor_valid': true,
  'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
  'start_time': DateTime.now()
      .subtract(const Duration(minutes: 1))
      .millisecondsSinceEpoch,
});

Future<(Device, FakeRecognition)> mountLive(
  WidgetTester tester, {
  List<RegisteredAppliance> appliances = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final device = Device();
  final recognition = FakeRecognition()..list = [...appliances];
  await tester.pumpWidget(
    MaterialApp(
      home: Esp32LiveView(
        service: device,
        recognition: recognition,
        darkMode: false,
        onDarkModeChanged: (_) {},
      ),
    ),
  );
  await tester.pump();
  return (device, recognition);
}

void main() {
  group('RegistrationTracker', () {
    final start = DateTime.utc(2026, 10, 29, 12);
    OutletSession run(
      String id, {
      int stage = 2,
      bool open = true,
      Duration after = Duration.zero,
    }) => session(
      eventId: id,
      stage: stage,
      startedAt: start.add(after),
      endedAt: open ? null : start.add(after + const Duration(minutes: 1)),
    );

    test('plug in, measure, record, switch off, then the next plug-in', () {
      final t = RegistrationTracker(startedAt: start);
      expect(t.next(null), RegistrationStep.plugIn);
      expect(
        t.next(run('r1', stage: 1, after: const Duration(seconds: 3))),
        RegistrationStep.measuring,
      );
      expect(
        t.next(run('r1', after: const Duration(seconds: 3))),
        RegistrationStep.record,
      );
      t.recorded('r1');
      expect(
        t.next(run('r1', after: const Duration(seconds: 3))),
        RegistrationStep.switchOff,
      );
      // Switched off: the same run, ended, is not counted again.
      expect(
        t.next(run('r1', open: false, after: const Duration(seconds: 3))),
        RegistrationStep.plugIn,
      );
      expect(
        t.next(run('r2', stage: 1, after: const Duration(minutes: 2))),
        RegistrationStep.measuring,
      );
    });

    test('a run already going before registration must be restarted', () {
      final t = RegistrationTracker(startedAt: start);
      expect(
        t.next(run('old', after: const Duration(minutes: -5))),
        RegistrationStep.restart,
      );
      expect(
        t.next(run('old', open: false, after: const Duration(minutes: -5))),
        RegistrationStep.plugIn,
      );
    });

    test(
      'the run that opened the prompt counts, even though it started earlier',
      () {
        final t = RegistrationTracker(
          startedAt: start,
          initialEventId: 'prompted',
        );
        expect(
          t.next(run('prompted', after: const Duration(minutes: -1))),
          RegistrationStep.record,
        );
      },
    );

    test('a run that ended before Stage 2 is too short, once', () {
      final t = RegistrationTracker(startedAt: start);
      final short = run(
        's',
        stage: 1,
        open: false,
        after: const Duration(seconds: 5),
      );
      expect(t.next(short), RegistrationStep.tooShort);
      expect(t.next(short), RegistrationStep.plugIn);
    });
  });

  test('an outlet_sessions row parses candidates, suggestion and status', () {
    final s = session(
      status: 'SAME_TYPE_IN_USE',
      outlet: 'outlet_2',
      registerAs: {'typeName': 'Fan', 'name': 'Fan 2', 'resembles': 'Fan 1'},
      candidates: [
        {
          'applianceId': 'f1',
          'name': 'Fan 1',
          'typeName': 'Fan',
          'modeName': 'Normal',
          'score': 0.2,
        },
      ],
    );
    expect(s.outletName, 'B');
    expect(s.status.needsAnswer, isTrue);
    expect(s.registerAs!.name, 'Fan 2');
    expect(s.candidates.single.score, 0.2);
    expect(RecognitionStatus.parse('MATCHED_PROVISIONAL').needsAnswer, isFalse);
  });

  testWidgets('UNKNOWN asks once to register and says the safe limit applies', (
    tester,
  ) async {
    final (device, recognition) = await mountLive(tester);
    device.readings.add({'A': running('A')});
    recognition.sessions.add({
      'A': session(promptText: 'New appliance detected. Register it?'),
    });
    await tester.pumpAndSettle();
    // Registration is a pop-up, opened by the new appliance itself.
    expect(find.byType(RegistrationDialog), findsOneWidget);
    expect(find.text('New appliance detected on Outlet A'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Register'), findsOneWidget);
    expect(find.textContaining('30-minute safety limit'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    // The same run does not ask again; the card still offers the answer.
    recognition.sessions.add({'A': session()});
    await tester.pumpAndSettle();
    expect(find.text('New appliance detected on Outlet A'), findsNothing);
    expect(find.text('Needs your answer'), findsOneWidget);
    expect(find.text('30 min (safe default)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AMBIGUOUS pre-selects the unit last used here and confirms it', (
    tester,
  ) async {
    final (device, recognition) = await mountLive(tester);
    device.readings.add({'B': running('B')});
    final fan2 = {
      'applianceId': 'fan-2',
      'name': 'Fan 2',
      'typeName': 'Fan',
      'modeName': 'Normal',
    };
    recognition.sessions.add({
      'B': session(
        outlet: 'outlet_2',
        status: 'AMBIGUOUS',
        eventId: 'e-amb',
        promptText: 'Is this Fan 1 or Fan 2?',
        reason: 'Fan 1 and Fan 2 give near-identical readings; WisePlug cannot tell identical units apart.',
        candidates: [
          {
            'applianceId': 'fan-1',
            'name': 'Fan 1',
            'typeName': 'Fan',
            'modeName': 'Normal',
          },
          fan2,
        ],
        suggested: fan2,
      ),
    });
    await tester.pumpAndSettle();
    expect(find.text('Which appliance is on Outlet B?'), findsOneWidget);
    expect(
      find.textContaining('cannot tell identical units apart'),
      findsOneWidget,
    );
    expect(find.text('Last used here'), findsOneWidget);
    await tester.tap(find.text('Yes, it is Fan 2'));
    await tester.pumpAndSettle();
    expect(recognition.calls, ['confirm e-amb fan-2']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('SAME_TYPE_IN_USE offers "Register as Fan 2" pre-filled', (
    tester,
  ) async {
    final (device, recognition) = await mountLive(tester);
    device.readings.add({'B': running('B')});
    recognition.sessions.add({
      'B': session(
        outlet: 'outlet_2',
        status: 'SAME_TYPE_IN_USE',
        promptText: 'This looks like another Fan. Register as Fan 2?',
        registerAs: {'typeName': 'Fan', 'name': 'Fan 2', 'resembles': 'Fan 1'},
      ),
    });
    await tester.pumpAndSettle();
    expect(
      find.text('This looks like another Fan. Register as Fan 2?'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Fan 1 is running on another outlet'),
      findsOneWidget,
    );
    await tester.tap(find.text('Register as Fan 2'));
    await tester.pumpAndSettle();
    expect(find.byType(RegistrationDialog), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Fan'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Fan 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a provisional label is marked and can be confirmed', (
    tester,
  ) async {
    final (device, recognition) = await mountLive(tester);
    device.readings.add({'A': running('A', appliance: 'Fan')});
    recognition.sessions.add({
      'A': session(
        status: 'MATCHED_PROVISIONAL',
        eventId: 'e-prov',
        applianceId: 'fan-1',
        applianceName: 'Fan',
      ),
    });
    await tester.pumpAndSettle();
    // Not a question by itself: no sheet opens, the card shows the badge.
    expect(find.text('Is this Fan?'), findsNothing);
    await tester.tap(find.text('Provisional · tap to confirm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, it is Fan'));
    await tester.pumpAndSettle();
    expect(recognition.calls, ['confirm e-prov fan-1']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('guided registration records 3 plug-ins on either outlet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recognition = FakeRecognition();
    final t0 = DateTime.now();
    OutletSession plugIn(
      String id, {
      int stage = 2,
      bool open = true,
      int s = 0,
      String outlet = 'outlet_1',
    }) => session(
      eventId: id,
      outlet: outlet,
      stage: stage,
      startedAt: t0.add(Duration(seconds: s)),
      endedAt: open ? null : t0.add(Duration(seconds: s + 70)),
    );
    // One entry per poll and outlet. Plug-ins 1 and 3 on A, plug-in 2 on B;
    // B starts with another appliance that was already running (ignored).
    final r1 = plugIn('r1', s: 1, open: false);
    final r2 = plugIn('r2', s: 90, open: false, outlet: 'outlet_2');
    recognition.latest['A'] = [
      null,
      plugIn('r1', stage: 1, s: 1),
      plugIn('r1', s: 1),
      r1,
      r1,
      r1,
      plugIn('r3', s: 180),
    ];
    recognition.latest['B'] = [
      plugIn('old', s: -600, outlet: 'outlet_2'),
      plugIn('old', s: -600, outlet: 'outlet_2'),
      plugIn('old', s: -600, outlet: 'outlet_2'),
      plugIn('old', s: -600, outlet: 'outlet_2'),
      plugIn('r2', s: 90, outlet: 'outlet_2'),
      r2,
      r2,
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: RegistrationDialog(
          service: recognition,
          pollEvery: const Duration(milliseconds: 50),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Only the type and the name: no mode, no safety limit (set by WisePlug).
    expect(find.textContaining('Mode'), findsNothing);
    expect(find.textContaining('Safe operating time'), findsNothing);
    expect(find.text('Which outlet will you use?'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Type of appliance'),
      'Fan',
    );
    // The name is required.
    await tester.ensureVisible(find.text('Register'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    expect(find.text('Give it a name you will recognise'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Bedroom fan',
    );
    await tester.ensureVisible(find.text('Register'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Register'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(recognition.calls, [
      'register r1 new Fan Bedroom fan',
      'register r2 new-1',
      'register r3 new-1',
    ]);
    expect(find.textContaining('is registered'), findsOneWidget);
    expect(find.text('3 of 3 samples'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  RegisteredAppliance fan1() => RegisteredAppliance.fromRow(
    {
      'id': 'fan-1',
      'name': 'Fan 1',
      'max_runtime_mins': 240,
      'use_count': 2,
      'last_outlet': 'outlet_1',
      'appliance_types': {'name': 'Fan'},
    },
    modes: [
      ApplianceMode.fromRow({
        'id': 'm1',
        'mode_name': 'Normal',
        'sample_count': 3,
        'avg_power_w_mean': 57,
        'avg_pf_mean': 0.92,
      }),
    ],
  );
  RegisteredAppliance lamp({String? runningOn}) => RegisteredAppliance.fromRow(
    {
      'id': 'lamp',
      'name': 'Lamp',
      'max_runtime_mins': 30,
      'appliance_types': {'name': 'Lamp'},
    },
    modes: [
      ApplianceMode.fromRow({
        'id': 'm2',
        'mode_name': 'Normal',
        'sample_count': 1,
      }),
    ],
    runningOn: runningOn,
  );

  testWidgets(
    'Profiles lists appliances, opens a profile, renames and deletes',
    (tester) async {
      final (device, recognition) = await mountLive(
        tester,
        appliances: [
          fan1(),
          lamp(runningOn: 'outlet_2'),
        ],
      );
      device.readings.add({'B': running('B', appliance: 'Lamp')});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profiles'));
      await tester.pumpAndSettle();
      expect(find.text('Appliance Profiles'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Learning · 5 more uses to learn'), findsOneWidget);
      // Where it runs, and for exactly how long (it started a minute ago).
      expect(
        find.textContaining(RegExp(r'^Running on Outlet B · 1:0[0-2]$')),
        findsOneWidget,
      );
      expect(find.text('Registering'), findsOneWidget);
      // A running appliance cannot be deleted; an idle one can.
      expect(find.byTooltip('Delete appliance'), findsOneWidget);
      await tester.tap(find.text('Fan 1'));
      await tester.pumpAndSettle();
      expect(find.text('Appliance\nProfile'), findsOneWidget);
      expect(find.text('57.0 W · PF 0.92'), findsOneWidget);
      // Safety limit (set by WisePlug) and the usage sessions, as in the
      // 19th commit: 2 of the 7 learning uses so far.
      expect(find.text('Learning · 2 of 7 uses (max 4 h)'), findsOneWidget);
      expect(find.text('Usage sessions'), findsOneWidget);
      expect(find.text('2 of 7 uses'), findsOneWidget);
      expect(find.text('Total sessions'), findsOneWidget);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Desk fan');
      await tester.tap(find.text('Save Profile'));
      await tester.pumpAndSettle();
      expect(recognition.calls, ['rename fan-1 Desk fan']);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(recognition.calls.last, 'delete fan-1');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the pop-up offers to continue an unfinished registration', (
    tester,
  ) async {
    final (device, recognition) = await mountLive(
      tester,
      appliances: [fan1(), lamp()],
    );
    device.readings.add({'A': running('A')});
    recognition.sessions.add({
      'A': session(promptText: 'New appliance detected. Register it?'),
    });
    await tester.pumpAndSettle();
    // Only the unfinished one is offered, never Fan 1 (fully registered).
    expect(
      find.textContaining('It is Lamp: continue registering (1 of 3)'),
      findsOneWidget,
    );
    expect(find.textContaining('It is Fan 1'), findsNothing);
    await tester.tap(find.textContaining('It is Lamp'));
    await tester.pumpAndSettle();
    expect(find.text('Continue registering Lamp'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the outlet card shows the exact running time, counting up', (
    tester,
  ) async {
    final (device, _) = await mountLive(tester);
    device.readings.add({
      'A': OutletReading.fromMap('A', {
        'status': 'Active',
        'currentState': 'ACTIVE',
        'sessionID': 'boot',
        'appliance': 'Fan',
        'sensor_valid': true,
        'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
        'start_time': DateTime.now()
            .subtract(const Duration(hours: 1, minutes: 2, seconds: 15))
            .millisecondsSinceEpoch,
      }),
    });
    await tester.pump();
    expect(find.text('Running time'), findsWidgets);
    expect(find.textContaining(RegExp(r'^1:02:1[5-7]$')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
