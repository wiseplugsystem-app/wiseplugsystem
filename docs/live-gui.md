# Live GUI data contract

## Registration and popup update

- The live dashboard prompts once per detected usage for an unnamed firmware signature, including signatures present when the app opens. Disregard or Cancel suppresses repeats for that use; an unregistered profile row can reopen registration manually.
- User names and types are stored in `appliance_registrations/OUTLET_A/{profileID}` (or `OUTLET_B`) and merged with the firmware-owned catalog. Deploy `database.rules.json` to enable registration. If that metadata path is inaccessible, the app displays the firmware catalog with a registration warning and suppresses automatic registration prompts until metadata is readable. Firmware catalog publications cannot overwrite these names and types.
- Home displays valid per-outlet power independently of the combined total. Device timestamps explain stale readings; telemetry and catalog read failures have separate messages. A profile error does not suppress live watts. The total remains unavailable when either outlet lacks valid live data.
- Registration requires a learned signature in `appliance_profiles`; telemetry alone cannot reliably identify an appliance. Existing firmware recognition remains per outlet. Shared recognition and relay changes are outside this UI update.
- Profile editing saves firmware runtime limits through the existing command receipt flow, then saves display metadata. A metadata error keeps the editor open; the runtime command may already have succeeded.
- Safety warnings open automatically and use the device countdown deadline. Turn Off Now sends the existing TURN_OFF command. Yes, Override is disabled while the average-usage calculation is deferred. Current firmware still does not disconnect electrical power.
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

## Deployment

Deploy the updated database rules to permit each signed-in user to read/write their alert preferences. Deploy the updated functions to honor those preferences for safety push delivery. These changes do not alter device ownership requirements.

Flash the updated ESP32 sketch to publish `profileID` and `safetyDeadline`. The GUI remains usable with older telemetry, but precise remaining time stays unavailable.

No database data, rules, functions or firmware are deployed by a Flutter hot reload. Fully restart/rebuild the app after adding the version asset.
