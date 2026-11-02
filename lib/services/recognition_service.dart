import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/recognition.dart';
import 'device_binding.dart';

/// Rule-based appliance recognition in Supabase, for the app: follows the
/// run on each outlet, answers the prompts (confirm-match), registers
/// appliances (register-sample) and manages them (manage-appliance).
///
/// Reads go straight to the tables (row-level security lets the owner read
/// their plug's rows); every write goes through an Edge Function.
class RecognitionService {
  final String deviceId;
  final SupabaseClient? _clientOverride;

  /// How often the open runs are re-read. Polling keeps it simple and well
  /// inside the free tier (one small query every few seconds while open).
  final Duration pollEvery;

  RecognitionService({
    this.deviceId = DeviceBinding.gadgetId,
    SupabaseClient? client,
    this.pollEvery = const Duration(seconds: 3),
  }) : _clientOverride = client;

  SupabaseClient get _db => _clientOverride ?? Supabase.instance.client;

  /// The open run on each outlet ('A' / 'B'), refreshed every [pollEvery].
  Stream<Map<String, OutletSession>> openSessions() =>
      _poll(pollEvery, () async {
        final rows = await _db
            .from('outlet_sessions')
            .select()
            .eq('device_id', deviceId)
            .isFilter('ended_at', null);
        return {
          for (final r in rows)
            outletLetter(r['outlet'].toString()): OutletSession.fromRow(r),
        };
      });

  /// The latest run on [outlet] ('A' / 'B'), open or ended.
  Future<OutletSession?> latestSession(String outlet) async {
    final rows = await _db
        .from('outlet_sessions')
        .select()
        .eq('device_id', deviceId)
        .eq('outlet', outletKey(outlet))
        .order('started_at', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : OutletSession.fromRow(rows.first);
  }

  /// The user's appliances with their modes and where each is running.
  Future<List<RegisteredAppliance>> appliances() async {
    final results = await Future.wait([
      _db
          .from('appliance_instances')
          .select(
            'id, name, max_runtime_mins, is_learned, use_count, '
            'baseline_runtime_s, last_outlet, appliance_types(name)',
          )
          .order('name'),
      _db.from('appliance_profiles').select().order('mode_name'),
      _db
          .from('outlet_sessions')
          .select('appliance_id, outlet')
          .isFilter('ended_at', null)
          .not('appliance_id', 'is', null),
    ]);
    final running = {
      for (final s in results[2])
        s['appliance_id'].toString(): s['outlet'].toString(),
    };
    return [
      for (final r in results[0])
        RegisteredAppliance.fromRow(
          r,
          modes: [
            for (final p in results[1])
              if (p['appliance_id'] == r['id']) ApplianceMode.fromRow(p),
          ],
          runningOn: running[r['id'].toString()],
        ),
    ];
  }

  /// The user's appliance types ("Fan", "Charger"), for the registration form.
  Future<List<String>> types() async {
    final rows = await _db.from('appliance_types').select('name').order('name');
    return [for (final r in rows) r['name'].toString()];
  }

  Future<RecognitionSettings> settings() async {
    final rows = await _db.from('recognition_config').select().limit(1);
    return rows.isEmpty
        ? const RecognitionSettings()
        : RecognitionSettings.fromRow(rows.first);
  }

  /// "Yes, this is [applianceId]" for the run [eventId].
  Future<void> confirm(String eventId, String applianceId) => _invoke(
    'confirm-match',
    {'eventId': eventId, 'applianceId': applianceId},
  );

  /// Records the run [eventId] as a registration sample. The first sample of
  /// a new appliance gives its [typeName] and [name] (both required); later
  /// samples give [applianceId]. The safe operating time and the modes are set
  /// by the system, never here.
  Future<RegistrationProgress> registerSample({
    required String eventId,
    String? applianceId,
    String? typeName,
    String? name,
  }) async => RegistrationProgress.fromJson(
    await _invoke('register-sample', {
      'eventId': eventId,
      'applianceId': ?applianceId,
      'typeName': ?typeName,
      'name': ?name,
    }),
  );

  Future<void> rename(String applianceId, String name) => _invoke(
    'manage-appliance',
    {'action': 'rename', 'applianceId': applianceId, 'name': name},
  );

  Future<void> deleteAppliance(String applianceId) => _invoke(
    'manage-appliance',
    {'action': 'delete', 'applianceId': applianceId},
  );

  Future<Map<String, dynamic>> _invoke(
    String function,
    Map<String, dynamic> body,
  ) async {
    try {
      final res = await _db.functions.invoke(
        function,
        body: {'deviceId': deviceId, ...body},
      );
      return (res.data as Map).cast<String, dynamic>();
    } on FunctionException catch (e) {
      final details = e.details;
      throw StateError(
        details is Map && details['error'] != null
            ? '${details['error']}'
            : 'Could not reach WisePlug\'s server ($function, ${e.status}).',
      );
    }
  }
}

/// A stream that runs [load] now and then every [every] while it is listened
/// to; a failed load is reported as an error and the next one is tried.
Stream<T> _poll<T>(Duration every, Future<T> Function() load) {
  late final StreamController<T> controller;
  Timer? timer;
  var busy = false;
  Future<void> tick() async {
    if (busy) return;
    busy = true;
    try {
      final value = await load();
      if (controller.hasListener) controller.add(value);
    } catch (error, stack) {
      if (controller.hasListener) controller.addError(error, stack);
    } finally {
      busy = false;
    }
  }

  controller = StreamController<T>(
    onListen: () {
      tick();
      timer = Timer.periodic(every, (_) => tick());
    },
    onCancel: () => timer?.cancel(),
  );
  return controller.stream;
}
