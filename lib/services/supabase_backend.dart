import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/esp32_data.dart';
import '../models/telemetry.dart';
import 'device_binding.dart';

/// One finished run on one outlet, from the Postgres `sessions` table
/// (written by the ESP32 through the log-session Edge Function).
class UsageSession {
  final OutletChannel outlet;
  final String applianceName;
  final String? profileId;
  final DateTime startedAt, endedAt;
  final int durationSeconds;
  final double energyWh, peakCurrent, peakPower;
  final double? averagePower;
  final String endReason;
  final bool countsTowardLearning;
  final int? learningUse; // 1..7 while the appliance is learning

  UsageSession.fromRow(Map<String, dynamic> r)
    : outlet = OutletChannel.fromKey(r['outlet'])!,
      applianceName = r['appliance_name']?.toString() ?? 'Unknown appliance',
      profileId = r['profile_id'] as String?,
      startedAt = DateTime.parse(r['started_at'] as String).toUtc(),
      endedAt = DateTime.parse(r['ended_at'] as String).toUtc(),
      durationSeconds = (r['duration_s'] as num).toInt(),
      energyWh = sensorNumber(r['energy_wh']) ?? 0,
      peakCurrent = sensorNumber(r['peak_current_a']) ?? 0,
      peakPower = sensorNumber(r['peak_power_w']) ?? 0,
      averagePower = sensorNumber(r['avg_power_w']),
      endReason = r['end_reason'] as String,
      countsTowardLearning = r['counts_toward_learning'] == true,
      learningUse = (r['learning_use'] as num?)?.toInt();

  double get energyKWh => energyWh / 1000;
}

/// One bar of the energy chart: an outlet's usage on one day (Philippine time).
class DailyEnergy {
  final OutletChannel outlet;
  final DateTime day;
  final int sessions, runtimeSeconds;
  final double energyWh;

  DailyEnergy.fromRow(Map<String, dynamic> r)
    : outlet = OutletChannel.fromKey(r['outlet'])!,
      day = DateTime.parse(r['day'] as String),
      sessions = (r['sessions'] as num).toInt(),
      runtimeSeconds = (r['runtime_s'] as num).toInt(),
      energyWh = sensorNumber(r['energy_wh']) ?? 0;
}

class SafetyAlertLog {
  final OutletChannel outlet;
  final String type, severity, message, applianceName;
  final DateTime occurredAt;

  SafetyAlertLog.fromRow(Map<String, dynamic> r)
    : outlet = OutletChannel.fromKey(r['outlet'])!,
      type = r['alert_type'] as String,
      severity = r['severity'] as String,
      message = r['message'] as String,
      applianceName = r['appliance_name']?.toString() ?? 'Unknown appliance',
      occurredAt = DateTime.parse(r['occurred_at'] as String).toUtc();
}

/// Reply of the match-signature Edge Function.
class SignatureMatch {
  /// matched (learned) | learning (recognized, still in its first 7 uses) |
  /// unrecognized_device (below the confidence cutoff) |
  /// registered (new profile saved) | duplicate (already saved, not saved again).
  final String status;
  final String? message;

  /// The matched ApplianceProfile, or null when unrecognized.
  final Map<String, dynamic>? appliance;

  /// Outlet the reading came from (profiles are shared by both outlets).
  final OutletChannel? outlet;

  /// 0-100 weighted similarity of the best profile, and the cutoff (e.g. 88).
  final double confidence, threshold;

  /// Per-quantity similarity 0-100: power, current, pf, reactive (null if n/a).
  final Map<String, double?> scores;

  SignatureMatch.fromJson(Map<String, dynamic> j)
    : status = j['status'] as String,
      message = j['message'] as String?,
      appliance = (j['appliance'] as Map?)?.cast<String, dynamic>(),
      outlet = OutletChannel.fromKey(j['outlet']),
      confidence = sensorNumber(j['confidence']) ?? 0,
      threshold = sensorNumber(j['threshold']) ?? 88,
      scores = {
        for (final e in ((j['scores'] as Map?) ?? const {}).entries)
          '${e.key}': sensorNumber(e.value),
      };

  bool get recognized => status == 'matched' || status == 'learning';
  bool get isUnrecognized => status == 'unrecognized_device';
  String? get applianceName => appliance?['name'] as String?;
}

/// Supabase: the permanent store and server-side logic. Live data and
/// commands stay on Firebase RTDB ([Esp32Service]).
///
/// Uses the WisePlug Supabase project by default. The publishable key is
/// public by design (RLS protects the data). Override for another project
/// with `--dart-define=SUPABASE_URL=...` and `--dart-define=SUPABASE_KEY=...`,
/// or pass empty values to run Firebase-only.
///
/// Identity: the Firebase ID token is sent as the Supabase access token
/// (third-party auth), so users sign in once, with Firebase.
class SupabaseBackend {
  static const url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://dadfldqjahglqdgoahql.supabase.co',
  );
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_KEY',
    defaultValue: 'sb_publishable_GkWu4_7pMPMQMVz7z7FdxA_8k9PD1PV',
  );
  static bool get configured => url.isNotEmpty && publishableKey.isNotEmpty;

  static Future<void> initialize() async {
    if (!configured) return;
    await Supabase.initialize(
      url: url,
      publishableKey: publishableKey,
      accessToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
    );
  }

  final String deviceId;
  SupabaseBackend({this.deviceId = DeviceBinding.gadgetId});

  SupabaseClient get _client => Supabase.instance.client;

  Future<Map<String, dynamic>> _invoke(
    String function,
    Map<String, dynamic> body,
  ) async {
    try {
      final res = await _client.functions.invoke(function, body: body);
      return (res.data as Map).cast<String, dynamic>();
    } on FunctionException catch (e) {
      // match-signature answers a duplicate with 409 and a normal body.
      if (e.status == 409 && e.details is Map) {
        return (e.details as Map).cast<String, dynamic>();
      }
      final details = e.details;
      throw StateError(
        details is Map && details['error'] != null
            ? '${details['error']}'
            : 'Supabase $function failed (${e.status})',
      );
    }
  }

  /// Call once after Firebase sign-in: claims the device in Postgres and
  /// gives the account the claim RLS needs, then refreshes the token.
  Future<void> linkAccount() async {
    final reply = await _invoke('link-account', {'deviceId': deviceId});
    if (reply['refreshToken'] == true) {
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
    }
  }

  /// Which saved appliance these live readings belong to, if any.
  /// The full PZEM reading of either outlet, as match-signature expects it.
  Map<String, Object?> _readingBody(TelemetryReading reading) {
    if (!reading.isValid) {
      throw StateError('No valid reading from ${reading.channel.label}.');
    }
    return {
      'deviceId': deviceId,
      'outlet': reading.channel.key,
      'voltage': ?reading.voltage,
      'power': reading.power,
      'current': reading.current,
      'powerFactor': ?reading.powerFactor,
    };
  }

  /// Which saved appliance is running on [reading]'s outlet. Every profile of
  /// the device is considered, whichever outlet it was learned on.
  Future<SignatureMatch> matchSignature(TelemetryReading reading) async =>
      SignatureMatch.fromJson(
        await _invoke('match-signature', _readingBody(reading)),
      );

  /// Saves a new profile from live readings, unless they already match one
  /// confidently (then [SignatureMatch.status] is `duplicate`, nothing saved).
  Future<SignatureMatch> registerAppliance({
    required TelemetryReading reading,
    required String name,
    String applianceType = 'Other',
    String? profileId,
    int maxRuntimeMins = 240,
  }) async {
    return SignatureMatch.fromJson(
      await _invoke('match-signature', {
        ..._readingBody(reading),
        'register': {
          'name': name,
          'applianceType': applianceType,
          'profileId': ?profileId,
          'maxRuntimeMins': maxRuntimeMins,
        },
      }),
    );
  }

  /// Finished sessions on one outlet, newest first (RLS: owner only).
  Future<List<UsageSession>> sessions(
    OutletChannel outlet, {
    DateTime? since,
    int limit = 50,
  }) async {
    var query = _client
        .from('sessions')
        .select()
        .eq('device_id', deviceId)
        .eq('outlet', outlet.key);
    if (since != null) {
      query = query.gte('started_at', since.toUtc().toIso8601String());
    }
    final rows = await query.order('started_at', ascending: false).limit(limit);
    return rows.map(UsageSession.fromRow).toList();
  }

  /// Energy per day for one outlet, oldest first, for a bar chart.
  Future<List<DailyEnergy>> dailyEnergy(
    OutletChannel outlet, {
    int days = 7,
  }) async {
    final from = DateTime.now().subtract(Duration(days: days - 1));
    final rows = await _client
        .from('daily_energy')
        .select()
        .eq('device_id', deviceId)
        .eq('outlet', outlet.key)
        .gte('day', '${from.year}-${_two(from.month)}-${_two(from.day)}')
        .order('day');
    return rows.map(DailyEnergy.fromRow).toList();
  }

  Future<List<SafetyAlertLog>> alerts({int limit = 50}) async {
    final rows = await _client
        .from('alert_logs')
        .select()
        .eq('device_id', deviceId)
        .order('occurred_at', ascending: false)
        .limit(limit);
    return rows.map(SafetyAlertLog.fromRow).toList();
  }

  /// Lets evaluate-safety-alert push to this phone (FCM HTTP v1).
  Future<void> savePushToken(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _client.from('push_tokens').upsert({
      'token': token,
      'owner_uid': uid,
      'platform': kIsWeb
          ? 'web'
          : defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios'
          : 'android',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
