// The app side of rule-based recognition: the registration state machine,
// the recognition prompts, the guided registration and the Profiles tab.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/appliance_icons.dart';
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

    test('a setting already saved (same fan speed again) is never saved', () {
      final t = RegistrationTracker(startedAt: start, applianceId: 'fan-1');
      OutletSession again({bool open = true, int stage = 2}) => session(
        eventId: 'r3',
        stage: stage,
        status: 'MATCHED_PROVISIONAL',
        applianceId: 'fan-1',
        startedAt: start.add(const Duration(minutes: 5)),
        endedAt: open ? null : start.add(const Duration(minutes: 6)),
      );
      // Recognized as fan-1 already at Stage 1: told at once, not recorded.
      expect(t.next(again(stage: 1)), RegistrationStep.alreadyDone);
      expect(t.next(again()), RegistrationStep.alreadyDone);
      // Switched off: ready for the next (different) speed.
      expect(t.next(again(open: false)), RegistrationStep.plugIn);
      // "Which appliance?" with fan-1 among the choices is a repeat too.
      final ambiguous = session(
        eventId: 'r4',
        status: 'AMBIGUOUS',
        candidates: [
          {'applianceId': 'fan-1', 'name': 'Fan 1', 'typeName': 'Fan'},
          {'applianceId': 'fan-2', 'name': 'Fan 2', 'typeName': 'Fan'},
        ],
        startedAt: start.add(const Duration(minutes: 8)),
      );
      expect(t.next(ambiguous), RegistrationStep.alreadyDone);
      // A new speed (not recognized) is recorded as usual.
      expect(
        t.next(run('r5', after: const Duration(minutes: 10))),
        RegistrationStep.record,
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
    expect(find.text('Something new on Outlet A'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Register'), findsOneWidget);
    expect(
      find.textContaining('turns it off after 30 minutes'),
      findsOneWidget,
    );
    expect(find.textContaining("Don't touch the buttons"), findsOneWidget);
    // Nothing picked yet: one sample.
    expect(find.text('Do this 1 time.'), findsOneWidget);
    // A fan: one sample for each speed, and the number of speeds can change.
    await tester.ensureVisible(find.text('Electric fan'));
    await tester.tap(find.text('Electric fan'));
    await tester.pumpAndSettle();
    expect(find.text('How many speeds does your fan have?'), findsOneWidget);
    expect(
      find.text('Do this 3 times, a different speed each time (any order).'),
      findsOneWidget,
    );
    expect(find.text('Level 1  →  Level 2  →  Level 3'), findsNothing);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '4'));
    await tester.tap(find.widgetWithText(ChoiceChip, '4'));
    await tester.pumpAndSettle();
    expect(
      find.text('Do this 4 times, a different speed each time (any order).'),
      findsOneWidget,
    );
    // A rice cooker: Cook, then Keep warm.
    await tester.ensureVisible(find.text('Rice cooker'));
    await tester.tap(find.text('Rice cooker'));
    await tester.pumpAndSettle();
    expect(find.text('Cook  →  Keep warm'), findsOneWidget);
    // A charger: 3 samples (its power changes with the battery).
    await tester.ensureVisible(find.text('Phone charger'));
    await tester.tap(find.text('Phone charger'));
    await tester.pumpAndSettle();
    expect(find.text('Do this 3 times.'), findsOneWidget);
    expect(find.textContaining('one with the battery low'), findsOneWidget);
    // Other: one sample, and more settings can be added.
    await tester.ensureVisible(find.text('Other'));
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add another setting'));
    await tester.tap(find.text('Add another setting'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Its name'), 'High');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Normal  →  High'), findsOneWidget);
    await tester.ensureVisible(find.text('Not now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    // The same run does not ask again; the card still offers the answer.
    recognition.sessions.add({'A': session()});
    await tester.pumpAndSettle();
    expect(find.text('Something new on Outlet A'), findsNothing);
    expect(find.text('Needs your answer'), findsOneWidget);
    // The safety limit is under the card's "Details".
    await tester.ensureVisible(find.text('Details'));
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
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
    // No pop-up, even after Stage 2: the outlet card itself asks, with a big
    // confirm button (pop-ups are for new or unsure appliances).
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Is this Fan?'), findsOneWidget);
    final yes = find.widgetWithText(FilledButton, 'Yes, it is Fan');
    expect(yes, findsOneWidget);
    await tester.tap(yes);
    await tester.pumpAndSettle();
    expect(recognition.calls, ['confirm e-prov fan-1']);
    expect(find.textContaining('Confirmed: Fan'), findsOneWidget);
    // "No" still opens the question with the other answers.
    await tester.tap(find.text('No, it is something else'));
    await tester.pumpAndSettle();
    expect(find.text('No, register a new appliance'), findsOneWidget);
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
    // "What are you adding?": a picture grid; nothing chosen yet.
    expect(find.text('What are you adding?'), findsOneWidget);
    await tester.ensureVisible(find.text('Register'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    expect(find.text('Choose what you are adding.'), findsOneWidget);
    await tester.ensureVisible(find.text('Electric fan'));
    await tester.tap(find.text('Electric fan'));
    await tester.pumpAndSettle();
    expect(find.text('Choose what you are adding.'), findsNothing);
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
      'register r1 new Electric fan Bedroom fan',
      'register r2 new-1',
      'register r3 new-1',
    ]);
    // One sample for each speed, in order.
    expect(recognition.plannedLevels, ['Level 1', 'Level 2', 'Level 3']);
    expect(recognition.sentLevels, ['Level 1', 'Level 2', 'Level 3']);
    expect(recognition.iconKeys, ['fan']); // sent once, with the new type
    expect(find.textContaining('All done!'), findsOneWidget);
    expect(find.text('3 of 3 done'), findsOneWidget);
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

  testWidgets('the "which appliance" prompt offers one still registering', (
    tester,
  ) async {
    final (device, recognition) = await mountLive(tester, appliances: [lamp()]);
    device.readings.add({'B': running('B')});
    final fan1 = {
      'applianceId': 'fan-1',
      'name': 'Fan 1',
      'typeName': 'Fan',
      'modeName': 'Normal',
    };
    recognition.sessions.add({
      'B': session(
        outlet: 'outlet_2',
        status: 'AMBIGUOUS',
        eventId: 'e-amb',
        promptText: 'Is this Fan 1 or Fan 2?',
        candidates: [
          fan1,
          {...fan1, 'applianceId': 'fan-2', 'name': 'Fan 2'},
        ],
      ),
    });
    await tester.pumpAndSettle();
    expect(find.text('Which appliance is on Outlet B?'), findsOneWidget);
    expect(find.text('Still registering:'), findsOneWidget);
    final cont = find.textContaining('It is Lamp: continue registering');
    expect(cont, findsOneWidget);
    await tester.ensureVisible(cont);
    await tester.tap(cont);
    await tester.pumpAndSettle();
    expect(find.text('Finish adding Lamp'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unfinished appliance can be continued from its page', (
    tester,
  ) async {
    await mountLive(tester, appliances: [lamp()]);
    await tester.tap(find.text('Appliances'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lamp'));
    await tester.pumpAndSettle();
    expect(find.textContaining('or tap Continue registering'), findsOneWidget);
    await tester.ensureVisible(find.text('Continue registering'));
    await tester.tap(find.text('Continue registering'));
    await tester.pumpAndSettle();
    expect(find.text('Finish adding Lamp'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

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
      await tester.tap(find.text('Appliances'));
      await tester.pumpAndSettle();
      expect(find.text('My appliances'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Used 2 of 7 times'), findsOneWidget);
      // Where it runs, and for exactly how long (it started a minute ago).
      expect(
        find.textContaining(RegExp(r'^Running on Outlet B · 1:0[0-2]$')),
        findsOneWidget,
      );
      expect(find.text('Registering'), findsOneWidget);
      // One action per row (open it): Delete is on the appliance's screen.
      expect(find.byTooltip('Delete appliance'), findsNothing);
      await tester.tap(find.text('Fan 1'));
      await tester.pumpAndSettle();
      expect(find.text('Appliance'), findsOneWidget);
      expect(find.text('57 W'), findsOneWidget);
      // Safe time (set by WisePlug) and the learning: 2 of 7 uses so far, so
      // the 30-minute default, as the plug enforces (not the type's 4 h).
      expect(find.text('Safe time'), findsOneWidget);
      expect(find.text('30 min'), findsOneWidget);
      expect(find.text('Used'), findsOneWidget);
      expect(find.text('2 of 7 times'), findsOneWidget);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Desk fan');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(recognition.calls, ['rename fan-1 Desk fan']);
      // Edit can also change what it is (and so its safe time).
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('also changes its safe time'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<ApplianceKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flat iron').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(recognition.calls.last, 'type fan-1 Flat iron flat_iron');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(recognition.calls.last, 'delete fan-1');
      // Deleting closes the detail screen: back on the list.
      expect(find.text('Appliance'), findsNothing);
      expect(find.text('My appliances'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the appliance detail screen: a full page with no usage history; Back '
    'returns to the list; a run left open on an idle outlet is not shown '
    'as plugged in',
    (tester) async {
      final fan = RegisteredAppliance.fromRow(
        {
          'id': 'fan-1',
          'name': 'Fan 1',
          'max_runtime_mins': 240,
          'use_count': 3,
          'last_outlet': 'outlet_1',
          'appliance_types': {'name': 'Fan'},
        },
        modes: fan1().modes,
        // An open run on A whose end was never reported.
        runningOn: 'outlet_1',
      );
      final (device, _) = await mountLive(tester, appliances: [fan]);
      final idle = OutletReading.fromMap('A', {
        'status': 'Idle',
        'currentState': 'IDLE',
        'sessionID': 'boot',
        'power_W': 0,
        'sensor_valid': true,
        'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
      });
      device.readings.add({'A': idle});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appliances'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Running on'), findsNothing);
      expect(
        find.text('Not plugged in · last used on Outlet A'),
        findsOneWidget,
      );
      await tester.tap(find.text('Fan 1'));
      await tester.pumpAndSettle();
      // A full screen (its own page and title), not a pop-up.
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Appliance'),
        ),
        findsOneWidget,
      );
      // Everything about the appliance is there...
      for (final label in ['Right now', 'Safe time', 'Used', 'Uses about']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // ...and only that: the old, overlapping fields are gone.
      for (final gone in ['Saved name', 'Usage sessions', 'Total sessions']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.text('Fan'), findsOneWidget);
      expect(find.text('Off (last used in Outlet A)'), findsOneWidget);
      expect(find.text('3 of 7 times'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Edit'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Delete'), findsOneWidget);
      // ...but no usage history.
      for (final gone in [
        'Usage history',
        'Total runtime',
        'Energy used',
        'Runs',
        'Outlet B',
      ]) {
        expect(find.textContaining(gone), findsNothing, reason: gone);
      }
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('My appliances'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the home screen says when it was updated, in plain words', (
    tester,
  ) async {
    final (device, _) = await mountLive(tester);
    device.readings.add({'A': running('A')});
    await tester.pumpAndSettle();
    // Under the card's "Details": "Last updated  3:19 PM" (today: the time only).
    await tester.ensureVisible(find.text('Details'));
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Last updated'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'^\d{1,2}:\d\d [AP]M$')),
      findsOneWidget,
    );
    for (final word in ['ESP32', 'Device updated', 'stale', 'telemetry']) {
      expect(find.textContaining(word), findsNothing, reason: word);
    }
    await tester.pumpWidget(const SizedBox());
  });

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
      find.textContaining('It is Lamp: continue (1 of 3 done)'),
      findsOneWidget,
    );
    expect(find.textContaining('It is Fan 1'), findsNothing);
    await tester.tap(find.textContaining('It is Lamp'));
    await tester.pumpAndSettle();
    expect(find.text('Finish adding Lamp'), findsOneWidget);
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
    // The card's timer: how long the appliance has been on.
    expect(find.text('On for 1 h 02 min'), findsOneWidget);
    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);

    // Under an hour it counts minutes and seconds.
    device.readings.add({
      'A': OutletReading.fromMap('A', {
        'status': 'Active',
        'currentState': 'ACTIVE',
        'sessionID': 'boot',
        'appliance': 'Fan',
        'sensor_valid': true,
        'last_updated_ms': DateTime.now().millisecondsSinceEpoch,
        'start_time': DateTime.now()
            .subtract(const Duration(minutes: 12, seconds: 34))
            .millisecondsSinceEpoch,
      }),
    });
    await tester.pump();
    expect(
      find.textContaining(RegExp(r'^On for 12 min 3[4-6] s')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  // Appliance icons (lib/models/appliance_icons.dart).
  Finder iconOf(IconData icon, double size) => find.byWidgetPredicate(
    (w) => w is Icon && w.icon == icon && w.size == size,
  );

  testWidgets('Home: each outlet shows what runs on it (48 dp); an appliance '
      'not recognised yet shows the question mark', (tester) async {
    final (device, recognition) = await mountLive(tester, appliances: [fan1()]);
    device.readings.add({
      'A': running('A', appliance: 'Fan 1'),
      'B': running('B'),
    });
    recognition.sessions.add({
      'A': session(
        status: 'MATCHED_CONFIRMED',
        applianceId: 'fan-1',
        applianceName: 'Fan 1',
      ),
    });
    await tester.pumpAndSettle();
    expect(iconOf(Icons.air, 48), findsOneWidget); // Fan 1 on A
    expect(iconOf(Icons.question_mark, 48), findsOneWidget); // unknown on B
    // Never icon-only: the name is next to it.
    expect(find.text('Fan 1'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Profiles list: each appliance shows its type icon (24 dp)', (
    tester,
  ) async {
    final (device, _) = await mountLive(tester, appliances: [fan1(), lamp()]);
    device.readings.add({'A': running('A')});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appliances'));
    await tester.pumpAndSettle();
    expect(iconOf(Icons.air, 24), findsOneWidget); // Fan 1 (type Fan)
    expect(iconOf(Icons.lightbulb_outline, 24), findsOneWidget); // Lamp
    expect(find.byIcon(Icons.person_outline), findsNothing); // no person icon
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"What are you adding?": every type as a picture (48 dp) with '
      'its name, and Other', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RegistrationDialog(service: FakeRecognition())),
      ),
    );
    await tester.pumpAndSettle();
    for (final k in applianceKinds) {
      if (!canAdd(k)) continue;
      expect(find.text(k.label), findsOneWidget, reason: k.label);
      expect(iconOf(k.icon, 48), findsWidgets, reason: k.label);
    }
    expect(find.text('Other'), findsOneWidget);
    expect(iconOf(Icons.electrical_services, 48), findsOneWidget);
    // "Other" lets you write what it is.
    expect(find.widgetWithText(TextFormField, 'What is it?'), findsNothing);
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'What is it?'), findsOneWidget);
  });

  testWidgets('hardware limit: no Aircon to pick, the watt limit is shown, '
      'and an aircon typed under Other is refused', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RegistrationDialog(service: FakeRecognition())),
      ),
    );
    await tester.pumpAndSettle();
    // Every type whose usual range goes above 1,760 W is gone.
    for (final k in [
      'Aircon',
      'Induction cooker',
      'Washing machine',
      'Hair dryer',
      'Electric kettle',
    ]) {
      expect(find.text(k), findsNothing, reason: k);
    }
    // No listed wattage: not offered (they go under Other).
    for (final k in [
      'Air fryer',
      'Lamp / LED bulb',
      'Water dispenser',
      'Blender',
    ]) {
      expect(find.text(k), findsNothing, reason: k);
    }
    // Only the five types with their usual power, and Other.
    for (final k in ['TV', 'Refrigerator', 'Microwave']) {
      expect(find.text(k), findsNothing, reason: k);
    }
    expect(find.text('35–65 W'), findsWidgets); // electric fan (and "Fan")
    expect(find.text('1,000–1,500 W'), findsOneWidget); // flat iron
    expect(find.text('30–750 W'), findsOneWidget); // rice cooker
    expect(find.text('10–140 W'), findsOneWidget); // laptop charger
    expect(find.text('5–120 W'), findsOneWidget); // phone charger
    expect(find.textContaining('Up to 1,760 W'), findsOneWidget);
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'What is it?'),
      'Washing machine',
    );
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    expect(find.textContaining('WisePlug cannot power this'), findsOneWidget);
  });

  testWidgets('prompts: the appliance icon in "Register as Fan 2?" and in '
      'each choice of "Which appliance…?"', (tester) async {
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
      find.descendant(
        of: find.byType(BottomSheet),
        matching: iconOf(Icons.air, 24),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());

    final (device2, recognition2) = await mountLive(tester);
    device2.readings.add({'B': running('B')});
    recognition2.sessions.add({
      'B': session(
        outlet: 'outlet_2',
        status: 'AMBIGUOUS',
        eventId: 'e-amb2',
        promptText: 'Is this Fan 1 or Desk lamp?',
        candidates: [
          {
            'applianceId': 'f',
            'name': 'Fan 1',
            'typeName': 'Fan',
            'modeName': 'Normal',
          },
          {
            'applianceId': 'l',
            'name': 'Desk lamp',
            'typeName': 'Lamp',
            'modeName': 'Normal',
          },
        ],
      ),
    });
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: iconOf(Icons.question_mark, 24)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: iconOf(Icons.air, 24)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: iconOf(Icons.lightbulb_outline, 24)),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
