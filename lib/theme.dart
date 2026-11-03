import 'package:flutter/material.dart';

/// The app's look, made for people who do not use technology much:
///  * body text 16 sp, nothing smaller than 14 sp, fitted to the screen's
///    width and the phone's text-size setting (see [fitTextToScreen]);
///  * every button, chip and icon button at least 48 dp tall on every
///    platform (the web build would otherwise shrink them to about 36 dp);
///  * text colours with at least 4.5:1 contrast (WCAG 2.2 AA) on the app's
///    light and dark backgrounds (see [ReadableColors]).
ThemeData wisePlugTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final base = ThemeData(
    useMaterial3: true,
    colorSchemeSeed: Colors.blue,
    brightness: brightness,
    scaffoldBackgroundColor: light ? lightBackground : null,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
  );
  final t = base.textTheme;
  TextStyle? size(TextStyle? s, double sp) => s?.copyWith(fontSize: sp);
  const tall = Size(64, 48);
  return base.copyWith(
    textTheme: t.copyWith(
      bodyLarge: size(t.bodyLarge, 16),
      bodyMedium: size(t.bodyMedium, 16),
      bodySmall: size(t.bodySmall, 14),
      labelLarge: size(t.labelLarge, 16),
      labelMedium: size(t.labelMedium, 14),
      labelSmall: size(t.labelSmall, 14),
      titleSmall: size(t.titleSmall, 16),
      titleMedium: size(t.titleMedium, 18),
      titleLarge: size(t.titleLarge, 22),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: tall),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: tall),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: tall),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(minimumSize: tall),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
  );
}

/// The largest the phone's text-size setting may make text (1.3x). Larger
/// settings would push buttons and numbers off a phone screen.
const maxTextScale = 1.3;

/// How much text shrinks for the screen: 0.85 on a 320 dp phone, rising to
/// full size on a 600 dp tablet, so every phone shows the same layout.
double screenTextFactor(double width) =>
    (0.85 + (width - 320) / (600 - 320) * 0.15).clamp(0.85, 1.0);

/// [MaterialApp.builder]: fits all text, including fixed sizes like the big
/// countdown, to the screen and caps the phone's text-size setting.
Widget fitTextToScreen(BuildContext context, Widget? child) {
  final media = MediaQuery.of(context);
  return MediaQuery(
    data: media.copyWith(
      textScaler: _FittedTextScaler(
        media.textScaler.clamp(maxScaleFactor: maxTextScale),
        screenTextFactor(media.size.shortestSide),
      ),
    ),
    child: child ?? const SizedBox(),
  );
}

class _FittedTextScaler extends TextScaler {
  final TextScaler phone;
  final double factor;
  const _FittedTextScaler(this.phone, this.factor);

  @override
  double scale(double fontSize) => phone.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => phone.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is _FittedTextScaler &&
      other.phone == phone &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(phone, factor);
}

/// The light page background. Cards are white; text is checked against this
/// slightly darker grey, the harder of the two.
const lightBackground = Color(0xFFF2F2F2);

/// The dark mode's card colour, the lightest dark surface (the hardest for
/// light text).
const darkSurface = Color(0xFF20252C);

/// WCAG contrast ratio of two colours (1..21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// [color] made darker (on a light background) or lighter (on a dark one)
/// until text in it reaches [ratio] against [background]. Keeps its hue, so
/// green stays green and amber stays amber.
Color readableOn(Color color, Color background, {double ratio = 4.5}) {
  final lighten = background.computeLuminance() < 0.5;
  var hsl = HSLColor.fromColor(color);
  for (var i = 0; i < 50; i++) {
    if (contrastRatio(hsl.toColor(), background) >= ratio) break;
    final l = (hsl.lightness + (lighten ? 0.02 : -0.02)).clamp(0.0, 1.0);
    hsl = hsl.withLightness(l);
  }
  return hsl.toColor();
}

/// Text colours that stay readable in light and dark mode.
extension ReadableColors on BuildContext {
  bool get _dark => Theme.of(this).brightness == Brightness.dark;
  Color get _background => _dark ? darkSurface : lightBackground;

  /// [accent] (a status green, amber, red or blue) as a text colour.
  Color readable(Color accent) => readableOn(accent, _background);

  /// Secondary text (labels, hints, notes) instead of a faint grey.
  Color get muted => readableOn(const Color(0xFF6B7280), _background);
}
