import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/models.dart';

class FirebaseBackendService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // --- Appliance Profile Methods ---

  Stream<List<ApplianceProfile>> streamApplianceProfiles(String deviceID) {
    return _db
        .collection('applianceProfiles')
        .where('deviceID', isEqualTo: deviceID)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ApplianceProfile.fromMap(doc.data(), doc.id))
            .toList());
  }

  Future<void> saveProfile(ApplianceProfile profile) async {
    try {
      DocumentReference docRef;
      if (profile.profileID.trim().isEmpty) {
        docRef = _db.collection('applianceProfiles').doc();
        profile.profileID = docRef.id;
      } else {
        docRef = _db.collection('applianceProfiles').doc(profile.profileID);
      }

      final data = profile.toFirestore();
      data['profileID'] = profile.profileID;

      await docRef.set(data, SetOptions(merge: true));
      debugPrint("✅ [Firestore] Profile saved successfully: ${profile.applianceName} (ID: ${profile.profileID})");
    } catch (e) {
      debugPrint("❌ [Firestore Error] Failed to save profile: $e");
      rethrow;
    }
  }

  Future<void> editProfile(String profileID, Map<String, dynamic> updates) async {
    try {
      await _db.collection('applianceProfiles').doc(profileID).update(updates);
      debugPrint("✅ [Firestore] Updated profile $profileID");
    } catch (e) {
      debugPrint("❌ [Firestore Error] Failed to edit profile: $e");
    }
  }

  Future<void> removeProfile(String profileID) async {
    try {
      await _db.collection('applianceProfiles').doc(profileID).delete();
      debugPrint("🗑️ [Firestore] Removed profile $profileID");
    } catch (e) {
      debugPrint("❌ [Firestore Error] Failed to delete profile: $e");
    }
  }

  Future<void> toggleAppliancePower(String profileID, bool isOn) async {
    try {
      await _db
          .collection('applianceProfiles')
          .doc(profileID)
          .update({'isOn': isOn});
      debugPrint("⚡ [Firestore] Toggled power for $profileID -> isOn: $isOn");
    } catch (e) {
      debugPrint("❌ [Firestore Error] Failed to toggle power: $e");
    }
  }

  // --- Telemetry & Sensor Streaming ---

  Stream<TelemetryLog?> streamLatestTelemetry(String deviceID) {
    return _db
        .collection('telemetryLogs')
        .where('deviceID', isEqualTo: deviceID)
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .map((snapshot) {
      if (snapshot.docs.isNotEmpty) {
        return TelemetryLog.fromMap(
            snapshot.docs.first.data(), snapshot.docs.first.id);
      }
      return null;
    });
  }

  // --- Anomaly Alert & Smart Override Methods ---

  Stream<List<AnomalyAlert>> streamActiveAlerts(String deviceID) {
    return _db
        .collection('anomalyAlerts')
        .where('deviceID', isEqualTo: deviceID)
        .where('resolution', isEqualTo: 'Pending')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => AnomalyAlert.fromMap(doc.data(), doc.id))
            .toList());
  }

  Future<void> requestSmartOverride(SmartOverride override) async {
    try {
      await _db
          .collection('smartOverrides')
          .doc(override.overrideID)
          .set(override.toMap());

      await _db.collection('anomalyAlerts').doc(override.alertID).update({
        'resolution': 'Extended by User (${override.extensionDuration} mins)',
      });
      debugPrint("🛡️ [Firestore] Override registered for alert: ${override.alertID}");
    } catch (e) {
      debugPrint("❌ [Firestore Error] Failed to execute override: $e");
    }
  }

  Future<void> acknowledgeShutdown(String alertID) async {
    try {
      await _db.collection('anomalyAlerts').doc(alertID).update({
        'resolution': 'Acknowledged Shutdown',
      });
      debugPrint("✅ [Firestore] Acknowledged shutdown for alert: $alertID");
    } catch (e) {
      debugPrint("❌ [Firestore Error] Failed to acknowledge shutdown: $e");
    }
  }

  // --- Pattern Detection Stream & Dismissal ---

  Stream<List<DetectedAppliance>> streamDetectedAppliances(String deviceID) {
    return _db
        .collection('detectedAppliances')
        .where('deviceID', isEqualTo: deviceID)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => DetectedAppliance.fromMap(doc.data(), doc.id))
            .toList());
  }

  Future<void> dismissDetectedAppliance(String signature) async {
    try {
      await _db.collection('detectedAppliances').doc(signature).delete();
      debugPrint("🗑️ [Firestore] Dismissed pattern: $signature");
    } catch (e) {
      debugPrint("❌ [Firestore Error] Failed to dismiss pattern: $e");
    }
  }
}