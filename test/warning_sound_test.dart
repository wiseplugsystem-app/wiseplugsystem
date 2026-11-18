// The phone's safety warning sound (SafetyAlarmManager): the warning sound
// loops until the warning is over, the cutoff tone plays once, and the sound
// files, their license note and the push channel fit together.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/services/safety_alarm_manager.dart';

class RecordingPlayer implements TonePlayer {
  final played = <String>[], looped = <String>[];
  int stops = 0;
  @override
  Future<void> play(String asset, double volume) async => played.add(asset);
  @override
  Future<void> loop(String asset, double volume) async => looped.add(asset);
  @override
  Future<void> stop() async => stops++;
}

const warning = 'sounds/warning_tone.mp3', cutoff = 'sounds/cutoff_tone.wav';

void main() {
  testWidgets('warning: the sound loops, and stops when the cutoff is due', (
    tester,
  ) async {
    final player = RecordingPlayer();
    final alarm = SafetyAlarmManager.withPlayer(player);
    await alarm.playSafetyAlarm(remaining: () => const Duration(seconds: 20));
    expect(player.looped, [warning]); // at once, looping
    await tester.pump(const Duration(seconds: 10));
    expect(player.looped, [warning]); // still the one loop
    expect(player.stops, 0);
    await tester.pump(const Duration(seconds: 11));
    expect(player.stops, 1); // silent once the cutoff is due
    await alarm.stopAlarm();
  });

  testWidgets('cutoff: one long beep, then silence', (tester) async {
    final player = RecordingPlayer();
    final alarm = SafetyAlarmManager.withPlayer(player);
    await alarm.playSafetyAlarm(remaining: () => const Duration(seconds: 30));
    await alarm.playCutoff();
    await tester.pump(const Duration(minutes: 1));
    expect(player.looped, [warning]);
    expect(player.played, [cutoff]);
  });

  testWidgets('a warning sounds until it is over; the next one sounds again', (
    tester,
  ) async {
    final player = RecordingPlayer();
    final alarm = SafetyAlarmManager.withPlayer(player);
    await alarm.playSafetyAlarm(remaining: () => const Duration(seconds: 40));
    await alarm.stopAlarm(); // answered, or the condition cleared
    expect(player.stops, 1);
    await alarm.playSafetyAlarm();
    expect(player.looped, [warning, warning]);
    await alarm.stopAlarm();
  });

  test('the sound files exist and their sources are written down', () {
    for (final path in [
      'assets/sounds/warning_tone.mp3',
      'android/app/src/main/res/raw/wiseplug_alert.mp3',
    ]) {
      final b = File(path).readAsBytesSync();
      final mp3 = String.fromCharCodes(b.sublist(0, 3)) == 'ID3' ||
          (b[0] == 0xff && (b[1] & 0xe0) == 0xe0);
      expect(mp3, isTrue, reason: path);
    }
    final cutoffWav = File('assets/sounds/cutoff_tone.wav').readAsBytesSync();
    expect(String.fromCharCodes(cutoffWav.sublist(0, 4)), 'RIFF');
    final license = File('assets/sounds/LICENSE.md').readAsStringSync();
    expect(license, contains('warning_tone.mp3'));
    expect(license, contains('wiseplug_alert.mp3'));
  });

  test('pushes name the channel and the sound the app creates', () {
    final sender = File(
      'supabase/functions/_shared/google.ts',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/example/wiseplug/MainActivity.kt',
    ).readAsStringSync();
    expect(sender, contains('channel_id: "wiseplug_safety_v2"'));
    expect(sender, contains('sound: "wiseplug_alert"'));
    expect(activity, contains('"wiseplug_safety_v2"'));
    expect(activity, contains('R.raw.wiseplug_alert'));
  });
}
