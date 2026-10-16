// Regenerates every platform launcher icon from WisePlugMarkPainter.
// Run from the project root: flutter test tool/generate_icons_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/widgets/wiseplug_logo.dart';

/// Blue tile with the white mark. [rounded] gives the tile rounded corners
/// (Android legacy, web, Windows); iOS and maskable icons are full-bleed.
/// [markScale] is the mark height as a fraction of the tile.
Future<Uint8List> _icon(
  int px, {
  bool rounded = true,
  double markScale = .6,
}) async {
  final size = px.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final tile = Paint()..color = wisePlugBlue;
  if (rounded) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size, size),
        Radius.circular(size * .22),
      ),
      tile,
    );
  } else {
    canvas.drawRect(Rect.fromLTWH(0, 0, size, size), tile);
  }
  final markH = size * markScale;
  final markW = markH * WisePlugMarkPainter.aspectRatio;
  canvas.translate((size - markW) / 2, (size - markH) / 2);
  const WisePlugMarkPainter(
    color: Colors.white,
    accent: Colors.white,
  ).paint(canvas, Size(markW, markH));
  final image = await recorder.endRecording().toImage(px, px);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Packs PNG frames into a Windows .ico container.
Uint8List _ico(Map<int, Uint8List> frames) {
  final header = BytesBuilder()
    ..add(_u16(0))
    ..add(_u16(1))
    ..add(_u16(frames.length));
  var offset = 6 + 16 * frames.length;
  final body = BytesBuilder();
  frames.forEach((px, png) {
    header
      ..addByte(px >= 256 ? 0 : px)
      ..addByte(px >= 256 ? 0 : px)
      ..add([0, 0])
      ..add(_u16(1))
      ..add(_u16(32))
      ..add(_u32(png.length))
      ..add(_u32(offset));
    offset += png.length;
    body.add(png);
  });
  return (header..add(body.takeBytes())).takeBytes();
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32(int v) => [..._u16(v & 0xFFFF), ..._u16(v >> 16)];

void main() {
  testWidgets('generate launcher icons', (tester) async {
    await tester.runAsync(() async {
      Future<void> write(String path, Future<Uint8List> png) async =>
          File(path).writeAsBytesSync(await png);

      const android = {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      };
      for (final MapEntry(:key, :value) in android.entries) {
        await write(
          'android/app/src/main/res/mipmap-$key/ic_launcher.png',
          _icon(value),
        );
      }

      const ios = {
        '20x20@1x': 20, '20x20@2x': 40, '20x20@3x': 60,
        '29x29@1x': 29, '29x29@2x': 58, '29x29@3x': 87,
        '40x40@1x': 40, '40x40@2x': 80, '40x40@3x': 120,
        '60x60@2x': 120, '60x60@3x': 180,
        '76x76@1x': 76, '76x76@2x': 152,
        '83.5x83.5@2x': 167, '1024x1024@1x': 1024,
      };
      for (final MapEntry(:key, :value) in ios.entries) {
        await write(
          'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-$key.png',
          _icon(value, rounded: false),
        );
      }

      for (final px in [16, 32, 64, 128, 256, 512, 1024]) {
        await write(
          'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$px.png',
          _icon(px),
        );
      }

      await write('web/favicon.png', _icon(32));
      await write('web/icons/Icon-192.png', _icon(192));
      await write('web/icons/Icon-512.png', _icon(512));
      await write(
        'web/icons/Icon-maskable-192.png',
        _icon(192, rounded: false, markScale: .5),
      );
      await write(
        'web/icons/Icon-maskable-512.png',
        _icon(512, rounded: false, markScale: .5),
      );

      File('windows/runner/resources/app_icon.ico').writeAsBytesSync(
        _ico({for (final px in [16, 32, 48, 256]) px: await _icon(px)}),
      );
    });
  });
}
