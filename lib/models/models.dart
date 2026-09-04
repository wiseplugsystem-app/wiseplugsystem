import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// User Class matching Class Diagram specifications
class WiseUser {
  final String userID;
  final String name;
  final String email;

  WiseUser({
    required this.userID,
    required this.name,
    required this.email,
  });

  factory WiseUser.fromMap(Map<String, dynamic> map, String id) {
    return WiseUser(
      userID: id,
      name: map['name'] ?? '',
      email: map['email'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userID': userID,
      'name': name,
      'email': email,
    };
  }
}

/// ApplianceProfile Class matching Class Diagram specifications
class ApplianceProfile {
  String profileID;
  String deviceID;
  String applianceName;
  String applianceType;
  double baselineWattage;
  double thresholdWattage;
  int maxRunTime; // in minutes
  int safetyCeilingDuration; // in minutes
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
    this.maxRunTime = 120,
    this.safetyCeilingDuration = 180,
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
      maxRunTime: map['maxRunTime'] ?? 120,
      safetyCeilingDuration: map['safetyCeilingDuration'] ?? 180,
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
      safetyCeilingDuration: safetyCeilingDuration ?? this.safetyCeilingDuration,
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
        return Colors.blue;
      default:
        return Colors.blueGrey;
    }
  }
}

/// TelemetryLog Class matching Class Diagram specifications
class TelemetryLog {
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
    this.resolution = 'Pending',
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
          : DateTime.now().add(const Duration(minutes: 5)),
      resolution: map['resolution'] ?? 'Pending',
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
  final int extensionDuration; // in minutes

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
  final String outlet;
  final double estimatedWattage;
  final String signature;
  final String? suggestedType;

  DetectedAppliance({
    required this.outlet,
    required this.estimatedWattage,
    required this.signature,
    this.suggestedType,
  });

  factory DetectedAppliance.fromMap(Map<String, dynamic> map, String id) {
    return DetectedAppliance(
      outlet: map['outlet']?.toString() ?? 'A',
      estimatedWattage: (map['estimatedWattage'] as num?)?.toDouble() ?? 0.0,
      signature: map['signature'] ?? '',
      suggestedType: map['suggestedType'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'outlet': outlet,
      'estimatedWattage': estimatedWattage,
      'signature': signature,
      'suggestedType': suggestedType,
    };
  }
}