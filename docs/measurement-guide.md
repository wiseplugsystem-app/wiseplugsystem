# Appliance measurement guide

How to measure common household appliances with WisePlug and build the
dataset for the thesis: what is safe to test, how many runs to make, how to
fill in the recording sheet, and how to run the analysis. Every number in the
results comes from these measurements; the guide gives no "typical" appliance
values.

Files:

| File | What it is |
|---|---|
| `measurements/recording_sheet_template.csv` | The recording sheet (copy it to `measurements/recording_sheet.csv`) |
| `tool/measure_log.ts` | Records one outlet's live readings for the long logs |
| `tool/measure_analyze.ts` | Exports the runs from Supabase and makes the results |
| `measurements/results/` | What the analysis writes: `report.md`, `dataset.csv`, `features_summary.csv`, charts |

## 1. Safety first

### The plug's rating

| Part | Rating | Notes |
|---|---|---|
| Socket | 10 A, 250 V | Printed on the socket |
| SSR | SSR-40DA: 40 A at 24–380 V AC, 3–32 V DC input | On an aluminium heatsink ("10A–100A" type) with thermal paste |
| PZEM-004T v3.0 | 100 A version (external current transformer) | Not the limit |
| Firmware | Cuts the outlet off above 10 A at once, and above 8 A after 10 s (`MAX_CURRENT_A`, `CONTINUOUS_CURRENT_A`) | Locks it out |

An SSR loses about 1–1.5 V while it conducts, so it heats up by about
1–1.5 W per ampere; the heatsink carries that heat away. Many low-cost
"40 A" SSRs are also clones with weaker parts, which is one more reason not
to go near 10 A.

> **Test only appliances whose nameplate says 8 A or less (about 1,760 W at
> 220 V)**: 80 % of the socket's 10 A, the usual limit for loads that stay on
> (Philippine Electrical Code / NEC). The plug enforces it: above 8 A for 10
> seconds the outlet is cut off and locked.
>
> **Fit the heatsinks first.** Until they are on, stay at 4 A (880 W) or less:
> a bare SSR overheats above that.

The app's picture list has the fan, rice cooker, flat iron, microwave, TV,
refrigerator and phone and laptop chargers. Register anything else (lamp,
blender, air fryer, water dispenser…) under **Other**, with its name.

Read the **input** rating on the appliance's label (W or A). A microwave's
"800 W" is often its cooking power; it draws more from the socket.

### Which appliances can be tested

| | Appliances |
|---|---|
| **Safe** (small loads) | Electric fan, TV, phone charger, laptop charger, LED bulb, desk lamp, blender |
| **Only if the label is 1,760 W / 8 A or less** | Rice cooker, refrigerator, water dispenser, microwave, air fryer, flat iron |
| **Do not test** (the app refuses them) | Aircon, electric kettle, hair dryer, induction cooker / electric stove, washing machine: their usual range goes above 1,760 W (or, for an aircon, its start-up surge can pass 10 A) |

The app also refuses to register any appliance it measures above 1,760 W,
whatever it is called.

**Rice cookers and flat irons come first** (the study's main heating
appliances). With the heatsinks on, most fit:

- **Rice cooker:** check the label; test Cooking and Keep warm.
- **Flat iron:** an iron's element draws its **full label wattage every time
  it heats, on every setting** (a lower setting only switches it off sooner).
  An iron labelled 1,760 W or less (for example 1,000 W) can be tested on
  all its settings.

### Rules during every test

1. **Never leave a heating appliance unattended** (iron, rice cooker, air
   fryer, water dispenser hot side).
2. **Never run a microwave empty**: heat a cup of water.
3. **Keep a switch within reach** (the wall switch or an extension cord with
   a switch). An SSR that fails usually fails *stuck on*: the outlet keeps
   giving power even if the app says it is off.
4. **Touch-check the SSR** after a few minutes of a larger load. If it is too
   hot to hold a finger on, stop and let it cool.
5. If the plug cuts off for safety (overcurrent), **stop testing that
   appliance**. Do not retry it.
6. Only one person changes plugs; the other writes the sheet.

## 2. Before you start

1. The plug is online, and both outlets show readings in the app.
2. The outlets are calibrated (docs/appliance-identification.md,
   "Calibrating the outlets"), so Outlet A and B read the same.
3. Copy `measurements/recording_sheet_template.csv` to
   `measurements/recording_sheet.csv` and open it in Excel or Google Sheets.
4. Write down each appliance's label: brand, model, rated W.
5. Use the phone's clock (or the app's) for the times: the analysis matches
   your times to the plug's runs within 2 minutes.

## 3. How many runs

For **each appliance and each mode** (each fan speed, each heat setting…):

| Runs | Where | What for |
|---|---|---|
| 3 registration runs | 2 on Outlet A, 1 on Outlet B | The appliance's profile |
| 10 test runs | Outlet A | Recognition results |
| 10 test runs | Outlet B | Recognition results, and A vs B |
| 1 long log (about 10 min) | Either outlet | Thermostat or on/off cycling |

A registered profile works on both outlets, so the appliance is registered
once (3 plug-ins), not once per outlet.

Each run: plug in or switch on, **leave it on at least 90 seconds** (WisePlug
needs about 60 s for the full measurement), then switch off or unplug and wait
10 seconds before the next run. A run shorter than 60 s is reported in the
analysis as incomplete.

**Two units of the same type** (two fan brands, and if possible two
identical fans): register each as its own appliance ("Fan 1", "Fan 2"). Two
identical fans are expected to give "Which appliance is it?" questions; that
is a result to report, not a mistake.

**Time:** about 23 runs × 2 minutes per mode. A fan with 4 speeds, with and
without oscillation, is 8 modes, about 6 hours. Order: **rice cooker and flat
iron first**, then the fan, then the others as time allows.

**Safe times during tests:** heating appliances now have shorter safe times
(docs/scope.md, section 3): a microwave is turned off after 30 minutes, an
iron after 60, a rice cooker after 90, with the usual 60-second warning. A long
log longer than that ends at the cutoff; that is expected.

## 4. Appliances and modes

Record each mode as its own row group in the sheet (the `mode` column):

| Appliance | Modes to record | Long log |
|---|---|---|
| Electric fan | Each speed (e.g. Speed 1–4), each with and without oscillation ("Speed 2 + oscillation") | No |
| Rice cooker | Cooking, Keep warm (always with rice or water inside) | Yes: keep warm |
| Flat iron | Each heat setting | Yes: each setting, on/off cycling |
| Air fryer | Preheat, Cooking | Yes: heating cycles |
| Microwave | High, a lower level (it switches on and off), Standby (clock only) | Yes: the lower level |
| TV | On (normal picture), Standby | No |
| Refrigerator | Running (compressor cycles) | Yes: 10 min or more |
| Phone charger | Charging a phone | No |
| Laptop charger | Charging, laptop on | No |
| LED bulb, desk lamp | On (each brightness if dimmable) | No |
| Water dispenser | Hot, Cold | Yes |
| Blender | Each speed (with water, short runs) | No |

**About modes in the app:** the app registers the first mode of an
appliance ("What are you adding?"). A different mode, for example a new fan
speed, may show "New appliance"; for those runs tap **Not now** and write the
mode in the sheet. The analysis builds one profile per mode from the sheet's
registration runs and tests the rules on them, so every mode gets results
even if the app has only learned the first one.

**Refrigerator:** each compressor start is one run. Write the time each one
starts, or leave the time empty and fill in `session_id` from the export.

**Small loads:** the 100 A meter starts measuring at about 0.02 A (about
4–5 W). Phone chargers and a microwave's clock may read 0 W or jump around.
Record them anyway; it is a real limit of the meter.

## 5. Step by step for one appliance

1. Write the appliance's label in the sheet (brand, model, nameplate_w).
2. **Registration run 1 (Outlet A):** plug it in, switch it on in the mode.
   When the app asks "What are you adding?", pick the type and name it (for
   example "Fan 1"). Wait 90 s. Switch off. Sheet row: `run_type =
   registration`.
3. **Registration runs 2 and 3:** run 2 on Outlet A, run 3 on Outlet B. Answer
   the app as it asks ("Plug it in again").
4. **10 test runs on Outlet A**, then **10 on Outlet B**. Answer the app's
   question honestly (yes if it guessed right; the right appliance if it asks).
   Write what it said in `app_result` ("Fan 1", "Asked", "New appliance").
5. Repeat steps 2–4 for each mode (the registration rows of a later mode are
   that mode's first 3 runs).

   **The app's own registration** asks for a different setting each time
   (low, then medium, then high), so the appliance's profile in the app
   covers all its settings. Do the app's 3 plug-ins that way, and write each
   one's real setting in the `mode` column. For the later modes' runs, tap
   **Not now** if the app asks to register again; the analysis still builds one
   profile per mode from the sheet.
6. **Long log** (if listed): start the logger first, then switch the
   appliance on:

   ```powershell
   node tool/measure_log.ts --outlet A --minutes 10 --out measurements/logs/iron1_high.csv
   ```

   It asks for the app's e-mail and password (the password is not shown or
   saved). Stay with the appliance for the whole log. Sheet row: `run_type =
   long_log`, `log_file = measurements/logs/iron1_high.csv`.

## 6. The recording sheet

One row per run. Columns:

| Column | What to write |
|---|---|
| `run_no` | 1, 2, 3… |
| `date` | 2026-11-05 (YYYY-MM-DD) |
| `start_time` | When you switched it on, 14:05:30 (24-hour, the phone's clock) |
| `outlet` | A or B |
| `appliance_type` | Electric fan, Rice cooker… (the same spelling every time) |
| `unit` | The name in the app: Fan 1, Fan 2 |
| `brand`, `model` | From the label |
| `nameplate_w` | Rated input power from the label (W) |
| `mode` | Speed 2 + oscillation, Keep warm, High… (the same spelling every time) |
| `run_type` | registration, test or long_log |
| `app_result` | What the app said (optional) |
| `session_id` | Leave empty; fill it only if the analysis cannot match a row |
| `log_file` | Long logs only: the CSV file of the logger |
| `notes` | Anything unusual (power cut, water added, wrong button) |

Voltage, power, power factor and the other features are not typed in: the
analysis takes them from the plug's own measurement of each run.

## 7. Running the analysis

In PowerShell in the project folder:

```powershell
node tool/measure_analyze.ts export
node tool/measure_analyze.ts analyze --sheet measurements/recording_sheet.csv
```

`export` reads the runs and the evaluation views from Supabase (read-only).
`analyze` writes `measurements/results/`:

| Output | Contents |
|---|---|
| `report.md` | Data check, features per mode (mean ± standard deviation), overlap table, recognition results, the live views, long logs |
| `dataset.csv` | Every sheet row with its voltage and all 7 features |
| `features_summary.csv` | Per appliance / mode: n, mean, standard deviation, min, max of every feature, and Outlet B vs A |
| `watts_vs_pf*.svg` | Average power (log scale) vs power factor, every run; 8 appliance types per chart, all on the same axes |
| `log_*.svg` | Power over time of each long log, with the on/off threshold |

What the report means:

- **Overlap:** each mode's average run is checked against every other mode's
  rules (the same check as recognition). *Cannot be separated* means each
  fits the other; *one-way* means one fits the other. The table names the
  features that still tell them apart. Modes of the same appliance that
  overlap are harmless (it is still the right appliance).
- **Recognition:** profiles from the registration runs, then every test run
  through the real rules (`matching.ts`, with the project's
  `recognition_config`): accuracy, precision, recall, F1 and the confusion
  table. A question ("Which appliance is it?") counts as not recognised, as in
  the database view.
- **Live views:** what the plug actually decided during the tests
  (`recognition_summary`, `recognition_metrics`, `recognition_confusion`).
  These only cover modes the app had registered.
- **Long logs:** readings arrive about every 3 s, so on and off times are
  accurate to about ±3 s. Recognition itself only sees the first ~60 s of a
  run, so a cycle longer than that has no cycle period in recognition; the
  long log is where it is documented.

If a row cannot be matched, the data check says which; fill in `session_id`
from `measurements/export/sessions.json` (same outlet, nearest `started_at`;
times there are UTC, 8 hours behind Philippine time).

## 8. References

Appliance signatures and features:

1. G. W. Hart, "Nonintrusive appliance load monitoring," *Proceedings of the
   IEEE*, vol. 80, no. 12, pp. 1870–1891, 1992.
2. J. Liang, S. K. K. Ng, G. Kendall, and J. W. M. Cheng, "Load signature
   study—Part I: Basic concept, structure, and methodology," *IEEE
   Transactions on Power Delivery*, vol. 25, no. 2, pp. 551–560, 2010.
3. M. Zeifman and K. Roth, "Nonintrusive appliance load monitoring: Review
   and outlook," *IEEE Transactions on Consumer Electronics*, vol. 57, no. 1,
   pp. 76–84, 2011.
4. A. Zoha, A. Gluhak, M. A. Imran, and S. Rajasegarar, "Non-intrusive load
   monitoring approaches for disaggregated energy sensing: A survey,"
   *Sensors*, vol. 12, no. 12, pp. 16838–16866, 2012.

How other appliance datasets were recorded:

5. J. Z. Kolter and M. J. Johnson, "REDD: A public data set for energy
   disaggregation research," in *Proc. SustKDD Workshop*, 2011.
6. A. Reinhardt et al., "On the accuracy of appliance identification based
   on distributed load metering data," in *Proc. SustainIT*, 2012
   (the Tracebase dataset).
7. A. Ridi, C. Gisler, and J. Hennebert, "ACS-F2: A new database of
   appliance consumption signatures," in *Proc. SoCPaR*, 2014.
8. J. Gao, S. Giri, E. C. Kara, and M. Bergés, "PLAID: A public dataset of
   high-resolution electrical appliance measurements for load identification
   research," in *Proc. ACM BuildSys*, 2014.
9. J. Kelly and W. Knottenbelt, "The UK-DALE dataset, domestic
   appliance-level electricity demand and whole-house demand from five UK
   homes," *Scientific Data*, vol. 2, 150007, 2015.

Evaluation:

10. M. Sokolova and G. Lapalme, "A systematic analysis of performance
    measures for classification tasks," *Information Processing &
    Management*, vol. 45, no. 4, pp. 427–437, 2009.
11. N. Batra et al., "NILMTK: An open source toolkit for non-intrusive load
    monitoring," in *Proc. ACM e-Energy*, 2014.

Power and ratings:

12. IEEE Std 1459-2010, *IEEE Standard Definitions for the Measurement of
    Electric Power Quantities Under Sinusoidal, Nonsinusoidal, Balanced, or
    Unbalanced Conditions* (power factor).
13. Peacefair / Innovators Guru, *PZEM-004T V3.0 User Manual* (measuring
    range, starting current, accuracy).
14. *Philippine Electrical Code 2017, Part 1* (IIEE), and NFPA 70 *National
    Electrical Code* (loads that stay on: 80 % of the circuit rating).

Check each reference in Google Scholar or the publisher's site before using
it in the thesis.
