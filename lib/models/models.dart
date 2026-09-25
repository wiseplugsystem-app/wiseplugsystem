import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// User Class matching Class Diagram specifications
class User {
  final String userID;
  final String name;
  final String email;

  User({required this.userID, required this.name, required this.email});
  Future<void> login(DomainRepository repository, String password) =>
      repository.login(email, password);
  Future<void> logout(DomainRepository repository) => repository.logout();
  Stream<TelemetryLog?> monitorAppliance(
    DomainRepository repository,
    String deviceID,
  ) => repository.monitorAppliance(deviceID);
  Stream<List<AnomalyAlert>> receiveAlert(
    DomainRepository repository,
    String deviceID,
  ) => repository.receiveAlert(deviceID);
  Future<void> requestSmartOverride(
    DomainRepository repository,
    SmartOverride request,
  ) {
    if (request.userID != userID) {
      throw ArgumentError('Override user does not match.');
    }
    return repository.continueRuntime(request);
  }

  Future<void> acknowledgeShutdown(
    DomainRepository repository,
    String alertID,
  ) => repository.acknowledgeShutdown(alertID);

  factory User.fromMap(Map<String, dynamic> map, String id) {
    return User(userID: id, name: map['name'] ?? '', email: map['email'] ?? '');
  }

  Map<String, dynamic> toMap() {
    return {'userID': userID, 'name': name, 'email': email};
  }
}

/// Device attributes from the class diagram. Detection is a state flag.
class WiseplugDevice {
  final String deviceID;
  final String userID;
  final String deviceStatus;
  final String currentState;
  final bool _applianceDetected;
  bool detectAppliance() => _applianceDetected;
  Stream<TelemetryLog?> displayDashboard(DomainRepository repository) =>
      repository.monitorAppliance(deviceID);
  Stream<TelemetryLog?> displayRealtimeStatus(DomainRepository repository) =>
      repository.monitorAppliance(deviceID);
  Stream<List<AnomalyAlert>> displaySmartAlert(DomainRepository repository) =>
      repository
          .receiveAlert(deviceID)
          .map(
            (alerts) => alerts.where((a) => a.resolution == 'PENDING').toList(),
          );
  Stream<List<AnomalyAlert>> displayShutdownAlert(
    DomainRepository repository,
  ) => repository
      .receiveAlert(deviceID)
      .map(
        (alerts) => alerts.where((a) => a.resolution == 'SHUTDOWN').toList(),
      );
  Stream<List<ApplianceProfile>> registerAppliance(
    DomainRepository repository,
  ) => repository.profiles(deviceID);

  WiseplugDevice({
    required this.deviceID,
    required this.userID,
    this.deviceStatus = 'Unknown',
    this.currentState = 'Unknown',
    bool detectAppliance = false,
  }) : _applianceDetected = detectAppliance;

  factory WiseplugDevice.fromMap(Map<String, dynamic> map, String id) =>
      WiseplugDevice(
        deviceID: id,
        userID: map['userID'] ?? '',
        deviceStatus: map['deviceStatus'] ?? 'Unknown',
        currentState: map['currentState'] ?? 'Unknown',
        detectAppliance: map['detectAppliance'] ?? false,
      );

  Map<String, dynamic> toMap() => {
    'deviceID': deviceID,
    'userID': userID,
    'deviceStatus': deviceStatus,
    'currentState': currentState,
    'detectAppliance': _applianceDetected,
  };
}

/// Diagram attributes plus outlet and runtime state; see docs/class-diagram.md.
class ApplianceProfile {
  String profileID;
  String deviceID;
  String applianceName;
  String applianceType;
  double baselineWattage;
  double thresholdWattage;
  int maxRunTime; // seconds
  int safetyCeilingDuration; // seconds
  Future<void> saveProfile(DomainRepository repository) =>
      repository.saveProfile(this);
  Future<void> editProfile(DomainRepository repository) =>
      repository.saveProfile(this);
  Future<void> removeProfile(DomainRepository repository) =>
      repository.removeProfile(this);
  Future<void> turnOn(DomainRepository repository) =>
      repository.setPower(deviceID, true);
  Future<void> turnOff(DomainRepository repository) =>
      repository.setPower(deviceID, false);
  bool isOn;
  String outlet;
  DateTime? startTime;

  ApplianceProfile({
    required this.profileID,
    required this.deviceID,
    required this.applianceName,
    required this.applianceType,
    this.baselineWattage = 0.0,
    this.thresholdWattage = 1000.0,
    this.maxRunTime = 3600,
    this.safetyCeilingDuration = 3600,
    this.isOn = false,
    required this.outlet,
    this.startTime,
  });

  factory ApplianceProfile.fromMap(Map<String, dynamic> map, String id) {
    DateTime? parsedStartTime;
    if (map['startTime'] != null) {
      if (map['startTime'] is Timestamp) {
        parsedStartTime = (map['startTime'] as Timestamp).toDate();
      } else if (map['startTime'] is String) {
        parsedStartTime = DateTime.tryParse(map['startTime']);
      }
    }

    return ApplianceProfile(
      profileID: id,
      deviceID: map['deviceID'] ?? '',
      applianceName: map['applianceName'] ?? '',
      applianceType: map['applianceType'] ?? 'Unknown',
      baselineWattage: (map['baselineWattage'] ?? 0).toDouble(),
      thresholdWattage: (map['thresholdWattage'] ?? 1000).toDouble(),
      maxRunTime: (map['maxRunTime'] as num?)?.toInt() ?? 3600,
      safetyCeilingDuration:
          (map['safetyCeilingDuration'] as num?)?.toInt() ?? 3600,
      isOn: map['isOn'] ?? false,
      outlet: map['outlet'] ?? 'A',
      startTime: parsedStartTime,
    );
  }

  factory ApplianceProfile.fromFirestore(Map<String, dynamic> map, String id) =>
      ApplianceProfile.fromMap(map, id);

  ApplianceProfile copyWith({
    String? profileID,
    String? deviceID,
    String? applianceName,
    String? applianceType,
    double? baselineWattage,
    double? thresholdWattage,
    int? maxRunTime,
    int? safetyCeilingDuration,
    bool? isOn,
    String? outlet,
    DateTime? startTime,
  }) {
    return ApplianceProfile(
      profileID: profileID ?? this.profileID,
      deviceID: deviceID ?? this.deviceID,
      applianceName: applianceName ?? this.applianceName,
      applianceType: applianceType ?? this.applianceType,
      baselineWattage: baselineWattage ?? this.baselineWattage,
      thresholdWattage: thresholdWattage ?? this.thresholdWattage,
      maxRunTime: maxRunTime ?? this.maxRunTime,
      safetyCeilingDuration:
          safetyCeilingDuration ?? this.safetyCeilingDuration,
      isOn: isOn ?? this.isOn,
      outlet: outlet ?? this.outlet,
      startTime: startTime ?? this.startTime,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'profileID': profileID,
      'deviceID': deviceID,
      'applianceName': applianceName,
      'applianceType': applianceType,
      'baselineWattage': baselineWattage,
      'thresholdWattage': thresholdWattage,
      'maxRunTime': maxRunTime,
      'safetyCeilingDuration': safetyCeilingDuration,
      'isOn': isOn,
      'outlet': outlet,
      'startTime': startTime?.toIso8601String(),
    };
  }

  Map<String, dynamic> toMap() => toFirestore();

  IconData get icon {
    switch (applianceType) {
      case 'Rice cooker':
        return Icons.rice_bowl;
      case 'Flat Iron':
      case 'Flat iron / hair straightener':
        return Icons.iron;
      case 'Electric Fan':
      case 'Electric fan':
        return Icons.air;
      default:
        return Icons.power;
    }
  }

  Color get color {
    switch (applianceType) {
      case 'Rice cooker':
        return Colors.green;
      case 'Flat Iron':
      case 'Flat iron / hair straightener':
        return Colors.deepOrange;
      case 'Electric Fan':
      case 'Electric fan':
        return Colors.blue;
      default:
        return Colors.blueGrey;
    }
  }
}

/// TelemetryLog Class matching Class Diagram specifications
class TelemetryLog {
  double measureVoltage() => voltage;
  double measureCurrent() => current;
  double measurePower() => activePower;
  Map<String, dynamic> transmitSensorData() => {
    'voltage_V': voltage,
    'current_A': current,
    'power_W': activePower,
  };
  final String logID;
  final String deviceID;
  final double voltage;
  final double current;
  final double activePower;
  final DateTime timestamp;

  TelemetryLog({
    required this.logID,
    required this.deviceID,
    required this.voltage,
    required this.current,
    required this.activePower,
    required this.timestamp,
  });

  factory TelemetryLog.fromMap(Map<String, dynamic> map, String id) {
    DateTime parsedTimestamp = DateTime.now();
    if (map['timestamp'] != null) {
      if (map['timestamp'] is Timestamp) {
        parsedTimestamp = (map['timestamp'] as Timestamp).toDate();
      } else if (map['timestamp'] is String) {
        parsedTimestamp = DateTime.tryParse(map['timestamp']) ?? DateTime.now();
      }
    }

    return TelemetryLog(
      logID: id,
      deviceID: map['deviceID'] ?? '',
      voltage: (map['voltage'] as num?)?.toDouble() ?? 0.0,
      current: (map['current'] as num?)?.toDouble() ?? 0.0,
      activePower: (map['activePower'] as num?)?.toDouble() ?? 0.0,
      timestamp: parsedTimestamp,
    );
  }

  factory TelemetryLog.fromFirestore(Map<String, dynamic> map, String id) =>
      TelemetryLog.fromMap(map, id);

  Map<String, dynamic> toMap() {
    return {
      'logID': logID,
      'deviceID': deviceID,
      'voltage': voltage,
      'current': current,
      'activePower': activePower,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  Map<String, dynamic> toFirestore() => toMap();
}

/// AnomalyAlert Class matching Class Diagram specifications
class AnomalyAlert {
  bool validateThresholdExceed(ApplianceProfile profile, double watts) =>
      watts > profile.thresholdWattage;
  bool evaluateBehavior(ApplianceProfile profile, Duration activeDuration) =>
      activeDuration.inSeconds >= profile.safetyCeilingDuration;
  Stream<List<AnomalyAlert>> triggerAlert(DomainRepository repository) =>
      repository.receiveAlert(deviceID);
  final String alertID;
  final String profileID;
  final String deviceID;
  final String alertType;
  final DateTime triggerTime;
  final DateTime countdownExpiry;
  final String resolution;

  AnomalyAlert({
    required this.alertID,
    this.profileID = '',
    required this.deviceID,
    required this.alertType,
    required this.triggerTime,
    required this.countdownExpiry,
    this.resolution = 'PENDING',
  });

  factory AnomalyAlert.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic raw) {
      if (raw is Timestamp) return raw.toDate();
      if (raw is String) return DateTime.tryParse(raw) ?? DateTime.now();
      return DateTime.now();
    }

    return AnomalyAlert(
      alertID: id,
      profileID: map['profileID'] ?? '',
      deviceID: map['deviceID'] ?? '',
      alertType: map['alertType'] ?? 'General Anomaly',
      triggerTime: parseDate(map['triggerTime']),
      countdownExpiry: map['countdownExpiry'] != null
          ? parseDate(map['countdownExpiry'])
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      resolution: (map['resolution'] as String? ?? 'PENDING').toUpperCase(),
    );
  }

  factory AnomalyAlert.fromFirestore(Map<String, dynamic> map, String id) =>
      AnomalyAlert.fromMap(map, id);

  Map<String, dynamic> toMap() {
    return {
      'alertID': alertID,
      'profileID': profileID,
      'deviceID': deviceID,
      'alertType': alertType,
      'triggerTime': triggerTime.toIso8601String(),
      'countdownExpiry': countdownExpiry.toIso8601String(),
      'resolution': resolution,
    };
  }

  Map<String, dynamic> toFirestore() => toMap();
}

/// SmartOverride Class matching Class Diagram specifications
class SmartOverride {
  final String overrideID;
  final String alertID;
  final String userID;
  final int extensionDuration; // seconds
  Future<void> continueRuntime(DomainRepository repository) {
    if (extensionDuration <= 0 || extensionDuration > 3600) {
      throw ArgumentError('Override must be between 1 and 3600 seconds.');
    }
    return repository.continueRuntime(this);
  }

  SmartOverride({
    required this.overrideID,
    required this.alertID,
    required this.userID,
    required this.extensionDuration,
  });

  factory SmartOverride.fromMap(Map<String, dynamic> map, String id) {
    return SmartOverride(
      overrideID: id,
      alertID: map['alertID'] ?? '',
      userID: map['userID'] ?? '',
      extensionDuration: (map['extensionDuration'] as num?)?.toInt() ?? 0,
    );
  }

  factory SmartOverride.fromFirestore(Map<String, dynamic> map, String id) =>
      SmartOverride.fromMap(map, id);

  Map<String, dynamic> toMap() {
    return {
      'overrideID': overrideID,
      'alertID': alertID,
      'userID': userID,
      'extensionDuration': extensionDuration,
    };
  }

  Map<String, dynamic> toFirestore() => toMap();
}

/// DetectedAppliance Class matching real-time pattern detection
class DetectedAppliance {
  final String deviceID;
  final String outlet;
  final double estimatedWattage;
  final String signature;
  final String? suggestedType;

  DetectedAppliance({
    required this.deviceID,
    required this.outlet,
    required this.estimatedWattage,
    required this.signature,
    this.suggestedType,
  });

  factory DetectedAppliance.fromMap(Map<String, dynamic> map, String id) {
    dynamic unwrap(dynamic value) {
      if (value is Map<String, dynamic>) {
        if (value.containsKey('stringValue')) return value['stringValue'];
        if (value.containsKey('doubleValue')) return value['doubleValue'];
        if (value.containsKey('integerValue')) return value['integerValue'];
      }
      return value;
    }

    final fields = map.containsKey('fields') && map['fields'] is Map<String, dynamic>
        ? map['fields'] as Map<String, dynamic>
        : map;

    return DetectedAppliance(
      deviceID: (unwrap(fields['deviceID']) ?? '').toString(),
      outlet: (unwrap(fields['outlet']) ?? 'A').toString(),
      estimatedWattage: double.tryParse(unwrap(fields['estimatedWattage'])?.toString() ?? '0') ?? 0.0,
      signature: (unwrap(fields['signature']) ?? id).toString(),
      suggestedType: unwrap(fields['suggestedType'])?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'deviceID': deviceID,
      'outlet': outlet,
      'estimatedWattage': estimatedWattage,
      'signature': signature,
      'suggestedType': suggestedType,
    };
  }
}

/// Domain operations delegate I/O to an authenticated repository. Safety is
/// evaluated and persisted by the ESP32; model evaluations are informational.
abstract interface class DomainRepository {
  Future<void> login(String email, String password);
  Future<void> logout();
  Stream<TelemetryLog?> monitorAppliance(String deviceID);
  Stream<List<AnomalyAlert>> receiveAlert(String deviceID);
  Stream<List<ApplianceProfile>> profiles(String deviceID);
  Future<void> saveProfile(ApplianceProfile profile);
  Future<void> removeProfile(ApplianceProfile profile);
  Future<void> setPower(String deviceID, bool on);
  Future<void> continueRuntime(SmartOverride request);
  Future<void> acknowledgeShutdown(String alertID);
}