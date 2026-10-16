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

## Upload the sketch

1. Open `arduino/wiseplug_esp32/wiseplug_esp32.ino` in Arduino IDE.
2. Copy `secrets.example.h` to `secrets.h` in that folder and enter the database
   host and secret. `secrets.h` is ignored by Git. A secret that has ever been
   pasted into code, chat or a commit must be rotated in the Firebase console.
3. Install the libraries: PZEM004Tv30, WiFiManager (tzapu), ArduinoJson 7.
4. Wiring: PZEM A on RX 32 / TX 33 (Serial2), PZEM B on RX 25 / TX 26 (Serial1),
   relays on GPIO 18 / 19 (`RELAY_ON` is HIGH; swap the defines for an active-low
   board), optional reset buttons from GPIO 4 / 5 to GND.
5. On first boot (or whenever it cannot reach a router for 20 s), the plug opens its own Wi-Fi `wisewp` (open, no password). Join it with a phone: a setup page opens by itself listing the 2.4 GHz networks the plug can see; tap yours and enter its password. The app does the same under Settings → Wi-Fi Configuration → **Nearby setup** (it detects the join automatically). Manual fallback: open `http://192.168.4.1` and choose
   the home network. Later changes can be sent from the app's Wi-Fi screen.

Appliances learned by the previous sketch (`app_N` records) are migrated on
first boot; the app then asks once to register each one.

## Hardware behavior

Each outlet has a relay. The relay is on in IDLE, SAMPLING, ACTIVE and WARNING
and off in DISABLED and LOCKED_OUT; that state is saved, so relays stay off
across reboots. A reboot while an appliance was running locks the outlet, so
nothing restarts unattended after a power cut. When a session reaches its safety
ceiling (30 minutes for a new appliance) the outlet enters a 60-second WARNING;
the app can turn it off, extend it, or let it lock out. A locked outlet is
switched back on with its button or the app's **Reset Safety**.

The control loop (sensors, safety, relays) never waits for the network; Firebase
and Wi-Fi run in a separate task, publishing every second and polling commands
every second.

## Gadget node (`devices/gadget-1`)

The app is bound to exactly one gadget, `gadget-1` (stored in
SharedPreferences under `boundDeviceId`; the firmware's `DEVICE_ID` must
match). Alongside `telemetry_logs`, the sketch publishes a device summary:

| Path | Type | Meaning |
| --- | --- | --- |
| `status/outletA`, `status/outletB` | bool | Outlet switched on (not DISABLED / LOCKED_OUT) |
| `status/powerDraw` | double | Sum of both outlets, watts |
| `status/connectionStatus` | string | Always `"Online"` while publishing |
| `status/lastSeen` | server timestamp | The app shows **Offline** if older than 30 s |
| `status/remainingLimit` | double | Seconds to the earliest safety deadline; `0` when tripped; absent when nothing is running |
| `status/safetyTriggered` | bool | Any outlet in WARNING or LOCKED_OUT |
| `wifiConfig/ssid`, `wifiConfig/password` | string | Written by the app; the device saves them to flash, then deletes `password` |
| `wifiConfig/updatedAt`, `wifiConfig/receivedAt` | number | `receivedAt == updatedAt` once the device has the new settings |

The app-wide safety dialog and alarm open only when `safetyTriggered` is true
or `remainingLimit <= 0` (and `lastSeen` is fresh). Outlet switches and
**Reset Safety** go through the confirmed `commands/` queue; `RESET_SAFETY`
is the one command the device accepts while LOCKED_OUT.

Wi-Fi changes only reach a gadget that is online. If the new network fails
for 20 s the sketch rolls back to the previous network; after 60 s offline it
switches to its `wisewp` setup network (retrying the saved router every 2 minutes while nobody is joined).

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
