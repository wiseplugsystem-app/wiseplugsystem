# WisePlug bridge audit (Phase 1, no code changed)

Date: 2026-11-11. Scope: firmware `arduino/wiseplug_esp32/`, `database.rules.json`,
`functions/`, the Flutter app `lib/`, `supabase/` (migrations and Edge Functions).

## 0. Symptoms and hardware used for this audit

The symptoms and hardware sections of the brief were blank, so this audit uses
what was found while testing on 2026-11-09 to 2026-11-11:

| # | Symptom | Seen in |
|---|---|---|
| S1 | Both meters silent: `PZEM not responding (V=0.0)` on both outlets, `pin_finder` finds nothing on any pin | Serial Monitor |
| S2 | On the HLK-5M05 alone the ESP32's red light blinks, then goes off. It lights only when the 5V wire is touched or moved | By eye |
| S3 | One crash and self-restart: `Backtrace … Rebooting…`, reset reason 4 (crash) | Serial Monitor, 17:45 |
| S4 | `TURN_ON -> REJECTED_STALE` and `RESET_SAFETY -> REJECTED_STALE` right after boot | Serial Monitor |
| S5 | App shows "Meter not responding" | App |

| Part | Detail |
|---|---|
| Board | ESP32 Dev Module (ESP32-WROOM), Arduino core esp32 3.3.12 |
| Meters | 2 × PZEM-004T v3.0, 100 A version with CT |
| Switches | 2 × SSR-40DA (DC input, AC output) |
| Supply | HLK-5M05 (5 V, 1 A), with its own mains plug, wall side |
| Level shifter | None |
| Wiring (user, 2026-11-11) | PZEM A: TX → GPIO 32, RX → GPIO 33. PZEM B: TX → GPIO 25, RX → GPIO 26. SSR A → GPIO 13, SSR B → GPIO 12 |

## 1. Where the code and the brief disagree (please decide)

| # | The brief says | The code does | Question |
|---|---|---|---|
| C1 | "Accumulated runtime survives power outages and restarts" | Runtime is **not** saved. If the power goes off while an appliance runs, that outlet comes back **off and locked** ("Power cut" in the app). The user must Reset, then Turn on again. An idle outlet comes back as it was. (`setup()`, `wiseplug_esp32.ino:1504-1509`; `persistSafety()`, line 255) | Keep "lock after a power cut" (safer: nothing restarts unattended), or switch to "resume with the time already used"? |
| C2 | "Safety limit is set after 7 usage sessions; before that a default 30-minute limit applies" | 30 minutes applies until the appliance is **recognised and confirmed** by the user. From the first confirmed run it gets its **type's safe time** (normally 4 h, heating appliances 15–90 min). The 7 uses only change it to "1.5 × your usual time", never above the type's safe time. (`recognize-appliance`, `_shared/matching.ts`, `docs/how-wiseplug-works.md` Step 7) | Keep the current rule, or make every appliance stay at 30 minutes until 7 uses? |
| C3 | "Possibly DS18B20, buzzer, status LED" | None of these are in the firmware. The only extras are two optional reset buttons: Outlet A on GPIO 4, Outlet B on GPIO 5, both to GND. | Are buttons wired? If not, nothing to do. |
| C4 | "No Cloud Functions" | `functions/index.js` is a Firebase Cloud Function (push alerts), and `firebase.json` lists it. Cloud Functions need the paid Blaze plan. Push alerts are now sent by Supabase (`evaluate-safety-alert`). | Remove `functions/` and its `firebase.json` entry? (Section 5, item B10) |
| C5 | Readings, commands and heartbeats are in Firebase | Matches. | — |
| C6 | Only the affected outlet is cut off | Matches: each outlet has its own state, lockout and relay. | — |

## 2. Hardware

### 2.1 Pin map

| GPIO | Connected to (code) | Job | Safe? |
|---|---|---|---|
| 13 | SSR A input 3 (+) | Output, HIGH = outlet A on | ✅ Not a strapping pin |
| 12 | SSR B input 3 (+) | Output, HIGH = outlet B on | ⚠️ **Strapping pin (MTDI)**. If anything pulls it HIGH at power-up, the ESP32 picks 1.8 V flash and will not boot. The SSR input does not pull it high and the ESP32 pulls it low at reset, so today it is fine. Never add a pull-up. |
| 32 | PZEM A TX → ESP RX (Serial2) | UART receive | ✅ |
| 33 | ESP TX (Serial2) → PZEM A RX | UART send | ✅ |
| 25 | PZEM B TX → ESP RX (Serial1) | UART receive | ✅ |
| 26 | ESP TX (Serial1) → PZEM B RX | UART send | ✅ |
| 4 | Optional button A to GND | Input, pull-up | ✅ |
| 5 | Optional button B to GND | Input, pull-up | ⚠️ Strapping pin, but a pull-up matches its boot default. Do not hold the button while powering up. |
| 1 / 3 | USB Serial (UART0) | Serial Monitor | ✅ Not reused |

None of the following are used: GPIO 6–11 (flash), 34–39 (input-only) as outputs, analog reads.

The code matches your wiring after today's swap (`wiseplug_esp32.ino:69-70`): A = 13 + 32/33, B = 12 + 25/26.

### 2.2 Meter link (UART)

- Each PZEM has its **own UART**: A on Serial2, B on Serial1, both moved to safe pins. They don't share a bus, so Modbus addresses don't matter. Both use the default address 0xF8.
- The ports are opened twice: by the library, then again in `setup()` (line 1490).
- A silent meter has its port reopened every 5 s (line 580).

### 2.3 Voltage levels (PZEM 5 V and ESP32 3.3 V)

- The PZEM's TTL side is optically isolated, and its TX line is pulled up to whatever feeds its **5V pin**. With 5 V there, the ESP32's RX pins (32 and 25) see 5 V. **ESP32 pins are rated for 3.6 V maximum**, so this is outside the rating.
- Many hobby builds run like this for a long time, but it is a slow-damage risk.
- **I'm not certain of the exact pull-up value on your boards.** Look up "PZEM-004T v3.0 TTL interface schematic" or measure the TX pin to GND with the meter powered.
- **Free fix, often used:** feed the PZEM's TTL **5V pin from the ESP32's 3V3 pin** instead of the 5 V line. The optocouplers then work at 3.3 V, so the TX line goes up to 3.3 V only. Then test with `pin_finder`.
- **Needs your OK:** it is a wiring change.

### 2.4 SSR drive

- SSR-40DA input is usually rated **3–32 V DC**. A 3.3 V GPIO is near the bottom of that range.
- Yours switch (relay_test worked, and a fan ran on both outlets). Check the label for the exact input range: Fotek-style SSRs are often copies with a weaker real rating than the "40 A" printed.
- **No pull-down resistor.** Before `setup()` runs (about 0.3 s after power-up, and during USB flashing), GPIO 13 floats. An SSR is unlikely to turn on from a floating pin, but a 10 kΩ resistor from each SSR + input to GND makes "off at boot" certain. It costs very little, but it is a hardware addition, so **ask first**.
- **Zero-cross:** the "DA" models switch at zero-cross. That's good for fans, rice cookers and irons, and doesn't matter for the loads in scope.
- **Leakage:** an SSR that is off still leaks a few mA, so **the socket is live even when "off"**. The CT sits before the SSR, so that leak can show as about 0–1 W. It stays below the 2 W start threshold.

### 2.5 Power and ground

- **Critical (S1, S2):** the 5 V joint from HLK +Vo to the ESP32 header is loose. The same 5 V line feeds both PZEMs.
  - A loose 5 V or GND makes the ESP32 blink or reset.
  - It leaves the PZEM optocouplers unpowered, so both meters are silent on every pin. That matches S1 exactly.
- **Common ground** (HLK −Vo, ESP32 GND, both PZEM GND, both SSR 4 (−)) is required. The code can't check it.
- **Brownout:** the HLK-5M05 gives up to 1 A, and the ESP32 needs about 0.5 A peaks when Wi-Fi transmits. That's enough if the joints are good. The firmware records a brownout as `lastRestart: "brownout"` in `devices/gadget-1/status/health`.
- **Decoupling:** a 100–470 µF capacitor across 5 V and GND near the ESP32 helps on long wires. It is optional hardware, so **ask first**.
- **Mains protection:** the code can't tell if there is a **fuse** before the HLK and the outlets. Check in section 4.

### 2.6 Outlet mapping

In code, row 0 is Outlet A (SSR 13, meter on 32/33) and row 1 is Outlet B (SSR 12, meter on 25/26), and every path uses that row. Whether **meter A's CT really sits on the live wire of the socket that SSR A switches** can only be checked by eye (section 4, step 5).

### 2.7 Hardware risk list

| Sev. | Risk | Symptom |
|---|---|---|
| **Critical** | Loose 5 V (and maybe GND) joint at the ESP32 header; the same line feeds both PZEMs | S1, S2, S5 |
| **Critical** | Fuse before the HLK and sockets not confirmed | — |
| **High** | A silent meter leaves its outlet **powered with no monitoring** (see F3) | S5 |
| Medium | 5 V PZEM TX into 3.3 V ESP32 pins | possible S1 later |
| Medium | GPIO 12 (SSR B) is a strapping pin | boot failure if ever pulled high |
| Low | No pull-down on the SSR inputs | outlet blip at boot (unlikely) |
| Low | No bulk capacitor on 5 V | resets under Wi-Fi load |

## 3. Firmware

### 3.1 Libraries

- `PZEM004Tv30` (mandulaj, current).
- `ArduinoJson 7`.
- ESP32 core 3.3.12 (`WiFi`, `HTTPClient`, `WiFiClientSecure`, `WebServer`, `DNSServer`, `ArduinoOTA`, `LittleFS`).
- **No Firebase library**: plain REST over HTTPS, so the deprecated Firebase-ESP-Client isn't used. Nothing here is deprecated.

### 3.2 Structure

- **Core 1, `loop()`:** safety only. It does no network work, has `delay(10)`, and the loop watchdog is on.
- **Core 0, three tasks:**
  - `meters`: reads the PZEMs every 200 ms;
  - `firebase`: Wi-Fi, commands, publishing;
  - `supabase`: recognition, run and safety reports.
- The tasks talk only through queues, so a slow network call can't stop the meters or the cutoff timer. ✅

### 3.3 Findings

| ID | Sev. | Where | What is wrong | Link | Proposed fix |
|---|---|---|---|---|---|
| F1 | **High** | `wiseplug_esp32.ino:1420` | **The crash.** Decoded backtrace: `sntp_request → dns_gethostbyname → udp_new_ip_type → assert` (an lwIP "core not locked" check). The clock sync starts with `configTime()` at boot, while Wi-Fi is still connecting. I believe the cause is this timing; the full `assert failed: …` line would confirm it. | S3 | Start the clock sync once, when Wi-Fi first reports "online" (`updateWifi`, Connecting → Online), not at boot. The safety logic doesn't depend on the clock. |
| F2 | **High** | `firebasePatch` 784, `firebaseRequest` 767 | **Firebase sends every write back.** A REST PATCH or PUT answers with the data it wrote, and Firebase counts that as download. The once-a-second update is about 3–4.5 KB, which comes to about **8–12 GB a month** from this echo alone. The Spark plan allows **10 GB a month**; above that the database stops answering until next month. | — | Add `print=silent` to PATCH, PUT and POST (the answer becomes `204` with no body). Accept 204 as success where the code checks for 200. |
| F3 | **High** (safety rule) | `relayEnergized()` 251; `handleSensor()` 454 | An **Idle** outlet keeps its relay **on**. If its meter is silent, no run is ever detected, so there's no time limit and no over-current trip; the app only says "Meter not responding". A running outlet whose meter stops does get a warning, then a lockout 60 s later (line 1588). | S5 | Option: switch an outlet off while its meter is silent, and back on when it answers. **This changes a safety rule, so it needs your approval.** |
| F4 | Medium | `sensorTask` 564 | Each getter (`power()`, `current()`, …) retries the Modbus read when the meter is silent. That's 6 timeouts of about 100 ms each, so a silent meter slows the **other** meter's readings to about once a second. A healthy pair reads every ~0.3 s. | S1 | Read `voltage()` first and skip the other five getters when it is NaN. |
| F5 | Medium | `addLiveTelemetry` 909 | `devices/gadget-1/live_telemetry` is written every 3 s, but **no screen reads it**. `streamLiveTelemetry` and `streamAllLiveTelemetry` are never called. | — | Stop writing it, or move the app to it. Stopping saves about 0.6 KB per write plus its echo. |
| F6 | Medium | `syncLockdown` 1358 | `outlets/<o>/isLockedDown` is written and polled (a GET every second while locked), but the app never sets it; it unlocks with `RESET_SAFETY`. | — | Remove the polling, or keep it and say why. |
| F7 | Low | `addOutlet` 863-872 | The last command result and the last alert are re-sent **every second forever**: about 1 KB of the 4.5 KB. | — | Send each once, when it changes. |
| F8 | Low | firmware + rules | `alerts/`, `command_results/`, `activity_log/` and `devices/gadget-1/notifications/` only grow; nothing deletes old entries. They're small, but they never stop growing. | — | Delete command results older than a day, and keep about the last 100 log entries. |
| F9 | Low | `handleCommand` 550 | The acknowledgment has the result and revision but no server timestamp. The brief asks for one. | — | Add `at: {".sv":"timestamp"}`. |
| F10 | Info | secrets.h | The plug still uses the **database secret** (`FIREBASE_AUTH`). Anyone who reads the chip gets full database access, and the database rules don't apply to the plug. The plug's own login (G2) is written but not set up. | — | Do the 6 G2 steps in `docs/live-gui.md`. |

### 3.4 What already works as asked

- **Safety without network:** limits, the 60 s warning, lockouts and electrical trips all run in `loop()` from local readings. With no Supabase answer an appliance keeps the 30-minute default.
- **Bad readings:**
  - NaN, negative values or PF > 1 are marked invalid and never used for power or limits.
  - The app shows "no signal", not zeros.
  - A silent meter's port is restarted.
- **Flash wear:** the safety state is saved only when it changes, not every tick. Run and safety reports go to LittleFS and are sent later.
- **Only the affected outlet** is ever cut off.
- **Commands:**
  - The plug polls every 1 s.
  - Each command has an ID and is applied once (same ID → ignored).
  - A command must carry the current boot's `sessionID` and `revision` and expire within 30 s.
  - After a reboot, old commands get `REJECTED_STALE`. **That's S4: it is correct, not a bug.**
- **Wi-Fi:**
  - Reconnects by itself.
  - Opens the "wisewp" setup network after 60 s offline.
  - Retries home Wi-Fi every 2 min.
  - Never reboots to fix Wi-Fi.
- **Watchdog and health:** loop watchdog, task heartbeats, memory checks, safe self-restart only while both outlets are idle, and the restart reason is reported in `status/health`.
- **Relays at boot:** written LOW before `pinMode`, then set from the saved state.

## 4. Data contract (one row per shared field)

Naming used everywhere:
- Firebase uses `outlet_A` / `outlet_B`.
- Supabase and `live_telemetry` use `outlet_1` / `outlet_2`.
- The app's labels are A / B.

The mapping is consistent: `OUTLET_HW` in the firmware; `OutletChannel` and `outletKey()` in the app; `outletOf()` in Supabase. Device ID is `gadget-1` everywhere.

| Path / field | Firmware writes | Rules | App reads | Units / type | Status |
|---|---|---|---|---|---|
| `telemetry_logs/<outlet_A\|B>/power_W, current_A, voltage_V, power_factor` | 1 s | device write, owner read | `OutletReading` | W, A, V, 0–1 | ✅ |
| `…/energy_kWh` | 1 s (meter total) | same | not read | kWh | ⚠️ written, never read |
| `…/sensor_valid` | 1 s | same | ✅ | bool | ✅ |
| `…/currentState, status, revision, sessionID, alertID` | 1 s | same; command rules check `sessionID` and `revision` | ✅ | strings / int | ✅ |
| `…/last_updated_ms`, `last_updated` | 1 s | same | ✅ (`_ms` first) | **plug's NTP clock**, ms / ISO UTC | ⚠️ see A1 |
| `…/safetyDeadline, countdownExpiry, start_time` | 1 s | same | ✅ | ISO UTC text ("N/A" when none) | ✅ |
| `…/countdownRemaining` | 1 s | same | ✅ | seconds | ✅ |
| `…/runtime_warning, overridden, safetyResetHold, relay_on, storage_ok` | 1 s | same | ✅ | bool | ✅ (`relay_on` and `storage_ok` not read) |
| `…/profileID, appliance, recognitionStatus, applianceConfirmed` | 1 s | same | ✅ | text | ✅ |
| `…/peak_power_W` | 1 s | same | ✅ | W | ✅ |
| `commands/<outlet>` {commandID, userID, type, sessionID, revision, expiresAt, alertID, extensionDuration} | reads (GET every 1 s) | owner write (validated), device read | app writes | `expiresAt` = server ms, now + 20 s | ✅ (`extensionDuration` is ignored by the firmware; the plug sizes the override itself) |
| `commands` types `REMOVE_PROFILE, MERGE_PROFILE, EDIT_PROFILE` | rejected (`REJECTED_INVALID`) | still allowed | still sent by old functions (`deleteProfile`, `mergeProfile`, `editProfile`) | — | ⚠️ dead path (A4) |
| `command_results/<outlet>/<id>/result, revision` | 1 s | device write, owner read | `command()` waits up to 25 s | text | ✅ (no timestamp, F9) |
| `alerts/<id>/deviceID, alertType, triggerTime, countdownExpiry, resolution` | 1 s | device write, owner read | old repository only | ISO UTC | ✅ / F7 |
| `devices/gadget-1/status/lastSeen` | `{".sv":"timestamp"}` | device write, owner read | `GadgetStatus.isOnline` | **server ms** | ⚠️ see A1 |
| `…/status/connectionStatus, powerDraw, outletA, outletB, safetyTriggered, remainingLimit, wifiSSID` | 1 s | same | ✅ | W, bool, s | ✅ |
| `…/status/outlet_1\|2/{relayOn,state,appliance}`, `…/status/health` | 1 s | same | not read | — | ⚠️ written, never read (health is for you, fine) |
| `devices/gadget-1/live_telemetry/outlet_1\|2` | 3 s | device write, owner read | **not read** | W, A, V, Hz, **Wh** | ⚠️ F5 |
| `devices/gadget-1/outlets/<o>/relayState, isLockedDown` | 1 s / on change | device write, owner may set `isLockedDown` false | **not read** | bool | ⚠️ F6 |
| `devices/gadget-1/wifiConfig` {ssid, password, updatedAt, updatedBy, receivedAt, ackAt} | reads every 10 s; acks; deletes password | owner + device | ✅ | server ms | ✅ |
| `devices/gadget-1/notifications` | on trip | device write, owner read | (push via Supabase) | — | ✅ |
| `activity_log` | per event (POST) | device write, owner read/clear | `streamActivity` not used by any screen | ms | ⚠️ written, never shown (the app shows no history by design) |
| `appliance_profiles`, `appliance_registrations` | **not written any more** | still in rules | `streamProfiles` → old repository | — | ⚠️ dead (A4) |
| `device_owners/outlet_A\|B` | — | owner claim | `claimDevice` | uid | ✅ |
| `device_accounts/gadget-1` | — | no client access | rules only | uid | ✅ (G2, not set yet) |
| `users/<uid>/fcmTokens`, `preferences` | — | owner only | ✅ | — | ✅ (`fcmTokens` was only for the Cloud Function, C4) |
| Supabase `recognize-appliance` body: deviceId, outlet `outlet_1\|2`, eventId, startedAt (ms), stage, features{avg_power_w, avg_pf, avg_voltage_v, startup_peak_ratio, settling_time_s, power_variation, cycle_period_s, standby_power_w, unstable} | per run, twice | `x-device-key` | — | W, s, ratio | ✅ (optional `running` not sent, fine) |
| Supabase `log-session`: startedAt, endedAt (ms), durationS, energyWh, peakCurrentA, peakPowerW, endReason | per run | `x-device-key` | app reads `sessions` | **Wh** (meter is kWh; firmware integrates its own Wh) | ✅ |
| Supabase `evaluate-safety-alert`: eventId, type, occurredAt, runtimeS, limitS, powerW, currentA | per event | `x-device-key` | app reads `alert_logs` | s, W, A | ✅ |
| Supabase `ingest-batch` | **not called** | — | — | — | ⚠️ unused function |

**Rules check:**
- The device can write everything it writes, and the app can read what it reads and write commands. ✅
- Rules are not too open: there's no public read or write, commands are validated field by field, and `device_accounts` is closed. ✅
- One limit: the rules allow **one owner for the whole plug** (both outlets must belong to the same account). That matches "1 app = 1 plug".
- Today the plug uses the database secret, so **rules don't restrict the plug** (F10).

**Who sends what to Supabase:**
- Only the **plug** sends runs, recognition and safety reports.
- Each is sent once and stored on flash until accepted, so there are no gaps.
- Duplicates are ignored on the server: sessions are unique per device, outlet and start time; alerts are unique per `eventId`; recognition is unique per `eventId` and stage.
- The 7-use count is updated once per run.
- The app only reads, and calls user functions with the user's Firebase login. ✅

**Firebase login → Supabase:**
- The app passes its Firebase ID token as Supabase's `accessToken`.
- Edge Functions verify it against Google's keys (`_shared/auth.ts`).
- RLS is on for **all 16 tables** (owners read, only Edge Functions write).
- **Check in the Supabase dashboard:** Authentication → Third-party auth → **Firebase** must be enabled for project `wise-46f92`. It isn't in the local `config.toml`, so I can't see it from the code.

## 5. Flutter app

| ID | Sev. | Where | What is wrong | Fix |
|---|---|---|---|---|
| A1 | Medium | `gadget_status.dart:43`, `esp32_data.dart:67`, `telemetry.dart:61` | "Online" and "fresh" compare the **phone's own clock** with the plug's or server's time. If the phone clock is more than 30 s off, the app shows Offline even when the plug is fine. Commands already correct for this (`.info/serverTimeOffset`), but the screens don't. | Use the server time offset everywhere. |
| A2 | Medium | `esp32_live_view.dart` labels | A meter that isn't answering still shows the outlet as "Ready to use" (offered earlier, not approved yet). | Show "Meter not answering, outlet unsafe to use" (wording to agree), tied to F3. |
| A3 | Low | `esp32_service.dart:131` | The app listens to the whole `telemetry_logs` (both outlets). Two widgets listen, but Firebase merges identical listeners, so it is one download. Firebase sends only what changed. Fine. | — |
| A4 | Low | `wiseplug_repository.dart`, `firebase_service.dart`, `main.dart` (only with `WISEPLUG_USE_FIRESTORE`), `esp32_service.dart:241-320, 417` | Old code paths: Firestore screens, `appliance_profiles`, `REMOVE/MERGE/EDIT_PROFILE`. They aren't used by the normal app but are still compiled in (`cloud_firestore` dependency). | Remove in a cleanup commit. |
| A5 | ✅ | `esp32_service.dart:323` | Commands wait for the plug's acknowledgment (25 s) and show its reason in plain words. | — |

## 6. Free-tier use (one plug, estimated)

| Item | Estimate | Free limit | Risk |
|---|---|---|---|
| Firebase download: echo of the 1 s PATCH (F2) | **8–12 GB / month** | 10 GB / month | **High: will hit it** |
| Firebase download: `GET /commands` every 1 s | ≈ 0.5–1 GB / month | (same 10 GB) | Low |
| Firebase download: app open (deltas of `telemetry_logs` and `status`) | ≈ 1–2 KB/s while open, so ≈ 0.1–0.2 GB for 1 h/day | (same) | Low |
| Firebase connections | REST requests aren't long-lived; the app holds 1 | 100 at once | Low |
| Firebase stored data | grows slowly (F8) | 1 GB | Low |
| Supabase Edge Function calls | about 3–4 per appliance run (2 × recognize, 1 × log-session, alerts) → a few hundred a month | 500,000 / month | Low |
| Supabase database | small rows per run | 500 MB | Low |
| Supabase pausing | GitHub Action pings every 3 days | pauses after 7 days idle | ✅ handled |

With F2 fixed (`print=silent`), Firebase download drops to roughly 1–2 GB a month.

## 7. Physical checks (no multimeter, unless you get one)

**Always unplug both wall plugs (HLK and outlets) and USB before touching anything.**

1. **5 V joint (S1, S2):**
   - Re-solder HLK +Vo onto the ESP32's 5V/VIN pin, and HLK −Vo onto GND. The joints should be shiny cones that don't move when tugged.
   - Plug in only the HLK, hands off. **Pass:** the red light stays steady, and doesn't flicker when you move the wire with a plastic pen.
2. **PZEM power:**
   - Each PZEM's 5V and GND wire goes to the same 5 V and GND line.
   - Look for loose strands and solder bridges between neighbouring pins.
3. **Meters answer:**
   - Upload `pin_finder` with USB connected and the HLK unplugged; the PZEMs then need mains on their L/N.
   - **Pass:** `FOUND: PZEM TX on GPIO 32, PZEM RX on GPIO 33` and `… GPIO 25 … GPIO 26`.
   - Then upload `meter_test`. **Pass:** both lines show about 220–240 V.
4. **Fuse:** look along the live wire from the wall plug. Is there a fuse or fuse holder before the HLK and the sockets? If not, tell me before running loads.
5. **Outlet A is one outlet:**
   - Follow socket A's live wire: it should pass through **meter A's CT ring**, then into **SSR A** pins 1 and 2.
   - SSR A's 3 (+) should go to GPIO 13. Do the same for B (meter B's CT, SSR B, GPIO 12).
6. **Common ground:** HLK −Vo, ESP32 GND, PZEM A GND, PZEM B GND, SSR A 4 (−) and SSR B 4 (−) should all be on one line.
7. **SSR label:** read the input range printed on each SSR. 3–32 V DC is fine for 3.3 V.
8. **With a multimeter (if you get one):**
   - With power off, in continuity mode: no beep between 5 V and GND; a beep between every GND point.
   - With only the HLK on: 4.9–5.2 V at the ESP32 5V pin.
   - With the meter on: the PZEM TX pin to GND reads 3.3 V or 5 V (section 2.3).

## 8. Proposed fix order

1. **Hardware first:** the 5 V joint (section 7, steps 1–3). Without meters nothing else can be tested.
2. **F1:** move the clock sync to "Wi-Fi online" (crash).
3. **F2:** `print=silent` on Firebase writes (quota).
4. **F4:** faster reads when one meter is silent.
5. **F3 + A2:** a silent meter switches its outlet off, and the app says so. **Needs your approval (safety rule).**
6. **A1:** server-time offset for Online/fresh.
7. **F5, F6, F7, F9:** stop unused writes, send-once results, timestamp on acks.
8. **G2 deploy** (F10): your console steps.
9. **Cleanup:** A4, `functions/` (C4), the unused `ingest-batch`, F8 trimming.
10. **Phase 2 items from the brief:**
    - a single contract file (`contract.h` plus Dart constants plus `CONTRACT.md`);
    - a fake-device simulator;
    - `HARDWARE_TEST.md`.

## 9. Decisions needed from you

1. **C1:** after a power cut during a run, keep "off and locked", or resume with the saved runtime?
2. **C2:** keep "type safe time once confirmed, learned after 7 uses", or "30 minutes until 7 uses"?
3. **F3:** may a silent meter switch its outlet off?
4. **2.3:** try feeding the PZEM TTL 5V pin from the ESP32 3V3 pin?
5. **2.4 and 2.5:** add 10 kΩ pull-downs on the SSR inputs and a capacitor on 5 V (a few pesos, but it is hardware)?
6. **C4:** remove the Firebase Cloud Function (`functions/`)?
7. **Electrical limits:** the code already uses 10 A (instant trip) and 8 A for 10 s. These came from the socket and SSR ratings in earlier work. Confirm they're still right for your parts.

## 10. System evaluation, 12 November 2026 (after hardware testing)

**What works well:** safety runs on the plug without the internet (limits,
warnings, cutoffs, power-cut lock, watchdog); one code path for both outlets;
commands carry an ID, a time limit and a revision, so none runs twice; run
reports are stored on flash and survive outages; Firebase use fell about 80 %
after `print=silent`.

| # | Weakness | Seen as | Status |
|---|---|---|---|
| 1 | Two sources of truth with no shared run ID: the card followed Firebase, registration followed Supabase | "On for 23 min" in registration while the card said 23 s; samples not progressing | **Fixed:** the plug publishes `runEventId`; registration follows exactly that run |
| 2 | Supabase learned of a run's end late (30 s retries) | Old runs left "running"; outlet B not recognising a moved appliance | **Fixed:** run list in every recognition upload (stale runs closed), report retries every 10 s |
| 3 | Two secure connections did not fit in memory (largest block ~17 KB) | No pop-up, "Unknown appliance", uploads failing | **Fixed:** one secure connection at a time |
| 4 | One spoiled meter reading started a 60 s countdown that always cut the outlet | Fan cut after a minute while registering | **Fixed:** 5 s without a good reading; the warning ends if the meter answers |
| 5 | One registration sample and ±2 % power allowance | Chargers and fans "Something new" every time | **Fixed:** ±10 % floors, 3 samples for chargers, settling time skipped for never-steady runs |
| 6 | Every restart during a run locks that outlet (by design) | "Reset Safety" after each firmware upload | Documented: upload only with both outlets empty (HARDWARE_TEST.md) |
| 7 | Breadboard meter wiring is fragile | Missed readings | Handled in firmware; solder the final build |
| 8 | Commands wait while the plug uploads to Supabase | App commands may take 2–10 s | Acceptable for the prototype; watch `largestBlock` |
| 9 | No end-to-end hardware test | Problems found only on the real plug | **Added:** HARDWARE_TEST.md |
