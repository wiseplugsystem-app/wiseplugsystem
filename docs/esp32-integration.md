# ESP32 → Firebase Realtime Database → mobile app

The supplied sketch uses Realtime Database, not Cloud Firestore. The default
mobile dashboard now subscribes to its existing paths in project `wise-46f92`.
There is no migration or need to copy readings into Firestore.

| Database path | App display |
| --- | --- |
| telemetry_logs/outlet_A | Outlet A readings and measured activity |
| telemetry_logs/outlet_B | Outlet B readings and measured activity |
| appliance_profiles/OUTLET A/{name} | Outlet A learned appliances |
| appliance_profiles/OUTLET B/{name} | Outlet B learned appliances |

The adapter maps `power_W` to active power, `voltage_V` to voltage, `current_A`
to current, `power_factor` to power factor and `peak_power_W` to peak power.
Profile `steadyPower_W` is baseline wattage. Fields are kept in their original
Arduino format; these adapter models are separate from the Firestore domain models.

## Run the mobile app

1. Run `flutter pub get`, then `flutter run` on the phone/emulator.
2. Home shows both outlets. Profiles shows appliances learned by the ESP32.
3. Realtime Database rules must allow this client's reads at `telemetry_logs`
   and `appliance_profiles`. The current app has no Firebase sign-in flow.
   If your rules require authentication, that must be configured before live
   reads can succeed; the app displays a permission/connection error otherwise.
   Do not embed the Arduino's database secret in Flutter or open database writes.

The database URL defaults to the one in your sketch. To use another instance:

```text
flutter run --dart-define=WISEPLUG_DATABASE_URL=https://your-database.firebasedatabase.app
```

The old Firestore dashboard is available with
`--dart-define=WISEPLUG_USE_FIRESTORE=true`. It is a separate data source;
Firestore edits do not configure or control this ESP32 firmware.

## Upload the compatible sketch

1. Open `arduino/wiseplug_esp32/wiseplug_esp32.ino` in Arduino IDE.
2. Copy `secrets.example.h` to `secrets.h` in that folder and enter your Wi-Fi
   credentials and database secret locally. `secrets.h` is ignored by Git.
   Credentials pasted into chat should be rotated; they are not copied into the repository.
3. Use your ESP32 board and existing PZEM004Tv30 and Firebase ESP32 Client
   libraries. The local Firebase library inspected during implementation is 4.4.17.
4. Sensor A uses RX 32 / TX 33 (Serial2); sensor B uses RX 25 / TX 26 (Serial1).
   Select the actual board and serial port before uploading.
5. Open Serial Monitor at 115200 baud with newline. For a new appliance, enter
   `A:Fan` or `B:Rice cooker`. A plain name also works when only one outlet is
   awaiting registration. Learned profiles are uploaded automatically.

The existing sketch already works with the new app. The supplied replacement
retains the same NVS signature structure and paths, and improves delivery:

- Updates all fields in one Firebase operation, every three seconds, including idle.
- Adds `last_updated_ms` using Firebase server time and `sensor_valid`.
- Keeps monitoring while waiting for a Serial Monitor name; fingerprint capture
  still takes about two seconds and network operations are synchronous.
- Bounds stored profiles to 20 and retries unsynced profiles after reconnection.
- Emits UTC timestamps; the app also supports the original UTC+8 text timestamps.

The app marks readings older than 30 seconds as stale. Total power is shown only
when both outlets have recent valid power readings. The original sketch stops
publishing while idle, so its idle readings eventually appear stale. Neither
sketch stores a historical time series: each outlet path contains its latest sample.

## Hardware behavior

This integration monitors measurements. The supplied sketch has no relay pins,
command listener, automatic safety cutoff or smart-override enforcement, so the
ESP32 dashboard does not offer those controls. Activity is inferred from measured
power, not relay feedback. Naming through Serial Monitor remains the source of
learned profiles; mobile registration requires a separate firmware command protocol.

## Verify the connection

1. Confirm the outlet records update in the Realtime Database console.
2. Check that voltage/current/power on the phone agree with the sensor output.
3. Register an appliance and confirm its name appears under Profiles.
4. Disconnect ESP32 Wi-Fi and check that readings become stale after 30 seconds.
5. If no data appears, confirm the database URL and read permissions. A legacy
   token allowing the ESP32 to write does not grant the mobile app permission to read.

## References

- [Firebase Flutter Realtime Database setup](https://firebase.google.com/docs/database/flutter/start)
- [Realtime Database live listeners](https://firebase.google.com/docs/database/flutter/read-and-write)
- [Firebase ESP32 library examples](https://github.com/mobizt/Firebase-ESP32/blob/master/examples/Basic/Basic.ino)
- [PZEM004Tv30 library](https://github.com/mandulaj/PZEM-004T-v30)
