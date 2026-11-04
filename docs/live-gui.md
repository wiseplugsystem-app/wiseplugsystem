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
- **Words, not only colours.** Each outlet says what it is doing in words,
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

## Measuring appliances (in plain words)

- **What it is for:** measuring real appliances on WisePlug to build the
  thesis dataset and check how well recognition works.
- **Only use what the plug can carry:** appliances whose label says **8 A or
  1,760 W or less** (with the heatsinks fitted). Never an aircon. Above that
  the plug turns the outlet off after 10 seconds.
- **Stay with heating appliances** the whole time, never run a microwave
  empty (heat a cup of water), and keep a switch within reach to cut power
  by hand.
- **Each appliance and each setting:** 3 plug-ins to register it (2 on
  Outlet A, 1 on B), then 10 tests on A and 10 on B, each left on at least
  90 seconds. Irons, rice cookers and fridges also get one 10-minute log.
- **Write every run in the recording sheet** (date, time, outlet, which
  appliance, which setting). The plug measures the rest by itself.
- **The analysis** makes the tables and charts for the thesis from your
  measurements only.

How it works: `docs/measurement-guide.md` (the full steps, safety and
references), `measurements/recording_sheet_template.csv`,
`tool/measure_log.ts` (10-minute logs from the plug's live readings, about
every 3 s) and `tool/measure_analyze.ts` (export from Supabase, then the
report and charts in `measurements/results/`).

## What WisePlug can power (in plain words)

- **Appliances up to 1,760 W (8 A).** Look at the label on the appliance. Most
  fans, TVs, chargers, rice cookers, irons and microwaves fit.
- **Above that, WisePlug turns the outlet off** after 10 seconds and locks it,
  and at once above 10 A. A motor's short start-up surge does not count.
- **These cannot be added:** aircon, electric kettle, hair dryer, induction
  cooker and washing machine. They can draw more than the plug can carry.
- **When you add an appliance**, the pictures are: electric fan, rice cooker,
  flat iron, microwave, TV, refrigerator, phone charger and laptop charger,
  each with its usual power (for example "30–100 W" for a fan). Anything else
  goes under **Other**. The app refuses any appliance it measures above
  1,760 W, whatever you call it.

How it works: `CONTINUOUS_CURRENT_A` (8 A) and `OVERLOAD_MS` (10 s) next to
`MAX_CURRENT_A` (10 A) in the firmware; the outlet trips with the existing
OVERCURRENT reason, so the server and database are unchanged. In the app,
`maxApplianceWatts`, `applianceWatts` (each type's usual range, from the owner's list) and `unsupportedKinds` (the types whose range goes above the limit) in `lib/models/appliance_icons.dart`; on the server, `recognition_config.max_appliance_w` (migration `20261105010000_appliance_power_limit.sql`) and `tooPowerful` in register-sample.
The limit assumes the SSR-40DA sits on its heatsink with thermal paste.

## After a safety cutoff (in plain words)

- **Reset Safety unlocks the outlet, but keeps it off.** The appliance that
  hit its limit does not start again by itself.
- **To use it again, press Turn on again** (under Power Control) and confirm.
  The app asks: "Only turn it on if you are there and want to use it again."
  Choose **Keep it off** if you are not.
- **The Power Control switch asks the same question** in this case. An outlet
  you switched off yourself turns on without asking.
- **The button on the plug** turns the outlet on straight away: you are
  standing at it.

How it works: `remoteReset()` in `safety_state.h` now leaves the outlet
DISABLED with `resetHold`; the plug publishes `safetyResetHold` in
telemetry_logs; only a TURN_ON (or the plug's button) clears it. The app
(`_turnOnAgain` in esp32_live_view.dart) asks before sending TURN_ON.

## Heating appliances (in plain words)

- **Appliances that make heat get a shorter time limit.** A kettle may stay
  on 15 minutes, a hair dryer 15, a microwave 30, an iron, air fryer or
  heater 60, and a rice cooker 90. Other appliances keep
  their normal limit.
- **You still get the 60-second warning** before WisePlug turns it off, and
  you can keep it on if you are there.
- **You don't set anything:** WisePlug knows from the picture you chose when
  you added the appliance (or from its name, like "heater").
- **A water dispenser is not limited:** its hot water is made to stay on all
  day.

How it works: the `heating_safe_times` table (migration
`20261105000000_heating_safe_times.sql`) holds the minutes for each type. A
heating type's default is its limit, and an appliance is never allowed more
(a shorter time stays shorter). Changing a row updates every type and
appliance. Why these numbers: docs/scope.md, section 3.

## Deployment

Deploy the updated database rules to permit each signed-in user to read/write their alert preferences. Deploy the updated functions to honor those preferences for safety push delivery. These changes do not alter device ownership requirements.

Flash the updated ESP32 sketch to publish `profileID` and `safetyDeadline`. The GUI remains usable with older telemetry, but precise remaining time stays unavailable.

No database data, rules, functions or firmware are deployed by a Flutter hot reload. Fully restart/rebuild the app after adding the version asset.
