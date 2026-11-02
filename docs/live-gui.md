# Live GUI data contract

## Registration and popup update

- The live dashboard prompts once per detected usage for an unnamed firmware signature, including signatures present when the app opens. Disregard or Cancel suppresses repeats for that use; an unregistered profile row can reopen registration manually.
- User names and types are stored in `appliance_registrations/OUTLET_A/{profileID}` (or `OUTLET_B`) and merged with the firmware-owned catalog. Deploy `database.rules.json` before using this update; otherwise the profile stream reports a permissions error. Firmware catalog publications cannot overwrite these names and types.
- Registration requires a learned signature in `appliance_profiles`; telemetry alone cannot reliably identify an appliance. Existing firmware recognition remains per outlet. Shared recognition and relay changes are outside this UI update.
- Profile editing saves firmware runtime limits through the existing command receipt flow, then saves display metadata. A metadata error keeps the editor open; the runtime command may already have succeeded.
- Safety warnings are raised app-wide by `SafetyAlertListener` from `devices/gadget-1/status` (`safetyTriggered` or `remainingLimit <= 0`), with the WisePlug warning sound (see "Warning sounds" below). Turn Off Now sends TURN_OFF (the relay cuts power); Reset Safety sends RESET_SAFETY; Dismiss closes the current event; Mute this warning silences only its sound.
- Validate with `flutter test test/live_popups_test.dart test/esp32_live_view_test.dart test/esp32_data_test.dart` and `flutter analyze`.

The default ESP32 dashboard implements the supplied Home, Profiles, profile-detail and Settings references. Screenshot names, wattages, times, identifiers and session counts are not production fixtures.

- Home reads `telemetry_logs/outlet_A` and `outlet_B`. Total power and active counts are unavailable when either reading is missing, stale, invalid or inaccessible.
- Profiles read `appliance_profiles/OUTLET_A` and `OUTLET_B`, with legacy spaced outlet keys supported. Profile identity uses telemetry `profileID`; legacy appliance-name matching is used only when unique within that outlet.
- Limits come from `safetyCeilingDuration` and `maxRunTime` in seconds. Missing limits are displayed as unavailable and are blank in the editor.
- Optional profile `applianceType` and `totalSessions` are displayed only when supplied by the database. The current firmware does not collect these fields; no guessed types or counts are generated.
- Remaining time uses telemetry `safetyDeadline`, an absolute timestamp published by the updated firmware from its effective monotonic deadline. This includes accepted overrides. Older firmware without this field shows an unavailable remaining time.
- Edit, delete, monitoring switches and overrides send commands and wait for ESP32 receipts. Delete is offered only for an idle or disabled outlet. The current firmware has software monitoring states, not physical relay switching, so the UI describes monitoring and does not promise electrical shutoff.
- Alert preferences are saved in `users/{uid}/preferences`. Device changes and new profiles generate in-app messages after the initial snapshot; safety messages also use the existing mobile push delivery function. Turning alerts off does not disable firmware protection.
- The app version is read from the bundled `pubspec.yaml` rather than a screenshot value.

## Warning sounds (in plain words)

- **One sound for every safety warning**, so you learn it: two short beeps,
  a low one then a high one.
- **When an appliance is about to be switched off** (the 60-second
  countdown), the two beeps repeat every 4 seconds, and every second in the
  last 10 seconds.
- **When the power is cut** (also right away for an electrical fault): one
  long beep, then silence.
- **"Mute this warning"** in the warning pop-up silences this warning only.
  The next warning sounds again. Muting does not stop the cutoff: the
  appliance is still switched off on time.
- **App closed or in the background:** the safety notification plays the
  same sound on Android (once the app has been opened once). iPhones play
  their default sound until the tone is added in Xcode. The web version
  plays the sound only while the page is open (and some browsers only
  after you have tapped the page once).

Why this sound: ISO 7731 (auditory danger signals for public and work
areas) asks for a pulsed signal that stands out clearly (about 15 dB above
the surrounding noise), with its main sound low enough (about 500 to 1500 Hz)
for people with some hearing loss and through a door. Our tone pulses, and
its first beep is 1 kHz; the second, 2.5 kHz, keeps it sharp. It is NOT the
"3 beeps, pause" rhythm of ISO 8201 (Temporal-3), which people know from
smoke alarms and fire evacuation.

How it works: `lib/services/safety_alarm_manager.dart` (timings and volume
in `WarningSoundConfig`); the tones are made by `tool/make_warning_tone.ts`
(`node tool/make_warning_tone.ts`), released as CC0
(`assets/sounds/LICENSE.md`). Android: the "Safety warnings" channel
(`MainActivity.kt`, `res/raw/wiseplug_warning.wav`), named by the Supabase
sender (`supabase/functions/_shared/google.ts`). The Firebase function
`safetyAlert` (needs the paid Blaze plan, not deployed) still names the
default sound.

## Deployment

Deploy the updated database rules to permit each signed-in user to read/write their alert preferences. Deploy the updated functions to honor those preferences for safety push delivery. These changes do not alter device ownership requirements.

Flash the updated ESP32 sketch to publish `profileID` and `safetyDeadline`. The GUI remains usable with older telemetry, but precise remaining time stays unavailable.

No database data, rules, functions or firmware are deployed by a Flutter hot reload. Fully restart/rebuild the app after adding the version asset.
