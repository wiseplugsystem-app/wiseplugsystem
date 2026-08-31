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
  });

  factory ApplianceProfile.fromMap(Map<String, dynamic> map, String id) {
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
    );
  }

  Map<String, dynamic> toMap() {
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
    };
  }

  IconData get icon {
    switch (applianceType) {
      case 'Rice cooker':
        return Icons.rice_bowl;
      case 'Flat Iron':
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
    return TelemetryLog(
      logID: id,
      deviceID: map['deviceID'] ?? '',
      voltage: (map['voltage'] ?? 0).toDouble(),
      current: (map['current'] ?? 0).toDouble(),
      activePower: (map['activePower'] ?? 0).toDouble(),
      timestamp: map['timestamp'] != null
          ? DateTime.parse(map['timestamp'])
          : DateTime.now(),
    );
  }

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
}

/// AnomalyAlert Class matching Class Diagram specifications
class AnomalyAlert {
  final String alertID;
  final String deviceID;
  final String alertType;
  final DateTime triggerTime;
  final DateTime countdownExpiry;
  final String resolution;

  AnomalyAlert({
    required this.alertID,
    required this.deviceID,
    required this.alertType,
    required this.triggerTime,
    required this.countdownExpiry,
    this.resolution = 'Pending',
  });

  factory AnomalyAlert.fromMap(Map<String, dynamic> map, String id) {
    return AnomalyAlert(
      alertID: id,
      deviceID: map['deviceID'] ?? '',
      alertType: map['alertType'] ?? 'General Anomaly',
      triggerTime: map['triggerTime'] != null
          ? DateTime.parse(map['triggerTime'])
          : DateTime.now(),
      countdownExpiry: map['countdownExpiry'] != null
          ? DateTime.parse(map['countdownExpiry'])
          : DateTime.now().add(const Duration(minutes: 5)),
      resolution: map['resolution'] ?? 'Pending',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'alertID': alertID,
      'deviceID': deviceID,
      'alertType': alertType,
      'triggerTime': triggerTime.toIso8601String(),
      'countdownExpiry': countdownExpiry.toIso8601String(),
      'resolution': resolution,
    };
  }
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

  Map<String, dynamic> toMap() {
    return {
      'overrideID': overrideID,
      'alertID': alertID,
      'userID': userID,
      'extensionDuration': extensionDuration,
    };
  }
}