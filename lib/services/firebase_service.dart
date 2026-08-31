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
    if (profile.profileID.isEmpty) {
      final docRef = _db.collection('applianceProfiles').doc();
      profile.profileID = docRef.id;
      await docRef.set(profile.toMap());
    } else {
      await _db
          .collection('applianceProfiles')
          .doc(profile.profileID)
          .update(profile.toMap());
    }
  }

  Future<void> editProfile(String profileID, Map<String, dynamic> updates) async {
    await _db.collection('applianceProfiles').doc(profileID).update(updates);
  }

  Future<void> removeProfile(String profileID) async {
    await _db.collection('applianceProfiles').doc(profileID).delete();
  }

  Future<void> toggleAppliancePower(String profileID, bool isOn) async {
    await _db
        .collection('applianceProfiles')
        .doc(profileID)
        .update({'isOn': isOn});
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
    // Record the override request
    await _db.collection('smartOverrides').doc(override.overrideID).set(override.toMap());
    
    // Resolve the triggered anomaly alert
    await _db.collection('anomalyAlerts').doc(override.alertID).update({
      'resolution': 'Extended by User (${override.extensionDuration} mins)',
    });
  }
}