# Live GUI data contract

## Registration and popup update

- The live dashboard prompts once per detected usage for an unnamed firmware signature, including signatures present when the app opens. Disregard or Cancel suppresses repeats for that use; an unregistered profile row can reopen registration manually.
- User names and types are stored in `appliance_registrations/OUTLET_A/{profileID}` (or `OUTLET_B`) and merged with the firmware-owned catalog. Deploy `database.rules.json` before using this update; otherwise the profile stream reports a permissions error. Firmware catalog publications cannot overwrite these names and types.
- Registration requires a learned signature in `appliance_profiles`; telemetry alone cannot reliably identify an appliance. Existing firmware recognition remains per outlet. Shared recognition and relay changes are outside this UI update.
- Profile editing saves firmware runtime limits through the existing command receipt flow, then saves display metadata. A metadata error keeps the editor open; the runtime command may already have succeeded.
- Safety warnings are raised app-wide by `SafetyAlertListener` from `devices/gadget-1/status` (`safetyTriggered` or `remainingLimit <= 0`), with the WisePlug warning sound (see "Warning sounds" below). Turn off now sends TURN_OFF (the relay cuts power); Reset Safety sends RESET_SAFETY; During the countdown there is no Dismiss and no mute: the warning ends with Turn off now, Keep it on or the cutoff. After a cutoff, Close closes the pop-up.
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
  you answer (Turn off now, or Keep it on) or when the
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

## Adding an appliance (in plain words)

The app shows the same three steps to everyone, in short words a child can
follow:

1. **Turn it on.**
2. **Leave it on for about 1 minute.** Don't touch the buttons.
3. **Turn it off.**

**Do this one time for each setting** of the appliance:

| Appliance | Its settings (one sample each) |
|---|---|
| Electric fan | Level 1, Level 2, Level 3 (you choose: 1, 2, 3 or 4 levels; Level 1 is the slowest, and each level you add is one more sample) |
| Flat iron | Low, Medium, High |
| Rice cooker | Cook, Keep warm |
| Laptop charger, phone charger | 1 sample (a charger picks its speed by itself) |
| Other | 1 sample; tap **Add another setting** if it has more (up to 6) |

Outlet A or B, both work. Each time the app says which setting to use and
what to do next ("Turn the fan on. Set it to Level 2.", "Sample 2 of 3 done!
Now turn the fan off. Next: Level 3."), and "All done!" at the end. This way
WisePlug knows the fan on every level. Until then, WisePlug turns the
appliance off after 30 minutes to keep you safe. You can stop and finish
later: turn it on again and WisePlug will ask.

The picture list has the electric fan (35–65 W), flat iron (1,000–1,500 W),
rice cooker (30–750 W), laptop charger (10–140 W) and phone charger
(5–120 W); anything else is **Other**.

How it works: each setting is its own profile (`appliance_profiles`, with
`required_samples` and `level_position`, migration
`20261106000000_samples_per_level.sql`); `recognition_config.samples_per_level`
(1) is the samples for each. Recognition already accepts an appliance when any
of its settings matches. A setting with one sample starts strict (only the
minimum allowance) and widens each time you confirm "Yes, it is the fan".
Appliances registered before this keep their single 3-sample profile. The
settings for each type are `levelsFor()` in `lib/models/appliance_icons.dart`.

## After a safety cutoff (in plain words)

- **Reset Safety unlocks the outlet, but keeps it off.** The appliance that
  hit its limit does not start again by itself.
- **To use it again, press Turn on again** (under Power Control) and confirm.
  The app asks: "Only turn it on if you are there and want to use it again."
  Choose **Keep it off** if you are not.
- **The Power Control switch asks the same question** in this case. An outlet
  you switched off yourself turns on without asking.
- **There is no button on the plug:** Reset Safety and Turn on again are
  only in the app.

How it works: `remoteReset()` in `safety_state.h` now leaves the outlet
DISABLED with `resetHold`; the plug publishes `safetyResetHold` in
telemetry_logs; only a TURN_ON from the app clears it. The app
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

## Heatsinks and too much power (in plain words)

Each solid-state relay (SSR) sits on its own aluminium heatsink. The relay
gets warm while it gives power (about 1.6 V × the current: roughly 13 W at
8 A), and the heatsink carries that heat away. WisePlug has no temperature
sensor, so the heatsinks are checked by hand.

**Fitting the heatsinks (with the plug unplugged from the wall):**

1. A thin, even layer of thermal paste (non-conductive, like CPU paste)
   between the relay's metal base and the heatsink.
2. Two M4 screws per relay, tightened a little at a time, firm but not
   forced (the relay's tabs are plastic). Spring washers keep them tight.
3. Fins pointing up and down, so warm air rises out.
4. Vent holes in the box, low on one side and high on the other.
5. The heatsink touches no screw terminal, bare wire or the current
   clamp; route the wires away from the fins.
6. The ESP32 and the meters beside or below the heatsinks, not above them
   in the warm air.

**Touch check:** run something big (a rice cooker or an iron) for 10
minutes, then touch the heatsink. Warm is fine. Too hot to keep a finger on
means the paste or the airflow is wrong: unplug it and fix that first.

**Too much power:** WisePlug turns the outlet off at once above 10 A, or
after 10 seconds above 8 A (about 1,760 W). The phone then says: *"This
appliance uses too much power for WisePlug. Outlet A was turned off to stay
safe."* Unplug that appliance before resetting.

How it works: `MAX_CURRENT_A`, `CONTINUOUS_CURRENT_A` and `OVERLOAD_MS` in the
firmware; the notice text in `sendNotices()`; the push text in
`supabase/functions/_shared/safety.ts`. Every trip is logged in `alert_logs`
for the thesis:
`select occurred_at, outlet, appliance_name, power_w, current_a from alert_logs where alert_type = 'OVERCURRENT' order by occurred_at;`

## Keeping the plug running (in plain words)

WisePlug looks after itself, so nobody has to unplug it to "restart" it:

- **If the internet connection keeps failing**, the plug closes and reopens
  its connection to the cloud by itself.
- **If that does not help, or its memory gets too cut up, or after 7 days**,
  it restarts itself, but **only while both outlets are idle or off**, so a
  running appliance is never interrupted. After a restart for a lasting
  internet problem it waits 6 hours before trying that again.
- **If the safety part ever froze**, a hardware watchdog restarts it; an
  outlet that was running then comes back off and locked, like after a power
  cut.
- **Run summaries and safety reports** wait in the plug's memory until
  the server has them (since the 42nd commit: the flash store of the 36th
  stopped them from reaching Supabase at all, see below).
- **Updates over Wi-Fi:** new firmware can be sent from the Arduino IDE
  without a cable, only while both outlets are idle or off.
- **Connections** are encrypted, but the servers' certificates are not
  checked (as in the 35th commit; checking them needed more memory than the
  plug has, see below).

How it works: the SELF-HEALING section of the firmware (cloud health,
heartbeats, `healthCheck()` in the safety loop, `enableLoopWDT()`);
`sendSupabase()`; Arduino OTA when `OTA_PASSWORD` is set in `secrets.h`. The plug reports `devices/gadget-1/status/health`
(uptime, free memory, largest free block, last self-restart) in Firebase.

**Arduino IDE setting (once):** Tools → Partition Scheme → **Minimal SPIFFS
(1.9MB APP with OTA/128KB SPIFFS)**. The firmware no longer fits the default
layout with room to spare.

## The plug's own login (in plain words)

The plug used to talk to Firebase with the **database secret**, a master key
that can read and change everything. If someone read it from the chip, the
whole database was open. Now the plug can sign in with **its own account**,
like the app does, and the database rules let that account do only what the
plug does: write its readings, alerts and results, read the app's commands
and the new Wi-Fi network. It cannot read other users' data or change who
owns the plug. Its login lasts an hour and the plug renews it by itself.
If the login fails, safety is not affected: the outlets keep working and the
plug tries again every minute.

Set it up once, in this order:

1. **Firebase console → Authentication → Users → Add user:** an email such
   as `plug-gadget-1@<your domain>` (it does not need to be a real mailbox)
   and a long password. Copy the **User UID** it shows.
2. **Realtime Database → Data:** at the top level add `device_accounts` with
   the child `gadget-1` = that UID. (Only the console can change it.)
3. **Deploy the rules:** `firebase deploy --only database --project wise-46f92`.
   The plug keeps working on the old secret meanwhile.
4. **secrets.h:** add `FIREBASE_API_KEY` (Project settings → General → Web
   API key), `FIREBASE_DEVICE_EMAIL` and `FIREBASE_DEVICE_PASSWORD`, then flash.
5. Check that the app still shows live readings and that a command (turn off,
   turn on) works.
6. Then **Project settings → Service accounts → Database secrets:** delete the
   old secret, and remove `FIREBASE_AUTH` from `secrets.h`.

How it works: `haveLogin()` in the firmware (Identity Toolkit sign-in,
Secure Token renewal, `?auth=<ID token>`); `device_accounts/gadget-1` in
`database.rules.json`.

## When a meter stops answering (in plain words)

Each outlet has its own meter. A meter that stops answering no longer
switches its outlet off. (Before, a silent meter kept its outlet off, so the
two outlets took turns being on.) Now:

- **Nothing running:** the outlet stays on or off, the way you set it. The
  card says **"Not measuring"**. WisePlug can't time an appliance on that
  outlet until the meter answers again.
- **A short blip does nothing.** The plug restarts the meter's connection
  by itself.
- **Something running when the meter stops for 5 seconds:** the usual
  60-second warning appears, then the outlet turns off for safety. If the
  meter answers within that time, the run simply goes on.

If an outlet keeps saying "Not measuring", check that meter's 5V, GND, TX and
RX wires (see the wiring page), and that the meter is connected to mains. A
PZEM meter needs mains power to measure; USB power alone is not enough.

## Fewer downloads, steadier clock (in plain words)

- **Firebase free plan:** Firebase used to send every once-a-second update
  back to the plug. Those replies alone came to about 10 GB a month, the whole
  free allowance. The plug now asks for no reply (`print=silent`), so a month
  uses about 1–2 GB.
- **Internet time:** the plug starts asking for the time only once its Wi-Fi
  is online. Asking at power-up, while Wi-Fi was still connecting, could
  crash it.
- **No paid Firebase features:** the old Firebase Cloud Function
  (`functions/`) was removed. It needed the paid Blaze plan, and Supabase
  already sends the phone alerts.

## The outlet card (in plain words)

Each outlet card says one thing in big letters and one sentence on what to
do. Nothing else when nothing is running.

| Card says | Means | The sentence under it |
|---|---|---|
| **Ready to use** | On, nothing running | Plug in an appliance. |
| **In use** | An appliance runs: its name, watts, "On for…" and "Turns off in…" with a bar | (Start time, safety limit and last update are under **Details**) |
| **Not ready** | The meter is not answering | Check that the WisePlug is plugged into the wall. This outlet turns back on by itself. |
| **Turned off** | Switched off by the user | Turn it on below when you want to use it. |
| **Turned off for safety** | Locked after a cutoff, or waiting after a reset | Press Reset Safety / Turn on again below |
| **Safety warning** | The 60-second countdown is on | Answer the warning, or this outlet turns off. |
| **No connection** | No recent reading from the plug | Last seen …. Check that the WisePlug is plugged into the wall and your Wi-Fi is on. |

The switch under **Power Control** is greyed out (cannot be pressed) while
the outlet cannot be used from the app: the plug is offline, or the outlet
is **Not ready** (its meter is not answering). It says "Check that the
WisePlug is plugged into the wall. This switch works again by itself."
An outlet the user turned off can
still be turned on.

The app names the plug like a product label: **WisePlug WP-001** (product
name and unit code) on Home, Settings, My account and Wi-Fi setup, and
**Model WP-2 (2 outlets)** in Settings and My account. The unit code comes
from the technical ID (`gadget-1` → WP-001, `gadget-2` → WP-002), which is
not shown but is still used inside the app and the cloud. The names are set
in one place: `DeviceBinding` in `lib/services/device_binding.dart`.

`_cardState` and `_running` in `lib/screens/esp32_live_view.dart`; the
switch is `_PowerControl` (`ready`).

## Simpler screens and the same words everywhere (in plain words)

- **Home:** only the two outlet cards and Power Control. The "Total draw"
  and "Outlets active" boxes are gone; each card shows its own watts.
- **The warning pop-up:** one red bar ("Safe time is up"), one question
  ("Still using the fan?"), the seconds left, and two buttons: **Turn off
  now** and **Keep it on**. After a cutoff it says **Turned off for
  safety** with **Close** and **Reset Safety**.
- **Appliances tab** (was Profiles): an appliance's page shows only
  **Where**, **Safe time**, **Times used** (3 of 7) and **Power use**,
  then Edit and Delete.
- **Settings:** **My account**, **Change Wi-Fi**, **Dark mode**, the plug
  (online or offline), **Sign out**, and the app version in small print.
- **Change Wi-Fi:** no choice to make. If the plug is online it gets the
  new Wi-Fi over the internet; if it is offline the app shows the steps to
  do next to the plug.
- **One word for each idea:** the time an appliance may stay on is its
  **safe time**; an outlet the plug cut is **turned off for safety**;
  extra time after the warning is **Keep it on**.

## Recognition answers reach Supabase again (in plain words)

- **The problem:** the plug kept two secure connections open, one to
  Firebase and one to Supabase. Each needs about 40 KB of memory in one
  piece, and together they did not fit (the largest free piece was about
  17 KB). So the plug's measurements never reached Supabase: no pop-up, and
  the card only said "Unknown appliance".
- **The fix:** one secure connection at a time. When the plug has something
  for Supabase, it closes Firebase's connection, sends, closes its own, and
  Firebase reconnects. Live updates pause for a second or two; safety is
  never affected (it runs on its own).
- **Less to send:** the plug no longer writes what nothing reads:
  `live_telemetry`, `alerts/`, `activity_log`, `devices/gadget-1/notifications`,
  `outlets/…/relayState` and `isLockedDown`, and `status/outlet_1|2`. Phone
  alerts still come from Supabase; Reset Safety still works (it uses the
  RESET_SAFETY command).
- **Faster first answer:** an appliance whose power keeps moving gets its
  first guess 20 s after it is switched on (it used to wait 60 s).
- **While waiting** the card says "Finding out what it is… This takes about
  20 seconds", not "Unknown appliance".
- **If an upload still fails,** the Serial Monitor says why: "Stage 1 not
  delivered yet (HTTP -1, largest free block 17396)". HTTP -1 means no
  connection (often too little memory), 0 means the clock is not set yet.

## Recognising appliances whose power changes; editing what an appliance is (in plain words)

- **Why a charger was "Something new" every time:** it was registered with
  one sample, so WisePlug allowed only ±2 % of its power. A laptop charger
  drew 80, 103 and 91 W on different days. Now the minimum allowance is
  **±10 %** (settling time ±10 s, start-up peak ±0.25), a charger is
  registered with **3 samples** so its real spread is learned, and a run
  that never got steady is not compared on settling time. All three of
  those charger runs are recognised with 3 samples. A charger registered
  with one sample before this should be deleted and registered again.
  (`recognition_config`: floor_power_pct, floor_settling_time_s,
  floor_startup_peak_ratio, samples_per_charger; migration
  20261112000000_varying_loads.)
- **Moving an appliance from A to B:** the plug now tells Supabase which
  runs it has going, so a run that ended on A is closed at once and the
  appliance is recognised on B (it is no longer "still running on A").
- **Edit an appliance:** its page's **Edit** changes its name and **what it
  is** (Electric fan, Flat iron, … or Other). A new type brings its safe
  time: heating types are shorter. Not while it is running.
- **"Registering · 1 of 3 done"** shows on the outlet card while the
  appliance on it is still being registered.
- **No cutoff for one spoiled meter reading:** a running outlet gets the
  "meter stopped answering" warning only after 5 s without a good reading
  (it used to start on one bad reading, and the outlet was always cut 60 s
  later). If the meter answers again within that minute, the warning ends
  and the run continues. After **Reset Safety** the card says **Reset
  done** and "Press Turn on again below"; it no longer looks locked.
- **Registration** follows the newest run Supabase has on either outlet,
  as in the 35th commit. That works again now that run ends reach Supabase
  within seconds (a run end is retried every 10 s). See HARDWARE_TEST.md for
  the full check on the real plug.
- **The warning pop-up is only for the safe time.** A meter that stops
  answering, too much power or a fault show on the outlet card instead
  ("Meter stopped answering … turns it off for safety in 45 s") and as a
  phone notification. The plug sends why (`alertType` in telemetry_logs).

## Back to the 35th commit's network part (in plain words)

Registration and "Times used" worked until the 36th commit. Supabase shows
the plug's run ends and safety reports stopped on 9 November, the day after
it. That commit added, at once, certificate checks on every secure
connection (much more memory per connection) and a flash store for reports.
From then on run ends never arrived (so no use was ever counted, and no
safety notification reached the phone), recognition uploads failed, and a
connection crashed the plug during a test.

So the plug's network part is back to the 35th commit's way: connections
without certificate checks (`setInsecure`; still encrypted; a known
limitation on an untrusted Wi-Fi), and run ends and safety reports sent
straight from memory. Everything else from later commits stays (pins, clock
fix, quiet Firebase writes, silent meter, missed-reading rule, one secure
connection at a time, run list, alert type, run ID). The program is about
115 KB smaller.

## Deployment

Deploy the updated database rules to permit each signed-in user to read/write their alert preferences. Phone alerts are sent by Supabase (`evaluate-safety-alert`); there are no Firebase Cloud Functions to deploy. These changes do not alter device ownership requirements.

Flash the updated ESP32 sketch to publish `profileID` and `safetyDeadline`. The GUI remains usable with older telemetry, but precise remaining time stays unavailable.

No database data, rules, functions or firmware are deployed by a Flutter hot reload. Fully restart/rebuild the app after adding the version asset.

## "Running now" when nothing is plugged in

If the plug restarts or goes offline during a run, the run's end never reaches
Supabase, so it still looks like the appliance is running. You then couldn't
edit or delete it ("…is running now; switch it off or unplug it first").
Now, when you press Edit or Delete, the app tells the server which outlets the
plug shows as empty right now. The server closes the stuck run, and the edit or
delete goes through. This only happens while the plug is online. Safety is not
affected: the plug times and turns off its outlets by itself.

## How many samples each appliance takes (in plain words)

A sample is one run of about a minute while WisePlug measures the appliance.
WisePlug takes one sample for each setting you can choose, and more for a
charger:

| Appliance | Samples | Why |
|---|---|---|
| Electric fan | 1 per speed (you pick 1–4) | Each speed uses different watts (e.g. 35, 48, 60 W) |
| Flat iron | 1 ("Heating") | The dial doesn't change the watts: it always heats at 1,000–1,500 W. The dial only changes how long it rests at 0 W. |
| Rice cooker | 2 (Cook, Keep warm) | About 700 W while cooking, 30–50 W keeping warm |
| Laptop or phone charger | 3 (battery low, half, nearly full) | A charger picks its own speed: fast on a low battery, slow when nearly full |
| Other | 1, or add settings (up to 6) | Add one for each button or setting that changes how much it uses |

## Irons and other heating appliances: the timer keeps going (in plain words)

A flat iron's thermostat switches its heater off (0 W) once it is hot, then
on again when it cools. Before, WisePlug thought the iron had been unplugged
at every rest, and gave it a fresh safe time when it heated again. An iron
left on was never turned off.

Now a heating appliance (one that used 500 W or more in this run) may rest at
0 W for up to **3 minutes** and still count as on. Its safe time keeps
counting, so an iron left on is turned off when its safe time is up. After 3
minutes at 0 W the run ends as before. Fans and chargers use far less than
500 W, so they still count as off 3 seconds after you switch them off. Both
numbers live in Supabase (`recognition_config.rest_gap_s` and
`rest_gap_min_w`).

## "Turned off" notification after an unanswered warning (in plain words)

When the 60-second warning ran out with no answer, the plug turned the outlet
off, but never told Supabase. So the phone got "Safe time is up", but never
"The outlet was turned off". Found with the plug simulator
(`tool/simulate_plug.ts`). Now the plug sends the "turned off" report whenever
a warning ends without an answer, or with "Turn off now". A restart or power
cut does not send it: that is shown on the card instead.

## "Turn off now" and the 20 % buffer (in plain words)

These two changes make the system match the thesis (Chapter III):

- **"Turn off now"** in the safe-time pop-up just switches the outlet off.
  It is **not locked**: the outlet's switch in Power Control works right
  away. Only a warning that **nobody answers** locks the outlet, and then
  you need **Reset Safety**.
- **The learned safe time** (after 7 uses) is now your usual time **plus
  20 %**: for example, 60 minutes of usual use gives a 72-minute safe time.
  It was plus 50 %. It is still never longer than the safe time for that
  type of appliance (`recognition_config.learned_margin` = 1.20).

## Simpler words for everyday users (in plain words)

The app is for people who just want it to work. The logic underneath is
unchanged (one sample per speed, 7 uses to learn, safe times, all safety
rules); only the words on screen are simpler.

- **Fan speeds in any order.** "How many speeds does your fan have? Count
  its speed buttons." Each step says "Use a speed you have NOT done yet", so
  nobody has to know which button is "Level 1".
- **Every wait is said out loud:** "Please wait about 1 minute. Leave it on
  and don't touch its buttons." / "Saving… please wait a few seconds." /
  "Step 1 of 3 done! Now turn the fan off and wait 5 seconds. Then turn it
  on at a DIFFERENT speed. You will wait about 1 minute again."
- **The appliance page:** Right now (On, in Outlet A / Off), Turns off after,
  Used (3 of 7 times; later "Usually on for"), Uses about (45 W).
  The status badge and the list filters stay All / Active / Idle.

## Finishing a registration later (in plain words)

Each speed you already registered is recognized at once, so turning the fan
on at one of those speeds does not bring up the registration pop-up. To
finish registering:

- **From the appliance's page:** tap **Continue registering**, then turn the
  appliance on at a speed (or setting) you have not done yet.
- **From the outlet card:** while it runs, a **Finish registering** button
  appears under "Registering · 1 of 3 done". A run that is already going is
  not used (it may be a speed you already did): turn it off, count to 5,
  and turn it on at a different speed.
- **Or simply** turn it on at a speed you have not done yet: WisePlug does
  not know that speed, so the pop-up appears with "It is … : continue".
- **In every "Which appliance…?" / "Is this …?" question:** an appliance
  that is still being registered is listed under **Still registering:** as
  "It is … : continue registering (2 of 3 done)". A speed or battery level
  not registered yet can look like another appliance; tapping it saves this
  run as that appliance's next step.
- **The same speed twice is caught.** If a step is done at a speed (or
  setting) that is already saved, WisePlug recognizes it within about 20
  seconds and says: "That speed is already saved (about 33 W). It will not be
  saved again. Turn the fan off, wait 5 seconds, then turn it on at a
  DIFFERENT speed." That run is never saved. (Chargers are not affected:
  their 3 steps are meant to be the same "Charging" setting.)

## "How to use WisePlug" (in plain words)

Settings → **How to use WisePlug** is a short instruction manual for people
who have never used a smart plug. Eight topics, each a tap-to-open card with
numbered steps in the same words the app uses: getting started, adding a new
appliance, everyday use, Power Control, when the safe time is up, what the
outlet cards mean, your appliances, and staying safe. Its numbers (30
minutes, 7 uses, 1,760 W) come from Supabase, so the help always matches the
app (`lib/screens/help_screen.dart`).

## Chargers: one sample (in plain words)

A laptop or phone charger is now registered in **one step**, like any
appliance with one setting: "Charge a laptop or phone with it." (It was 3
steps at different battery levels.) Chargers already being registered are
finished at once. If WisePlug is unsure about a charger later (a very
different battery level), it simply asks "Which appliance…?". Set by
`recognition_config.samples_per_charger` = 1 (migration 20261113020000).

## Your own warning sound (in plain words)

The 60-second safety warning now plays the project's chosen sound
(`assets/sounds/warning_tone.mp3`, 7.6 s), **looped from start to end** until
you tap Keep it on or Turn off now, the warning clears, or the outlet is cut
off. (Before, two short beeps repeated every 4 s.) The phone notification
uses the same sound (`res/raw/wiseplug_alert.mp3`, Android channel
"wiseplug_safety_v2"; the old channel with the old beeps is removed). Phones
need app 1.2.0 or newer for the new notification sound. Where the sound comes
from and its license are written in `assets/sounds/LICENSE.md`.

## Restart WisePlug (in plain words)

Settings → **Restart WisePlug** restarts the plug from the app, without
touching it. The app asks first ("WisePlug will be offline for about 20
seconds…"), then the plug restarts 3 seconds later and comes back online by
itself.

- **Only when nothing is running.** If an appliance is on, the plug says "An
  appliance is running. Turn it off (or unplug it), then restart the
  WisePlug." If an outlet is turned off for safety, press Reset Safety first.
  (A restart during a run would lock that outlet, as after a power cut.)
- **Kept:** appliances, history, the saved Wi-Fi, and each outlet's state
  (off stays off).
- **Not possible while the plug is Offline:** the command cannot reach it.
  Then unplug it from the wall and plug it back in.
- After it, the plug reports "restarted from the app" as its last restart.

How it works: the app sends a RESTART command (like Turn on/off);
`handleCommand` checks both outlets and answers ACCEPTED, REJECTED_RUNNING or
REJECTED_LOCKED; `healthCheck` restarts after `APP_RESTART_DELAY_MS`. The
Firebase rules allow the new command type: deploy them with
`firebase deploy --only database --project wise-46f92`.

## The appliance keeps running if the plug restarts (in plain words)

- **Wi-Fi drops for a while:** nothing changes. The appliance keeps running
  and its timer keeps counting; the safety cutoff works without Wi-Fi.
- **The plug restarts by itself** (watchdog, crash, Restart from the app,
  a small power dip): the outlet is off for 1–2 seconds while the plug
  starts, then the **same run continues with its timer**: same appliance,
  same safe time, the time already used still counts. A rice cooker keeps
  cooking (its own switch is still on).
- **A real power cut** (the plug itself lost power): the outlet stays off
  and shows "Turned off for safety" until you press Reset Safety, so nothing
  starts again unattended. (Same as before.)
- **An outlet already turned off for safety** stays off after a restart,
  with its own reason.

How it works: the plug saves the run (state, safe time, appliance, start
time) whenever it changes and its used seconds every 30 s
(`RUN_CHECKPOINT_S`). After a restart it counts the saved time **plus 30 s**
(the most that can be missing), so the safe time is never extended; once the
internet clock is set, it uses the real start time if that is earlier
(`resumeRun`, `checkResumedRun` in the firmware). Serial Monitor shows:
`[outlet_A] Restart during a run (reset reason 6): efan continues, 95 s used
of 14400 s`.

## Back online faster after the Wi-Fi returns (in plain words)

When the Wi-Fi disappears for more than a minute, the plug opens its setup
Wi-Fi "wisewp". It now tries your saved Wi-Fi again **every 30 seconds** (it
was every 2 minutes), so it is back online about 30–50 seconds after your
Wi-Fi returns. A phone that joined "wisewp" by itself no longer stops these
tries; they only pause while someone is actually using the setup page or the
app's Change Wi-Fi steps (until 1 minute after the last use), so setting up a
new Wi-Fi is never interrupted. (`SETUP_RETRY_MS`, `SETUP_IDLE_MS` in the
firmware.)

## Fixes from the full system test (in plain words)

- **After a power cut, the app no longer shows the appliance as running.**
  The plug now sends the end of the run that the power cut stopped (it is
  saved every 30 s), so Supabase closes it. It is kept in the history as
  "turned off for safety" and, being cut short, does not count toward the 7
  uses.
- **Fewer worrying notifications.** "Meter stopped answering" reaches the
  phone only if the meter is still silent after 20 seconds. A short dropout
  that recovers by itself only shows on the outlet card. If the meter never
  comes back, the outlet is turned off after 60 s and the phone is told.
  (`SENSOR_NOTIFY_MS` in the firmware.)
- **One word for one idea:** the appliance page says "Safe time", like the
  pop-up ("Safe time is up") and the help.
- **Wi-Fi words:** "Pick your normal home Wi-Fi… use the one WITHOUT '5G' at
  the end" instead of "2.4 GHz only".

## The safe time keeps learning: always the last 7 uses (in plain words)

After 7 normal uses, WisePlug knows how long you usually use an appliance.
From then on, **every normal use updates it**: WisePlug always takes the
average of the **last 7 uses**, adds 20 %, and that is the safe time (never
shorter than 5 minutes, never longer than the appliance type's own). So if
you start using the fan for longer, its safe time grows with you; old uses
drop out. (Before, it was worked out once at the 7th use and never changed
again, so 7 short test runs could leave a fan with a 5-minute safe time.)
Registration runs never count as uses. (`recordUse` in
`supabase/functions/_shared/matching.ts`.)

## The safe-time pop-up, every case (in plain words)

**One appliance**
1. "Safe time is up — Still using the efan?" with a 60-second countdown,
   Turn off now / Keep it on.
2. At 0, until the plug confirms: "No answer: WisePlug is turning it off now…"
   (not a stuck 0).
3. Then: "Turned off for safety — The efan on Outlet B reached its safe time,
   so WisePlug turned it off." with Close / Reset Safety.

**Two appliances at the same time** (each outlet has its own row, its own
countdown and its own buttons)
- Both counting down: "Two appliances reached their safe time." Each row:
  "Turns off in 25 s", Turn off / Keep it on for that appliance only. Keeping
  one on leaves the pop-up open for the other.
- One already off, one counting down: the off one shows "Reached its safe
  time: turned off" with Reset Safety; the other keeps its countdown.
- Both off: "Both appliances reached their safe time, so WisePlug turned them
  off." with Close / Reset both.

The plug now sends each new state to the app first, so the pop-up starts at
60 s and the "turned off" message comes right after 0 (firmware:
`publishPending`).

## The plug and the app always show the same safe time (in plain words)

When you confirm an appliance in the app ("Yes, it is efan"), Supabase gives
that run the appliance's own safe time. The plug used to hear about it only
at its next measurement step, so a confirmation made later never reached it:
the app said "Safe time 6 min" while the plug kept its 30-minute default.
Now, while a run is not confirmed, the plug asks Supabase again **once a
minute** (and right after a restart it measures again and asks within ~20 s).
Within about a minute the plug uses the same safe time the app shows. Once
the run is confirmed it stops asking. (`RECHECK_MS` in the firmware.)

## Chargers are recognised at any battery level (in plain words)

A laptop charger draws a lot when the battery is low and little when it is
nearly full (one real charge: 120 W at the start, 48 W near the end). It was
compared like a fan (±10 %), so most of a charge looked like "something new",
and the same charger ended up registered several times. A charger is now
compared with **±50 %** of its registered power
(`recognition_config.floor_power_pct_charger` = 0.50); its power factor and
the other measurements still tell it apart from a fan. Fans and everything
else keep ±10 %.

## Weak or unstable Wi-Fi (in plain words)

- The plug keeps trying your Wi-Fi for **3 minutes** after it drops (was 1)
  before it opens "wisewp", so a weak spot that drops now and then does not
  send it into setup mode.
- Wi-Fi power saving is off (it made weak connections drop), the plug
  transmits at full power and joins the strongest access point with your
  Wi-Fi's name (mesh or repeater).
- Each request may take up to 10 s (Firebase) / 15 s (Supabase) before it
  counts as failed (was 5 s / 8 s), so a slow connection still gets through.
- Safety never depends on any of this: timing and cutoff run on the plug.

## "wisewp" stays visible for every phone (in plain words)

- When the plug cannot reach your home Wi-Fi, it opens its own Wi-Fi
  "wisewp". It now **stays on the whole time**, so every phone nearby can see
  it and join it.
- Before, the plug switched "wisewp" off for about 20 seconds every half
  minute to try your home Wi-Fi again, and phones that looked during that
  gap did not see it.
- The plug still tries your home Wi-Fi every 30 seconds, now in the
  background. When it connects, "wisewp" closes by itself and the plug is
  online again.
- While someone is using the setup page, the plug does not try in the
  background, so the page is not interrupted.

## Recognised on both outlets (in plain words)

- Outlet A and Outlet B each have their own meter. Two meters read the same
  appliance's "power factor" (how it uses electricity) a little differently.
- Appliances are registered with one sample, so that small difference was
  enough to make a registered appliance look "new" when it was moved to the
  other outlet.
- The power-factor margin is now 0.05 (was 0.02), set in
  `recognition_config.floor_pf`. An appliance registered on one outlet is
  recognised on the other. Power (within 10 %) still tells appliances apart,
  and if two appliances both fit, the app asks which one it is.
- Chargers: how hard a charger starts, how steady it is and how fast it
  settles all follow the battery, so they are no longer compared for a
  charger. A charger is recognised by its power (within 50 %) and its power
  factor (within 0.10, `recognition_config.floor_pf_charger`), which also
  follows the battery. Every other appliance keeps all its checks.
- Checked on the real runs: the laptop charger registered on Outlet B is now
  recognised on Outlet A from about 48 W to 115 W; the fan is still
  recognised on both outlets and never taken for the charger.

## Limit on "Keep it on" (in plain words)

- When the safe time is up, "Keep it on" gives extra time. It can now be
  used **3 times for each use** of an appliance (the number is
  `recognition_config.max_overrides`; the plug uses 3 until Supabase tells it).
- The pop-up says how many are left: "You can tap Keep it on 2 more times",
  then "Last time…".
- When they are used up, the 60-second warning still comes, but with only
  "Turn off now". If nobody answers, WisePlug turns the appliance off and
  locks the outlet, as before; Reset Safety turns it on again.
- The count starts again with each new use, and a restart of the plug does
  not give new ones (it is saved with the run).
- Electrical dangers (too much current) are never overridable, as before.

## Linking a WisePlug only when you are near it (in plain words)

- A WisePlug that has no owner can only be linked by a phone that is near
  it: on the plug's own Wi-Fi "wisewp", or on the same home Wi-Fi.
- In the app, tap **Pair**. The app asks the plug (over the local Wi-Fi) for
  a one-time code; the plug answers only phones on its own network. The code
  works for 10 minutes. With it, your account becomes the owner.
- Someone far away never gets the code, so they cannot take the plug.
- If you are already the owner, nothing changes for you.
- Deleting your account now lets the plug go in Firebase **and** Supabase,
  so the next owner can pair with it and register appliances.

## More than one sample when registering (in plain words)

- When registration says "All done!", there is now a **Take another
  sample** button (one per setting, e.g. "Take another sample: Level 2").
- Tap it, turn the appliance off, then on at that setting, and leave it on
  for about 1 minute. WisePlug saves one more sample. Repeat as often as you
  like.
- Every sample is kept. WisePlug works out each setting's range from its
  samples (the latest 20), so more samples make recognition more accurate,
  especially for appliances whose power changes a little each time.
- During normal registration, a setting already saved is still refused
  ("already saved"), so a fan speed is never sampled twice by mistake.
- Heating appliances (flat iron, rice cooker, air fryer, microwave, water
  dispenser): registration asks **"How many heat settings does it have?"**
  (1 to 5), e.g. a flat iron with 4 levels gets Level 1 to Level 4, one
  sample each. Their settings heat at the same power, so a setting is saved
  even when it matches one already saved; WisePlug recognizes the appliance,
  but may not tell which setting it is on.
