import 'package:firebase_auth/firebase_auth.dart' as auth;

import '../models/models.dart';
import '../models/esp32_data.dart';
import 'esp32_service.dart';

class WiseplugRepository implements DomainRepository {
  final Esp32Service service;
  WiseplugRepository(this.service);
  String _outlet(String deviceID) {
    if (!['outlet_A', 'outlet_B'].contains(deviceID)) {
      throw ArgumentError('Unknown outlet');
    }
    return deviceID.substring(7);
  }

  Future<OutletReading> _reading(String deviceID) async {
    _outlet(deviceID);
    return OutletReading.fromMap(
      _outlet(deviceID),
      databaseMap(
        (await service.database.ref('telemetry_logs/$deviceID').get()).value,
      ),
    );
  }

  @override
  Future<void> login(String email, String password) async {
    await auth.FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  @override
  Future<void> logout() => auth.FirebaseAuth.instance.signOut();
  @override
  Stream<TelemetryLog?> monitorAppliance(String deviceID) =>
      service.streamOutlets().map((readings) {
        final reading = readings[_outlet(deviceID)];
        if (reading == null ||
            reading.sensorValid != true ||
            reading.lastUpdated == null ||
            reading.voltage == null ||
            reading.current == null ||
            reading.activePower == null) {
          return null;
        }
        return TelemetryLog(
          logID: '${reading.lastUpdated!.millisecondsSinceEpoch}',
          deviceID: deviceID,
          voltage: reading.voltage!,
          current: reading.current!,
          activePower: reading.activePower!,
          timestamp: reading.lastUpdated!,
        );
      });
  @override
  Stream<List<AnomalyAlert>> receiveAlert(String deviceID) {
    _outlet(deviceID);
    return service.database
        .ref('alerts')
        .onValue
        .map(
          (event) => databaseMap(event.snapshot.value).entries
              .where(
                (entry) => databaseMap(entry.value)['deviceID'] == deviceID,
              )
              .map(
                (entry) =>
                    AnomalyAlert.fromMap(databaseMap(entry.value), entry.key),
              )
              .toList(),
        );
  }

  @override
  Stream<List<ApplianceProfile>> profiles(String deviceID) =>
      service.streamProfiles().map(
        (profiles) => profiles
            .where((profile) => profile.outlet == _outlet(deviceID))
            .map(
              (p) => ApplianceProfile(
                profileID: p.profileID,
                deviceID: deviceID,
                applianceName: p.name,
                applianceType: 'Unknown',
                outlet: p.outlet,
                baselineWattage: p.baselineWattage ?? 0,
                maxRunTime: p.maxRunTime,
                safetyCeilingDuration: p.safetyCeilingDuration,
              ),
            )
            .toList(),
      );
  @override
  Future<void> saveProfile(ApplianceProfile profile) async {
    final reading = await _reading(profile.deviceID);
    final existing =
        (await service.database
                .ref(
                  'appliance_profiles/OUTLET_${reading.outlet}/${profile.profileID}',
                )
                .get())
            .value;
    if (existing == null) {
      throw StateError(
        'Connect the appliance first; registration is performed by the ESP32.',
      );
    }
    await service.editProfile(
      reading,
      LearnedAppliance.fromMap(
        reading.outlet,
        profile.profileID,
        databaseMap(existing),
      ),
      profile.applianceName,
      profile.maxRunTime,
      profile.safetyCeilingDuration,
    );
  }

  @override
  Future<void> removeProfile(ApplianceProfile profile) async => service.command(
    await _reading(profile.deviceID),
    'REMOVE_PROFILE',
    fields: {'profileID': profile.profileID},
  );
  @override
  Future<void> setPower(String deviceID, bool on) async =>
      service.command(await _reading(deviceID), on ? 'TURN_ON' : 'TURN_OFF');
  @override
  Future<void> continueRuntime(SmartOverride request) async {
    if (request.userID != auth.FirebaseAuth.instance.currentUser?.uid ||
        request.extensionDuration <= 0 ||
        request.extensionDuration > 3600) {
      throw ArgumentError('Invalid override identity or duration.');
    }
    final alert = databaseMap(
      (await service.database.ref('alerts/${request.alertID}').get()).value,
    );
    if (alert['resolution'] != 'PENDING') {
      throw StateError('This alert is no longer pending.');
    }
    await service.command(
      await _reading(alert['deviceID'] as String),
      'SMART_OVERRIDE',
      fields: {
        'alertID': request.alertID,
        'extensionDuration': request.extensionDuration,
      },
    );
  }

  @override
  Future<void> acknowledgeShutdown(String alertID) async {
    final uid = auth.FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in first.');
    // Acknowledgment is an audit record and never changes the device lock.
    await service.database.ref('acknowledgments/$alertID/$uid').set(true);
  }
}
