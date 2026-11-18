// The firmware keeps its one secure connection free for Firebase around the
// safe time, so the warning, Turn off / Keep it on and "Turned off for safety"
// reach the app within about a second (not ~30 s behind a Supabase upload).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final ino = File('arduino/wiseplug_esp32/wiseplug_esp32.ino')
      .readAsStringSync();

  test('a quiet window starts before the deadline, longer than one upload', () {
    final before = RegExp(r'SAFETY_QUIET_BEFORE_MS = (\d+);')
        .firstMatch(ino)!
        .group(1)!;
    final timeout = RegExp(r'supaHttp\.setTimeout\((\d+)\)')
        .firstMatch(ino)!
        .group(1)!;
    // An upload already running (timeout + ~4 s to connect) ends in time.
    expect(int.parse(before), greaterThanOrEqualTo(int.parse(timeout) + 4000));
  });

  test('the safety loop sets it near the deadline and during the warning', () {
    expect(ino, contains('safetyQuiet = quiet;'));
    expect(ino, contains('safety.deadline - now <= SAFETY_QUIET_BEFORE_MS'));
    expect(ino, contains('if (safety.state == SocketState::Warning ||'));
  });

  test('the Supabase task waits while it is set', () {
    expect(ino, contains('if (safetyQuiet) appFirst = true;'));
  });
}
