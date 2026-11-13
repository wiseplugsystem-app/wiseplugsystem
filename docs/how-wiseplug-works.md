# How WisePlug works, step by step

WisePlug is a smart plug with two outlets, **A** and **B**. It measures what
is plugged in, works out which appliance it is, and turns an outlet off when
something has been on for too long or draws too much power. This guide
follows one appliance from the moment the plug is set up to the moment it
is turned off, in plain words. Small notes in *italics* name the part of the
system that does each step, for readers who want to look it up.

## The parts

| Part | What it does |
|---|---|
| **The plug** (ESP32 board) | Reads the meters, switches the outlets on and off, and keeps everyone safe, even without Wi-Fi |
| **Two power meters** (PZEM-004T, one per outlet) | Measure voltage, current, power and power factor about once a second |
| **Two switches** (solid-state relays on heatsinks, one per outlet) | Give or cut power to each outlet |
| **The app** (Android phone) | Shows the outlets, asks what an appliance is, warns before a cutoff |
| **Firebase** | Carries live readings and the app's commands between the plug and the phone |
| **Supabase** | Keeps the appliances and their measurements, recognises appliances, sends phone notifications |

```
 appliance ── outlet A/B ── meter ── switch ── plug (ESP32)
                                                │  Wi-Fi
                         Firebase (live readings, commands) ── app
                         Supabase (appliances, recognition, alerts) ── app
```

## Step 1. Setting up the plug

1. Plug WisePlug into the wall. Both outlets start **off** until the plug
   knows it is safe.
2. **Wi-Fi:** the first time (or when the home Wi-Fi is gone), the plug makes
   its own Wi-Fi called **"wisewp"**. Join it with the phone; a page opens by
   itself listing the home networks. Tap yours and type its password. The
   app can do the same from Settings.
3. **Sign in** to the app. The plug is linked to your account, so only you
   see and control it. The app stays signed in.

*Firmware: Wi-Fi setup and captive portal; app: Wi-Fi setup, sign-in.*

## Step 2. Measuring, all the time

- Each meter reads its outlet **about once a second**: voltage, current,
  power (watts) and power factor.
- The app's **Home** screen shows one card per outlet: one big status and
  one sentence saying what to do. The status is **Ready to use** (on,
  nothing running), **In use** (with the appliance, its watts, how long it
  has been on and when it turns off), **Not ready** (the meter is not
  answering), **Turned off**, **Turned off for safety**, **Safety warning**
  or **No connection**. Start time, safety limit and last update are under
  **Details** on a running outlet. It refreshes every few seconds.
- **A meter that stops answering:** the plug cannot time or protect that
  outlet, so after **15 seconds** of silence with nothing running it switches
  that outlet off, and back on by itself as soon as the meter answers. A short
  blip changes nothing. If something is running, one spoiled reading (a fan
  motor's noise) changes nothing either: only **5 seconds without a good
  reading** start a 60-second warning, and if the meter answers again in
  that minute the warning ends and the appliance keeps running. From the first missed reading the card says
  **Not ready**, never "Ready to use".

*Firmware: sensor task; Firebase: telemetry_logs.*

## Step 3. An appliance is switched on

1. When an outlet's power goes above **2 W**, the plug knows something was
   switched on. This is the start of a **run**.
2. Straight away the run gets the **default safe time: 30 minutes**. Until
   WisePlug knows what the appliance is, it never gets more.
3. When the power stays below 1.5 W for 3 seconds, the run has ended
   (switched off or unplugged).

*Firmware: run detection, DEFAULT_LIMIT_S.*

## Step 4. Measuring the appliance's "fingerprint"

During the first minute of a run, the plug measures seven things that make
each appliance different:

| Feature | In plain words |
|---|---|
| Average power | How many watts it uses |
| Power factor | How "smooth" its electricity use is (heaters ≈ 1, chargers lower) |
| Start-up peak | How big the jump is when it switches on (motors jump) |
| Settling time | How long it takes to calm down after switching on |
| Power variation | How much its power wobbles while running |
| Cycle period | How often it switches itself on and off (thermostats) |
| Standby power | What it draws while "off" but still plugged in |

The plug sends this summary twice: **Stage 1** about 10 seconds after the
power settles (a quick first guess) and **Stage 2** after about a minute
(the full fingerprint). An appliance whose power keeps moving (some fans, a
thermostat) still gets its Stage 1 **20 seconds** after it is switched on.
So the app has a first answer in about **20–25 seconds**; until then the
card says **"Finding out what it is… This takes about 20 seconds"**.

*Firmware: recognition_window.h; Supabase: recognize-appliance.*

## Step 5. Recognising the appliance (rules, no machine learning)

Supabase compares the fingerprint with every appliance you have registered:

1. For each feature, the new value must be within that appliance's normal
   range: **3 × its usual spread**, or a minimum allowance, whichever is
   bigger. The minimum is **±10 % of its power**, ±10 s of settling time and
   ±0.25 of start-up peak, so an appliance whose power changes a little from
   day to day (a fan, a charger) is still recognised. A run that never got
   steady is not compared on settling time.
2. Every appliance that passes gets a score (how close it is, with power and
   power factor counting most).
3. The result is one of:

| Result | What the app shows |
|---|---|
| **One clear match** | The appliance's name; after you confirm ("Yes, it is the fan"), it gets its own safe time |
| **Two that fit equally** (e.g. two identical fans) | "Which appliance is it?" with the one last used on that outlet already selected |
| **Another of a type already running** | "Another fan? Register as Fan 2" |
| **Nothing fits** | "Something new on Outlet A": register it |

Until you confirm, the run keeps the **30-minute** default.

*Supabase: _shared/matching.ts, recognition_config (all numbers are there).*

## Step 6. Registering a new appliance

1. **"What are you adding?"**: pick a picture: electric fan, rice cooker,
   flat iron, laptop charger, phone charger, or **Other** (type its name).
   Each picture shows its usual power. Air conditioners, kettles, hair
   dryers, induction cookers and washing machines are not offered: they can
   draw more than the plug can carry.
2. Give it a **name** (e.g. "Bedroom fan").
3. **Its settings:** the app takes **one sample of each setting**:
   - electric fan: Level 1, Level 2, Level 3… (you choose 1 to 4 levels);
   - flat iron: Low, Medium, High;
   - rice cooker: Cook, then Keep warm;
   - chargers: **3 samples** (a charger's power changes with the battery,
     so WisePlug needs to see how much);
   - Other: one sample, plus any settings you add.
4. **For each sample:** turn it on at that setting, leave it on for about 1
   minute without touching the buttons, then turn it off. The app says what
   to do at every step ("Set it to Level 2", "Sample 2 of 3 done!").
5. Each setting becomes its own fingerprint. If a sample measures above
   **1,760 W**, WisePlug refuses it: the appliance is too powerful.

*App: registration_dialog.dart; Supabase: register-sample, appliance_profiles.*

## Step 7. How long an appliance may stay on

| Situation | Safe time |
|---|---|
| Not recognised yet / not confirmed | **30 minutes** |
| Confirmed appliance | Its type's safe time (normally 4 hours) |
| Heating appliances | Shorter: kettle 15, hair dryer 15, microwave 30, flat iron / air fryer / heater 60, rice cooker 90 minutes |
| After 7 confirmed uses (normal runs after registration; the registration samples do not count) | WisePlug learns how long you usually use it and allows **1.2 ×** that (20 % more), never more than the safe time above |

Each time you answer "Yes, it is the fan", that run also refines the
appliance's fingerprint, so recognition gets better with use.

*Supabase: appliance_types, heating_safe_times, 7-use learning.*

## Step 8. The warning before a cutoff

1. When the safe time is reached, the phone shows a **60-second countdown**
   with a warning sound that cannot be muted. This pop-up is **only for the
   safe time**. A meter that stops answering, too much power or a fault
   show on the outlet card (and as a phone notification), not as a pop-up.
2. You choose:
   - **Keep it on**: it gets extra time (20 % of how long it has run,
     between 1 minute and 1 hour);
   - **Turn off now**.
3. If nobody answers in 60 seconds, the plug **turns that outlet off**. Only
   that outlet; the other keeps working.

*Firmware: safety_state.h (tick, overrideRuntime); app: safety_alert_listener.dart.*

## Step 9. Too much power or a fault

These act at once, with no countdown:

| What happens | What WisePlug does |
|---|---|
| More than **10 A** | Turns the outlet off on the first reading |
| More than **8 A** (about 1,760 W) for **10 seconds** | Turns the outlet off ("This appliance uses too much power for WisePlug") |
| A confirmed appliance suddenly uses **twice** its normal power | Turns the outlet off (something may be broken) |

A motor's short start-up jump does not count. Every such event is logged for
the thesis.

*Firmware: electricalTrip(); Supabase: alert_logs.*

## Step 10. Turning it back on after a cutoff

1. The outlet stays **off and locked**. The card says **Turned off for safety**.
2. Check the appliance, then press **Reset Safety**. This only unlocks the
   outlet: it **stays off**, so the appliance does not start again by itself.
3. When you are there and want to use it, press **Turn on again** and confirm
   ("Only turn it on if you are there and want to use it again").
4. The button on the plug itself turns the outlet on directly (you are
   standing at it).

*Firmware: remoteReset() keeps the outlet off (resetHold); app: Power Control.*

## Step 11. Without Wi-Fi or after a power cut

- **No Wi-Fi or no internet:** the plug keeps measuring and keeps every
  safety rule (safe times, warnings, cutoffs). Appliances it cannot
  recognise without the internet get the 30-minute default. Its run records
  and safety reports wait in the plug's memory and are sent when the
  internet is back (a restart before then loses them; the safety rules
  never depend on them). After a minute without the home Wi-Fi it opens "wisewp" again,
  and keeps retrying the home network every 2 minutes.
- **Power cut:** if the power goes off while an appliance was running, that
  outlet comes back **off and locked** ("Turned off for safety" in the app), so nothing
  restarts while nobody is watching. Reset, then Turn on again. An outlet
  that was idle comes back as it was.

*Firmware: sendSupabase() (reports from memory, as in the 35th commit), setup().*

## Step 11b. Looking after itself (no one has to restart it)

- **Connection trouble:** if the plug cannot reach the cloud 10 times in a
  row while Wi-Fi works, it opens a fresh connection by itself.
- **Self-restart, only when safe:** if that does not help, if its memory gets
  too broken up, or if part of its program stops, it restarts itself, but
  **only while both outlets are idle or off**, so a running appliance is
  never cut. It also refreshes itself once a week the same way. After a
  restart because the internet was down, it waits 6 hours before trying
  that again.
- **Watchdog:** if the safety program ever froze, a built-in timer restarts
  the plug; a running outlet then comes back off and locked, as after a
  power cut.
- **Updates over Wi-Fi:** new firmware can be sent from the Arduino IDE over
  Wi-Fi (with a password), only while both outlets are idle or off.
- **Health check:** the plug reports how long it has been running, its free
  memory and why it last restarted (Firebase: status/health).

*Firmware: healthCheck(), noteCloud(), enableLoopWDT(), ArduinoOTA.*

## Step 12. What is kept, and for what

| Kept | Where | Used for |
|---|---|---|
| Every run and its fingerprint | Supabase: outlet_sessions | Recognition, learning, the thesis evaluation |
| Each appliance and its settings | Supabase: appliance_instances, appliance_profiles | Recognition |
| Safety events (warnings, cutoffs, too much power) | Supabase: alert_logs | Phone notifications, the thesis |
| Recognition results | Supabase: recognition_summary, recognition_metrics, recognition_confusion | Accuracy, precision, recall, F1 |

The app shows no usage history; it shows what is happening now. For the
thesis measurements see `docs/measurement-guide.md`; for what WisePlug does
and does not cover see `docs/scope.md`.

## The whole process at a glance

```
Set up plug & Wi-Fi ─► Sign in
        │
Appliance switched on (> 2 W) ─► 30-minute default safe time starts
        │
Fingerprint measured (Stage 1 ≈ 10 s, Stage 2 ≈ 1 min)
        │
Recognised? ── no ──► "Something new": register it (one sample per setting)
        │ yes
Confirm ("Yes, it is …") ─► its own safe time (shorter for heating appliances;
        │                    learned after 7 uses)
        │
Running ──► too much power / fault ─► turned off at once ─┐
        │                                                 │
Safe time reached ─► 60-second warning ─► Keep it on ─► more time
        │                              └► no answer / Turn off now
        ▼                                                 │
Outlet turned off for safety ◄────────────────────────────┘
        │
Reset Safety (stays off) ─► Turn on again (confirm) ─► running again
```
