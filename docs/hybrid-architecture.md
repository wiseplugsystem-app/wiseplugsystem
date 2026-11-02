# WisePlug hybrid backend: Firebase RTDB + Supabase (free tiers only)

WisePlug splits its backend in two, each part doing what its free plan does well:

| Layer | Service (free plan) | Holds | Why |
|---|---|---|---|
| Live layer | Firebase Realtime Database (Spark) | Live readings, relay state, commands | Pushes every change to the app over a WebSocket |
| Permanent layer | Supabase Postgres (Free) | Appliance profiles, session history, alert logs | SQL queries, charts, foreign keys, Row Level Security |
| Server logic | Supabase Edge Functions (Free) | Signature matching, session logging, safety alerts + push | Firebase Cloud Functions need the paid Blaze plan |
| Push | Firebase Cloud Messaging (free) | Safety notifications | Sent from an Edge Function with the FCM HTTP v1 API |
| Login | Firebase Auth (free) | One account for everything | Supabase accepts Firebase ID tokens (third-party auth) |

**Safety stays on the plug.** The ESP32 firmware recognizes appliances, runs the
7-use learning phase, enforces runtime limits and trips on overcurrent by itself,
with or without internet. The cloud records and explains what the plug did and
notifies the owner; it never decides whether a relay switches off.

## 1. Architecture and data flow

```text
                 every 1 s: telemetry_logs/* (control, countdowns)
                 every 3 s: devices/gadget-1/live_telemetry/outlet_1|2
 ┌───────────────────┐        PATCH (REST)        ┌──────────────────────────────┐
 │ ESP32  "gadget-1" │ ─────────────────────────► │ Firebase Realtime Database   │
 │  PZEM-004T  x2    │ ◄───────────────────────── │  (Spark, free)               │
 │  relay      x2    │   commands/outlet_A|B      └──────────────┬───────────────┘
 │  safety logic     │   (ON/OFF, override, reset)    WebSocket   │ ▲ commands
 └─────────┬─────────┘                              live updates  ▼ │
           │                                             ┌──────────────────────┐
           │ HTTPS POST, once per event:                 │ Flutter app          │
           │  • run ended   → log-session                │  live dashboard,     │
           │  • warning/trip → evaluate-safety-alert     │  audio alarm,        │
           ▼   (x-device-key)                            │  history charts      │
 ┌───────────────────────────────┐   Firebase ID token   └───┬──────────────▲───┘
 │ Supabase Edge Functions (Deno)│ ◄──────────────────────────┘              │
 │  match-signature  link-account│   match-signature, link-account           │
 │  log-session                  │                                           │
 │  evaluate-safety-alert ───────┼──► FCM HTTP v1 ──► push notification ─────┤
 └───────────────┬───────────────┘                                           │
                 │ service role                    SQL over HTTPS (RLS):     │
                 ▼                                 sessions, daily_energy,   │
 ┌───────────────────────────────┐                 alert_logs                │
 │ Supabase Postgres             │ ──────────────────────────────────────────┘
 │  devices  appliances          │
 │  sessions alert_logs          │
 │  push_tokens  daily_energy    │
 └───────────────────────────────┘
```

| Event | Path |
|---|---|
| Live reading | ESP32 → RTDB `live_telemetry` (3 s) → app over WebSocket |
| Relay ON/OFF | App → RTDB `commands/outlet_A\|B` → ESP32 (≤1 s) → `command_results` |
| Appliance recognized | On the ESP32 (works offline); the app can ask `match-signature` too |
| Run finished | ESP32 → `log-session` → Postgres `sessions` (one row per run per outlet) |
| Warning, lockout, trip | ESP32 → `evaluate-safety-alert` → `alert_logs` + FCM push |
| History chart | App → Postgres `daily_energy` / `sessions` (RLS: owner only) |

## 2. The bridge: how data gets from the plug to Supabase

Firebase Cloud Functions (the usual "database trigger") need the Blaze plan, so
something else has to move data into Supabase. Three free options:

| Option | Works with the app closed? | Requests | Freshness | Weak point |
|---|---|---|---|---|
| **A. ESP32 posts summaries to Edge Functions** | **Yes** | **1 per session / alert** | Instant | Firmware must speak HTTPS to a second host |
| B. Flutter app posts on state changes | No: only while open | 1 per session | Instant | Missed sessions; two phones double-post; device key would sit in the app |
| C. `pg_cron` polls RTDB every minute | Yes | 43,200 / month | ≤ 1 min | Misses runs shorter than a minute; Firebase database secret stored in Supabase |

**Chosen: A.** The plug is the one place that knows exactly when each run
starts and ends, and it already queues events while offline (like its
`activity_log` uploads). It sends a small summary once per finished run, never
per-second ticks. Retries are safe: Postgres keeps one row per
(device, outlet, start time) and one alert per event ID, so a repeated upload
is ignored.

## 3. Firebase Realtime Database

### 3.1 Live telemetry (new; written by the ESP32 every 3 s)

```json
"devices": {
  "gadget-1": {
    "live_telemetry": {
      "outlet_1": {
        "deviceId": "gadget-1", "outlet": "outlet_1",
        "timestamp": "2026-10-22T08:00:03Z", "timestamp_ms": 1792656003000,
        "relayOn": true, "state": "ACTIVE", "appliance": "Rice Cooker",
        "status": "OK",
        "voltage_V": 229.8, "current_A": 2.612, "power_W": 598.4,
        "powerFactor": 0.99, "frequency_Hz": 60.0, "energy_Wh": 12345.0
      },
      "outlet_2": {
        "deviceId": "gadget-1", "outlet": "outlet_2",
        "timestamp": "2026-10-22T08:00:03Z", "timestamp_ms": 1792656003000,
        "relayOn": false, "state": "DISABLED", "appliance": "None",
        "status": "NO_SIGNAL"
      }
    }
  }
}
```

**Sanitation**, done on the plug and again in the app (`TelemetryReading.fromMap`):

- A meter that is not reporting (no mains, loose wire, stale) is
  `"status": "NO_SIGNAL"` with **no values**, never fake zeros.
- Below 0.5 W is meter noise: power, current and power factor are stored as 0.
- Frequency outside 45–65 Hz, or a negative energy counter, is dropped alone.
- The node is replaced every 3 s, so a value that turns invalid disappears.

`energy_Wh` is the meter's lifetime counter. Usage per session is computed by the
plug (power integrated 5 times a second) and stored in Postgres.

### 3.2 Device status (written by the ESP32 every second)

```json
"status": {
  "connectionStatus": "Online", "lastSeen": 1792656003000, "wifiSSID": "HomeWiFi",
  "powerDraw": 598.4, "safetyTriggered": false, "remainingLimit": 2105.0,
  "outletA": true, "outletB": false,
  "outlet_1": { "relayOn": true,  "state": "ACTIVE",   "appliance": "Rice Cooker" },
  "outlet_2": { "relayOn": false, "state": "DISABLED", "appliance": "None" }
}
```

`outletA`/`outletB` are kept for the existing screens; `outlet_1`/`outlet_2` are
the per-channel objects.

### 3.3 Security rules

In [`database.rules.json`](../database.rules.json): everything is closed by
default (`".read": false, ".write": false`). Only the signed-in owner of both
outlets (`device_owners`) can read `live_telemetry`, `status` and the rest, and
can only write commands that match the plug's current session and revision.
The ESP32 writes with the database secret, which bypasses rules; that secret
lives only in `secrets.h` on the device.

## 4. Supabase Postgres

Script: [`supabase/migrations/20261022000000_wiseplug_schema.sql`](../supabase/migrations/20261022000000_wiseplug_schema.sql).
Seed: [`supabase/seed.sql`](../supabase/seed.sql).

| Table | One row per | Key points |
|---|---|---|
| `devices` | plug (`gadget-1`) | `owner_uid` = Firebase uid, set by `link-account` |
| `appliances` | appliance profile | Signature bounds, `max_runtime_mins`, learning state mirrored from the plug |
| `sessions` | finished run per outlet | `outlet` ∈ `outlet_1`/`outlet_2`; unique (device, outlet, start) |
| `alert_logs` | safety event | Unique `event_id`; severity, baseline ratio, push count |
| `push_tokens` | phone | FCM token of each app install |
| `daily_energy` (view) | outlet per day | For charts, in Philippine time |

**Row Level Security**: every table has RLS on. Signed-in users can only *read*
rows of devices they own, and manage their own push tokens. Nobody but the Edge
Functions (service role) can write profiles, sessions or alerts. Anonymous
requests get nothing. This was checked on a real Postgres engine (PGlite):
a stranger sees zero rows, the owner sees both outlets, and a direct insert is
refused.

### Appliance signatures

Profiles belong to the **device** (`appliances.device_id`), not to an outlet,
so a profile calibrated on `outlet_1` is matched on `outlet_2` and vice versa
(the firmware does the same with both outlets' catalogs).

Each profile stores every PZEM-004T quantity
([migration 20261023](../supabase/migrations/20261023000000_multi_parameter_signatures.sql)):

| Quantity | Columns | Source |
|---|---|---|
| Active power P (W) | `min_power`, `target_power`, `max_power` | measured |
| Current I (A) | `min_current`, `target_current`, `max_current` | measured |
| Power factor PF | `min_pf`, `target_pf`, `max_pf` | measured (null if unknown) |
| Apparent power S (VA) | `min_apparent_power`, `max_apparent_power` | generated: P / PF |
| Reactive power Q (VAR) | `min_reactive_power`, `max_reactive_power` | generated: P · tan(acos PF) |

S and Q are generated columns, so they can never disagree with P and PF. A
trigger fills targets from the bounds when a writer leaves them out, and check
constraints keep min ≤ target ≤ max (PF columns all set or all empty).

Seed signatures (typical 230 V ranges; the plug still learns each real appliance):

| Appliance | Power (W) min / target / max | Current (A) | PF | Max runtime |
|---|---|---|---|---|
| Electric Fan | 35 / 55 / 75 | 0.16 / 0.25 / 0.34 | 0.85 / 0.95 / 1.00 | 8 h |
| Rice Cooker | 450 / 600 / 750 | 1.95 / 2.62 / 3.30 | 0.95 / 1.00 / 1.00 | 90 min |
| Flat Iron | 900 / 1100 / 1300 | 3.90 / 4.80 / 5.70 | 0.95 / 1.00 / 1.00 | 60 min |
| Electric Kettle | 1500 / 1750 / 2000 | 6.50 / 7.70 / 8.90 | 0.95 / 1.00 / 1.00 | 15 min |
| LED TV | 40 / 75 / 110 | 0.25 / 0.475 / 0.70 | 0.45 / 0.60 / 0.75 | 6 h |
| Laptop/Phone Charger | 5 / 45 / 90 | 0.04 / 0.345 / 0.65 | 0.30 / 0.55 / 0.80 | 5 h |
| Refrigerator | 80 / 140 / 200 | 0.45 / 0.825 / 1.20 | 0.60 / 0.75 / 0.90 | 24 h |

A kettle above 2.2 kW is not listed because the plug's 10 A hardware limit
would trip it. The seed ranges are deliberately broad references; the charger's
in particular overlaps many small low-PF loads (see §5.1).

## 5. Edge Functions

Code in [`supabase/functions/`](../supabase/functions). Shared logic in
`_shared/` (matching and safety rules are plain TypeScript, unit-tested with
`node --test supabase/tests/shared.test.ts`). New profiles get the firmware's
own learning bands (power ±15 %, current ±20 %, power factor ±0.10).

### 5.1 The matching algorithm (`_shared/signature.ts`)

1. **Filter.** Live P, I and PF must lie inside the profile's bounds, plus a
   small offset for meter accuracy (P: 1 % or 0.5 W, I: 1 % or 5 mA, PF: 0.02).
2. **Score.** For each quantity, similarity = 1 − d², where d is the distance
   from the target as a fraction of the band (0 on target, 1 at the edge).
   Composite = 0.40·P + 0.30·I + 0.20·PF + 0.10·Q. Reactive power comes from
   S = V × I (or P / PF without voltage) and Q = √(S² − P²). A quantity that is
   unavailable drops out and the other weights are rescaled.
3. **Cutoff.** The best profile is returned only at **≥ 88 %** confidence
   (secret `MATCH_THRESHOLD`, 0–1). Otherwise the reply is
   `unrecognized_device`, and the app may start a registration.

Measured on the unit tests' profiles:

| Reading | Result |
|---|---|
| Desk fan 52 W, 0.24 A, PF 0.94 | fan 98.3 % → matched |
| Drill at light load 52 W, 0.36 A, PF 0.63 | drill 99.0 % (charger 94.3 %, TV 71.3 %) → matched; fails the fan's PF bounds |
| Fan with normal drift 56 W, 0.255 A, PF 0.94 | fan 99.2 % → matched |
| Edge of every fan band 73 W, 0.33 A, PF 0.87 | fan 39.1 % → `unrecognized_device` |

Same wattage, different appliance: current, PF and Q separate them. The
charger's 94.3 % for the drill shows the limit of broad seed ranges: without a
learned drill profile it would have been labelled a charger. Learned profiles
(±15 % bands) are far tighter, and `candidates` in each reply lists the top
three scores so a close second is visible.

| Function | Caller | Does |
|---|---|---|
| `match-signature` | App or ESP32 | Scores the reading against every profile of the device (§5.1). Returns `matched` (learned), `learning` (in its first 7 uses), or `unrecognized_device` below 88 %. With `register`, saves a new profile **only if unrecognized**; otherwise `409 duplicate`. |
| `log-session` | ESP32 | Stores a finished run for `outlet_1` or `outlet_2` and copies the plug's learning progress (uses so far, learned average) onto the profile. |
| `evaluate-safety-alert` | ESP32 | Rates the event against the adaptive baseline (e.g. "ran 60 min; typical use 30 min, learned from 7 uses" is critical at 2×), logs it once, pushes it with FCM HTTP v1 and removes dead tokens. |
| `link-account` | App, after sign-in | Claims the device for the Firebase user and adds the `role: authenticated` claim Supabase needs (see §6). |

Example: `match-signature`

```json
// request (from either outlet)
{ "deviceId": "gadget-1", "outlet": "outlet_2", "voltage": 229.8,
  "power": 52.0, "current": 0.24, "powerFactor": 0.94 }
// reply
{ "status": "learning", "outlet": "outlet_2", "confidence": 98.3, "threshold": 88,
  "scores": { "power": 97.9, "current": 98.9, "pf": 99.3, "reactive": 96.3 },
  "reading": { "apparentPower": 55.2, "reactivePower": 18.4 },
  "candidates": [{ "name": "Electric Fan", "confidence": 98.3 }],
  "appliance": { "name": "Electric Fan", "learning": { "sessionCount": 3, "required": 7, "usesLeft": 4 } } }
```

## 6. One login for both services

Users sign in **only with Firebase Auth** (the existing sign-in screen).

1. Supabase **Third-Party Auth** is set to trust the Firebase project. The app
   gives Supabase the Firebase ID token as its access token
   (`Supabase.initialize(accessToken: ...)`), and RLS reads the Firebase uid
   from `auth.jwt() ->> 'sub'`.
2. Supabase only applies the `authenticated` role when the token carries
   `role: "authenticated"`. `link-account` adds that claim once with the
   Firebase admin API (free) and the app refreshes its token.
3. Edge Functions verify the Firebase token themselves against Google's public
   keys, so they work even before the claim exists.

There is no second password, no account syncing, and nothing extra to explain
at the defense: "Firebase is our identity provider; Supabase trusts it."

### Staying logged in (in plain words)

- **You log in once.** The app remembers you on this phone. Next time you open
  it, even after restarting the phone, it goes straight to your WisePlug.
- **No internet?** You stay logged in. You are only asked to log in again
  once the internet is back, and only if your account really changed (for
  example, your password was changed on another phone, or the account was
  deleted).
- **Sign out** (Settings or Profile → Sign out): this phone stops getting your WisePlug's
  safety alerts, and the app shows the log-in screen again. If there is no
  internet at that moment, you are still signed out at once; the alerts stop
  reaching this phone after the next alert.

How it works: Firebase Auth keeps the login on the phone (Keychain on iPhone,
the app's private storage on Android, the browser's storage on the web) and
refreshes the hour-long access token by itself; Supabase asks for that token
on every request (`accessToken: getIdToken()`), so it never keeps a separate
login. `AuthGate` (`lib/screens/auth_gate.dart`) follows Firebase's login
state. Every Sign out button goes through `SessionService.signOut()`
(`lib/services/session_service.dart`): it removes this phone's notification
token from Firebase (`users/<uid>/fcmTokens`) and Supabase (`push_tokens`),
deletes it on the phone, then logs out. Each step gives up after 5 s, so it
never hangs without internet. Tests: `test/session_test.dart`.

On the web build the login is kept per browser: clearing the site's data logs
you out. Showing the last known readings while the phone is offline is a
separate item (it needs the app's offline storage).

## 7. Setup, step by step

All commands run in PowerShell in the project folder. `npx supabase` runs the
Supabase CLI without installing it.

### 7.1 Create the Supabase project
1. Sign up at [supabase.com](https://supabase.com) (GitHub login; no card needed) and create a
   project in region **Southeast Asia (Singapore)**. Save the database password.
2. Note from **Project Settings → API**: the project URL and the publishable (anon) key.

### 7.2 Create the tables and seed data
```powershell
npx supabase login
npx supabase link --project-ref YOUR-PROJECT-REF
npx supabase db push --include-seed
```
Or paste the migration file, then `seed.sql`, into **SQL Editor → Run**.

### 7.3 Trust Firebase logins
In the Supabase dashboard open **Authentication → Third-Party Auth** (under the
Authentication section; the exact menu name can shift between dashboard
versions), choose **Add provider → Firebase Auth** and enter the project ID
`wise-46f92`.

### 7.4 Store the secrets
```powershell
# Device key: the ESP32 sends it with every report.
$key = node -e "console.log(require('crypto').randomBytes(24).toString('base64url'))"
npx supabase secrets set DEVICE_KEY=$key FIREBASE_PROJECT_ID=wise-46f92
$key   # copy this into secrets.h

# Firebase service account (console → Project settings → Service accounts →
# Generate new private key), stored base64-encoded so PowerShell cannot mangle it.
$sa = [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\keys\wise-service-account.json"))
npx supabase secrets set FIREBASE_SERVICE_ACCOUNT_B64=$sa
```
Secrets are encrypted in Supabase and only visible to the Edge Functions. Keep
the JSON key file outside the project folder.

### 7.5 Deploy the functions
```powershell
npx supabase functions deploy match-signature log-session evaluate-safety-alert link-account
```
`supabase/config.toml` turns off the gateway's Supabase-JWT check because each
function checks its caller itself.

### 7.6 The ESP32
In `arduino/wiseplug_esp32/secrets.h` (see `secrets.example.h`):
```cpp
#define SUPABASE_FUNCTIONS_URL "https://YOUR-PROJECT-REF.supabase.co/functions/v1"
#define SUPABASE_DEVICE_KEY "the DEVICE_KEY from 7.4"
```
Upload the sketch. Without these two lines it builds and runs as before,
Firebase only.

### 7.7 The app
```powershell
firebase deploy --only database --project wise-46f92
flutter run -d chrome
```
The project URL and publishable key are the defaults in
`lib/services/supabase_backend.dart` (the publishable key is public by design;
RLS protects the data). To use another project, pass
`--dart-define=SUPABASE_URL=...` and `--dart-define=SUPABASE_KEY=...`; empty
values run the app Firebase-only. Dart entry points:

- `Esp32Service.streamLiveTelemetry(OutletChannel.outlet1)`: `Stream<TelemetryReading>`
  for the live UI (the existing `SafetyAlertListener` plays the alarm sound).
- `SupabaseBackend().matchSignature(...)`, `.registerAppliance(...)`
- `SupabaseBackend().sessions(OutletChannel.outlet2)`, `.dailyEnergy(...)`, `.alerts()`

### 7.8 Keep the project awake
Free projects pause after 7 days without activity. Daily use of the plug keeps
it awake; for idle weeks (holidays), add `SUPABASE_URL` and `SUPABASE_KEY` as
repository secrets on GitHub (**Settings → Secrets and variables → Actions**).
The workflow `.github/workflows/supabase-keepalive.yml` then calls a harmless
`keepalive()` function every 3 days. GitHub disables scheduled workflows in
repositories with no commits for 60 days; re-enable it from the Actions tab if
needed. A paused project can also be restored from the dashboard in a minute.

## 8. Staying inside the free plans

| Limit (free) | WisePlug usage |
|---|---|
| RTDB: 1 GB stored, 10 GB/month downloaded, 100 connections | Live node is overwritten, never grows; one app ≈ 2 KB per update |
| Supabase DB: 500 MB | A session row is ~300 B: 10,000 sessions ≈ 3 MB |
| Edge Functions: 500,000 calls/month | ~1 call per session or alert: a few hundred per month |
| FCM | Free, no limit for this use |
| Supabase pause after 7 idle days | Plug traffic + keep-alive workflow |

## 9. What was verified, and what was not

| Part | Checked how |
|---|---|
| Matching and safety rules | 8 Node unit tests (`node --test supabase/tests/`) |
| SQL schema, seed, RLS | Ran on PGlite (Postgres 16): owner/stranger/anon access, duplicates, constraints |
| Edge Functions | `deno check` and `deno lint` pass |
| Dart models and services | `flutter analyze`; unit tests in `test/hybrid_models_test.dart` |
| ESP32 firmware | **Not compiled here** (no Arduino toolchain). Verify in the Arduino IDE. |
| Live end-to-end | Needs your Supabase project, secrets and the flashed plug |
