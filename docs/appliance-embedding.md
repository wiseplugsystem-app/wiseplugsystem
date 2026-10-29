# Appliance identification with a CNN signature embedding

This design adapts Matindife, Sun & Wang (2020) to WisePlug. It extends
[appliance-identification.md](appliance-identification.md), which covers the
open-set k-NN on hand-crafted features. That method remains the **baseline and
the fallback**.

| Part | File |
|---|---|
| Training (Google Colab) | `training/wiseplug_embedding.ipynb` (source: `training/wiseplug_embedding.py`) |
| CNN runtime (plain TypeScript) | `supabase/functions/_shared/embedder.ts`; tests in `supabase/tests/embedder.test.ts` |
| Deployed model | `supabase/functions/_shared/model/embedder.json` (a placeholder until the first training) |
| Open-set decision, shared by both methods | `decide()` in `supabase/functions/_shared/knn.ts` |
| Schema | `supabase/migrations/20261029000000_appliance_instances.sql`, `20261029010000_signature_embeddings.sql` |
| Edge Functions | `identify-appliance` (plug), `confirm-appliance` (app) |
| Firmware | `SignatureSignal` in `arduino/wiseplug_esp32/signature_window.h`; `sendSupabase()` in the sketch |

## 1. Mapping the base study to WisePlug

| Base study | WisePlug | Why |
|---|---|---|
| Recognises appliances with equal or very close power specifications | Same goal: Fan vs a 57 W look-alike, Fan 1 vs Fan 2 | This is the reported failure |
| P, I_rms and PF at 1 Hz as a multivariate time series | Same three channels from the PZEM-004T v3.0 at 1 reading/s | Same sensor quantities and the same rate |
| Non-intrusive: one meter on the mains, needs disaggregation | **Intrusive**: one meter per outlet, so **no disaggregation** | Each outlet's meter sees one appliance; only the recognition part is needed |
| MPS-CNN, LSTM and CNN-LSTM as classifiers | The same three, compared; the MPS-CNN is used as an **embedding** network | A classifier has a fixed list of classes and must be retrained for every new appliance |
| Softmax over the known appliances (closed set) | Distance to a signature **databank**; "no pairing = new appliance" | Users register appliances at any time |
| Signature databank of each appliance | `signature_samples` (raw windows + summaries) and `signature_embeddings`, per **instance** and mode | Fan 1 and Fan 2 have their own samples and cutoffs |
| Transfer learning from a large dataset | Pretrain on a public 1 Hz plug dataset, fine-tune on WisePlug recordings | Few home recordings are available |
| 70:30 split; accuracy, precision, recall, F1 | Same, plus the unknown-detection rate and a safety metric | The open set and safety need their own measures |

**Not adopted:**
- The study's reliance on deep networks alone. At 1 Hz, most of the
  information is in the steady levels, so the hand-crafted k-NN is kept as
  the baseline. The thesis should report which one wins on the real data.
- Any claim that identical units can be separated (section 8).

## 2. Pipeline

```
switch-on (P > 3.5 W)
  │  ESP32: first 32 readings of P, I, PF (+ 35 s steady summary)
  ▼
identify-appliance (Supabase Edge Function)
  │  model deployed and every instance has a recorded window?
  │     yes: CNN embedding (16 numbers) → k-NN in embedding space, T1/T2 from validation
  │     no:  feature k-NN (z-scored), per-mode thresholds
  ▼
decide(): outlet exclusivity → CONFIDENT / AMBIGUOUS / UNKNOWN → cutoff
  │  stored in active_sessions (live) and identification_events (log)
  ▼
plug shortens its deadline if the reply is shorter      app shows the prompt (Realtime)
                                                          │ user confirms / registers
                                                          ▼
                                       confirm-appliance: new sample + embedding, label
```

## 3. Signature input

- **Window:** N = **32 readings** (32 s at 1 Hz), starting with the reading
  that triggered the run, so the start-up is included. 32 halves cleanly
  through the two pooling layers.
- **Why not 60 s:** the identification would take twice as long, and the
  extra readings would mostly repeat the steady level.
- **Why not under 20 s:** slow start-ups, like a charger's soft start or a
  lamp's warm-up, would be cut off.
- **Channels:** P (W), I_rms (A) and PF, as in the base study.
- **Normalisation:** a fixed formula rather than one fitted to the data, so
  registering new appliances never changes it. It is identical in the
  notebook and `embedder.ts`:
  - P → ln(1+P) / ln(1+3000). A 5 W charger and a 2 kW kettle both fit in
    0..1, and a 5 % change looks the same at any size.
  - I → ln(1 + I/5 mA) / ln(1 + 15 A/5 mA).
  - PF → PF. Below 5 W it is set to 0, because the meter cannot measure it
    there.
- **Limits at 1 Hz:**
  - The PZEM averages each second, so millisecond inrush spikes are
    invisible. The window only captures slow behaviour: motor spin-up over
    1–5 s, a charger's soft start, a CFL's warm-up, a heating element's
    drift.
  - The first reading may cover only part of a second.
  - Harmonics and V-I trajectories need waveform data (kHz), which this
    hardware cannot provide.
  - The notebook's augmentation covers these effects: a partial first
    second, switch-on detected one reading late, mains ±1 % and meter noise.

## 4. Model

| | MPS-CNN (recommended) | LSTM | CNN-LSTM |
|---|---|---|---|
| Structure | 3 parallel 1D-CNN branches (P, I, PF): Conv(8,k5)→AvgPool→Conv(16,k3)→AvgPool→[global avg, global max], concatenated →Dense(32)→Dense(16) | LSTM(32) over the 3-channel sequence →Dense(32)→Dense(16) | Conv(16,k5)→AvgPool→LSTM(32)→Dense(32)→Dense(16) |
| Parameters | ≈ 5,000 | ≈ 6,500 | ≈ 7,000 |
| Work per window | ≈ 26 k multiply-adds, all parallel | 32 sequential steps | 16 sequential steps |
| Same-wattage appliances | the PF branch learns on its own and the max pooling keeps start-up peaks | must learn the channel interactions | in between |
| Transfer when public data has no PF | only the PF branch is re-initialised | the whole input layer changes | the whole input layer changes |
| Runtime in an Edge Function | ~150 lines of TypeScript, verified against Keras | needs an LSTM implementation | needs an LSTM implementation |
| Explainability | "one filter bank per measurement" | "memory of the sequence" | both |

The notebook prints the exact parameter counts and trains all three on the
same split for the comparison table.

**Recommendation: the MPS-CNN.**
- It is the smallest of the three.
- Its branch per parameter matches the study.
- It handles a public dataset without PF.
- It is the simplest to run without TensorFlow.

**Embedding, not a classifier.** The last layer outputs 16 numbers scaled to
unit length, so two embeddings are 0 (identical) to 2 apart. The network is
trained with a **batch-hard triplet loss** (Schroff et al. 2015; Hermans et
al. 2017):
- Each batch holds 8 classes × 4 windows.
- For every window (the *anchor*), the loss takes the farthest window of the
  same class and the nearest window of another class, and requires
  `d(anchor, same) + 0.3 ≤ d(anchor, other)`.

A new appliance needs no retraining. Its embeddings are stored, and matching
is by distance.

**Classes:**
- A training class is *appliance model + mode*, so fan speed 1 and speed 3
  are not forced together.
- Two units of the same model share a label. Training them as separate
  classes would teach the network to separate meter noise.

## 5. Data collection protocol

**Appliances.** Overlap is deliberate.

| Group | Appliances (examples; use what is available) | Purpose |
|---|---|---|
| A. Same wattage, different load type (55–60 W) | stand fan, LED floodlight / LED driver, laptop charger, soldering iron or 60 W incandescent bulb, TV or monitor | the reported failure; PF and start-up must separate them |
| B. Identical units | 2 fans of the same model (and 2 identical lamps if possible) | to measure, honestly, that they cannot be separated |
| C. Multi-mode | fan at speeds 1, 2, 3; a dimmable lamp at 2 levels | modes |
| D. Range | phone charger (5–10 W), CFL lamp, rice cooker or kettle (≤ the relay and PZEM rating) | small and large loads |
| E. Held out (never registered) | 3 or more other appliances | unknown-detection rate |

**Sessions:**
- At least **20 switch-ons per appliance per mode**. 15 is the minimum; with
  20, the 30 % validation part gets 6.
- Spread them over **at least 3 days**, at different times of day (the mains
  voltage varies), on **both outlets**, and include cold starts as well as
  restarts within a minute.
- Before each switch-on, unplug or switch off the appliance for **at least
  30 s**, so motors stop and the plug sees a fresh start. Let it run **at
  least 60 s**.
- Target: about 15 classes × 20 = 300 sessions, roughly 8 hours of plug time
  in total. Record a further **test day** of 5 sessions per class for the
  final numbers.

**Labelling:**
1. Every switch-on creates a row in `identification_events`, with its
   32-reading signal, outlet and time.
2. Keep a recording sheet (time, outlet, appliance, mode).
3. In the Supabase **Table Editor**, enter for each row:
   - `label_appliance`: the model, e.g. `Stand fan (Brand A)`
   - `label_mode`: e.g. `2` for speed 3
   - `label_note`: free text such as "unit 2" or "cold start"
4. Runs the user confirms in the app are labelled automatically
   (`confirmed_instance_id`).

**Export.** In the SQL editor, run `select * from training_readings;`, then
choose *Download CSV*. The file has one row per reading:

```
session_id,device_id,outlet,appliance,instance,mode,t_s,power_w,current_a,pf,started_at
gadget-1_outlet_1_123,gadget-1,outlet_1,Stand fan (Brand A),Fan 1,0,0,71.3,0.342,0.88,2026-11-02 09:14:05+08
gadget-1_outlet_1_123,gadget-1,outlet_1,Stand fan (Brand A),Fan 1,0,1,63.0,0.300,0.90,2026-11-02 09:14:05+08
...
```

## 6. Training (Colab, free tier)

1. Open `training/wiseplug_embedding.ipynb` in Colab (*File → Upload
   notebook*). A CPU runtime is enough.
2. **Test the pipeline first.** Keep `DEMO = True` and choose *Run all*. It
   uses synthetic appliances, including four at 56–58 W. **Never report demo
   numbers.**
3. Set `DEMO = False`, upload `training_readings.csv`, and run all.
4. **Optional transfer learning:**
   - Cut a public recording into switch-on windows with
     `sessions_from_recording`, save it as `PUBLIC_CSV`, and run again.
   - **iAWE** (1 Hz plug meters with V, I, P, apparent power and phase angle,
     so PF = P/S) is the best match. Load it with NILMTK.
   - **ACS-F2** has 225 appliances in 15 categories, but reads every 10 s.
     It is useful for steady levels only.
   - **ECO** and **UK-DALE** plugs record power only. Set
     `PUBLIC_HAS_PF = False`: the PF branch is then re-initialised before
     fine-tuning.
   - Fine-tuning runs in two stages: first only the dense layers for 20
     epochs, then all layers at 1e-4.
5. Download `embedder.json` and copy it to
   `supabase/functions/_shared/model/embedder.json`. Then run
   `node --test supabase/tests/embedder.test.ts`; its parity test checks that
   the TypeScript runtime reproduces Keras. Redeploy `identify-appliance` and
   `confirm-appliance`.
6. **Model upgrades:**
   - Every export has a new `version`.
   - Stored raw windows are re-embedded automatically, once per sample
     (`ensureEmbeddings`).
   - Old embeddings stay in the table under their version.

## 7. Databank (PostgreSQL)

```
appliance_types (Fan) 1─* appliance_instances (Fan 1, Fan 2; own max_runtime_mins, last_outlet)
appliance_instances 1─* signature_samples (≤ 20 per mode: P, I, PF, Q, CV, peak + window_signal jsonb)
signature_samples 1─* signature_embeddings (one per model_version, real[16])
outlets (outlet_1, outlet_2) 1─0..1 active_sessions *─0..1 appliance_instances
identification_events: every decision + the user's or researcher's label (evaluation and training)
```

Exclusivity and safety are enforced by the database, not only by the code
(`active_sessions`):

```sql
unique (device_id, outlet),          -- one load per outlet
unique (instance_id),                -- an instance is active on at most one outlet
check ((instance_id is not null) = (state in ('CONFIDENT', 'CONFIRMED'))),
check (state in ('CONFIDENT', 'CONFIRMED') or cutoff_s <= 1800)   -- unconfirmed: ≤ 30 min
```

## 8. Matching

```
INPUT  signal s (32 × [P, I, PF]) and features x of the new load on outlet o
IF a model is deployed AND every instance has ≥ 1 sample with a recorded window:
    q ← embed(s)                                   # 16 numbers, unit length
    FOR each instance j, each mode m:  D_jm ← mean of the 3 smallest ‖q − e‖ over j's mode-m embeddings
    T1, T2, tie ← the model's validation thresholds
ELSE:
    D_jm ← feature k-NN (appliance-identification.md, section 4); per-mode T1, T2; tie = 0.5
D_j ← min over modes
EXCLUDE every j active on another outlet           # outlet exclusivity
    if an excluded j has D_j ≤ T2: suggest "Register as <type of j> <next number>?"
best b ← nearest remaining
IF none or D_b > T2                                → UNKNOWN    (no pairing: register new; 30 min cutoff)
ELSE IF D_b > T1                                   → AMBIGUOUS  (pre-select b; 30 min)
ELSE IF another c with D_c ≤ T1 and D_c − D_b < tie → AMBIGUOUS  (identical units: pre-select the one
                                                                   last seen on o; 30 min)
ELSE                                               → CONFIDENT  (b, with b's own cutoff)
```

**Thresholds from validation data** (notebook, section 8):
- *Genuine* distance: a validation window to its own class in the databank.
- *Impostor* distance: a window to the nearest **other** class. This is how
  close a different, possibly unregistered, appliance gets.
- **T1 = 1st percentile of impostor distances.** At most about 1 % of other
  appliances fall within T1. This bounds confident mislabels, which are the
  dangerous error because they apply the wrong cutoff.
- **T2 = 95th percentile of genuine distances**, and at least T1 + 0.05. 95 %
  of runs of a registered appliance are at least offered as a candidate.
- **Tie margin = 0.25 × T1.**
- The notebook plots both distributions with T1 and T2; use the figure in
  the thesis.

**Never mixing distances.** The embedding is used only when **every**
instance on the device has a recorded window. Migrated appliances have only
summary values until the user first confirms them, and until then the whole
device stays on the feature k-NN.

**Identical units** (honest limitation, as the base study advises caution):
- Two units of the same model fall within meter noise of each other. The
  embedding cannot separate them, and the system does not claim to.
- It decides, in order, by:
  1. Exclusivity: Fan 1 is on Outlet A, so this one is Fan 2.
  2. The last-known outlet, to pre-select a unit.
  3. A one-tap confirmation from the user.

**Safety rule:**
- AMBIGUOUS and UNKNOWN loads always get the conservative 30 min cutoff,
  never a candidate's limit, until the user confirms.
- The plug applies a server cutoff only if it is *shorter* than its own
  deadline.
- Overcurrent and power-anomaly trips are always local.

**Continuous learning.** Only user-confirmed runs add a sample (the newest
20 per mode are kept). Auto-labels never train the databank.

## 9. Deployment: on the ESP32 or in the Edge Function?

| | (a) TFLite Micro on the ESP32, send the embedding | (b) send the raw window, the Edge Function runs the model (**recommended**) |
|---|---|---|
| ESP32 memory | The sketch already uses **87 % of program flash** (1,151,788 of 1,310,720 bytes, default partition; measured 2026-10-29). The TFLM library (~100–200 KB) would not fit without switching to the "Huge APP" partition, which gives up OTA updates. It also needs a tensor arena (~10–20 KB RAM), next to two TLS clients (Firebase and Supabase) | + about 1.2 KB of buffers (two 32-reading windows), and no new library |
| Model updates | reflash every plug | replace `embedder.json` and redeploy once |
| Latency | ~ms on the device, plus the same upload | upload ≈ 0.3–1 s; inference < 5 ms. Both are negligible next to the 32 s window |
| Free-tier use | one request per switch-on either way | one request per switch-on (~1 KB). 2 outlets × 30 switch-ons a day ≈ 1,800 a month per plug, far below the 500,000 free invocations a month |
| Offline | the embedding is ready but matching needs the databank anyway | no identification, and the plug keeps its own limits; the same as (a), since the databank is in Supabase |
| Retraining data | windows must also be uploaded | every window is already stored (`identification_events`) |
| Explainability | two runtimes (C++ and Python) | one small TypeScript file, checked against Keras by parity vectors |

**Recommendation: (b).**
- Matching needs the server-side databank anyway, so on-device inference
  gains nothing.
- It keeps the ESP32 firmware and memory almost unchanged, and allows
  retraining without reflashing.
- The notebook still exports float32 and int8 `.tflite` files, so (a)
  remains an option for future work. Those files contain the network up to
  the 16 numbers; the unit-length step is then done in C.

## 10. ESP32 firmware

Outline per outlet (FreeRTOS tasks: `meters`, `firebase`, `supabase`):

1. **Read:** both PZEM-004T modules about once a second, on two UARTs
   (Serial2 on GPIO 32/33, Serial1 on 25/26). For one shared UART with
   Modbus addresses 0x01 and 0x02, see appliance-identification.md, section 5.
2. **Detect:** `handleSensor()` starts a run when P > 3.5 W, and
   `window.begin()` opens the window.
3. **Buffer:** `SignatureWindow::add()` stores one reading per second in
   `SignatureSignal` (32 × P, I, PF). In parallel, it computes the 35 s
   steady summary (Welford) for the feature fallback.
4. **Send:** `queueFeatures()` hands both to the `supabase` task, which
   POSTs them to `identify-appliance`. The event ID is the boot session +
   outlet + start time, so retries are idempotent.
5. **Apply:** the reply's `cutoffS` is queued back, and `loop()` shortens the
   deadline if the reply is shorter.

```cpp
// signature_window.h: the first readings of a run as the model sees them
struct SignatureSignal {
  static constexpr uint32_t N = 32;
  float power[N], current[N], pf[N];
  uint32_t n;
};
// in SignatureWindow::add(), once per second from switch-on:
if (s.n < SignatureSignal::N && (!s.n || now - lastSignal >= READING_MS)) {
  s.power[s.n] = power; s.current[s.n] = current; s.pf[s.n] = powerFactor; ++s.n;
  lastSignal = now;
}
// sendSupabase(): "signal": {"power": [...], "current": [...], "pf": [...]} at meter resolution
```

Serial Monitor shows
`Signature: 57.2 W, ... (31 readings, signal 32 s)`, then
`Identified CONFIDENT: cutoff 14400 s`.

## 11. App flow

The Flutter screens are **not built yet**. The backend replies and the
`active_sessions` rows they read are in place. Screens and prompts:

| State | Screen | Prompt / actions |
|---|---|---|
| Recognising (0–35 s) | outlet card with a progress ring | "Recognising appliance… 30 min safety limit for now" |
| CONFIDENT | the card shows "Fan 1" and its limit | a small link "Not Fan 1?" opens the AMBIGUOUS sheet |
| AMBIGUOUS | bottom sheet | "Which appliance is on Outlet B?" Up to 3 candidates, the suggested one pre-selected. **Register new appliance** · **Ask me later**. Banner: "Using a 30 min safety limit until you choose" |
| AMBIGUOUS, identical units | the same sheet | "Fan 1 and Fan 2 look identical to WisePlug. It was last on Outlet B, so we chose Fan 2." One tap to confirm |
| UNKNOWN (no pairing) | "New appliance on Outlet B" | type (existing or new) → name, pre-filled "Fan 2" → safe operating time, pre-filled from the type → **Register** · **Not now** (keeps 30 min) |
| UNKNOWN with `registerAs` | the same sheet | "Looks like Fan 1, which is running on Outlet A. Register as Fan 2?" **Register as Fan 2** · **Something else** |
| Confirmed | snackbar | "Saved. WisePlug recognises Fan 2 better each use." The app sends the limit to the plug |

Every button calls `confirm-appliance`. Its body is
`{ action: "confirm", instanceId }` or
`{ action: "register", typeName, name?, maxRuntimeMins? }`.

## 12. Test plan

Automated tests use seeded noise, so the results repeat exactly:
- `node --test supabase/tests/knn.test.ts` covers the features.
- `node --test supabase/tests/embedder.test.ts` covers the embedding runtime
  and matching.

On hardware, repeat each scenario 10 times, then record the outcome and
cutoff from Serial Monitor and `identification_events`.

| # | Scenario | Expected result |
|---|---|---|
| 1 | Fan registered and running on Outlet A; a 55–60 W load on B | B is **UNKNOWN**, never "Fan"; prompt "Register as Fan 2?"; 30 min cutoff. With A idle, the same load on A is **CONFIDENT Fan** |
| 2 | 57 W fan (PF ≈ 0.92) and 57 W LED driver or charger (PF ≈ 0.55–0.6) | each identified as itself. With only the fan registered, the other is **UNKNOWN**. The PF branch and the start-up shape separate them |
| 3a | Two identical fans registered, both idle, one plugged into B | **AMBIGUOUS** ("look identical"), pre-selects the fan last seen on B; 30 min |
| 3b | Fan 1 running on A, the other fan plugged into B | **CONFIDENT Fan 2**, with Fan 2's cutoff (exclusivity decides) |
| 4 | Fan learned at speed 1, first run at speed 3 | not CONFIDENT. After confirming "Fan", speed 3 becomes a new mode; later runs at either speed are **CONFIDENT** |
| 5 | Sensor noise: the same appliance, 20 runs on different days and outlets | ≥ 90 % CONFIDENT, **0 wrong CONFIDENT** |
| 6 | Unconfirmed load near an appliance with an 8 h limit | the cutoff stays 30 min |
| 7 | Held-out appliance (group E) never registered | **UNKNOWN** (or AMBIGUOUS), never CONFIDENT |
| 8 | Server unreachable | no identification; the plug keeps its own learned or conservative limit and the local trips |
| 9 | Model deployed, one migrated appliance without a window | the device stays on the feature k-NN (`method = features` in `identification_events`) until it is confirmed once |

## 13. Evaluation metrics

Each metric is computed by the notebook (section 9) on validation and test
data, and on hardware from `identification_events` (prediction) against
`confirmed_instance_id` or `label_appliance` (truth).

- **Accuracy:** correct labels / runs of registered appliances, in the
  closed set (nearest class) and the open set (correct CONFIDENT).
- **Precision, recall and F1 per appliance:**
  - Precision_j = TP_j/(TP_j+FP_j)
  - Recall_j = TP_j/(TP_j+FN_j)
  - F1 = 2PR/(P+R)
  - Also report the macro averages.
- **Confusion matrix:**
  - closed set
  - open set, with an extra column "asked the user" for AMBIGUOUS and
    UNKNOWN
- **Unknown-appliance detection rate:** leave-one-appliance-out (remove all
  modes of one appliance from the databank, then run its windows). Report
  the share that is UNKNOWN, the share that is UNKNOWN or AMBIGUOUS, and the
  share wrongly CONFIDENT.
- **Safety metric:** runs where an unconfirmed load received another
  appliance's cutoff. The target is 0, and the database constraint enforces
  it.
- **User burden:** the share of runs auto-labelled vs prompted.
- **Comparison table:** MPS-CNN vs LSTM vs CNN-LSTM vs features k-NN, giving
  parameters, ms per window, accuracy, macro-F1 and unknown detection.

ISO/IEC 25010:
- *functional correctness*: accuracy and F1
- *fault tolerance*: scenario 8
- *time behaviour*: the identification delay of 32 s plus the upload
- *safety*: the safety metric

## 14. References (verify each in Google Scholar)

- Matindife, L., Sun, Y., & Wang, Z. (2020). A machine-learning based nonintrusive smart home appliance status recognition. *Mathematical Problems in Engineering*, 2020, 9356165. https://doi.org/10.1155/2020/9356165
- Schroff, F., Kalenichenko, D., & Philbin, J. (2015). FaceNet: A unified embedding for face recognition and clustering. *Proc. IEEE CVPR*, 815–823. (triplet loss, embedding + distance threshold)
- Hermans, A., Beyer, L., & Leibe, B. (2017). In defense of the triplet loss for person re-identification. *arXiv:1703.07737*. (batch-hard mining)
- Weinberger, K. Q., & Saul, L. K. (2009). Distance metric learning for large margin nearest neighbor classification. *Journal of Machine Learning Research*, 10, 207–244.
- Scheirer, W. J., de Rezende Rocha, A., Sapkota, A., & Boult, T. E. (2013). Toward open set recognition. *IEEE TPAMI*, 35(7), 1757–1772.
- Bendale, A., & Boult, T. E. (2016). Towards open set deep networks. *Proc. IEEE CVPR*, 1563–1572.
- De Baets, L., Develder, C., Dhaene, T., & Deschrijver, D. (2019). Detection of unidentified appliances in non-intrusive load monitoring using siamese neural networks. *International Journal of Electrical Power & Energy Systems*, 104, 645–653.
- Pan, S. J., & Yang, Q. (2010). A survey on transfer learning. *IEEE Transactions on Knowledge and Data Engineering*, 22(10), 1345–1359.
- Yosinski, J., Clune, J., Bengio, Y., & Lipson, H. (2014). How transferable are features in deep neural networks? *Advances in Neural Information Processing Systems*, 27.
- David, R., Duke, J., Jain, A., et al. (2021). TensorFlow Lite Micro: Embedded machine learning for TinyML systems. *Proceedings of Machine Learning and Systems*, 3, 800–811.
- Warden, P., & Situnayake, D. (2019). *TinyML: Machine learning with TensorFlow Lite on Arduino and ultra-low-power microcontrollers*. O'Reilly.
- Batra, N., Gulati, M., Singh, A., & Srivastava, M. B. (2013). It's different: Insights into home energy consumption in India. *Proc. ACM BuildSys '13*. (iAWE dataset)
- Ridi, A., Gisler, C., & Hennebert, J. (2014). ACS-F2: A new database of appliance consumption signatures. *Proc. SoCPaR 2014*, 145–150.
- Ridi, A., Gisler, C., & Hennebert, J. (2014). A survey on intrusive load monitoring for appliance recognition. *Proc. ICPR 2014*, 3702–3707.
- Beckel, C., Kleiminger, W., Cicchetti, R., Staake, T., & Santini, S. (2014). The ECO data set and the performance of non-intrusive load monitoring algorithms. *Proc. ACM BuildSys '14*, 80–89.
- Kelly, J., & Knottenbelt, W. (2015). The UK-DALE dataset, domestic appliance-level electricity demand and whole-house demand from five UK homes. *Scientific Data*, 2, 150007.
- Batra, N., Kelly, J., Parson, O., et al. (2014). NILMTK: An open source toolkit for non-intrusive load monitoring. *Proc. ACM e-Energy '14*, 265–276.
- Hart, G. W. (1992). Nonintrusive appliance load monitoring. *Proceedings of the IEEE*, 80(12), 1870–1891.
- Sokolova, M., & Lapalme, G. (2009). A systematic analysis of performance measures for classification tasks. *Information Processing & Management*, 45(4), 427–437.
- ISO/IEC 25010:2023. Systems and software engineering — SQuaRE — Product quality model.

## 15. Deploying

```
npx supabase db push        # both 20261029… migrations
npx supabase functions deploy identify-appliance confirm-appliance log-session
```

Then upload the sketch. Until a trained `embedder.json` replaces the
placeholder, everything runs on the feature k-NN. The plug already uploads
its windows, so the data collection (section 5) can start immediately.
