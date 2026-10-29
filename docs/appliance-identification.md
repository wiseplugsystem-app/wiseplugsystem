# Appliance identification: open-set k-NN with outlet exclusivity

How WisePlug decides which appliance is plugged into an outlet, why the old
wattage-range rule failed, and how the new design is tested and evaluated.

The CNN signature embedding adapted from Matindife et al. (2020) is described
in [appliance-embedding.md](appliance-embedding.md). It uses the same
`decide()` step. This k-NN on hand-crafted features is its baseline and its
fallback.

| Part | File |
|---|---|
| Matcher (pure, tested) | `supabase/functions/_shared/knn.ts`, tests in `supabase/tests/knn.test.ts` |
| Schema | `supabase/migrations/20261029000000_appliance_instances.sql` |
| Edge Functions | `identify-appliance` (plug), `confirm-appliance` (app); `log-session` frees the outlet |
| Firmware | `arduino/wiseplug_esp32/signature_window.h`, `finishSampling()` and `sendSupabase()` in the sketch |

## 1. Root cause of the Fan / Appliance Y failure

1. **One feature.** A wattage range cannot separate appliances that draw the
   same power. 57 W of fan motor and 57 W of laptop charger differ in power
   factor (about 0.9 vs about 0.55) and current, which the range ignored.
2. **Closed-set decision.** The rule always returned *some* registered
   appliance whose range contained the reading. There was no "I don't know"
   outcome, so a new appliance could only ever be mislabelled.
3. **No physical constraint.** Matching ignored that the registered Fan was
   *running on Outlet A*. One physical appliance cannot be in two sockets, so
   the Fan should have been excluded from matching on Outlet B.
4. **Type and instance conflated.** "Fan" was both the kind of appliance and
   the single unit, so a second fan could not be registered with its own
   signature and limit.

The firmware fix for (3) is in `finishSampling()`: a profile running on the
other outlet is skipped, and a second load that only resembles it is learned
as a new appliance for the user to name. `MERGE_PROFILE` refuses to merge two
profiles that are both running.

## 2. Signature features at 1 reading per second

The PZEM-004T v3.0 reports V, I, P, PF, energy and frequency about once per
second. It gives no waveform, so harmonic and V-I trajectory features
(used with high-rate data such as PLAID) are out of reach.

| Feature | How it is obtained | Reliability at 1 Hz | Weight |
|---|---|---|---|
| Active power P | measured, mean over 30 s | high (0.5 % accuracy, 0.1 W resolution) | 1 |
| RMS current I | measured, mean over 30 s | high | 1 |
| Power factor PF | measured, mean over 30 s | high above ~5 W; ignored below `MIN_PF_POWER_W` | 1 |
| Reactive power Q | derived: S = V x I, Q = sqrt(S^2 - P^2) | medium: a small difference of large numbers when PF is near 1 | 0.5 |
| Steady variation (CV) | std(P) / mean(P) over the window | medium: needs the full 30 s | 0.5 |
| Start-up peak ratio | highest P in the first 5 s / steady P | low: the meter averages away most of a millisecond inrush | 0.25 |
| Standby power | smoothed P while idle | low (noise floor ~0.5 W); stored, not matched | 0 |
| On/off cycling | duty cycle over many minutes | unavailable at plug-in time; analyse later from `sessions` | 0 |

P and I are strongly correlated (I is about P / (V x PF)), so together they count
somewhat double. PF and Q add the independent information that separates
same-wattage appliances.

**Window.** The plug ignores the first 5 s (start-up, used only for the peak),
then summarises 30 s of steady load (`SignatureWindow`, Welford's running
mean and variance, one reading counted per second). Runs shorter than that
are not identified. The plug's own limit and the electrical trips still
apply to them.

## 3. Data model

```
appliance_types (Fan)  1--*  appliance_instances (Fan 1, Fan 2)  1--*  signature_samples (<= 20 per mode)
outlets (outlet_1, outlet_2)  1--0..1  active_sessions  *--0..1  appliance_instances
```

* `appliance_instances` has its own `max_runtime_mins`, so Fan 1 and Fan 2
  can have different safe operating times.
* `signature_samples.mode` lets one instance have several operating points
  (fan speed 1 and speed 3). A trigger keeps the newest 20 samples per mode.
* `active_sessions` enforces the rules in the database:
  * `unique (device_id, outlet)`: one load per outlet.
  * `unique (instance_id)`: **an instance is active on at most one outlet.**
  * an identity is attached only to CONFIDENT or CONFIRMED loads.
  * an unconfirmed load cannot have a cutoff above 30 min.

## 4. Matching algorithm

```
INPUT  x = (P, I, PF, Q, CV, peakRatio) of the new load on outlet o
FOR each instance j of the device:
    FOR each mode m of j:
        mu, sigma  <- mean, std of the mode's samples
        sigma_f    <- sqrt(std_f^2 + floor_f^2) * sqrt(1 + 1/n)     # meter floor, small-n inflation
        d(x, s)    <- sqrt( sum_f w_f ((x_f - s_f) / sigma_f)^2 / sum_f w_f )   # per sample s
        D_jm       <- mean of the k = 3 smallest d(x, s)            # k-NN distance
        T1_jm, T2_jm <- thresholds of the mode (below)
    D_j <- min over modes;  keep that mode's T1, T2
EXCLUDE every j active on another outlet            # outlet exclusivity
    if an excluded j has D_j <= T2_j: suggest "Register as <type of j> <next number>?"
SORT the rest by D_j: best b, then the others
IF no b or D_b > T2_b         -> UNKNOWN    (cutoff = conservative 30 min)
ELSE IF D_b > T1_b            -> AMBIGUOUS  (pre-select b; cutoff = 30 min)
ELSE IF another c has D_c <= T1_c and D_c - D_b < 0.5
                              -> AMBIGUOUS  (identical units: pre-select the one last
                                             seen on outlet o; cutoff = 30 min)
ELSE                          -> CONFIDENT  (label b; cutoff = b's own limit)
```

**Thresholds.** Distances are in standard-deviation units. Until a mode has
5 samples: T1 = 2.0, T2 = 3.5. For Gaussian features, a genuine reading
rarely exceeds an RMS z of 2. From 5 samples on, leave-one-out: each sample
is matched against the others, T1 = the 95th percentile of those genuine
distances (clamped to 1.0..3.0), and T2 = max(1.75 x T1, T1 + 1).

**Why they tighten.** The `sqrt(1 + 1/n)` inflation shrinks towards 1 as n
grows, the sample std converges to the appliance's real spread, and the
percentile replaces the lenient default. In the test data a Fan with 20
samples calibrates to T1 = 1.0, T2 = 2.0. It then accepts about ±5 % in
power as CONFIDENT, ±5–9 % as AMBIGUOUS, and beyond that UNKNOWN.

**Continuous learning.** Only user-confirmed runs (`confirm-appliance`)
append a sample, into the closest mode, or into a new mode when the run is
beyond that mode's T2. Unconfirmed auto-labels never train the model, so one
mislabel cannot drift a signature.

**Identical units (honest limitation).** Two units of the same model are
electrically indistinguishable: their signatures overlap within meter noise.
The system does not claim otherwise. It uses, in order:

1. Exclusivity: if Fan 1 runs on Outlet A, a fan on Outlet B is Fan 2.
2. Last-known outlet: pre-selects the likely unit.
3. The user's one-tap confirmation.

**Safety rule.** AMBIGUOUS and UNKNOWN loads always get the conservative 30
min cutoff, never a candidate's limit, even a shorter one: it is not that
appliance's rule until confirmed. The plug applies the server's cutoff only
if it is *shorter* than its own deadline, so a wrong or unreachable server can
never extend a run. Overcurrent and power-anomaly trips are always local.

## 5. ESP32 side

1. **Detect.** Every reading, `handleSensor()` compares P with
   `START_W_THRESHOLD` (3.5 W). Crossing it starts a run, opens the window
   and records standby power from before the run.
2. **Collect.** `SignatureWindow::add()` keeps the peak for 5 s, then 30 s of
   Welford statistics.
3. **Send.** `queueFeatures()` queues the summary; the `supabase` task POSTs
   it to `identify-appliance` (event ID = boot session + outlet + start time,
   so retries are idempotent).
4. **Apply.** The reply's `cutoffS` goes back through `cutoffReplies` and
   `loop()` shortens the deadline if needed.

The sketch reads the two meters on **two UARTs** (Serial2 on GPIO 32/33,
Serial1 on 25/26), which needs no address setup and is the more robust
wiring. If both modules must share one UART, give each a Modbus address
first (one module connected at a time), then read both on the same port:

```cpp
#include <PZEM004Tv30.h>
// One-time: connect only module A, run pzem.setAddress(0x01); then only B, setAddress(0x02).
PZEM004Tv30 pzemA(Serial2, 16, 17, 0x01);   // RX, TX, Modbus address
PZEM004Tv30 pzemB(Serial2, 16, 17, 0x02);   // same bus, different address
void setup() { Serial.begin(115200); Serial.printf("A=0x%02x B=0x%02x\n", pzemA.readAddress(), pzemB.readAddress()); }
void loop() {
  for (auto* m : {&pzemA, &pzemB}) {
    float v = m->voltage(), i = m->current(), p = m->power(), pf = m->pf();
    if (isnan(p)) { Serial.println("no reply: check address and wiring"); continue; }
    float s = v * i, q = sqrt(fmaxf(s * s - p * p, 0));
    Serial.printf("P=%.1f W I=%.3f A PF=%.2f Q=%.1f var\n", p, i, pf, q);
  }
  delay(1000);
}
```

On a shared bus the modules' TX outputs are wired together; keep the wires
short and read the modules one after the other, never at the same time.

## 6. App screens and states

The app listens to `active_sessions` (Supabase Realtime) for its outlets.

| State | Screen | Prompt / actions |
|---|---|---|
| Sampling (0–35 s) | Outlet card: "Recognizing appliance…" with a progress ring | none; the conservative 30 min limit is shown |
| CONFIDENT | Card shows "Fan 1" and its limit | small "Not Fan 1?" link opens the AMBIGUOUS sheet |
| AMBIGUOUS | Bottom sheet "Which appliance is on Outlet B?" | up to 3 candidates (the suggested one pre-selected), **Register new appliance**, **Ask me later**; banner: "Using a 30 min safety limit until you choose" |
| AMBIGUOUS, identical units | Same sheet, text: "Fan 1 and Fan 2 look identical to the plug. It was last on Outlet B, so we chose Fan 2." | one tap to confirm |
| UNKNOWN | Sheet "New appliance on Outlet B" | type picker (existing types + new), name pre-filled "Fan 2", safe operating time (pre-filled from the type), **Register**; or **Not now** (keeps 30 min) |
| UNKNOWN with `registerAs` | Sheet headline: "Looks like Fan 1, which is running on Outlet A. Register as Fan 2?" | **Register as Fan 2**, **Something else** |
| Confirmed | Card shows the name; snackbar "Saved. WisePlug learns Fan 2 better each use." | the app sends the instance limit to the plug (`EDIT_PROFILE`) |

Registration flow: choose type → name (auto "Type N") → safe operating time
→ the current run's features become the instance's first sample.

## 7. Test plan

Automated: `node --test supabase/tests/knn.test.ts` (seeded noise, so the
results repeat exactly). On hardware, repeat each row 10 times and record
the outcome.

| # | Scenario | Expected result | Automated |
|---|---|---|---|
| 1 | Fan registered and running on Outlet A; a 55–60 W load plugged into B | B is **UNKNOWN** (never "Fan"); prompt "Register as Fan 2?"; 30 min cutoff. With A idle, the same reading on A is **CONFIDENT Fan**. | test 1 |
| 2 | 57 W fan (PF ~0.92) and 57 W laptop charger (PF ~0.55) | Each identified as itself; with only the fan registered, the charger is **UNKNOWN** (distance ~11.6 vs T2 = 2) | test 2 |
| 3a | Two identical fans registered, both idle, one plugged into B | **AMBIGUOUS** "look identical", pre-selects the fan last seen on B, 30 min cutoff | test 3a |
| 3b | Fan 1 running on A, the other fan plugged into B | **CONFIDENT Fan 2** with Fan 2's own cutoff (exclusivity decides) | test 3b |
| 4 | Fan learned at speed 1 (40 W), first run at speed 3 (57 W) | Not CONFIDENT; after the user confirms "Fan", speed 3 becomes mode 1; later runs at either speed are **CONFIDENT** | test 4 |
| 5 | Sensor noise: ±1 % P, ±0.005 PF, ±0.5 % V, 200 runs | ≥ 90 % CONFIDENT and **0 mislabels** (measured: 200/200 correct) | test 5 |
| 6 | Unconfirmed load near an appliance with an 8 h limit | cutoff stays 30 min | "never inherit" test |
| 7 | Same instance claimed on both outlets at once (race) | database rejects the second (unique key); that outlet becomes AMBIGUOUS | migration check |

## 8. Evaluation metrics

Collect a labelled log: for each run, the true appliance (noted by the
tester) and the system's outcome. Include runs of appliances that are **not
registered** to measure open-set behaviour (leave-one-appliance-out:
de-register one appliance, run it, repeat for each).

* **Accuracy** (known appliances): correct CONFIDENT labels / all runs of registered appliances.
* **Precision, recall, F1 per appliance** from the confusion matrix, treating
  "UNKNOWN/AMBIGUOUS" as its own column; report macro-F1 too.
  Precision_j = TP_j / (TP_j + FP_j), Recall_j = TP_j / (TP_j + FN_j), F1 = 2PR / (P + R).
* **Unknown-detection rate**: runs of unregistered appliances that end
  UNKNOWN or AMBIGUOUS / all such runs. Its complement is the open-set error
  (a new appliance mislabelled as a known one).
* **Coverage / user burden**: share of runs auto-labelled (CONFIDENT) vs runs
  that needed a prompt.
* **Safety metric**: number of runs where an unconfirmed load received another
  appliance's cutoff. The design target is 0, and the database constraint
  makes anything else impossible.
* **Learning curve**: accuracy and T1 vs number of confirmed samples (1, 3, 5, 10, 20).

These map onto ISO/IEC 25010 functional correctness (accuracy, F1),
reliability/fault tolerance (server offline: local limits still apply) and
safety (the cutoff metric).

## 9. References (verify each in Google Scholar)

* Hart, G. W. (1992). Nonintrusive appliance load monitoring. *Proceedings of the IEEE*, 80(12), 1870–1891. (appliance signatures, steady-state P/Q features)
* Liang, J., Ng, S. K. K., Kendall, G., & Cheng, J. W. M. (2010). Load signature study—Part I: Basic concept, structure, and methodology. *IEEE Transactions on Power Delivery*, 25(2), 551–560.
* Zeifman, M., & Roth, K. (2011). Nonintrusive appliance load monitoring: Review and outlook. *IEEE Transactions on Consumer Electronics*, 57(1), 76–84. (feature requirements, sampling-rate limits)
* Ridi, A., Gisler, C., & Hennebert, J. (2014). A survey on intrusive load monitoring for appliance recognition. *22nd International Conference on Pattern Recognition (ICPR)*, 3702–3707. (plug-level identification, k-NN baselines)
* Gao, J., Giri, S., Kara, E. C., & Bergés, M. (2014). PLAID: A public dataset of high-resolution electrical appliance measurements for load identification research. *ACM BuildSys '14*, 198–199. (high-rate features this hardware cannot provide)
* Hassan, T., Javed, F., & Arshad, N. (2014). An empirical investigation of V-I trajectory based load signatures for non-intrusive load monitoring. *IEEE Transactions on Smart Grid*, 5(2), 870–878.
* De Baets, L., Develder, C., Dhaene, T., & Deschrijver, D. (2019). Detection of unidentified appliances in non-intrusive load monitoring using siamese neural networks. *International Journal of Electrical Power & Energy Systems*, 104, 645–653. (open-set / unknown appliances; we use the same idea with distance thresholds instead of a neural network)
* Cover, T., & Hart, P. (1967). Nearest neighbor pattern classification. *IEEE Transactions on Information Theory*, 13(1), 21–27.
* Scheirer, W. J., de Rezende Rocha, A., Sapkota, A., & Boult, T. E. (2013). Toward open set recognition. *IEEE Transactions on Pattern Analysis and Machine Intelligence*, 35(7), 1757–1772.
* Welford, B. P. (1962). Note on a method for calculating corrected sums of squares and products. *Technometrics*, 4(3), 419–420.
* Sokolova, M., & Lapalme, G. (2009). A systematic analysis of performance measures for classification tasks. *Information Processing & Management*, 45(4), 427–437.
* ISO/IEC 25010:2011 (revised 2023). Systems and software Quality Requirements and Evaluation (SQuaRE) — product quality model.

## 10. Deploying

```
npx supabase db push                      # applies 20261029000000_appliance_instances.sql
npx supabase functions deploy identify-appliance confirm-appliance log-session
```

Then upload the sketch. Serial Monitor shows `Signature: …` about 35 s after
a load starts and `Identified <OUTCOME>: cutoff <s>` when the server answers.

Not built yet: the Flutter screens in section 6. The backend replies and the
`active_sessions` rows they read are in place, and `confirm-appliance` is the
call behind every button.
