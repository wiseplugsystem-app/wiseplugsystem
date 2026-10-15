import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class SafetyAlarmManager {
  static final SafetyAlarmManager _instance = SafetyAlarmManager._internal();
  factory SafetyAlarmManager() => _instance;
  SafetyAlarmManager._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlayingAlarm = false;

  /// Starts playing a looping warning/safety alarm
  Future<void> playSafetyAlarm() async {
    if (_isPlayingAlarm) return; // Prevent overlapping triggers
    
    try {
      _isPlayingAlarm = true;
      // Set to loop mode so it keeps beeping/alarming until resolved
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      
      // Option A: Play from asset bundle
      await _audioPlayer.play(AssetSource('sounds/alarm_beep.mp3'));
      
      // Option B: If using URL stream or default behavior
      // await _audioPlayer.play(UrlSource('https://...'));
    } catch (e) {
      debugPrint("Error playing safety alarm: $e");
      _isPlayingAlarm = false;
    }
  }

  /// Stops the active alarm sound
  Future<void> stopAlarm() async {
    if (!_isPlayingAlarm) return;
    
    try {
      await _audioPlayer.stop();
    } catch (e) {
      debugPrint("Error stopping safety alarm: $e");
    } finally {
      _isPlayingAlarm = false;
    }
  }
}