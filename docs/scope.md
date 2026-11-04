# WisePlug: scope and delimitation

WisePlug is a two-outlet smart plug that measures what is plugged in,
recognises the appliance from its electrical behaviour with plain rules, and
turns an outlet off when an appliance has been on longer than is safe. It is
made for households, including people who do not use technology much.

This document sets what the study covers (scope) and what it does not
(delimitation), with the reasons.

## 1. Scope

### 1.1 Hardware

| Part | What is used | Role |
|---|---|---|
| Microcontroller | ESP32 (Wi-Fi) | Reads the meters, runs the safety rules, switches the outlets |
| Energy meters | 2 × PZEM-004T v3.0, 100 A version (external current transformer), one per outlet on its own UART (A: GPIO 32/33, B: GPIO 25/26) | Voltage, current, power, power factor, frequency, energy |
| Switches | 2 × SSR-40DA solid-state relay (40 A at 24–380 V AC, 3–32 V DC input), A on GPIO 13, B on GPIO 12, each on an aluminium heatsink with thermal paste | Turns each outlet on and off |
| Sockets | 2 outlets (A and B), 10 A 250 V | Where appliances plug in |
| Rating | **10 A per outlet** (the socket); **8 A (about 1,760 W)** for loads that stay on | Above 10 A the outlet is cut off at once; above 8 A after 10 seconds (`CONTINUOUS_CURRENT_A`) |

Wiring order per outlet: current transformer, SSR, PZEM, ESP32, socket.

### 1.2 What is measured

- Voltage (V), current (A), power (W), power factor, frequency (Hz) and energy
  (Wh) of each outlet, read about every second.
- The app shows live readings, refreshed about every 3 seconds.
- For each run (from plug-in to unplug), the plug computes seven features
  used for recognition: average power, power factor, start-up peak ratio,
  settling time, power variation, cycle period (on/off cycling) and standby
  power.

### 1.3 Appliance recognition (rule-based, no machine learning)

- **Registration:** the user plugs a new appliance in 3 times and picks what
  it is from pictures ("What are you adding?"). The 3 runs become the
  appliance's profile (mean and spread of each feature).
- **Recognition:** each new run is compared with every profile in two
  stages: about 10 s after the load settles (power, power factor, start-up)
  and at about 60 s (all seven features). A feature matches when it is
  within max(3 × standard deviation, a minimum allowance) of the profile.
  All numbers are in the `recognition_config` table.
- **Results:** recognised (with its name), a question when two appliances fit
  ("Which appliance is it?"), "another of the same type" (for example a second
  fan), or new.
- Appliances belong to the user, not to an outlet: a profile made on Outlet
  A is recognised on Outlet B too. One appliance cannot run on two outlets
  at the same time.
- Outlets A and B are calibrated so that they read the same.

### 1.4 Safety

- **Overcurrent:** above 10 A the outlet is cut off at once, and above 8 A
  (about 1,760 W) after 10 seconds, so a motor's start-up surge does not
  count; it stays locked until the user resets it.
- **What can be added:** the app offers only types with a listed usual power
  within the limit: electric fan (30–100 W), rice cooker (30–700 W), flat iron
  (400–1,500 W), microwave (400–1,500 W), TV (50–150 W), refrigerator
  (100–400 W), phone charger (5–30 W) and laptop charger (30–100 W), plus
  "Other". It leaves out every type whose usual range goes above 1,760 W
  (aircon, electric kettle, hair dryer, induction cooker, washing machine), and the server refuses to register any run it
  measures above `recognition_config.max_appliance_w` (1,760 W).
- **Fault:** a confirmed appliance drawing twice its own steady power for
  several readings in a row is cut off.
- **Safe operating time:**
  - an appliance that is not yet confirmed gets the default, 30 minutes;
  - a confirmed appliance gets its own safe time, set by its type;
  - heating appliances get a shorter safe time for each type (section 3);
  - after 7 uses, WisePlug learns the appliance's usual running time and
    uses 1.5 × that time, never more than its own safe time.
- **Warning:** 60 seconds before a cutoff, the phone shows a countdown with a
  warning sound that cannot be muted; the user can keep the appliance on
  (Keep it on) or let it turn off.
- **Offline:** the plug keeps enforcing the limits without Wi-Fi or
  internet, and sends its records once it is back online.
- **After a safety cutoff** the outlet stays off until the user resets it in
  the app.

### 1.5 The app

- Flutter app for Android phones (also runs in Chrome).
- Home: both outlets with live power and a plain status (Ready to use, In
  use, Turned off, Turned off for safety), the running timer, and outlet on/off.
- Appliance Profiles: each registered appliance with its picture, status,
  safe time and learning progress; a screen for each appliance (rename,
  delete).
- Registration and recognition questions, safety warnings with sound,
  phone notifications through Supabase and Firebase Cloud Messaging.
- Settings: Wi-Fi setup of the plug, dark mode, account; stays signed in.
- Made easy to read: text fitted to the screen, 4.5:1 contrast, 48 dp
  buttons, plain words (docs/live-gui.md, "Easy to read").
- No usage history is shown (no history list, charts or past runs). The
  database keeps the runs for recognition and evaluation.

### 1.6 Online services (free plans only)

- **Firebase Realtime Database:** live readings, commands, sign-in.
- **Supabase (PostgreSQL + Edge Functions):** appliances, profiles, runs,
  recognition, safety reports, and the evaluation views (accuracy, precision,
  recall, F1).
- **Firebase Cloud Messaging:** phone notifications.

### 1.7 Evaluation

- Appliance measurements and recognition tests follow
  `docs/measurement-guide.md`: 3 registration runs and 10 test runs on
  each outlet per appliance mode, and 10-minute logs for appliances that
  switch on and off (thermostats).
- Usability: 5–6 tasks with users and the System Usability Scale
  (`docs/usability-test.md`).

## 2. Delimitation

### 2.1 Loads and appliances

- **One appliance per outlet.** Power strips or several appliances on one
  outlet are not recognised (they add up into one load). Splitting a whole
  house's load into appliances (NILM) is outside the study.
- **Rating:** appliances above 10 A are not supported. Loads that stay on
  should stay at or below 80 % of 10 A (8 A, about 1,760 W), the usual rule
  for continuous loads (Philippine Electrical Code / NEC).
- **Appliance limit: 8 A (about 1,760 W).** The SSRs sit on heatsinks, so
  appliances whose label says 8 A or 1,760 W or less are supported and
  tested. A flat iron draws
  its full label wattage every time it heats, on every setting, so its label
  decides.
- **Not supported, and refused by the app:** air conditioners (a
  compressor's start-up surge can pass 10 A), electric kettles and hair
  dryers (up to 3,000 W), induction cookers and electric stoves (their high
  levels go above 1,760 W), and washing machines (models with a water heater
  reach 2,200 W, and the app cannot tell them apart). Any appliance measured
  above 1,760 W is refused at registration, whatever its name.
- **Small loads:** the 100 A meter starts measuring at about 0.02 A (about
  4–5 W). Phone chargers and standby power may read 0 W or unsteadily.

### 2.2 Recognition

- Rule-based only: no machine learning, no training on other datasets.
- Uses the first ~60 seconds of a run. On/off cycles longer than that (an
  iron's or a fridge's thermostat) are not used for recognition; they are
  documented with the 10-minute logs.
- Two identical units (two fans of the same model) cannot be told apart by
  their electricity: WisePlug asks the user, pre-selecting the one last used
  on that outlet.
- The app registers the first mode of an appliance; other settings (fan
  speeds, heat settings) are learned when the user confirms them, or tested
  in the analysis from the recording sheet.
- Heating appliances' settings often look the same in watts (the element is
  either fully on or off); the settings differ in how long the element stays
  on.

### 2.3 Safety

- WisePlug does not replace a circuit breaker, a fuse or an earth-leakage
  breaker. It has no temperature sensor and no physical buzzer: warnings are
  on the phone.
- An SSR that fails usually fails stuck on; WisePlug cannot detect or
  override that. A switch within reach is still needed.
- Safety warnings need the app (or a notification) to be seen; if nobody sees
  the warning, the appliance turns off at the cutoff.

### 2.4 Software and services

- English only. Android phones; the iPhone build is not tested.
- Free plans only: Supabase pauses a project after 7 idle days (kept awake by
  daily use or the keep-alive workflow); no paid Firebase (Blaze) features.
- The app and the online services need internet; the plug's safety rules do
  not.

## 3. Heating appliances

Appliances that make heat with a heating element or by induction are the ones
that start fires when left on. In the Philippines, electrical causes were the
top cause of fires in 2023 (about 40 % of incidents, most in homes; BFP figures
as reported in the news [1]); in the US, unattended cooking is the leading
factor of home cooking fires [2]. Irons themselves switch off after 8
minutes upright or 30 seconds flat when not moved [3].

So WisePlug gives each heating type a shorter safe operating time
(`heating_safe_times` table, migration `20261105000000_heating_safe_times.sql`).
An appliance of that type never gets more; the 7-use learning still works under
it; the 60-second warning and Keep it on still apply.

| Heating appliance | Safe time | Why |
|---|---|---|
| Electric kettle | 15 min | Boils water in minutes, then should switch itself off |
| Hair dryer | 15 min | Hand-held, used for minutes at a time |
| Microwave | 30 min | Short heating runs; never run empty |
| Flat iron | 60 min | Hot soleplate; irons switch themselves off after 8 min upright |
| Air fryer | 60 min | Cooking with a heating element and fan |
| Induction cooker / electric stove | 60 min | Cooking: unattended cooking is the leading cause of cooking fires |
| Heater (room or water) | 60 min | A heating element left on |
| Rice cooker | 90 min | Cooking, then keep-warm |

The kettle and hair dryer rows stay as a safeguard: those types cannot be
added (section 2.1), but an appliance typed under another name still gets the
short limit. Not limited: a water dispenser's hot tank is made to stay on all day and is
switched by its own thermostat. Each appliance type also has its own safety
standard: IEC 60335-2-3 (irons), -2-6 (cooking appliances, induction),
-2-9 (grills, air fryers), -2-15 (kettles, rice cookers), -2-23 (hair dryers),
-2-25 (microwaves) and -2-30 (room heaters) [4]. The 2024 edition of
IEC 60335-2-6 added requirements for operating ovens remotely [5].

## 4. Household appliances and their settings

The table below lists the appliances in the study and how their settings
change their power. **The ranges are unverified estimates** (not from a
cited source and not measured); they are a guide to what to expect, and are
replaced by the labels' ratings and our own measurements
(`measurements/results/features_summary.csv`). For published defaults, see
Meralco's Appliance Energy Calculator [6].

"Draw" is the power while the appliance is on. "Average" is over its on/off
cycling: a thermostat switches the element fully on and off, so a lower
setting has the **same draw**, on for less of the time.

| Appliance | Settings | Estimated range (unverified) | How the setting changes the power | Measured (WisePlug) |
|---|---|---|---|---|
| Electric fan | Speed 1 / 2 / 3 | 30–40 W / 45–60 W / 70–100 W | Motor speed: the draw itself changes | |
| Air conditioner | By horsepower; temperature and fan | 800–2,000 W+ | Compressor on/off (inverter: variable) | Not tested (out of scope) |
| Hair dryer | Low / medium / high | 500–800 W / 1,000–1,500 W / 1,800–2,500 W+ | Heater and fan steps: the draw changes | Not supported |
| Flat iron | Silk / cotton / linen dial | 1,000–1,500 W label | Thermostat: **same draw**, longer on at higher settings; low settings average less | Only irons labelled ≤ 1,760 W |
| Induction cooker / electric stove | Levels 1–10 | 300 W – 3,000 W+ | Power level (induction may pulse at low levels) | Not supported |
| Refrigerator | Dial 1–5 | 100–400 W | Compressor on/off: the dial changes **how long** it runs, not its draw | |
| Microwave | 20–100 % power | 800–1,500 W | Lower levels switch the magnetron on and off (**same draw**, less on-time), except inverter models | Only if label ≤ 1,760 W |
| Television | Eco / standard / vivid | 50–150 W | Backlight brightness: the draw changes | |
| Rice cooker | Cook / keep warm | 300–700 W / 30–50 W | Two separate heaters or a thermostat | |
| Washing machine | Cold / warm / hot | 300–500 W / 1,000–2,200 W+ | Motor only when cold; the water heater adds most | Not supported |
| Electric kettle | On / off | 1,200–3,000 W | Single level until it boils, then off | Not supported |

Appliances that heat up (high-heat): electric cooktop / induction stove, hair
dryer, electric kettle, washing machine when heating water, microwave, and
electric iron. Some of their estimated ranges above exceed WisePlug's
1,760 W limit; the label decides.

## 5. References

1. Philippine Daily Inquirer, "Over 15,000 fire cases recorded in 2023, says
   BFP," 2024; Philstar, "BFP records 21.1 percent increase in fires in 2023,"
   2024. For the thesis, cite the Bureau of Fire Protection's own annual
   statistics.
2. National Fire Protection Association, *Home Cooking Fires*, 2023 (data
   2017–2021).
3. Philips, "My Philips steam iron does not heat up anymore" (safety auto-off:
   30 s horizontal, 8 min on the heel rest); Rowenta steam iron instructions
   (auto-off 8 min upright, 30 s flat or tipped over).
4. IEC 60335 series, *Household and similar electrical appliances – Safety*:
   Part 1 (general) and Parts 2-3, 2-6, 2-9, 2-15, 2-23, 2-25, 2-30.
5. IEC 60335-2-6:2024, *Particular requirements for stationary cooking
   ranges, hobs, ovens and similar appliances* (remote operation of ovens).
6. Meralco, Appliance Energy Calculator, appliancecalculator.meralco.com.ph.
7. Measurement, recognition and evaluation references: `docs/measurement-guide.md`,
   section 8.

Check every reference at its source before using it in the thesis; the IEC
clauses were not read here.
