import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'dart:async';
import 'dart:convert';

import '../models/esp32_data.dart';

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
  Future<void> registerProfile(
    LearnedAppliance profile,
    String name,
    String type,
  ) async {
    if (name.trim().isEmpty ||
        utf8.encode(name.trim()).length > 63 ||
        ![
          'Rice cooker',
          'Flat iron / hair straightener',
          'Electric fan',
          'Other',
        ].contains(type)) {
      throw ArgumentError('Enter a name up to 63 bytes and an appliance type.');
    }
    await database
        .ref(
          'appliance_registrations/OUTLET_${profile.outlet}/${profile.profileID}',
        )
        .set({'name': name.trim(), 'applianceType': type});
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
    final offset = (await database.ref('.info/serverTimeOffset').get()).value;
    final now = DateTime.now().toUtc().add(
      Duration(milliseconds: (offset as num?)?.toInt() ?? 0),
    );
    if (!reading.canCommand(now)) {
      throw StateError('Fresh, unlocked device state is required.');
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
          completer.completeError(StateError('ESP32: $result'));
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
