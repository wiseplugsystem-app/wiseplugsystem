// Easy to read for people who do not use technology much (lib/theme.dart):
// text size, contrast (WCAG 2.2 AA, 4.5:1), 48 dp buttons, and no technical
// words on the screens people use.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/recognition.dart';
import 'package:wiseplug/screens/esp32_dashboard.dart';
import 'package:wiseplug/screens/recognition_prompt.dart';
import 'package:wiseplug/screens/registration_dialog.dart';
import 'package:wiseplug/theme.dart';

import 'fake_recognition.dart';
import 'responsive_test.dart' show SmallScreenDevice;

// The app's accent colours (esp32_live_view.dart) and Material ones used as text.
const accents = {
  'green': Color(0xFF00B744),
  'amber': Color(0xFFF5B800),
  'blue': Color(0xFF00A4EF),
  'red': Colors.red,
  'orange': Colors.orange,
  'material green': Colors.green,
  'grey': Colors.grey,
};

/// Words people should not have to understand. Kept on purpose (the owner's
/// choice): outlet, appliance profile(s), usage session(s), sample, and
/// watts as numbers ("73 W").
final technical = <RegExp>[
  RegExp(r'\bwatts?\b', caseSensitive: false),
  RegExp(r'power factor', caseSensitive: false),
  RegExp(r'\bPF\b'),
  RegExp(r'\bMode \d'),
  RegExp(r'\bserver\b', caseSensitive: false),
  RegExp(r'\bsync', caseSensitive: false),
  RegExp(r'calibrat', caseSensitive: false),
  RegExp(r'tolerance', caseSensitive: false),
  RegExp(r'\bESP32\b'),
  RegExp(r'Supabase|Firebase', caseSensitive: false),
  RegExp(r'telemetry', caseSensitive: false),
  RegExp(r'\bRSSI\b|\bNTP\b|\btimeout\b', caseSensitive: false),
  RegExp(r'firmware', caseSensitive: false),
];

List<String> shownTexts(WidgetTester tester) => [
  for (final w in tester.widgetList<Text>(find.byType(Text)))
    w.data ?? w.textSpan?.toPlainText() ?? '',
];

void expectPlainWords(WidgetTester tester, String screen) {
  for (final text in shownTexts(tester)) {
    for (final word in technical) {
      expect(word.hasMatch(text), isFalse, reason: '$screen: "$text" ($word)');
    }
  }
}

Future<void> showApp(
  WidgetTester tester,
  Widget home, {
  Brightness? dark,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: wisePlugTheme(dark ?? Brightness.light),
      builder: fitTextToScreen,
      home: home,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  test('text colours reach 4.5:1 in light and dark mode', () {
    for (final background in [lightBackground, Colors.white, darkSurface]) {
      for (final MapEntry(:key, :value) in accents.entries) {
        final text = readableOn(value, background);
        expect(
          contrastRatio(text, background),
          greaterThanOrEqualTo(4.5),
          reason: '$key on $background',
        );
      }
    }
    // The faint grey the app used for labels was only about 2.7:1.
    expect(contrastRatio(Colors.grey, Colors.white), lessThan(3));
    // Buttons: white on the dark green, dark text on amber.
    final green = readableOn(const Color(0xFF00B744), Colors.white);
    expect(contrastRatio(Colors.white, green), greaterThanOrEqualTo(4.5));
    expect(
      contrastRatio(
        Colors.black87.withValues(alpha: 1),
        const Color(0xFFF5B800),
      ),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('secondary text is readable in both modes', (tester) async {
    for (final brightness in Brightness.values) {
      late Color muted;
      await tester.pumpWidget(
        MaterialApp(
          theme: wisePlugTheme(brightness),
          home: Builder(
            builder: (context) {
              muted = context.muted;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle(); // a theme change animates
      final background = brightness == Brightness.light
          ? lightBackground
          : darkSurface;
      expect(contrastRatio(muted, background), greaterThanOrEqualTo(4.5));
    }
  });

  test('text fits the screen: smaller on narrow phones, full on tablets', () {
    expect(screenTextFactor(320), closeTo(0.85, 0.001));
    expect(screenTextFactor(360), lessThan(screenTextFactor(412)));
    expect(screenTextFactor(800), 1.0);
    expect(screenTextFactor(200), 0.85);
  });

  testWidgets('the phone text setting is capped at 1.3x', (tester) async {
    late TextScaler scaler;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 1280),
          textScaler: TextScaler.linear(2),
        ),
        child: MaterialApp(
          builder: fitTextToScreen,
          home: Builder(
            builder: (context) {
              scaler = MediaQuery.textScalerOf(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(scaler.scale(16), closeTo(16 * maxTextScale, 0.01));
  });

  test('body text is 16 sp, nothing under 14 sp; buttons are 48 dp tall', () {
    final theme = wisePlugTheme(Brightness.light);
    final t = theme.textTheme;
    expect(t.bodyMedium!.fontSize, 16);
    expect(t.bodyLarge!.fontSize, 16);
    expect(t.labelLarge!.fontSize, 16);
    for (final s in [t.bodySmall, t.labelMedium, t.labelSmall]) {
      expect(s!.fontSize, greaterThanOrEqualTo(14));
    }
    expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
    for (final style in [
      theme.textButtonTheme.style,
      theme.filledButtonTheme.style,
      theme.outlinedButtonTheme.style,
      theme.elevatedButtonTheme.style,
      theme.iconButtonTheme.style,
    ]) {
      expect(style!.minimumSize!.resolve({})!.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('no technical words: Home, Appliance Profiles, Settings', (
    tester,
  ) async {
    final recognition = FakeRecognition()
      ..list = [
        RegisteredAppliance.fromRow(
          {
            'id': 'fan',
            'name': 'Bedroom fan',
            'max_runtime_mins': 240,
            'use_count': 3,
            'appliance_types': {'name': 'Electric fan'},
          },
          modes: [
            ApplianceMode.fromRow({
              'id': 'm',
              'mode_name': 'Normal',
              'sample_count': 3,
              'avg_power_w_mean': 57,
            }),
            ApplianceMode.fromRow({
              'id': 'm2',
              'mode_name': 'Mode 2',
              'sample_count': 2,
            }),
          ],
        ),
      ];
    await showApp(
      tester,
      Esp32Dashboard(
        service: SmallScreenDevice(),
        recognition: recognition,
        darkMode: false,
        onDarkModeChanged: (_) {},
      ),
    );
    expectPlainWords(tester, 'Home');
    // No history on Home (removed on request).
    expect(find.text('History'), findsNothing);
    expect(find.text('In use'), findsOneWidget); // A: the kettle
    expect(find.text('Ready to use'), findsOneWidget); // B: nothing running
    await tester.tap(find.text('Appliances'));
    await tester.pump(const Duration(milliseconds: 500));
    expectPlainWords(tester, 'My appliances');
    await tester.tap(find.text('Bedroom fan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expectPlainWords(tester, 'Appliance');
    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 500));
    expectPlainWords(tester, 'Settings');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no technical words: registration and the questions', (
    tester,
  ) async {
    await showApp(
      tester,
      Scaffold(body: RegistrationDialog(service: FakeRecognition())),
    );
    expectPlainWords(tester, 'Registration');
    for (final status in [
      'UNKNOWN',
      'SAME_TYPE_IN_USE',
      'AMBIGUOUS',
      'MATCHED_PROVISIONAL',
    ]) {
      await showApp(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: RecognitionPromptSheet(
              session: session(
                status: status,
                applianceId: 'f',
                applianceName: 'Bedroom fan',
                promptText: 'This looks like another Fan. Register as Fan 2?',
                registerAs: {
                  'typeName': 'Fan',
                  'name': 'Fan 2',
                  'resembles': 'Fan 1',
                },
                candidates: [
                  {
                    'applianceId': 'f',
                    'name': 'Fan 1',
                    'typeName': 'Fan',
                    'modeName': 'Mode 2',
                  },
                ],
              ),
            ),
          ),
        ),
      );
      expectPlainWords(tester, 'Question $status');
    }
  });
}
