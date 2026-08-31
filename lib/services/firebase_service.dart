import 'package:cloud_firestore/cloud_firestore.dart';
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
      // Auto-generate doc ID from Firestore if empty
      docRef = _db.collection('applianceProfiles').doc();
      profile.profileID = docRef.id;
    } else {
      docRef = _db.collection('applianceProfiles').doc(profile.profileID);
    }

    // Use .set with merge: true to safely handle BOTH new documents and updates
    await docRef.set(profile.toFirestore(), SetOptions(merge: true));
    print("✅ [Firestore] Profile saved successfully: ${profile.applianceName} (ID: ${profile.profileID})");
  } catch (e) {
    print("❌ [Firestore Error] Failed to save profile: $e");
    rethrow;
  }
}

  Future<void> editProfile(String profileID, Map<String, dynamic> updates) async {
    try {
      await _db.collection('applianceProfiles').doc(profileID).update(updates);
      print("✅ [Firestore] Updated profile $profileID");
    } catch (e) {
      print("❌ [Firestore Error] Failed to edit profile: $e");
    }
  }

  Future<void> removeProfile(String profileID) async {
    try {
      await _db.collection('applianceProfiles').doc(profileID).delete();
      print("🗑️ [Firestore] Removed profile $profileID");
    } catch (e) {
      print("❌ [Firestore Error] Failed to delete profile: $e");
    }
  }

  Future<void> toggleAppliancePower(String profileID, bool isOn) async {
    try {
      await _db
          .collection('applianceProfiles')
          .doc(profileID)
          .update({'isOn': isOn});
      print("⚡ [Firestore] Toggled power for $profileID -> isOn: $isOn");
    } catch (e) {
      print("❌ [Firestore Error] Failed to toggle power: $e");
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
      print("🛡️ [Firestore] Override registered for alert: ${override.alertID}");
    } catch (e) {
      print("❌ [Firestore Error] Failed to execute override: $e");
    }
  }
}