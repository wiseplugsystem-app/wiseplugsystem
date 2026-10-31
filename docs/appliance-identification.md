# Rule-based appliance recognition

How WisePlug decides which appliance is on an outlet, why the old
wattage-range rule failed, and how the new design is tested and evaluated.
There is **no machine learning**: every decision is an explicit rule on
averages, standard deviations and tolerances, so each one can be checked by
hand.

| Part | File |
|---|---|
| Rules (pure, unit-tested) | `supabase/functions/_shared/matching.ts`, tests in `supabase/tests/matching.test.ts` |
| Scenario table for the thesis | `tool/recognition_table.ts` |
| Edge Functions | `recognize-appliance` (plug), `register-sample`, `confirm-match`, `manage-appliance` (app), `log-session` (end of run, 7-use learning) |
| Schema | `supabase/migrations/20261029020000…` to `…050000` |
| Tunable numbers | table `recognition_config` (one row) |
| Firmware measurement | `arduino/wiseplug_esp32/recognition_window.h` (tests in `test/recognition_window_test.cpp`) |
| App | `lib/screens/recognition_prompt.dart` (pop-ups), `register_appliance_screen.dart` (3 plug-ins), Profiles tab in `esp32_live_view.dart` |
| Evaluation | views `recognition_evaluation`, `recognition_confusion`, `recognition_metrics`, `recognition_summary` |

## 1. The failure being fixed

A Fan (55–60 W) runs on Outlet A. A different appliance drawing 55–60 W is
plugged into Outlet B, and the old system labelled it "Fan". It went wrong for
four reasons:

1. **Wattage alone** cannot separate same-wattage appliances. Power factor
   (a fan's motor ≈ 0.9, a laptop charger ≈ 0.55) and the start-up do.
2. **Closed set:** there was no "I don't know" answer.
3. **No physical rule:** one appliance cannot be in two sockets.
4. **Type and unit were mixed up:** "Fan" was both the kind of appliance and
   the one unit, so a second fan could not be registered.

## 2. What the plug measures

At plug-in (power above 2 W), each outlet runs a small state machine:

```
IDLE → STARTUP (first 5 s) → SETTLING → STEADY (30 s) → REPORTED
```

- **Settled** means 5 consecutive readings whose spread is under 2 % of their
  mean.
- If the load never settles within 60 s, everything collected so far is used
  and the run is marked `unstable`.
- The run ends after 3 s below 1.5 W.

| Feature | Definition | Sent at |
|---|---|---|
| `avg_power_w` | mean active power in STEADY | Stage 1 |
| `avg_pf` | mean power factor in STEADY | Stage 1 |
| `avg_voltage_v` | mean voltage in STEADY (for voltage correction) | Stage 1 |
| `startup_peak_ratio` | highest power in the first 5 s / `avg_power_w` | Stage 1 |
| `settling_time_s` | seconds from plug-in until settled | Stage 1 |
| `standby_power_w` | smoothed draw before the run, when ≥ 0.5 W (else null) | Stage 1 |
| `power_variation` | (max − min) / mean power in STEADY | Stage 2 |
| `cycle_period_s` | mean time between on-cycles, if the load cycled at least twice in the first minute (else null) | Stage 2 |

**Why not current:** I = P / (V × PF). Once power, voltage and PF are known,
current adds no independent information.

**When each stage is sent:** Stage 1 goes about 10 s after the load settles;
Stage 2 at the end of STEADY (about 35–60 s after plug-in).

**Limits of 1 reading per second:**
- Millisecond inrush is averaged away, so the peak only reflects slow
  start-ups (motor spin-up, a charger's soft start).
- A thermostat usually cycles over minutes, so `cycle_period_s` is mostly
  null.

## 3. Registration

Registration starts **only from the pop-up** WisePlug shows for a new
appliance. There is no other register button and there are no preset profiles.

- **What the user sets:** the type and the name, both required. The app then
  guides **3 plug-ins**.
- **What the system sets:** the **safety limit** (the type's default, then
  the 7-use learning) and the **modes**. The user cannot change either one,
  in the app or through the server.
- **Unfinished registrations:** if a registration is left unfinished, the next
  "New appliance" pop-up offers "It is <name>: continue registering".
- **Profiles tab:** lists every appliance with an All / Active / Idle filter,
  where it is plugged in, and its status. A profile can be renamed (Edit) or
  deleted, but not given a limit or a mode.

- **Where it is stored:** each run becomes a raw sample of the appliance's
  **mode profile**, for example "Fan – Low" or "Fan – High".
- **Mean and spread:** the profile stores the mean and standard deviation of
  every feature, plus the mean voltage at registration.
- **When it can be matched:** only once the profile has all 3 samples.
- **Modes:** matching any profile of an appliance counts as matching the
  appliance.

## 4. The rules

All numbers below come from `recognition_config`.

1. **Tolerance** of a feature for a profile:
   `tolerance = max(3 × std_dev, floor)`.
   - The floors are: power 2 % of the mean, PF 0.02, start-up ratio 0.10,
     variation 0.02, settling 2 s, cycle 10 % of the mean, standby 0.5 W.
   - Why a floor: 3 near-identical registration samples (std ≈ 0) must not
     make an appliance reject its own next run.
2. **Voltage correction (resistive loads):** for a profile with mean PF ≥ 0.95,
   `power × (registration V / measured V)²` is compared, because a heater
   follows P = V²/R. Other loads are compared as measured.
3. **Pass/fail:** every feature present on both sides must satisfy
   `|new − mean| ≤ tolerance`.
   - A feature missing on either side is skipped.
   - Power is always required, so a profile is never accepted on PF alone.
   - Any failure means the profile is not a candidate.
4. **Score:** `Σ wᵢ × |newᵢ − meanᵢ| / toleranceᵢ / Σ wᵢ`.
   - 0 means identical; 1 means at the edge of the tolerance; lower is better.
   - Weights: power 0.30, PF 0.30, start-up 0.15, variation 0.10, settling
     0.10, standby 0.05. Cycle period is pass/fail only.
   - Each appliance keeps its best-scoring mode.
5. **Outlet exclusivity:** an appliance in an open run on any outlet of the
   user's plugs is removed. The database enforces this too, with a unique
   index on open sessions.
6. **Decision:**

| Situation | Status | User sees |
|---|---|---|
| No candidate passes | `UNKNOWN` | "New appliance detected. Register it?" |
| The only passing candidates were removed by rule 5 | `SAME_TYPE_IN_USE` | "This looks like another Fan. Register as Fan 2?" |
| One candidate, or the runner-up scores ≥ 1.5 × the best **and** is more than 0.10 worse | `MATCHED_PROVISIONAL` | label marked provisional |
| Otherwise (a near tie) | `AMBIGUOUS` | "Is this A or B?", with the one last used on this outlet pre-selected |
| Stage 2 picks the same appliance as Stage 1 | `MATCHED_CONFIRMED` | its own cutoff applies |

   The tie-margin part of the clear-winner rule matters when both scores are
   tiny: 0.01 vs 0.02 is "twice as far", but the two are practically identical.

7. **Safety:** every status except `MATCHED_CONFIRMED` gets the conservative
   default cutoff (30 min), never another appliance's limit. This is enforced
   three times:
   - by the rules
   - by a database trigger on `outlet_sessions`
   - by the plug, which caps any unconfirmed cutoff at 30 min, and runs on
     30 min whenever Supabase cannot be reached
8. **Confirmed cutoff:** the appliance's own safe operating time. After 7
   confirmed normal uses, its average runtime × 1.5 applies instead: at least
   5 min, never above its own limit.
9. **Signature updating:** after a **user-confirmed** run:
   - **It fits a complete mode:** the mode's means move by
     `new = 0.9 × old + 0.1 × run`, and the standard deviation is recomputed
     from the newest 20 samples.
   - **It fits a mode still being learned:** that mode becomes the mean and
     standard deviation of its samples.
   - **It fits no mode** (e.g. a fan speed never seen): **the system starts a
     new mode** ("Mode 2") with this run. It is matched once it has 3 samples.
   - Unconfirmed runs never update anything.

**Known limitation (stated honestly):**
- Two units of the same model give near-identical readings. The readings
  decide the **type**.
- **Which unit** is decided by:
  1. outlet exclusivity
  2. the outlet it was last used on
  3. the user's confirmation
- Likewise, an electrically identical appliance of a different type, if it is
  free, is a valid candidate (scenario 2b in the table).

## 5. Data model

```
appliance_types (Fan) 1─* appliance_instances (Fan 1, Fan 2: owner, cutoff, 7-use learning, last outlet)
appliance_instances 1─* appliance_profiles (modes: mean/std per feature, registration V, sample count)
appliance_profiles 1─* signature_samples (raw samples, newest 20 kept)
outlets (device, outlet_1/outlet_2) 1─* outlet_sessions (one per run: status, cutoff, prediction, truth)
recognition_config (one row: every tunable number)
```

Appliances belong to the **user** (`devices.owner_uid`), so one Fan can move
between the user's plugs. Row-level security lets owners read their rows;
only Edge Functions write.

## 6. Test plan

**Automated tests:**
- `node --test supabase/tests/matching.test.ts`: 20 tests, including the 9
  required scenarios. They also run under `deno test`.
- `flutter test`: the prompts, guided registration and Appliances tab.
- The plug's measurement state machine is tested in
  `test/recognition_window_test.cpp`. It runs with g++ on a PC.

**Scenario table for the thesis:** `node tool/recognition_table.ts` prints
this table:

| # | Scenario | Expected |
|---|---|---|
| 1 | Fan active on A; 58 W charger (PF 0.55) on B | UNKNOWN (PF fails) |
| 2 | Fan active on A; identical fan (56 W, PF 0.91) on B | SAME_TYPE_IN_USE, "Register as Fan 2?" |
| 3 | Fan moved from A to B | MATCHED_PROVISIONAL at Stage 1, MATCHED_CONFIRMED at Stage 2 |
| 4 | Two registered appliances with close scores | AMBIGUOUS |
| 5 | Fan with Low and High modes, running on one of them | matches Fan in that mode |
| 6 | 1000 W heater registered at 220 V, measured at 235 V | matches after voltage correction |
| 7 | Never-seen appliance | UNKNOWN, 30 min cutoff |
| 8 | Noisy readings within tolerance | still matches |
| 9 | Unconfirmed load reaches the default cutoff | the plug warns, then cuts power 60 s later (firmware test) |

**On hardware:** repeat each scenario 10 times. For every run, note the
outcome in Serial Monitor and in `outlet_sessions`.

## 7. Evaluation (thesis numbers)

**What is stored for each run:**
- `predicted_status` / `predicted_appliance_id`: what WisePlug decided on its
  own.
- `actual_appliance_id`: the truth.

**Where the truth comes from:**
- **Automatically:** "Yes, it is …" in a prompt, or tapping a provisional
  badge, sets it. So does registering a run.
- **By hand:** a run auto-confirmed at Stage 2 asks nobody. Use your
  recording sheet and set its truth in the SQL editor:

```sql
-- one run
update outlet_sessions set actual_appliance_id =
  (select id from appliance_instances where name = 'Fan 1')
where event_id = '<event id>';
-- all auto-confirmed runs of a test session you checked were right
update outlet_sessions set actual_appliance_id = predicted_appliance_id
where confirmed_by = 'stage2' and actual_appliance_id is null
  and started_at between '2026-11-02 09:00+08' and '2026-11-02 11:00+08';
```

**Results:** `select * from recognition_summary;`, `recognition_metrics` and
`recognition_confusion`. Use *Export → CSV* for the appendix.

**What counts as new:** a run's appliance is "New appliance" when it was
registered during or after that run. UNKNOWN or SAME_TYPE_IN_USE is then the
correct answer. Registration plug-ins 2 and 3 are left out.

**The metrics:**
- **Accuracy (registered appliances):** correct recognitions / runs of
  registered appliances.
- **Overall accuracy:** (correct + new correctly flagged) / all runs.
- **Precision, recall and F1 per appliance:**
  - P = TP/(TP+FP), R = TP/(TP+FN), F1 = 2PR/(P+R).
  - A run WisePlug asked about counts as not recognised (FN). The question is
    safe, but it is not automatic.
- **Unknown-appliance detection rate:** new appliances flagged UNKNOWN or
  SAME_TYPE_IN_USE / all new-appliance runs.
- **Asked the user / wrong appliance / missed known:** counts per outcome.
- **Safety violations:** unconfirmed runs with more than the default cutoff.
  The trigger makes this 0.

**ISO/IEC 25010:**
- *functional correctness*: accuracy, F1
- *functional completeness*: the 9 scenarios
- *fault tolerance*: offline → default cutoff
- *time behaviour*: Stage 1 at about 15 s, Stage 2 at about 35–60 s
- *safety*: the safety-violation count and scenario 9

## 8. Deploying (order matters)

```powershell
npx supabase functions deploy recognize-appliance register-sample confirm-match manage-appliance log-session
npx supabase db push
npx supabase functions delete identify-appliance
npx supabase functions delete confirm-appliance
```

1. **Deploy the functions first:** the new `log-session` no longer uses
   `active_sessions`, which the last migration drops.
2. **Delete the old functions last:** they belong to the removed k-NN design.
