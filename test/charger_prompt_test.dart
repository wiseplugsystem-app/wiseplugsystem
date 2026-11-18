// A phone charger's reading is never offered as a new appliance: the pop-up
// only confirms the charger or picks which charger / phone it is
// (recognizeWithChargers -> candidates.chargerChoice).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/recognition.dart';
import 'package:wiseplug/screens/recognition_prompt.dart';

OutletSession _session({
  required String status,
  required bool chargerChoice,
  String? applianceId,
  String? applianceName,
  List<Map<String, Object?>> candidates = const [],
  Map<String, Object?>? suggested,
  String? promptText,
}) => OutletSession.fromRow({
  'event_id': 'boot_outlet_A_1',
  'device_id': 'gadget-1',
  'outlet': 'outlet_1',
  'stage': 2,
  'status': status,
  'appliance_id': applianceId,
  'candidates': {
    'candidates': candidates,
    'suggested': suggested,
    'registerAs': null,
    'applianceName': applianceName,
    'modeName': 'Charging',
    'reason': 'test',
    'chargerChoice': chargerChoice,
  },
  'prompt_text': promptText,
  'cutoff_s': 1800,
  'started_at': DateTime.now().toUtc().toIso8601String(),
});

Map<String, Object?> _charger(String id) => {
  'applianceId': id,
  'name': id,
  'typeName': 'Phone charger',
  'modeName': 'Charging',
  'score': 0.2,
  'charger': true,
};

Future<void> _show(WidgetTester tester, OutletSession s) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: RecognitionPromptSheet(session: s)),
      ),
    ),
  );
}

void main() {
  testWidgets('one charger: only "Yes, it is …" (no register)', (
    tester,
  ) async {
    final s = _session(
      status: 'MATCHED_PROVISIONAL',
      chargerChoice: true,
      applianceId: 'Purple charger',
      applianceName: 'Purple charger',
      candidates: [_charger('Purple charger')],
      promptText: 'Is this Purple charger?',
    );
    expect(s.chargerChoice, isTrue);
    expect(s.candidates.single.charger, isTrue);
    await _show(tester, s);
    expect(find.text('Yes, it is Purple charger'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.textContaining('register', findRichText: true), findsNothing);
    expect(find.textContaining('Register'), findsNothing);
  });

  testWidgets('several chargers: pick which one (no register)', (
    tester,
  ) async {
    final s = _session(
      status: 'AMBIGUOUS',
      chargerChoice: true,
      candidates: [_charger('Purple charger'), _charger('Samsung charger')],
      suggested: _charger('Purple charger'),
      promptText: 'Which charger is this: Purple charger or Samsung charger?',
    );
    await _show(tester, s);
    expect(find.text('Which charger is on Outlet A?'), findsOneWidget);
    expect(find.text('Purple charger'), findsOneWidget);
    expect(find.text('Samsung charger'), findsOneWidget);
    expect(find.text('Yes, it is Purple charger'), findsOneWidget);
    await tester.tap(find.text('Samsung charger'));
    await tester.pump();
    expect(find.text('Yes, it is Samsung charger'), findsOneWidget);
    expect(find.text('Register new appliance'), findsNothing);
    expect(find.text('Ask me later'), findsOneWidget);
  });

  testWidgets('not a charger: the register options stay as before', (
    tester,
  ) async {
    final s = _session(
      status: 'MATCHED_PROVISIONAL',
      chargerChoice: false,
      applianceId: 'Fan',
      applianceName: 'Fan',
    );
    await _show(tester, s);
    expect(find.text('No, register a new appliance'), findsOneWidget);
  });
}
