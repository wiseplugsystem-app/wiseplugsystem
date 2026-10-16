import 'dart:math' as math;

import 'package:flutter/material.dart';

/// WisePlug brand blue.
const wisePlugBlue = Color(0xFF00A4EF);
const _ink = Color(0xFF1C1D1F);

/// The WisePlug mark: a plug whose body is a timer dial with a blue wedge.
class WisePlugMark extends StatelessWidget {
  /// Height of the mark; the width follows the mark's aspect ratio.
  final double size;

  /// Plug and dial colour. Defaults to near-black, or white in dark mode.
  final Color? color;

  /// Timer wedge colour.
  final Color accent;

  const WisePlugMark({
    super.key,
    this.size = 40,
    this.color,
    this.accent = wisePlugBlue,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      size: Size(size * WisePlugMarkPainter.aspectRatio, size),
      painter: WisePlugMarkPainter(
        color: color ?? (dark ? Colors.white : _ink),
        accent: accent,
      ),
    );
  }
}

/// Mark plus "WisePlug" wordmark, with an optional tagline.
class WisePlugLogo extends StatelessWidget {
  final double fontSize;
  final bool showTagline;

  const WisePlugLogo({super.key, this.fontSize = 34, this.showTagline = false});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : _ink;
    final wordmark = Text.rich(
      const TextSpan(
        children: [
          TextSpan(text: 'Wise'),
          TextSpan(
            text: 'Plug',
            style: TextStyle(color: wisePlugBlue),
          ),
        ],
      ),
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        color: ink,
        height: 1.1,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WisePlugMark(size: fontSize * 1.25, color: ink),
        SizedBox(width: fontSize * .4),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              wordmark,
              if (showTagline)
                Text(
                  'ADAPTIVE SMART APPLIANCE CONTROL',
                  style: TextStyle(
                    fontSize: fontSize * .26,
                    fontWeight: FontWeight.w600,
                    letterSpacing: fontSize * .09,
                    color: dark ? Colors.white60 : const Color(0xFF5F6368),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Paints the mark in a 226 x 285 design grid scaled to [size].
class WisePlugMarkPainter extends CustomPainter {
  static const _w = 226.0, _h = 285.0;
  static const aspectRatio = _w / _h;

  final Color color;
  final Color accent;

  const WisePlugMarkPainter({required this.color, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / _w, size.height / _h);
    canvas
      ..save()
      ..translate(
        (size.width - _w * scale) / 2,
        (size.height - _h * scale) / 2,
      )
      ..scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 27;
    final fill = Paint()..color = color;
    const center = Offset(113, 171);

    // Prongs: rounded tips, flat ends buried in the dial ring's stroke.
    for (final x in const [76.0, 150.0]) {
      canvas
        ..drawLine(Offset(x, 13.5), Offset(x, 87), stroke)
        ..drawCircle(Offset(x, 13.5), 13.5, fill);
    }
    canvas.drawCircle(center, 100, stroke);

    // Timer wedge: 12 o'clock clockwise to 4 o'clock.
    canvas
      ..drawArc(
        Rect.fromCircle(center: center, radius: 58),
        -math.pi / 2,
        2 * math.pi / 3,
        true,
        Paint()..color = accent,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(WisePlugMarkPainter old) =>
      old.color != color || old.accent != accent;
}
