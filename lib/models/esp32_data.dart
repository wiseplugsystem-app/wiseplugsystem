// Wire-format adapters for the existing ESP32 Realtime Database sketch.
Map<String, dynamic> databaseMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : {};

double? sensorNumber(Object? value) {
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  return number != null && number.isFinite ? number : null;
}

DateTime? deviceTime(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is! String || value == 'N/A' || value == 'Time Sync Error') {
    return null;
  }
  // Original sketch formats local time at UTC+08:00 without an offset.
  final text = value.trim().replaceFirst(' ', 'T');
  final hasZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(text);
  return DateTime.tryParse(hasZone ? text : '$text+08:00')?.toUtc();
}

class OutletReading {
  final String outlet;
  final String appliance;
  final String status;
  final double? voltage, current, activePower, powerFactor, peakPower;
  final DateTime? startTime, lastUpdated;
  final bool? sensorValid;
  final String currentState, sessionID, alertID, profileID;
  final int revision;
  final DateTime? countdownExpiry, safetyDeadline;
  final bool runtimeWarning;

  /// Running on extra time granted by "Yes, Override", past its limit.
  final bool overridden;

  OutletReading.fromMap(this.outlet, Map<String, dynamic> map)
    : currentState = map['currentState']?.toString() ?? '',
      sessionID = map['sessionID']?.toString() ?? '',
      alertID = map['alertID']?.toString() ?? '',
      profileID = map['profileID']?.toString() ?? '',
      revision = (map['revision'] as num?)?.toInt() ?? 0,
      countdownExpiry = deviceTime(map['countdownExpiry']),
      safetyDeadline = deviceTime(map['safetyDeadline']),
      runtimeWarning = map['runtime_warning'] == true,
      overridden = map['overridden'] == true,
      appliance = map['appliance']?.toString() ?? 'Unknown',
      status = map['status']?.toString() ?? 'Unknown',
      voltage = sensorNumber(map['voltage_V']),
      current = sensorNumber(map['current_A']),
      activePower = sensorNumber(map['power_W']),
      powerFactor = sensorNumber(map['power_factor']),
      peakPower = sensorNumber(map['peak_power_W']),
      startTime = deviceTime(map['start_time']),
      lastUpdated = deviceTime(map['last_updated_ms'] ?? map['last_updated']),
      sensorValid = map['sensor_valid'] is bool
          ? map['sensor_valid'] as bool
          : null;

  bool isFresh(DateTime now) =>
      lastUpdated != null &&
      now.difference(lastUpdated!).inSeconds >= -10 &&
      now.difference(lastUpdated!) <= const Duration(seconds: 30);
  bool get isActive => status.toLowerCase() == 'active';
  // The meter detects a running load, not physical plug insertion.
  bool hasConnectedAppliance(DateTime now) =>
      isFresh(now) &&
      sensorValid != false &&
      (currentState.isEmpty
          ? isActive
          : ['ACTIVE', 'SAMPLING', 'WARNING'].contains(currentState));
  bool get isLockedOut =>
      currentState == 'LOCKED_OUT' || status == 'LOCKED_OUT';
  bool get isWarning => currentState == 'WARNING';
  int secondsRemaining(DateTime now) => countdownExpiry == null
      ? 0
      : ((countdownExpiry!.difference(now).inMilliseconds + 999) ~/ 1000).clamp(
          0,
          60,
        );
  bool canCommand(DateTime now) =>
      isFresh(now) && sessionID.isNotEmpty && !isLockedOut;

  /// Extra time "Yes, Override" grants now: a 20% safety buffer on how long
  /// this session has run. Matches the firmware's overrideSeconds().
  int overrideSeconds(DateTime now) => overrideBufferSeconds(
    startTime == null ? 0 : now.difference(startTime!).inSeconds,
  );
}

/// 20% of [ranSeconds], kept within 1 min..1 h (the most the rules accept).
int overrideBufferSeconds(int ranSeconds) =>
    (ranSeconds * 0.2).floor().clamp(60, 3600);

class LearnedAppliance {
  final bool registrationMetadataAvailable;

  /// Registered once the user has named it; a type is optional.
  final bool registered;
  bool get needsRegistration => !registered;
  final String firmwareName;
  final String outlet, profileID, name;
  final double? baselineWattage, peakPower, current, voltage, powerFactor;

  /// Recognition window published by the firmware (steady power, watts).
  final double? powerMin, powerMax;
  final DateTime? registeredAt;
  final int maxRunTime, safetyCeilingDuration;
  final String? applianceType;
  final int? totalSessions;

  /// Learning phase (written by the firmware): completed uses recorded, their
  /// durations in seconds, the learned average, and the limit now in force.
  static const learningSessions = 7;
  final int sessionCount;
  final List<int> sessionHistory;
  final double? baselineAverage;
  final bool isLearningComplete;
  final int? learnedLimit;

  /// The limit the plug enforces now: the learned one, else the backstop.
  int get effectiveLimit => learnedLimit ?? safetyCeilingDuration;

  int get learningUsesLeft =>
      isLearningComplete ? 0 : (learningSessions - sessionCount).clamp(0, 7);
  final bool hasSafetyLimit, hasRuntimeLimit;

  LearnedAppliance.fromMap(
    this.outlet,
    this.profileID,
    Map<String, dynamic> map,
  ) : registrationMetadataAvailable =
          map['registrationMetadataAvailable'] != false,
      firmwareName =
          map['firmwareName']?.toString() ??
          map['name']?.toString() ??
          profileID,
      registered =
          map['registered'] == true ||
          (map['applianceType']?.toString().trim().isNotEmpty ?? false),
      applianceType = map['applianceType']?.toString(),
      totalSessions = sensorNumber(map['totalSessions'])?.toInt(),
      sessionCount = sensorNumber(map['sessionCount'])?.toInt() ?? 0,
      sessionHistory = [
        for (final v
            in map['sessionHistory'] is List
                ? map['sessionHistory'] as List
                : const [])
          ?sensorNumber(v)?.toInt(),
      ],
      baselineAverage = sensorNumber(map['baselineAverage']),
      isLearningComplete = map['isLearningComplete'] == true,
      learnedLimit = sensorNumber(map['learnedLimit'])?.toInt(),
      hasSafetyLimit = (sensorNumber(map['safetyCeilingDuration']) ?? 0) > 0,
      hasRuntimeLimit = (sensorNumber(map['maxRunTime']) ?? 0) > 0,
      maxRunTime = (map['maxRunTime'] as num?)?.toInt() ?? 3600,
      safetyCeilingDuration =
          (map['safetyCeilingDuration'] as num?)?.toInt() ?? 3600,
      name = map['name']?.toString() ?? profileID,
      powerMin = sensorNumber(databaseMap(map['range'])['powerMin_W']),
      powerMax = sensorNumber(databaseMap(map['range'])['powerMax_W']),
      baselineWattage = sensorNumber(map['steadyPower_W']),
      peakPower = sensorNumber(map['peakPower_W']),
      current = sensorNumber(map['current_A']),
      voltage = sensorNumber(map['voltage_V']),
      powerFactor = sensorNumber(map['powerFactor']),
      registeredAt = deviceTime(map['registered_at']);
}

Map<String, OutletReading> parseOutlets(Object? value) {
  final root = databaseMap(value);
  return {
    for (final outlet in ['A', 'B'])
      if (root['outlet_$outlet'] is Map)
        outlet: OutletReading.fromMap(
          outlet,
          databaseMap(root['outlet_$outlet']),
        ),
  };
}

List<LearnedAppliance> parseLearnedAppliances(Object? value) {
  final root = databaseMap(value);
  return [
    for (final outlet in ['A', 'B'])
      for (final entry in databaseMap(
        root['OUTLET_$outlet'] ?? root['OUTLET $outlet'],
      ).entries)
        if (entry.value is Map)
          LearnedAppliance.fromMap(outlet, entry.key, databaseMap(entry.value)),
  ]..sort((a, b) => '${a.outlet}/${a.name}'.compareTo('${b.outlet}/${b.name}'));
}
