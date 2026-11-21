import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// The warning sounds and their volume. The warning sound
/// (assets/sounds/warning_tone.mp3, chosen by the project; see
/// assets/sounds/LICENSE.md) loops for the whole countdown. The cutoff tone is
/// made by `tool/make_warning_tone.ts`. [repeatEvery], [finalStretch] and
/// [finalRepeatEvery] belong to the old two-beep pattern and are unused now.
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
    this.warningTone = 'sounds/warning_tone.mp3',
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

  /// Plays [asset] over and over until [stop].
  Future<void> loop(String asset, double volume);
  Future<void> stop();
}

/// Safety sounds play like an alarm clock: on the phone's ALARM volume, so
/// silent or vibrate mode does not mute them, and Do Not Disturb lets them
/// through in its usual setting ("Alarms" allowed). iOS: the playback
/// category, which plays with the ring/silent switch on silent.
final safetyAlarmAudio = AudioContext(
  android: const AudioContextAndroid(
    usageType: AndroidUsageType.alarm,
    contentType: AndroidContentType.sonification,
    audioFocus: AndroidAudioFocus.gainTransient,
    stayAwake: true,
  ),
  iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
);

/// A safety push (FCM data "type") that should sound the warning.
bool isSafetyAlarmPush(Map<String, dynamic> data) => const {
  'RUNTIME_WARNING',
  'SAFETY_CEILING_EXCEEDED',
  'LOCKED_OUT',
  'OVERCURRENT',
  'POWER_ANOMALY',
  'SENSOR_UNAVAILABLE',
}.contains(data['type']);

/// With the app closed: a safety push plays the warning sound once on the
/// alarm volume (silent mode, Do Not Disturb), besides the notification.
Future<void> playSafetyAlarmInBackground() async {
  final player = AudioPlayer();
  try {
    await player.setAudioContext(safetyAlarmAudio);
    await player.play(AssetSource('sounds/warning_tone.mp3'));
    await player.onPlayerComplete.first.timeout(
      const Duration(seconds: 30),
      onTimeout: () {},
    );
  } catch (_) {
    // No sound possible (e.g. alarm volume off): the notification remains.
  } finally {
    await player.dispose();
  }
}

class _AudioTonePlayer implements TonePlayer {
  final _player = AudioPlayer();
  bool _alarmVolume = false;

  /// On the alarm volume (see [safetyAlarmAudio]), set once.
  Future<void> _useAlarmVolume() async {
    if (_alarmVolume) return;
    try {
      await _player.setAudioContext(safetyAlarmAudio);
      _alarmVolume = true;
    } catch (_) {
      // Not supported here (e.g. the web): the normal volume is used.
    }
  }

  @override
  Future<void> play(String asset, double volume) async {
    await _useAlarmVolume();
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.play(AssetSource(asset), volume: volume);
  }

  @override
  Future<void> loop(String asset, double volume) async {
    await _useAlarmVolume();
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(AssetSource(asset), volume: volume);
  }

  @override
  Future<void> stop() => _player.stop();
}

/// The phone's safety warning sound, the same for every safety warning:
///  * warning (the 60 s before a cutoff): the warning sound, looped from
///    start to end until the warning is answered, cleared or cut off;
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

  /// Loops the warning sound; a timer silences it once the cutoff is due
  /// (the cutoff tone follows the plug).
  Future<void> _beep() async {
    if (!_warning) return;
    final left = _remaining?.call();
    if (left != null && left <= Duration.zero) return; // the cutoff is due
    try {
      await _player.loop(config.warningTone, config.volume);
    } catch (error) {
      // E.g. a browser blocks sound until the page was tapped once.
      debugPrint('Safety sound: could not play ${config.warningTone}: $error');
    }
    if (!_warning || left == null) return;
    _next = Timer(left, () async {
      if (!_warning) return;
      try {
        await _player.stop();
      } catch (_) {}
    });
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
