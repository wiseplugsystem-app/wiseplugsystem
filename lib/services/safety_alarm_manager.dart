import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// The warning sounds' timing and volume. The tones themselves are made by
/// `tool/make_warning_tone.ts` (two short beeps, 1 kHz then 2.5 kHz; CC0,
/// see assets/sounds/LICENSE.md).
class WarningSoundConfig {
  /// Between beep pairs during a warning.
  final Duration repeatEvery;

  /// The last stretch before the cutoff, when the beeps come faster.
  final Duration finalStretch;
  final Duration finalRepeatEvery;

  /// Playback volume, 0..1.
  final double volume;
  final String warningTone, cutoffTone;

  const WarningSoundConfig({
    this.repeatEvery = const Duration(seconds: 4),
    this.finalStretch = const Duration(seconds: 10),
    this.finalRepeatEvery = const Duration(seconds: 1),
    this.volume = 1.0,
    this.warningTone = 'sounds/warning_tone.wav',
    this.cutoffTone = 'sounds/cutoff_tone.wav',
  });

  /// When the next beep pair plays, with [remaining] until the cutoff (null:
  /// unknown, the normal rate). Never the smoke-alarm "3 beeps, pause".
  Duration nextBeepIn(Duration? remaining) =>
      remaining != null && remaining <= finalStretch
      ? finalRepeatEvery
      : repeatEvery;
}

/// Plays a tone (an asset path under assets/).
abstract class TonePlayer {
  Future<void> play(String asset, double volume);
  Future<void> stop();
}

class _AudioTonePlayer implements TonePlayer {
  final _player = AudioPlayer();
  @override
  Future<void> play(String asset, double volume) async {
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.play(AssetSource(asset), volume: volume);
  }

  @override
  Future<void> stop() => _player.stop();
}

/// The phone's safety warning sound, the same for every safety warning:
///  * warning (the 60 s before a cutoff): two short beeps every 4 s, every
///    1 s in the last 10 s;
///  * cutoff (also an electrical trip): one long beep, then silence.
/// There is no mute: the sound stops only when the warning is over.
/// With the app closed, the push notification plays the same tone (Android
/// channel "wiseplug_safety", see MainActivity.kt).
class SafetyAlarmManager {
  static final SafetyAlarmManager _instance = SafetyAlarmManager._internal();
  factory SafetyAlarmManager() => _instance;
  SafetyAlarmManager._internal()
    : config = const WarningSoundConfig(),
      _output = null;

  /// A separate manager with its own [player] (tests).
  SafetyAlarmManager.withPlayer(
    TonePlayer player, {
    this.config = const WarningSoundConfig(),
  }) : _output = player;

  final WarningSoundConfig config;
  final TonePlayer? _output;
  late final TonePlayer _player = _output ?? _AudioTonePlayer();

  Timer? _next;
  Duration? Function()? _remaining;
  bool _warning = false;

  bool get isPlaying => _warning;

  /// Starts the warning pattern. [remaining] is the time left until the
  /// cutoff (null when unknown: the normal rate).
  Future<void> playSafetyAlarm({Duration? Function()? remaining}) async {
    if (_warning) return;
    _warning = true;
    _remaining = remaining;
    await _beep();
  }

  Future<void> _beep() async {
    if (!_warning) return;
    final left = _remaining?.call();
    if (left != null && left <= Duration.zero) return; // the cutoff is due
    await _play(config.warningTone);
    if (!_warning) return;
    _next = Timer(config.nextBeepIn(_remaining?.call()), _beep);
  }

  /// The power was cut: one long beep, then silence.
  Future<void> playCutoff() async {
    _stopPattern();
    await _play(config.cutoffTone);
  }

  /// The warning is over (closed, answered or cleared). The next one sounds.
  Future<void> stopAlarm() async {
    _stopPattern();
    try {
      await _player.stop();
    } catch (error) {
      debugPrint('Safety sound: could not stop: $error'); // for developers
    }
  }

  void _stopPattern() {
    _warning = false;
    _next?.cancel();
    _next = null;
  }

  Future<void> _play(String asset) async {
    try {
      await _player.play(asset, config.volume);
    } catch (error) {
      // E.g. a browser blocks sound until the page was tapped once.
      debugPrint('Safety sound: could not play $asset: $error');
    }
  }
}
