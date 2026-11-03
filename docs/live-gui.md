# Live GUI data contract

## Registration and popup update

- The live dashboard prompts once per detected usage for an unnamed firmware signature, including signatures present when the app opens. Disregard or Cancel suppresses repeats for that use; an unregistered profile row can reopen registration manually.
- User names and types are stored in `appliance_registrations/OUTLET_A/{profileID}` (or `OUTLET_B`) and merged with the firmware-owned catalog. Deploy `database.rules.json` before using this update; otherwise the profile stream reports a permissions error. Firmware catalog publications cannot overwrite these names and types.
- Registration requires a learned signature in `appliance_profiles`; telemetry alone cannot reliably identify an appliance. Existing firmware recognition remains per outlet. Shared recognition and relay changes are outside this UI update.
- Profile editing saves firmware runtime limits through the existing command receipt flow, then saves display metadata. A metadata error keeps the editor open; the runtime command may already have succeeded.
- Safety warnings are raised app-wide by `SafetyAlertListener` from `devices/gadget-1/status` (`safetyTriggered` or `remainingLimit <= 0`), with the WisePlug warning sound (see "Warning sounds" below). Turn Off Now sends TURN_OFF (the relay cuts power); Reset Safety sends RESET_SAFETY; During the countdown there is no Dismiss and no mute: the warning ends with Turn Off Now, Yes, Override or the cutoff. After a power cut, Dismiss closes the pop-up.
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
- **No mute, no dismiss.** During the countdown the sound stops only when
  you answer (Turn Off Now, or Yes, Override to keep it running) or when the
  power is cut.
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

## Appliance icons (in plain words)

- **Every appliance shows a picture of what it is**: a fan, a rice cooker,
  an iron, a TV and so on, always with its name next to it.
- **When you add an appliance**, you pick what it is from pictures ("What
  are you adding?"). If it is not there, tap **Other** and write what it is.
- **All appliances of the same type share the same picture**, so all your
  fans look alike.
- **A question mark** means WisePlug does not know the appliance yet (new,
  or not sure). It changes to the right picture once it is recognised.
- **Other** appliances show a general electrical picture.

Where: Home (each outlet at 48 dp, and Power Control), the Profiles list and
each appliance's screen, the "What are you adding?" grid (48 dp), the
recognition questions, and the safety warning. Push notifications use the
app icon (phones allow one small single-colour icon there).

How it works: one mapping file, `lib/models/appliance_icons.dart`: each
standard type has a key, a label and a Material Icon (built into Flutter,
Apache 2.0, see `CREDITS.md`). The key is stored per type in
`appliance_types.icon_key` (migration `20261104000000_appliance_icons.sql`)
and sent by registration (`register-sample`, `iconKey`). Types without a key
are matched by the words in their name; anything else is "Other". Closest
icons (the set has no exact one): fan (wind), kettle (coffee maker), air
fryer (grill), induction cooker (countertop), hair dryer (drying hands),
water dispenser (water drop). Icons are 24 dp in lists and 48 dp on Home and
in the grid, in a darker blue (about 4.6:1 on white), with screen-reader
labels.

## Easy to read (in plain words)

- **Text that fits your phone.** Normal text is 16 points, nothing is
  smaller than 14. Text is a little smaller on narrow phones and full size
  on tablets, so every screen looks the same on any phone. The app follows
  your phone's text size setting up to 1.3 times bigger; beyond that it
  stops growing so buttons and numbers stay on the screen.
- **Clear colours.** All text stands out from its background (at least
  4.5 to 1, the usual accessibility rule), in light and dark mode. Faint
  grey text is now darker.
- **Easy to tap.** Every button is at least 48 dp, about the size of a
  fingertip.
- **Words with pictures.** The bell on Home now says **History** (the list
  of everything that happened). Each outlet says what it is doing in words,
  not only in colour: **Ready to use** (on, nothing running), **In use**,
  **Turned off** (you turned it off) or **Turned off for safety** (the
  safety limit turned it off).
- **One thing per row.** The Profiles list has no trash can; open an
  appliance to delete it.
- **Plain words.** Screens don't use technical words (server, power factor,
  calibration, ESP32 and so on). Words we kept on purpose: outlet,
  appliance profile, usage session, sample, and watts as numbers ("73 W").

How it works: `lib/theme.dart` holds the text sizes, button sizes and the
contrast check (`readableOn`, `context.readable`, `context.muted`) and the
text fitting (`fitTextToScreen`, set as the app's `builder`), used by
every screen. Tests (kept local): `readability_test.dart` (contrast, sizes,
no technical words) and `responsive_test.dart` (a small phone at the
largest text size). How to test with people: `docs/usability-test.md`.

## Deployment

Deploy the updated database rules to permit each signed-in user to read/write their alert preferences. Deploy the updated functions to honor those preferences for safety push delivery. These changes do not alter device ownership requirements.

Flash the updated ESP32 sketch to publish `profileID` and `safetyDeadline`. The GUI remains usable with older telemetry, but precise remaining time stays unavailable.

No database data, rules, functions or firmware are deployed by a Flutter hot reload. Fully restart/rebuild the app after adding the version asset.
