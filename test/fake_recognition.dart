// A RecognitionService for widget tests: no Supabase, records every call.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wiseplug/models/recognition.dart';
import 'package:wiseplug/services/recognition_service.dart';

class FakeRecognition extends Fake implements RecognitionService {
  final sessions = StreamController<Map<String, OutletSession>>.broadcast();
  List<RegisteredAppliance> list = [];
  final calls = <String>[];

  /// What latestSession returns next, per outlet (the last one repeats).
  final latest = <String, List<OutletSession?>>{};
  int collected = 0;

  @override
  Stream<Map<String, OutletSession>> openSessions() => sessions.stream;

  @override
  Future<RecognitionSettings> settings() async => const RecognitionSettings();

  @override
  Future<List<String>> types() async => ['Fan'];

  @override
  Future<List<RegisteredAppliance>> appliances() async => list;

  /// What runs() returns, per appliance id.
  final history = <String, List<ApplianceRun>>{};

  @override
  Future<List<ApplianceRun>> runs(String applianceId, {int limit = 10}) async =>
      history[applianceId] ?? const [];

  @override
  Future<OutletSession?> latestSession(String outlet) async {
    final queue = latest[outlet] ?? const [];
    if (queue.isEmpty) return null;
    return queue.length == 1 ? queue.first : queue.removeAt(0);
  }

  @override
  Future<void> confirm(String eventId, String applianceId) async =>
      calls.add('confirm $eventId $applianceId');

  @override
  Future<RegistrationProgress> registerSample({
    required String eventId,
    String? applianceId,
    String? typeName,
    String? name,
  }) async {
    calls.add(
      'register $eventId ${applianceId ?? 'new'} ${typeName ?? ''} ${name ?? ''}'
          .trim(),
    );
    collected++;
    return RegistrationProgress.fromJson({
      'appliance': {'id': 'new-1', 'name': name ?? 'Fan 2'},
      'profile': {'id': 'p-1', 'modeName': 'Normal'},
      'samplesCollected': collected,
      'samplesRequired': 3,
      'complete': collected >= 3,
    });
  }

  @override
  Future<void> rename(String applianceId, String name) async =>
      calls.add('rename $applianceId $name');

  @override
  Future<void> deleteAppliance(String applianceId) async =>
      calls.add('delete $applianceId');

  Future<void> close() => sessions.close();
}

/// An outlet_sessions row as Supabase returns it.
OutletSession session({
  String outlet = 'outlet_1',
  String eventId = 'boot_outlet_A_1',
  String status = 'UNKNOWN',
  int stage = 2,
  String? applianceId,
  String? applianceName,
  List<Map<String, Object?>> candidates = const [],
  Map<String, Object?>? suggested,
  Map<String, Object?>? registerAs,
  String? promptText,
  String? reason,
  int cutoff = 1800,
  DateTime? startedAt,
  DateTime? endedAt,
}) => OutletSession.fromRow({
  'event_id': eventId,
  'device_id': 'gadget-1',
  'outlet': outlet,
  'stage': stage,
  'status': status,
  'appliance_id': applianceId,
  'candidates': {
    'candidates': candidates,
    'suggested': suggested,
    'registerAs': registerAs,
    'applianceName': applianceName,
    'modeName': 'Normal',
    'reason': reason,
  },
  'prompt_text': promptText,
  'cutoff_s': cutoff,
  'started_at': (startedAt ?? DateTime.now()).toUtc().toIso8601String(),
  'ended_at': endedAt?.toUtc().toIso8601String(),
});
