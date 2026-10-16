import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'dart:async';
import 'dart:convert';

import '../models/activity_event.dart';
import '../models/esp32_data.dart';
import '../models/gadget_status.dart';
import 'device_binding.dart';
import 'wifi_provisioning.dart';

export 'wifi_provisioning.dart' show WifiProvisionStage, WifiProvisionUpdate;

/// Registration metadata is optional for displaying the firmware catalog.
Stream<List<LearnedAppliance>> combineProfileStreams(
  Stream<Object?> catalogs,
  Stream<Object?> metadata,
) {
  late StreamController<List<LearnedAppliance>> controller;
  final subscriptions = <StreamSubscription<Object?>>[];
  Object? catalog;
  Map<String, dynamic> registrations = {};
  var catalogReady = false, metadataReady = false, metadataAvailable = false;
  void emit() {
    if (!catalogReady || !metadataReady) return;
    final root = databaseMap(catalog);
    controller.add(
      parseLearnedAppliances({
        for (final outlet in ['A', 'B'])
          'OUTLET_$outlet': {
            for (final entry in databaseMap(
              root['OUTLET_$outlet'] ?? root['OUTLET $outlet'],
            ).entries)
              if (entry.value is Map)
                entry.key: {
                  ...databaseMap(entry.value),
                  ...databaseMap(
                    databaseMap(registrations['OUTLET_$outlet'])[entry.key],
                  ),
                  'firmwareName': databaseMap(entry.value)['name'] ?? entry.key,
                  'registered': databaseMap(registrations['OUTLET_$outlet'])
                      .containsKey(entry.key),
                  'registrationMetadataAvailable': metadataAvailable,
                },
          },
      }),
    );
  }

  controller = StreamController<List<LearnedAppliance>>(
    onListen: () {
      subscriptions.add(
        catalogs.listen(
          (value) {
            catalog = value;
            catalogReady = true;
            emit();
          },
          onError: (Object error, StackTrace stack) {
            catalogReady = false;
            controller.addError(error, stack);
          },
        ),
      );
      subscriptions.add(
        metadata.listen(
          (value) {
            registrations = databaseMap(value);
            metadataReady = metadataAvailable = true;
            emit();
          },
          onError: (Object error) {
            // Old deployed rules may not allow this newly introduced path.
            // Preserve learned profiles, but don't mistake missing metadata for
            // proof that an appliance has never been registered.
            metadataReady = true;
            metadataAvailable = false;
            emit();
          },
        ),
      );
    },
    onCancel: () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    },
  );
  return controller.stream;
}

/// The ESP32 refused a command; [toString] explains it for the user.
class DeviceRejection implements Exception {
  final String code;
  const DeviceRejection(this.code);

  @override
  String toString() => switch (code) {
    'REJECTED_STORAGE_FAILURE' =>
      'The WisePlug could not save to its memory, so the outlet stays off for safety. '
          'Restart the WisePlug and try again; if this repeats, re-upload the firmware with '
          '"Erase All Flash Before Sketch Upload" enabled.',
    'REJECTED_STALE' =>
      'The outlet changed state before the command arrived. Try again.',
    'REJECTED_PHYSICAL_RESET_REQUIRED' => 'This outlet is locked. Use Reset Safety in Power Control or the outlet\'s button.',
    'REJECTED_INVALID' => 'The outlet cannot do that in its current state.',
    'REJECTED_NO_APPLIANCE' => 'No appliance is plugged into this outlet, so there is nothing to switch.',
    _ => 'The WisePlug refused the command ($code).',
  };
}

class Esp32Service {
  static const databaseUrl = String.fromEnvironment(
    'WISEPLUG_DATABASE_URL',
    defaultValue:
        'https://wise-46f92-default-rtdb.asia-southeast1.firebasedatabase.app',
  );
  final FirebaseDatabase database;

  Esp32Service({FirebaseDatabase? database})
    : database =
          database ??
          FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: databaseUrl,
          );

  Stream<Map<String, OutletReading>> streamOutlets() => database
      .ref('telemetry_logs')
      .onValue
      .map((event) => parseOutlets(event.snapshot.value));

  Stream<GadgetStatus> streamGadgetStatus() => database
      .ref(DeviceBinding.statusPath)
      .onValue
      .map((event) => GadgetStatus.fromMap(databaseMap(event.snapshot.value)));

  Stream<Map<String, dynamic>> streamWifiConfig() => database
      .ref(DeviceBinding.wifiConfigPath)
      .onValue
      .map((event) => databaseMap(event.snapshot.value));

  /// The ESP32 stores these in flash, switches networks, then deletes the
  /// password from the database.
  Future<void> saveWifiConfig(String ssid, String password) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in to configure Wi-Fi.');
    if (ssid.trim().isEmpty || utf8.encode(ssid).length > 32) {
      throw ArgumentError('Enter a network name up to 32 bytes.');
    }
    if (password.isNotEmpty && (password.length < 8 || password.length > 63)) {
      throw ArgumentError(
        'Wi-Fi passwords are 8 to 63 characters (leave empty for open networks).',
      );
    }
    return database.ref(DeviceBinding.wifiConfigPath).set({
      'ssid': ssid,
      'password': password,
      'updatedAt': ServerValue.timestamp,
      'updatedBy': uid,
    });
  }

  static const _ownedOutlets = ['outlet_A', 'outlet_B'];

  static bool _isPermissionDenied(FirebaseException e) =>
      e.code.toLowerCase().replaceAll('_', '-').contains('permission-denied');

  /// Links this gadget to the signed-in account if it has no owner yet
  /// (1 device = 1 owner). Returns false when another account owns it.
  Future<bool> claimDevice() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in to link the WisePlug.');
    try {
      await database.ref().update({
        for (final outlet in _ownedOutlets) 'device_owners/$outlet': uid,
      });
      return true;
    } on FirebaseException catch (e) {
      if (_isPermissionDenied(e)) return false;
      rethrow;
    }
  }

  /// Unlinks the gadget so the next account to sign in can claim it.
  /// Does nothing when the signed-in account is not the owner.
  Future<void> releaseDevice() async {
    try {
      await database.ref().update({
        for (final outlet in _ownedOutlets) 'device_owners/$outlet': null,
      });
    } on FirebaseException catch (e) {
      if (!_isPermissionDenied(e)) rethrow;
    }
  }

  /// Sends new Wi-Fi credentials and reports progress until the ESP32 is
  /// back online on the new network, has rolled back, or timed out.
  Stream<WifiProvisionUpdate> provisionWifi(
    String ssid,
    String password,
  ) async* {
    await saveWifiConfig(ssid, password);
    // Watch only after saving: set() replaced any earlier acknowledgement.
    yield* trackWifiProvisioning(
      config: streamWifiConfig(),
      status: streamGadgetStatus(),
      ssid: ssid,
    );
  }

  /// The newest [limit] history events written by the ESP32, newest first.
  Stream<List<ActivityEvent>> streamActivity({int limit = 100}) => database
      .ref('activity_log')
      .orderByKey()
      .limitToLast(limit)
      .onValue
      .map((event) => parseActivity(event.snapshot.value));

  Future<void> clearActivity() => database.ref('activity_log').remove();

  /// Makes the ESP32 forget a learned appliance, then removes its saved name.
  Future<void> deleteProfile(
    OutletReading reading,
    LearnedAppliance profile,
  ) async {
    await command(
      reading,
      'REMOVE_PROFILE',
      fields: {'profileID': profile.profileID},
    );
    await database
        .ref(
          'appliance_registrations/OUTLET_${profile.outlet}/${profile.profileID}',
        )
        .remove();
  }

  /// Remotely clears a WARNING or LOCKED_OUT outlet back to IDLE.
  Future<void> resetSafety(OutletReading reading) =>
      command(reading, 'RESET_SAFETY');

  Stream<List<LearnedAppliance>> streamProfiles() => combineProfileStreams(
    database
        .ref('appliance_profiles')
        .onValue
        .map((event) => event.snapshot.value),
    database
        .ref('appliance_registrations')
        .onValue
        .map((event) => event.snapshot.value),
  );

  /// Saves the user's name for a learned signature. update() keeps any
  /// appliance type saved by older versions of the app.
  Future<void> registerProfile(LearnedAppliance profile, String name) async {
    if (name.trim().isEmpty || utf8.encode(name.trim()).length > 63) {
      throw ArgumentError('Enter an appliance name up to 63 bytes.');
    }
    await database
        .ref(
          'appliance_registrations/OUTLET_${profile.outlet}/${profile.profileID}',
        )
        .update({'name': name.trim()});
  }

  Stream<Map<String, dynamic>> streamPreferences() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value({});
    return database
        .ref('users/$uid/preferences')
        .onValue
        .map((event) => databaseMap(event.snapshot.value));
  }

  Future<void> savePreferences(Map<String, bool> preferences) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in to save settings.');
    return database.ref('users/$uid/preferences').update(preferences);
  }

  /// Queue intent, then wait for the ESP32 receipt. Never update telemetry here.
  Future<void> command(
    OutletReading reading,
    String type, {
    Map<String, Object?> fields = const {},
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in before controlling an outlet.');
    // `.info` paths are client-local: get() sends them to the server on web,
    // which rejects them ("Invalid token in path"). A listener reads locally.
    final offset = await database
        .ref('.info/serverTimeOffset')
        .onValue
        .first
        .then((event) => event.snapshot.value)
        .timeout(const Duration(seconds: 5), onTimeout: () => 0);
    final now = DateTime.now().toUtc().add(
      Duration(milliseconds: (offset as num?)?.toInt() ?? 0),
    );
    final allowed = type == 'RESET_SAFETY'
        ? reading.isFresh(now) && reading.sessionID.isNotEmpty
        : reading.canCommand(now);
    if (!allowed) {
      throw StateError('Fresh, unlocked device state is required.');
    }
    // Interlock (also enforced by the ESP32): an empty outlet is not switched
    // off. "Turn Off Now" during a warning always applies.
    if (type == 'TURN_OFF' &&
        !reading.isWarning &&
        !reading.hasConnectedAppliance(now)) {
      throw const DeviceRejection('REJECTED_NO_APPLIANCE');
    }
    if (type == 'SMART_OVERRIDE' &&
        (!reading.isWarning || reading.secondsRemaining(now) == 0)) {
      throw StateError('The override window has expired.');
    }
    final id = database.ref().push().key!;
    final receipt = database.ref(
      'command_results/outlet_${reading.outlet}/$id',
    );
    final completer = Completer<void>();
    final subscription = receipt.onValue.listen(
      (event) {
        final result = databaseMap(event.snapshot.value)['result'];
        if (result == null || completer.isCompleted) return;
        if (result == 'ACCEPTED') {
          completer.complete();
        } else {
          completer.completeError(DeviceRejection('$result'));
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    // Attach the error handler before either network write can complete.
    final confirmation = completer.future.timeout(const Duration(seconds: 25));
    try {
      await Future.wait([
        database.ref('commands/outlet_${reading.outlet}').set({
          ...fields,
          'commandID': id,
          'userID': user.uid,
          'type': type,
          'sessionID': reading.sessionID,
          'revision': reading.revision,
          'expiresAt': now.millisecondsSinceEpoch + 20000,
        }),
        confirmation,
      ]);
    } on TimeoutException {
      throw StateError(
        'No device confirmation. Check the live state before retrying.',
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> editProfile(
    OutletReading reading,
    LearnedAppliance profile,
    String name,
    int maxRunTime,
    int safetyCeilingDuration,
  ) {
    if (name.trim().isEmpty ||
        utf8.encode(name.trim()).length > 63 ||
        maxRunTime <= 0 ||
        safetyCeilingDuration < maxRunTime ||
        safetyCeilingDuration > 604800) {
      throw ArgumentError(
        'Use a name up to 63 bytes and limits from 1 to 604800 seconds, with the ceiling at least the runtime.',
      );
    }
    return command(
      reading,
      'EDIT_PROFILE',
      fields: {
        'profileID': profile.profileID,
        'name': name.trim(),
        'maxRunTime': maxRunTime,
        'safetyCeilingDuration': safetyCeilingDuration,
      },
    );
  }
}
