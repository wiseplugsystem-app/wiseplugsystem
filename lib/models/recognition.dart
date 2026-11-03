// Rule-based appliance recognition as the app sees it: the run on each outlet
// (Supabase outlet_sessions, written by recognize-appliance) and the user's
// registered appliances with their mode profiles.
import 'appliance_icons.dart';
import 'esp32_data.dart' show sensorNumber;

/// recognize-appliance's verdict on the run on one outlet.
enum RecognitionStatus {
  recognizing('RECOGNIZING'),
  unknown('UNKNOWN'),
  ambiguous('AMBIGUOUS'),
  sameTypeInUse('SAME_TYPE_IN_USE'),
  provisional('MATCHED_PROVISIONAL'),
  confirmed('MATCHED_CONFIRMED');

  final String wire;
  const RecognitionStatus(this.wire);

  static RecognitionStatus parse(Object? value) => RecognitionStatus.values
      .firstWhere((s) => s.wire == value, orElse: () => recognizing);

  /// The user is asked: these loads run on the safe default limit until then.
  bool get needsAnswer =>
      this == unknown || this == ambiguous || this == sameTypeInUse;
}

/// Outlet letter of a Supabase outlet key: outlet_1 -> A, outlet_2 -> B.
String outletLetter(String key) => key == 'outlet_2' ? 'B' : 'A';
String outletKey(String letter) => letter == 'B' ? 'outlet_2' : 'outlet_1';

/// An appliance offered in a prompt ("Is this Fan 1 or Fan 2?").
class RecognitionCandidate {
  final String applianceId, name, typeName, modeName;
  final double? score;

  RecognitionCandidate.fromJson(Map<String, dynamic> j)
    : applianceId = j['applianceId'].toString(),
      name = j['name']?.toString() ?? 'Appliance',
      typeName = j['typeName']?.toString() ?? '',
      modeName = j['modeName']?.toString() ?? '',
      score = sensorNumber(j['score']);
}

/// SAME_TYPE_IN_USE: "This looks like another Fan. Register as Fan 2?"
class RegisterSuggestion {
  final String typeName, name, resembles;
  RegisterSuggestion.fromJson(Map<String, dynamic> j)
    : typeName = j['typeName']?.toString() ?? '',
      name = j['name']?.toString() ?? '',
      resembles = j['resembles']?.toString() ?? '';
}

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.map((k, v) => MapEntry('$k', v)) : <String, dynamic>{};

/// One run on one outlet (an outlet_sessions row).
class OutletSession {
  final String eventId, deviceId, outlet;
  final int stage;
  final RecognitionStatus status;
  final String? applianceId, applianceName, modeName, confirmedBy;
  final List<RecognitionCandidate> candidates;
  final RecognitionCandidate? suggested;
  final RegisterSuggestion? registerAs;
  final String? promptText, reason;
  final int cutoffSeconds;
  final DateTime startedAt;
  final DateTime? endedAt;

  OutletSession.fromRow(Map<String, dynamic> r)
    : eventId = r['event_id'].toString(),
      deviceId = r['device_id'].toString(),
      outlet = r['outlet'].toString(),
      stage = (r['stage'] as num?)?.toInt() ?? 0,
      status = RecognitionStatus.parse(r['status']),
      applianceId = r['appliance_id'] as String?,
      applianceName = _map(r['candidates'])['applianceName'] as String?,
      modeName = _map(r['candidates'])['modeName'] as String?,
      confirmedBy = r['confirmed_by'] as String?,
      candidates = [
        for (final c
            in (_map(r['candidates'])['candidates'] as List?) ?? const [])
          if (c is Map) RecognitionCandidate.fromJson(_map(c)),
      ],
      suggested = _map(r['candidates'])['suggested'] is Map
          ? RecognitionCandidate.fromJson(
              _map(_map(r['candidates'])['suggested']),
            )
          : null,
      registerAs = _map(r['candidates'])['registerAs'] is Map
          ? RegisterSuggestion.fromJson(
              _map(_map(r['candidates'])['registerAs']),
            )
          : null,
      promptText = r['prompt_text'] as String?,
      reason = _map(r['candidates'])['reason'] as String?,
      cutoffSeconds = (r['cutoff_s'] as num?)?.toInt() ?? 1800,
      startedAt = DateTime.parse(r['started_at'].toString()).toUtc(),
      endedAt = r['ended_at'] == null
          ? null
          : DateTime.parse(r['ended_at'].toString()).toUtc();

  String get outletName => outletLetter(outlet);
  bool get isOpen => endedAt == null;

  /// Stage 2 has arrived: the run is fully measured and can be registered.
  bool get measured => stage >= 2;
}

/// One mode profile of an appliance ("Normal", "Low", "High").
class ApplianceMode {
  final String id, name;
  final int sampleCount;
  final double? meanPowerW, meanPf;

  ApplianceMode.fromRow(Map<String, dynamic> r)
    : id = r['id'].toString(),
      name = r['mode_name']?.toString() ?? 'Normal',
      sampleCount = (r['sample_count'] as num?)?.toInt() ?? 0,
      meanPowerW = sensorNumber(r['avg_power_w_mean']),
      meanPf = sensorNumber(r['avg_pf_mean']);
}

/// A registered appliance (an appliance_instances row) and its modes.
class RegisteredAppliance {
  final String id, name, typeName;

  /// Its type's icon (appliance_types.icon_key), if stored.
  final String? typeIconKey;
  final int cutoffMinutes;
  final bool isLearned;
  final int useCount;
  final int? baselineRuntimeSeconds;
  final String? lastOutlet;
  final List<ApplianceMode> modes;

  /// The outlet it is running on now (an open outlet session), or null.
  final String? runningOn;

  RegisteredAppliance.fromRow(
    Map<String, dynamic> r, {
    required this.modes,
    this.runningOn,
  }) : id = r['id'].toString(),
       name = r['name'].toString(),
       typeName = _map(r['appliance_types'])['name']?.toString() ?? 'Appliance',
       typeIconKey = _map(r['appliance_types'])['icon_key']?.toString(),
       cutoffMinutes = (r['max_runtime_mins'] as num?)?.toInt() ?? 30,
       isLearned = r['is_learned'] == true,
       useCount = (r['use_count'] as num?)?.toInt() ?? 0,
       baselineRuntimeSeconds = (r['baseline_runtime_s'] as num?)?.toInt(),
       lastOutlet = r['last_outlet'] as String?;

  /// What it is, for its icon (lib/models/appliance_icons.dart).
  ApplianceKind get kind => kindForType(typeName, iconKey: typeIconKey);

  /// It can be recognised once one of its modes has all its registration samples.
  bool isReady(int requiredSamples) =>
      modes.any((m) => m.sampleCount >= requiredSamples);
}

/// The numbers the app shows from recognition_config.
class RecognitionSettings {
  final int registrationSamples, defaultCutoffMinutes, learningUses;
  const RecognitionSettings({
    this.registrationSamples = 3,
    this.defaultCutoffMinutes = 30,
    this.learningUses = 7,
  });
  RecognitionSettings.fromRow(Map<String, dynamic> r)
    : registrationSamples = (r['registration_samples'] as num?)?.toInt() ?? 3,
      defaultCutoffMinutes =
          (r['default_cutoff_minutes'] as num?)?.toInt() ?? 30,
      learningUses = (r['learning_uses'] as num?)?.toInt() ?? 7;
}

/// register-sample's reply.
class RegistrationProgress {
  final String applianceId, applianceName, profileId, modeName;
  final int samplesCollected, samplesRequired;
  final bool complete;

  RegistrationProgress.fromJson(Map<String, dynamic> j)
    : applianceId = _map(j['appliance'])['id'].toString(),
      applianceName = _map(j['appliance'])['name'].toString(),
      profileId = _map(j['profile'])['id'].toString(),
      modeName = _map(j['profile'])['modeName']?.toString() ?? 'Normal',
      samplesCollected = (j['samplesCollected'] as num).toInt(),
      samplesRequired = (j['samplesRequired'] as num).toInt(),
      complete = j['complete'] == true;
}
