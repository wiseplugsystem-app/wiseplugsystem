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

  /// The firmware's explicit lock-out flag; null from firmware that does not
  /// send it yet (then the older currentState/status check applies).
  final bool? lockedOut;

  /// Running on extra time granted by "Yes, Override", past its limit.
  final bool overridden;

  /// Off after a safety reset: it stays off until the user turns it on again.
  final bool safetyResetHold;

  /// Why the outlet is warning or was turned off: SAFETY_CEILING_EXCEEDED
  /// (its safe time is up), SENSOR_UNAVAILABLE, OVERCURRENT or POWER_ANOMALY.
  /// Empty from firmware that does not send it.
  final String alertType;

  /// The firmware's own seconds left in the 60-second warning, when this
  /// reading was taken (countdownRemaining); null from firmware without it.
  final int? countdownRemaining;

  /// When the app received this reading (the phone's clock).
  final DateTime receivedAt;

  OutletReading.fromMap(this.outlet, Map<String, dynamic> map)
    : countdownRemaining = (map['countdownRemaining'] as num?)?.toInt(),
      receivedAt = DateTime.now(),
      currentState = map['currentState']?.toString() ?? '',
      sessionID = map['sessionID']?.toString() ?? '',
      alertID = map['alertID']?.toString() ?? '',
      profileID = map['profileID']?.toString() ?? '',
      revision = (map['revision'] as num?)?.toInt() ?? 0,
      countdownExpiry = deviceTime(map['countdownExpiry']),
      safetyDeadline = deviceTime(map['safetyDeadline']),
      runtimeWarning = map['runtime_warning'] == true,
      lockedOut = map['lockedOut'] is bool ? map['lockedOut'] as bool : null,
      overridden = map['overridden'] == true,
      safetyResetHold =
          map['safetyResetHold'] == true && map['currentState'] == 'DISABLED',
      alertType = map['alertType']?.toString() ?? '',
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
  // The meter detects a running load, not physical plug insertion. The
  // firmware's state machine decides whether a run is on: one missed meter
  // answer (sensor_valid false for one update) does not end it, and a meter
  // that stays silent gets its own SENSOR_UNAVAILABLE warning. Only old
  // firmware without currentState needs the meter to vouch for the load.
  bool hasConnectedAppliance(DateTime now) =>
      isFresh(now) &&
      (currentState.isEmpty
          ? isActive && sensorValid != false
          : ['ACTIVE', 'SAMPLING', 'WARNING'].contains(currentState));

  /// The live power, or null while the meter is not answering (the firmware
  /// then sends 0, which is not a reading).
  double? get livePower => sensorValid == false ? null : activePower;

  /// New firmware: its explicit lockedOut flag. Firmware without the flag
  /// (not re-flashed yet): the previous check, kept so the APK still shows
  /// the lock-out pop-up and Reset Safety with the plug as it is now.
  bool get isLockedOut =>
      lockedOut ?? (currentState == 'LOCKED_OUT' || status == 'LOCKED_OUT');
  bool get isWarning => currentState == 'WARNING';

  /// The warning or cutoff is about the safe time running out: the only one
  /// that opens the pop-up. Any other reason (a power cut, a silent meter,
  /// too much power, a fault, or none given) shows on the outlet card and as
  /// a phone notification.
  bool get isSafeTimeAlert => alertType == 'SAFETY_CEILING_EXCEEDED';

  /// The outlet gives power (the plug switches it off when it is turned off
  /// or locked out for safety).
  bool get switchedOn => currentState != 'DISABLED' && !isLockedOut;
  int secondsRemaining(DateTime now) => countdownExpiry == null
      // The plug's clock is not synced (no countdownExpiry): its own
      // countdown, counted down on the phone since the reading arrived.
      ? (countdownRemaining == null
            ? 0
            : (countdownRemaining! - now.difference(receivedAt).inSeconds)
                  .clamp(0, 60))
      : ((countdownExpiry!.difference(now).inMilliseconds + 999) ~/ 1000).clamp(
          0,
          60,
        );

  /// The safe-time alert in this reading is still going on, for the pop-up.
  /// isFresh(now) as before, or one of: the plug's clock is not synced yet
  /// (last_updated 0: its age cannot be judged), a lock-out (it lasts until
  /// Reset Safety, however long the plug waits before its next update), or
  /// a warning whose 60-second countdown has not run out yet. Whether the
  /// plug is online is checked separately (GadgetStatus.isOnline).
  bool isCurrentForAlert(DateTime now) {
    if (isFresh(now)) return true;
    final updated = lastUpdated;
    if (updated == null || updated.year < 2023) return true;
    if (isLockedOut) return true;
    final expiry = countdownExpiry;
    if (isWarning && expiry == null) {
      return now.difference(receivedAt) <= const Duration(seconds: 75);
    }
    return isWarning &&
        expiry != null &&
        now.isBefore(expiry.add(const Duration(seconds: 15)));
  }

  /// How much of the safe time has passed, 0.0 to 1.0, measured as the plug
  /// measures it: from the run's start to its deadline (safetyDeadline, any
  /// "Keep it on" time included). Exactly 1.0 when the safe time is up, the
  /// moment the pop-up opens (WARNING), and after the cutoff. Null when the
  /// plug gives no deadline.
  double? safeTimeProgress(DateTime now) {
    if (isSafeTimeAlert && (isWarning || isLockedOut)) return 1;
    final start = startTime, end = safetyDeadline;
    if (start == null || end == null) return null;
    final total = end.difference(start).inMilliseconds;
    if (total <= 0) return 1;
    return (now.difference(start).inMilliseconds / total).clamp(0.0, 1.0);
  }

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
