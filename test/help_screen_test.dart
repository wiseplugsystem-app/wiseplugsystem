import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/recognition.dart';
import 'package:wiseplug/screens/help_screen.dart';

void main() {
  testWidgets('How to use WisePlug: plain topics with the real numbers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HelpScreen(
          settings: RecognitionSettings(defaultCutoffMinutes: 30, learningUses: 7),
        ),
      ),
    );
    expect(find.text('How to use WisePlug'), findsOneWidget);
    expect(find.text('1. Getting started'), findsOneWidget);
    // The first topic is open; the others open with a tap.
    expect(find.text('Plug the WisePlug into the wall.'), findsOneWidget);
    await tester.tap(find.text('2. Adding a new appliance (first time only)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('after 30 minutes'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('5. When the safe time is up'), 200);
    await tester.tap(find.text('5. When the safe time is up'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Keep it on'), findsOneWidget);
  });
}
