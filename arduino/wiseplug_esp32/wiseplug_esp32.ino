// WisePlug ESP32 firmware: two PZEM-004T v3 meters, two relays, Firebase
// Realtime Database over REST. Matches the Flutter app's protocol:
//   telemetry_logs/outlet_A|B              live state, read by the app
//   commands/outlet_A|B -> command_results confirmed app commands
//   devices/gadget-1/status, /wifiConfig   gadget summary, Wi-Fi provisioning
// Optional (SUPABASE_FUNCTIONS_URL in secrets.h): session summaries and
// safety reports are POSTed to Supabase Edge Functions (supabase/functions).
//
// Appliance recognition is rule-based and happens in Supabase
// (recognize-appliance). The plug measures each run (recognition_window.h),
// sends a Stage 1 and a Stage 2 summary, and applies the cutoff it gets back.
// Until an appliance is MATCHED_CONFIRMED, and whenever Supabase cannot be
// reached, the run uses the conservative DEFAULT_LIMIT_S. The plug no longer
// matches appliances itself.
//
// Libraries: PZEM004Tv30, ArduinoJson 7 (WebServer and DNSServer ship with the ESP32 core).
#include <PZEM004Tv30.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <esp_wifi.h>
#include <algorithm>
#include <atomic>
#include <vector>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoOTA.h>
// Exact 64-bit millisecond timestamps (doubles would be rounded in JSON).
#define ARDUINOJSON_USE_LONG_LONG 1
#include <ArduinoJson.h>
#include <esp_timer.h>
#include <esp_heap_caps.h>
#include <time.h>
#include "secrets.h"        // FIREBASE_HOST and the plug's login. Never commit or share.
#include "safety_state.h"   // shared state machine, unit-tested in test/
#include "recognition_window.h"  // per-run features for recognize-appliance

// ==========================================
// CONFIGURATION
// ==========================================
#define DEVICE_ID_TEXT "gadget-1"
constexpr const char* DEVICE_ID = DEVICE_ID_TEXT;  // must match the app's DeviceBinding

// Outlet switches: one solid-state relay (SSR "DA", DC input) per outlet,
// + to the GPIO, - to GND. An SSR conducts while its input is HIGH, and both
// pins are LOW while the ESP32 starts, so the outlets stay off at power-up.
//   Outlet A: GPIO 13 (no boot function).
//   Outlet B: GPIO 12. It is a boot-strapping pin: it must NOT be pulled
//             HIGH at power-up or the ESP32 will not boot. An SSR input pulls
//             it towards GND, which is safe; never add a pull-up to it.
// (14 pulses during boot, 34 and 35 are input-only.)
//
// One row per outlet: the only things that differ between A and B. The rest
// of the firmware (measurement, recognition, cutoff, safety) is one code path
// for both, indexed 0 / 1.
struct OutletHw {
  const char *outlet, *key, *letter, *ns;  // Firebase name, Supabase name, app label, NVS namespace
  int relay; uint8_t relayOn;              // SSR pin, and the level that switches it on
  int button;                              // optional reset button to GND
  HardwareSerial& port; int rx, tx;        // the outlet's PZEM-004T, on its own UART
};
const OutletHw OUTLET_HW[2] = {
  {"outlet_A", "outlet_1", "A", "apps_a", 13, HIGH, 4, Serial2, 32, 33},
  {"outlet_B", "outlet_2", "B", "apps_b", 12, HIGH, 5, Serial1, 25, 26},
};

// Plug-in: power above START_W_THRESHOLD. Unplug / switched off: power below
// IDLE_W_THRESHOLD for UNPLUG_MS in a row (a single low reading is noise).
constexpr float START_W_THRESHOLD = 2.0f, IDLE_W_THRESHOLD = 1.5f;
constexpr uint64_t UNPLUG_MS = 3000;
// SAFETY: thermostat rests. A heating load (a run that peaked at or above
// restGapMinW: a flat iron, a microwave) clicks its element off to 0 W while
// it is still on. Such a run ends only after restGapS at 0 W, so its safe
// time keeps counting through the rests (before, each heating burst started
// a new run with a fresh timer, and an iron left on was never cut off).
// Supabase sends recognition_config.rest_gap_s / rest_gap_min_w with every
// recognition answer; these are the values until then, or without Supabase.
std::atomic<uint32_t> restGapS{180}, restGapMinW{500};
// SAFETY: the conservative cutoff for every run that is not MATCHED_CONFIRMED:
// before recognition, for UNKNOWN / AMBIGUOUS / SAME_TYPE_IN_USE /
// MATCHED_PROVISIONAL loads, and whenever Supabase cannot be reached. It is
// also the ceiling for any server cutoff of an unconfirmed load, so keep it at
// or above recognition_config.default_cutoff_minutes (30).
constexpr uint32_t DEFAULT_LIMIT_S = 30 * 60;
// A confirmed appliance's cutoff comes from Supabase, at most 7 days
// (appliance_instances.max_runtime_mins <= 10080).
constexpr uint32_t MAX_CONFIRMED_LIMIT_S = 7 * 24 * 3600;
// SAFETY: a running outlet whose meter has given no good reading for
// SENSOR_TIMEOUT_MS gets the SENSOR_UNAVAILABLE warning (60 s, then off). One
// spoiled reading (a fan motor's electrical noise) is not enough, and if the
// meter answers again within the 60 s the warning ends and the run goes on.
constexpr uint64_t SENSOR_TIMEOUT_MS = 5000;
// A meter that has not answered for this long has its serial link restarted
// (again every METER_RESTART_MS while it stays silent): noise from a switching
// load can leave the PZEM's UART stuck until then.
constexpr uint64_t METER_RESTART_MS = 5000;
// An idle outlet stays on (as the user set it) even while its meter is
// silent: the user chose this so both outlets stay on (the 40th commit's
// "silent meter switches its idle outlet off" made them take turns when the
// meters dropped out). A RUNNING outlet whose meter goes silent still gets the
// SENSOR_UNAVAILABLE warning above (60 s, then off).
// A recognition upload that fails (e.g. Wi-Fi reconnecting) is retried every
// RECOGNITION_RETRY_MS for as long as its run lasts; it is dropped once the run
// ends or a later stage of the same run is waiting. Meanwhile the run keeps
// its current (default) cutoff.
constexpr uint64_t RECOGNITION_RETRY_MS = 5000;
// "Restart WisePlug" in the app (RESTART command): restart at this time
// (monotonic ms; 0 = not asked), a few seconds after it was accepted so the
// answer reaches the app first.
uint64_t appRestartAt = 0;
constexpr uint64_t APP_RESTART_DELAY_MS = 3000;

constexpr uint32_t MIN_SESSION_S = 10;           // shorter runs are not reported as usage
constexpr float OVERRIDE_BUFFER = 0.20f;         // override: +20% safety buffer
// Electrical trips lock the outlet out at once: no countdown, no override.
// MAX_CURRENT_A is the hardware rating (socket 10 A 250 V, SSR, wiring): above
// it the outlet is cut off on the first reading. CONTINUOUS_CURRENT_A is the
// most a load may draw for longer than OVERLOAD_MS: 80 % of the rating, the
// rule for loads that stay on (the SSR-40DA on its heatsink). A motor's
// start-up surge is far shorter, so it does not count. Lower both to match the
// weakest part. A CONFIRMED appliance drawing
// ANOMALY_FACTOR x its own steady power (measured in this run) for
// ANOMALY_SAMPLES readings in a row (~0.6 s, so a short surge does not count)
// is a fault.
constexpr float MAX_CURRENT_A = 10.0f, CONTINUOUS_CURRENT_A = 8.0f, ANOMALY_FACTOR = 2.0f;
constexpr uint64_t OVERLOAD_MS = 10000;
constexpr uint32_t ANOMALY_SAMPLES = 3;

// ==========================================
// DATA STRUCTURES
// ==========================================
struct SensorSample { float power, current, voltage, pf, energy, frequency; bool valid; uint64_t captured; };
struct Command {
  char id[64] = {}, session[40] = {}, type[24] = {}, alertID[80] = {};
  uint32_t revision = 0;
  int64_t expires = 0;
};
struct AlertRecord {
  char id[80] = {}, type[40] = {}, resolution[16] = {};
  int64_t trigger = 0, expiry = 0;
};
struct Snapshot {
  SafetyState safety;
  SensorSample sensor = {};
  // The appliance on this outlet, as Supabase recognized it (empty until then).
  char activeName[64] = {}, activeProfileID[64] = {};   // name, appliance_instances.id
  // NONE; RECOGNIZING (measuring); PENDING (measured, Supabase has not answered
  // yet); or recognize-appliance's status.
  char recognition[24] = "NONE";
  bool confirmed = false;         // MATCHED_CONFIRMED: the appliance's own cutoff applies
  float steadyW = 0;              // this run's steady average power (anomaly trip)
  float peak = 0;
  int64_t startEpoch = 0, capturedEpoch = 0;
  uint64_t capturedMono = 0;
  AlertRecord alert;
  char commandID[64] = {}, commandResult[40] = {};
  uint32_t lockSeq = 0;  // counts lockouts, so an unlock applies to one only
};
struct SocketChannel {
  Preferences prefs;
  const char *ns, *outlet;
  int relay, button;
  uint8_t relayOn;  // pin level that switches the outlet on (SSR: HIGH)
  Snapshot data;
  uint32_t anomalySamples = 0;
  uint64_t overloadSince = 0;  // first reading above CONTINUOUS_CURRENT_A in a row (0: none)
  uint64_t buttonChanged = 0, lastSnapshot = 0;
  bool rawButton = true, stableButton = true, storageOK = true;
  QueueHandle_t sensors, commands, snapshots;
  // Usage of the run in progress, reported to Supabase when it ends.
  bool sessionOpen = false, tripping = false;
  int64_t sessionStartEpoch = 0;
  uint64_t sessionStartMono = 0, lastEnergySample = 0;
  // The run in progress (its sessionStartMono), 0 when none: read by the
  // Supabase task to drop uploads of runs that have already ended.
  std::atomic<uint64_t> runMono{0};
  std::atomic<int> stageQueued{0};  // the latest stage queued for that run
  double sessionWh = 0;
  float lastPower = 0, sessionPeakCurrent = 0, sessionPeakPower = 0;
  uint64_t lowSince = 0;  // first of the consecutive readings below IDLE_W_THRESHOLD
  uint64_t lastValid = 0;  // last good meter reading (0: none since power-up)
  // The run's measurement for recognize-appliance (Stage 1 and Stage 2).
  RecognitionWindow rec;
  float standbyW = 0;  // smoothed draw while idle (an appliance's standby)
};

PZEM004Tv30 meters[2] = {{OUTLET_HW[0].port, uint8_t(OUTLET_HW[0].rx), uint8_t(OUTLET_HW[0].tx)},
                          {OUTLET_HW[1].port, uint8_t(OUTLET_HW[1].rx), uint8_t(OUTLET_HW[1].tx)}};
SocketChannel outlets[2];
char sessionID[40];

// Supabase reports (optional, see secrets.example.h). They wait
// in a queue while offline; each is sent once, as a summary, never per tick.
struct SessionSummary {
  int outlet = 0;
  char name[64] = {}, reason[16] = {};
  int64_t startEpoch = 0, endEpoch = 0;
  uint64_t endMono = 0;
  uint32_t durationS = 0, limitS = 0;
  float energyWh = 0, peakCurrent = 0, peakPower = 0;
};
struct SafetyReport {
  int outlet = 0;
  char eventID[88] = {}, type[24] = {}, name[64] = {};
  uint32_t runtimeS = 0, limitS = 0;
  float power = 0, current = 0;
  int64_t at = 0;
  uint64_t mono = 0;
};
// One stage of a run's measurement for recognize-appliance, and its answer.
struct RecognitionReport {
  int outlet = 0, stage = 0;
  char eventID[88] = {};
  int64_t startEpoch = 0;
  uint64_t startMono = 0;
  RecFeatures f;
};
struct RecognitionReply {
  int outlet = 0, stage = 0;
  uint64_t startMono = 0;  // which run it is for
  uint32_t cutoffS = 0;
  char status[24] = {}, applianceID[64] = {}, name[64] = {};
};
QueueHandle_t sessionReports, safetyReports, recognitionReports, recognitionReplies;
// One cloud connection's health: consecutive failed calls and fresh starts.
struct CloudHealth { uint32_t fails = 0, resets = 0; };

// ==========================================
// TIME HELPERS (never block waiting for NTP)
// ==========================================
uint64_t monotonicMs() { return esp_timer_get_time() / 1000; }
int64_t epochMs() { time_t t = time(nullptr); return t > 1700000000 ? int64_t(t) * 1000 : 0; }
String timestamp(int64_t ms) {
  if (!ms) return "N/A";
  time_t t = ms / 1000; struct tm utc; gmtime_r(&t, &utc);
  char buffer[32]; strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return String(buffer);
}

// ==========================================
// SAFETY STATE & STORAGE (control loop only)
// ==========================================
bool relayEnergized(SocketState s) { return s != SocketState::Disabled && s != SocketState::LockedOut; }
// Whether the outlet actually has power: its state allows it and its meter works.
bool relayOnNow(const Snapshot& s) { return relayEnergized(s.safety.state); }
void applyRelay(SocketChannel& ch) {
  digitalWrite(ch.relay, relayOnNow(ch.data) ? ch.relayOn : !ch.relayOn);
}
bool persistSafety(SocketChannel& ch) {
  auto state = ch.data.safety.state;
  bool hazardous = state == SocketState::Sampling || state == SocketState::Active || state == SocketState::Warning || state == SocketState::LockedOut;
  bool ok = ch.prefs.putBool("hazard", hazardous) == 1;
  ok = (ch.prefs.putBool("disabled", state == SocketState::Disabled) == 1) && ok;
  // Off after a safety reset: still off, and still asking first, after a restart.
  ok = (ch.prefs.putBool("hold", state == SocketState::Disabled && ch.data.safety.resetHold) == 1) && ok;
  if (ch.data.alert.id[0]) ok = (ch.prefs.putBytes("alert", &ch.data.alert, sizeof(AlertRecord)) == sizeof(AlertRecord)) && ok;
  if (!ok) { ch.storageOK = false; ch.data.safety.state = SocketState::LockedOut; ++ch.data.lockSeq; }
  applyRelay(ch);
  return ok;
}
const char* activeProfileID(SocketChannel& ch) { return ch.data.activeProfileID; }
const char* activeName(SocketChannel& ch) {
  return ch.data.activeName[0] ? ch.data.activeName : "Unknown appliance";
}
// The cutoff the running session has now (seconds from its start).
uint32_t currentLimitS(const SafetyState& s) {
  return s.deadline > s.started ? uint32_t((s.deadline - s.started) / 1000) : 0;
}
// Supabase safety report for the running appliance (queued; sent by the Supabase task).
void reportSafety(SocketChannel& ch, const char* type, const char* eventID, float power, float current) {
  if (!safetyReports) return;
  SafetyReport r;
  uint64_t now = monotonicMs();
  r.outlet = int(&ch - outlets);
  strlcpy(r.type, type, sizeof(r.type)); strlcpy(r.eventID, eventID, sizeof(r.eventID));
  strlcpy(r.name, activeName(ch), sizeof(r.name));
  r.runtimeS = ch.sessionOpen ? uint32_t((now - ch.sessionStartMono) / 1000) : 0;
  r.limitS = currentLimitS(ch.data.safety);
  r.power = power; r.current = current; r.at = epochMs(); r.mono = now;
  xQueueSend(safetyReports, &r, 0);  // full queue: drop rather than block safety
}
// Queues the summary of the run that just ended. Blips under MIN_SESSION_S
// are not usage, but a lockout is always reported.
void reportSession(SocketChannel& ch, const char* reason) {
  if (!ch.sessionOpen) return;
  ch.sessionOpen = false;
  uint64_t now = monotonicMs();
  uint32_t seconds = uint32_t((now - ch.sessionStartMono) / 1000);
  if (!sessionReports || (seconds < MIN_SESSION_S && strcmp(reason, "LOCKED_OUT") != 0)) return;
  Serial.printf("[%s] Run ended (%s, %lu s): queued for Supabase\n", ch.outlet, reason, (unsigned long)seconds);
  SessionSummary s;
  s.outlet = int(&ch - outlets);
  strlcpy(s.reason, reason, sizeof(s.reason));
  strlcpy(s.name, activeName(ch), sizeof(s.name));
  s.limitS = currentLimitS(ch.data.safety);
  s.startEpoch = ch.sessionStartEpoch; s.endEpoch = epochMs(); s.endMono = now; s.durationS = seconds;
  s.energyWh = float(ch.sessionWh); s.peakCurrent = ch.sessionPeakCurrent; s.peakPower = ch.sessionPeakPower;
  if (xQueueSend(sessionReports, &s, 0) != pdTRUE) Serial.printf("[%s] Run report queue full: report lost\n", ch.outlet);
}
// Queues one stage of the run's measurement for recognize-appliance. The
// event ID (boot session + outlet + start time) makes retries idempotent.
void queueRecognition(SocketChannel& ch, int stage) {
  RecognitionReport r;
  r.outlet = int(&ch - outlets); r.stage = stage;
  snprintf(r.eventID, sizeof(r.eventID), "%s_%s_%llu", sessionID, ch.outlet, (unsigned long long)ch.sessionStartMono);
  r.startEpoch = ch.sessionStartEpoch; r.startMono = ch.sessionStartMono;
  r.f = ch.rec.features(stage);
  if (stage == 2) ch.data.steadyW = r.f.avgPowerW;
  // Measured; until Supabase answers, the app shows "Unknown appliance".
  if (stage == 2 && strcmp(ch.data.recognition, "RECOGNIZING") == 0) {
    strlcpy(ch.data.recognition, "PENDING", sizeof(ch.data.recognition));
  }
  ch.stageQueued = stage;
  Serial.printf("[%s] Stage %d: %.1f W, PF %.2f, %.1f V, peak x%.2f, settled %.0f s%s%s (%lu readings)\n",
                ch.outlet, stage, r.f.avgPowerW, r.f.avgPf, r.f.avgVoltageV, r.f.startupPeakRatio,
                r.f.settlingTimeS, r.f.hasVariation ? ", variation" : "", r.f.unstable ? ", UNSTABLE" : "",
                (unsigned long)r.f.readings);
  // Without Supabase (or a full queue) the run simply keeps the default cutoff.
  if (recognitionReports) xQueueSend(recognitionReports, &r, 0);
}
// Every way a run ends comes through here, so each one is reported once.
void endSession(SocketChannel& ch, const char* reason = "ENDED") {
  ch.rec.cancel();
  reportSession(ch, reason);
  ch.runMono = 0; ch.stageQueued = 0;
  auto& d = ch.data;
  d.activeName[0] = d.activeProfileID[0] = 0;
  strlcpy(d.recognition, "NONE", sizeof(d.recognition));
  d.confirmed = false; d.steadyW = 0; d.peak = 0;
}
void lock(SocketChannel& ch) {
  // A warning still PENDING went unanswered: report the lockout, so the phone says the outlet was turned off. Checked
  // on the alert, not the state: when the 60 s run out, tick() has already
  // set LOCKED_OUT before this is called, and the report was never sent.
  if (strcmp(ch.data.alert.resolution, "PENDING") == 0 && !ch.tripping) {
    char id[88]; snprintf(id, sizeof(id), "%s_LOCKED", ch.data.alert.id);  // the warning went unanswered
    reportSafety(ch, "LOCKED_OUT", id, ch.data.sensor.power, ch.data.sensor.current);
  }
  ch.data.safety.state = SocketState::LockedOut; ++ch.data.safety.revision; ++ch.data.lockSeq;
  if (ch.data.alert.id[0]) strlcpy(ch.data.alert.resolution, "SHUTDOWN", sizeof(ch.data.alert.resolution));
  endSession(ch, "LOCKED_OUT"); persistSafety(ch);
  Serial.printf("[%s] LOCKED OUT, relay off\n", ch.outlet);
}
// Keys left by earlier sketches, including the old on-plug appliance catalog
// ("profiles_v5": recognition now happens in Supabase). NVS is only ~16 KB
// (shared with Wi-Fi), so they are removed only when a save has failed.
void removeStaleKeys(SocketChannel& ch) {
  for (const char* key : {"profiles_v2", "count_v2", "count", "profiles_v3", "count_v3", "profiles_v4", "profiles_v5"}) {
    if (ch.prefs.isKey(key)) ch.prefs.remove(key);
  }
  for (uint32_t n = 0; n < 20; ++n) {
    char key[16]; snprintf(key, sizeof(key), "app_%lu", (unsigned long)n);
    if (ch.prefs.isKey(key)) ch.prefs.remove(key);
  }
}
// Called before accepting a reset when storage had failed: reopen and free space.
bool repairStorage(SocketChannel& ch) {
  ch.prefs.end();
  if (!ch.prefs.begin(ch.ns, false)) return false;
  removeStaleKeys(ch);
  return true;  // persistSafety() then proves a write works
}
void beginAlert(SocketChannel& ch, const char* type, uint64_t now) {
  ch.data.safety.state = SocketState::Warning;
  ch.data.safety.warningStarted = now; ++ch.data.safety.revision;
  auto& a = ch.data.alert;
  snprintf(a.id, sizeof(a.id), "%s_%s_%lu", sessionID, ch.outlet, (unsigned long)ch.data.safety.revision);
  strlcpy(a.type, type, sizeof(a.type)); strlcpy(a.resolution, "PENDING", sizeof(a.resolution));
  a.trigger = epochMs(); a.expiry = a.trigger ? a.trigger + 60000 : 0;
  reportSafety(ch, strcmp(type, "SAFETY_CEILING_EXCEEDED") == 0 ? "RUNTIME_WARNING" : type, a.id,
               ch.data.sensor.power, ch.data.sensor.current);
  persistSafety(ch);
  Serial.printf("[%s] WARNING %s: 60 s until lockout\n", ch.outlet, type);
}
// Electrical fault: power off first, then lock out (persisted, so a reboot
// stays locked) and queue the Supabase safety report (it sends the phone
// alert). Works with or without Wi-Fi.
void trip(SocketChannel& ch, const char* reason, const SensorSample& s, uint64_t now) {
  digitalWrite(ch.relay, !ch.relayOn);
  auto& a = ch.data.alert;
  snprintf(a.id, sizeof(a.id), "%s_%s_%lu", sessionID, ch.outlet, (unsigned long)ch.data.safety.revision + 1);
  strlcpy(a.type, reason, sizeof(a.type));
  a.trigger = a.expiry = epochMs();
  ch.anomalySamples = 0; ch.overloadSince = 0;
  Serial.printf("[%s] TRIP %s: %.1f W, %.2f A\n", ch.outlet, reason, s.power, s.current);
  reportSafety(ch, reason, a.id, s.power, s.current);
  ch.tripping = true;  // one report per trip, not a second LOCKED_OUT
  lock(ch);  // marks the alert SHUTDOWN
  ch.tripping = false;
}
// SENSOR_UNAVAILABLE ends as soon as the meter answers again within its 60 s:
// the outlet is measured and protected again, so the run continues on its own
// safe time (no cutoff, no reset needed). Any other warning is unchanged.
void meterRecovered(SocketChannel& ch) {
  auto& d = ch.data;
  if (d.safety.state != SocketState::Warning || strcmp(d.alert.type, "SENSOR_UNAVAILABLE") != 0) return;
  d.safety.state = SocketState::Active; ++d.safety.revision;
  strlcpy(d.alert.resolution, "RECOVERED", sizeof(d.alert.resolution));
  persistSafety(ch);
  Serial.printf("[%s] Meter answering again: warning cleared, run continues\n", ch.outlet);
}
// Checked on every reading while the relay is on, in any running state.
bool electricalTrip(SocketChannel& ch, const SensorSample& s, uint64_t now) {
  if (s.current > MAX_CURRENT_A) { trip(ch, "OVERCURRENT", s, now); return true; }
  // Too much for the hardware to carry for long (e.g. a 2,000 W kettle).
  if (s.current <= CONTINUOUS_CURRENT_A) ch.overloadSince = 0;
  else if (!ch.overloadSince) ch.overloadSince = now;
  else if (now - ch.overloadSince >= OVERLOAD_MS) { trip(ch, "OVERCURRENT", s, now); return true; }
  // Only for a confirmed appliance, against its own steady power in this run
  // (a provisional or unknown load may legitimately change its draw).
  const auto& d = ch.data;
  bool anomaly = d.safety.state == SocketState::Active && d.confirmed && d.steadyW > 0 &&
      s.power > d.steadyW * ANOMALY_FACTOR + 5.0f;
  ch.anomalySamples = anomaly ? ch.anomalySamples + 1 : 0;
  if (ch.anomalySamples < ANOMALY_SAMPLES) return false;
  trip(ch, "POWER_ANOMALY", s, now);
  return true;
}
// Time granted by "Yes, Override": a safety buffer of OVERRIDE_BUFFER x how
// long the session has run (on the first warning, that is its limit), kept
// within 1 min..1 h. The app computes the same value (overrideBufferSeconds).
uint32_t overrideSeconds(const SafetyState& s, uint64_t now) {
  uint64_t buffer = uint64_t((now - s.started) / 1000 * OVERRIDE_BUFFER);
  return uint32_t(min(max(buffer, uint64_t(60)), uint64_t(3600)));
}

// ==========================================
// RUN DETECTION AND MEASUREMENT (control loop)
// IDLE -> plug-in (> START_W) -> STARTUP -> SETTLING -> STEADY -> REPORTED,
// measured by RecognitionWindow; the run ends when the power stays below
// IDLE_W for UNPLUG_MS. The safety state is Sampling ("Recognizing
// appliance") until the first stage is sent, then Active. The cutoff starts
// at DEFAULT_LIMIT_S and changes only through recognize-appliance's replies.
// ==========================================
void handleSensor(SocketChannel& ch, const SensorSample& sample, uint64_t now) {
  auto& d = ch.data;
  d.sensor = sample;
  if (!sample.valid) return;
  if (!ch.sessionOpen && sample.power < START_W_THRESHOLD) ch.standbyW = ch.standbyW * 0.9f + sample.power * 0.1f;
  if (ch.sessionOpen) {  // energy of this run: power integrated at the meter's rate
    uint64_t dt = now - ch.lastEnergySample;
    if (dt <= SENSOR_TIMEOUT_MS) ch.sessionWh += (ch.lastPower + sample.power) / 2.0 * double(dt) / 3600000.0;
    ch.lastEnergySample = now; ch.lastPower = sample.power;
    ch.sessionPeakCurrent = max(ch.sessionPeakCurrent, sample.current);
    ch.sessionPeakPower = max(ch.sessionPeakPower, sample.power);
  }
  auto state = d.safety.state;
  if (relayEnergized(state) && electricalTrip(ch, sample, now)) return;
  if (!relayEnergized(state)) ch.overloadSince = 0;  // counts only while it is on
  if (state == SocketState::Disabled || state == SocketState::LockedOut || state == SocketState::Warning) return;
  if (state == SocketState::Idle) {
    if (sample.power <= START_W_THRESHOLD) return;
    // Plug-in: the conservative default applies until Supabase confirms an appliance.
    d.safety.begin(now, DEFAULT_LIMIT_S);
    d.startEpoch = epochMs(); d.peak = 0;
    d.activeName[0] = d.activeProfileID[0] = 0; d.confirmed = false; d.steadyW = 0;
    strlcpy(d.recognition, "RECOGNIZING", sizeof(d.recognition));
    ch.sessionOpen = true; ch.lowSince = 0;
    ch.sessionStartMono = now; ch.sessionStartEpoch = d.startEpoch; ch.lastEnergySample = now;
    ch.runMono = now; ch.stageQueued = 0;
    ch.sessionWh = 0; ch.lastPower = sample.power;
    ch.sessionPeakCurrent = sample.current; ch.sessionPeakPower = sample.power;
    ch.rec.begin(now, ch.standbyW);
    if (!persistSafety(ch)) return;
    Serial.printf("[%s] Plug-in: %.1f W, measuring (limit %lu s until confirmed)\n",
                  ch.outlet, sample.power, (unsigned long)DEFAULT_LIMIT_S);
  } else if (sample.power < IDLE_W_THRESHOLD) {
    // Unplugged or switched off only after UNPLUG_MS of low readings, or for
    // a heating load after its thermostat rest (restGapS), see above.
    bool heater = d.peak >= float(restGapMinW.load());
    uint64_t needLow = heater ? max(UNPLUG_MS, uint64_t(restGapS.load()) * 1000) : UNPLUG_MS;
    if (!ch.lowSince) {
      ch.lowSince = now;
      if (heater && needLow > UNPLUG_MS) {
        Serial.printf("[%s] 0 W after %.0f W: thermostat rest? Run (and its timer) kept for up to %lu s\n",
                      ch.outlet, d.peak, (unsigned long)(needLow / 1000));
      }
    }
    if (now - ch.lowSince < needLow) return;
    d.safety.state = SocketState::Idle; ++d.safety.revision;
    endSession(ch, "APPLIANCE_OFF"); persistSafety(ch);
    Serial.printf("[%s] Unplugged / switched off\n", ch.outlet);
    return;
  } else {
    ch.lowSince = 0;
  }
  d.peak = max(d.peak, sample.power);
  int stage = ch.rec.add(now, sample.power, sample.pf, sample.voltage);
  if (!stage) return;
  queueRecognition(ch, stage);
  if (d.safety.state == SocketState::Sampling) { d.safety.state = SocketState::Active; ++d.safety.revision; }
}

// ==========================================
// APP COMMANDS (validated against session + revision)
// ==========================================
void handleCommand(SocketChannel& ch, const Command& cmd, uint64_t now) {
  auto& d = ch.data;
  if (!cmd.id[0] || strcmp(cmd.id, d.commandID) == 0) return;
  strlcpy(d.commandID, cmd.id, sizeof(d.commandID));
  const char* result = "REJECTED_STALE";
  bool fresh = strcmp(cmd.session, sessionID) == 0 && cmd.revision == d.safety.revision &&
      epochMs() && cmd.expires > epochMs() && cmd.expires <= epochMs() + 30000;
  if (strcmp(cmd.type, "RESTART") == 0) {
    // "Restart WisePlug" in the app: only while nothing runs and nothing is
    // locked or warning on either outlet (a restart during a run would lock
    // it, as after a power cut). Saved states (off, reset hold) stay.
    bool locked = false, busy = false;
    for (const auto& o : outlets) {
      auto st = o.data.safety.state;
      if (st == SocketState::LockedOut || st == SocketState::Warning) locked = true;
      else if ((st != SocketState::Idle && st != SocketState::Disabled) || o.sessionOpen) busy = true;
    }
    result = !fresh ? "REJECTED_STALE" : locked ? "REJECTED_LOCKED" : busy ? "REJECTED_RUNNING" : "ACCEPTED";
    if (strcmp(result, "ACCEPTED") == 0) {
      appRestartAt = now + APP_RESTART_DELAY_MS;
      Serial.println("Restart asked from the app: restarting in 3 s");
    }
  } else if (strcmp(cmd.type, "RESET_SAFETY") == 0) {
    // The only remote command accepted while locked out.
    if (!fresh) result = "REJECTED_STALE";
    else if (!ch.storageOK && !(ch.storageOK = repairStorage(ch))) result = "REJECTED_STORAGE_FAILURE";
    else if (!d.safety.remoteReset()) result = "REJECTED_INVALID";
    else {
      endSession(ch, "RESET");
      if (d.alert.id[0]) strlcpy(d.alert.resolution, "RESET", sizeof(d.alert.resolution));
      result = persistSafety(ch) ? "ACCEPTED" : "REJECTED_STORAGE_FAILURE";
    }
  } else if (d.safety.state == SocketState::LockedOut) result = "REJECTED_PHYSICAL_RESET_REQUIRED";
  else if (fresh) {
    result = "REJECTED_INVALID";
    if (strcmp(cmd.type, "SMART_OVERRIDE") == 0) {
      // The plug, not the app, sizes the extension from the appliance's history.
      if (strcmp(cmd.alertID, d.alert.id) == 0 && d.safety.overrideRuntime(now, overrideSeconds(d.safety, now))) {
        strlcpy(d.alert.resolution, "OVERRIDDEN", sizeof(d.alert.resolution)); result = "ACCEPTED";
      }
    } else if (strcmp(cmd.type, "TURN_OFF") == 0 && d.safety.state == SocketState::Warning) {
      // "Turn off now": off, not locked (the switch in the app still works).
      d.safety.userTurnOff();
      strlcpy(d.alert.resolution, "TURNED_OFF", sizeof(d.alert.resolution));
      endSession(ch, "TURNED_OFF"); result = "ACCEPTED";
    } else if (strcmp(cmd.type, "TURN_ON") == 0 || strcmp(cmd.type, "TURN_OFF") == 0) {
      bool on = strcmp(cmd.type, "TURN_ON") == 0;
      if (!on && d.safety.state == SocketState::Idle) {
        result = "REJECTED_NO_APPLIANCE";  // interlock: nothing plugged in to switch off
      } else if (d.safety.remotePower(on)) {
        if (d.safety.state == SocketState::Disabled) endSession(ch, "TURNED_OFF");
        result = "ACCEPTED";
      }
    }
    // REMOVE_PROFILE, MERGE_PROFILE and EDIT_PROFILE are gone: appliances and
    // their limits live in Supabase now, so they are REJECTED_INVALID.
    if (!persistSafety(ch)) result = "REJECTED_STORAGE_FAILURE";
  }
  strlcpy(d.commandResult, result, sizeof(d.commandResult));
  Serial.printf("[%s] %s -> %s\n", ch.outlet, cmd.type, result);
}

// ==========================================
// SENSOR TASK (core 0)
// ==========================================
void sensorTask(void*) {
  uint64_t lastWarning[2] = {0, 0}, lastAnswer[2], lastRestart[2] = {0, 0};
  bool restarted[2] = {false, false};
  lastAnswer[0] = lastAnswer[1] = monotonicMs();
  for (;;) {
    for (int i = 0; i < 2; ++i) {
      SensorSample s;
      // A silent meter makes every getter wait for its own timeout; ask once
      // and skip the rest, so the other outlet's readings are not delayed.
      s.voltage = meters[i].voltage();
      if (isnan(s.voltage)) {
        s.power = s.current = s.pf = s.energy = s.frequency = NAN;
      } else {
        s.power = meters[i].power(); s.current = meters[i].current();
        s.pf = meters[i].pf(); s.energy = meters[i].energy(); s.frequency = meters[i].frequency();
      }
      s.valid = isfinite(s.power) && s.power >= 0 && isfinite(s.current) && s.current >= 0 &&
                isfinite(s.voltage) && s.voltage > 0 && isfinite(s.pf) && s.pf >= 0 && s.pf <= 1;
      s.captured = monotonicMs(); xQueueOverwrite(outlets[i].sensors, &s);
      // Without valid readings an outlet can never detect or learn an appliance.
      if (!s.valid && s.captured - lastWarning[i] >= 5000) {
        lastWarning[i] = s.captured;
        Serial.printf("[%s] PZEM not responding (V=%.1f): check its RX/TX wiring, 5V/GND and mains supply\n",
                      outlets[i].outlet, s.voltage);
      }
      // Self-recovery: restart a silent meter's serial link.
      if (s.valid) {
        lastAnswer[i] = s.captured;
        if (restarted[i]) Serial.printf("[%s] PZEM answering again\n", outlets[i].outlet);
        restarted[i] = false;
      } else if (s.captured - lastAnswer[i] >= METER_RESTART_MS && s.captured - lastRestart[i] >= METER_RESTART_MS) {
        const auto& h = OUTLET_HW[i];
        lastRestart[i] = s.captured; restarted[i] = true;
        h.port.end();
        h.port.begin(9600, SERIAL_8N1, h.rx, h.tx);
        Serial.printf("[%s] PZEM silent for %llu s: serial link restarted\n", outlets[i].outlet,
                      (unsigned long long)((s.captured - lastAnswer[i]) / 1000));
      }
    }
    vTaskDelay(pdMS_TO_TICKS(200));
  }
}

// ==========================================
// SELF-HEALING: nobody should have to restart the plug by hand
// ==========================================
// Safety (limits, warnings, cutoffs) runs in loop() and never needs the
// cloud. These keep the cloud side working for weeks:
//  A. Cloud calls need one large free block of memory for TLS. After
//     CLOUD_FAILS_TO_RESET failed calls in a row while Wi-Fi is up, the TLS
//     connection is closed and opened fresh (its buffers are freed).
//  B. A self-restart, only while BOTH outlets are idle or off (a restart
//     during a run would lock that outlet): when the cloud still fails after
//     CLOUD_RESETS_TO_RESTART fresh connections, when the largest free block
//     stays below LOW_BLOCK_BYTES for LOW_MEMORY_MS, when a network task has
//     not run for TASK_STUCK_MS, or as a preventive restart after
//     PREVENTIVE_RESTART_MS (then only with nothing waiting to be sent).
//  D. Watchdogs: the hardware watchdog restarts the plug if the safety loop
//     itself ever freezes (a running outlet then comes back locked, as after
//     a power cut); a frozen network task is caught by B's heartbeat check.
// The reason of the last self-restart is kept and reported in the status.
constexpr uint32_t CLOUD_FAILS_TO_RESET = 10, CLOUD_RESETS_TO_RESTART = 3;
constexpr size_t LOW_BLOCK_BYTES = 20 * 1024;
constexpr uint64_t LOW_MEMORY_MS = 10 * 60 * 1000ULL, TASK_STUCK_MS = 10 * 60 * 1000ULL;
constexpr uint64_t PREVENTIVE_RESTART_MS = 7ULL * 24 * 3600 * 1000;
constexpr uint64_t CLOUD_RESTART_BACKOFF_MS = 6ULL * 3600 * 1000;

enum RestartWhy : int { NoRestart = 0, CloudFailing, LowMemory, TaskStuck, Preventive, AppRequest };
const char* restartText(int why) {
  switch (why) {
    case CloudFailing: return "cloud calls kept failing";
    case LowMemory: return "memory too fragmented";
    case TaskStuck: return "a network task stopped";
    case Preventive: return "preventive (7 days)";
    case AppRequest: return "restarted from the app";
    default: return "";
  }
}
std::atomic<int> restartWhy{NoRestart};
// What the last self-restart was for (kept in NVS), reported in the status.
char lastRestart[40] = "";
// The first reason wins; a preventive restart never replaces a fault.
void requestRestart(int why) {
  // Restarting again cannot fix what a restart did not fix (e.g. the
  // internet is down): at most one such restart every CLOUD_RESTART_BACKOFF_MS.
  if (why == CloudFailing && strcmp(lastRestart, restartText(CloudFailing)) == 0 &&
      monotonicMs() < CLOUD_RESTART_BACKOFF_MS) return;
  int none = NoRestart;
  if (restartWhy.compare_exchange_strong(none, why)) Serial.printf("Self-restart requested: %s\n", restartText(why));
}
// Heartbeats of the network tasks (monotonic ms of their last loop).
std::atomic<uint64_t> netBeat{0}, supaBeat{0};

// Counts a call made while Wi-Fi was up. Returns true when the TLS
// connection should be closed and opened fresh.
bool noteCloud(CloudHealth& h, int code, const char* name) {
  if (code > 0) { h.fails = h.resets = 0; return false; }  // any HTTP answer: the link works
  if (++h.fails < CLOUD_FAILS_TO_RESET) return false;
  h.fails = 0;
  Serial.printf("%s: %lu failed calls, opening a fresh connection (largest free block %u)\n", name,
                (unsigned long)CLOUD_FAILS_TO_RESET, (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
  if (++h.resets >= CLOUD_RESETS_TO_RESTART) requestRestart(CloudFailing);
  return true;
}

// Nothing is waiting to be sent (a preventive restart must not drop records).
bool queuesEmpty() {
  for (QueueHandle_t q : {sessionReports, safetyReports, recognitionReports}) {
    if (q && uxQueueMessagesWaiting(q)) return false;
  }
  return true;
}

// Called from loop() (the safety task). Checks memory and the heartbeats,
// and restarts only while both outlets are idle or off.
void healthCheck(uint64_t now) {
  static uint64_t lastCheck = 0, lowSince = 0;
  if (now - lastCheck < 1000) return;
  lastCheck = now;
  if (heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) < LOW_BLOCK_BYTES) {
    if (!lowSince) lowSince = now;
    else if (now - lowSince >= LOW_MEMORY_MS) requestRestart(LowMemory);
  } else {
    lowSince = 0;
  }
  uint64_t nb = netBeat.load(), sb = supaBeat.load();
  if ((nb && now - nb >= TASK_STUCK_MS) || (sb && now - sb >= TASK_STUCK_MS)) requestRestart(TaskStuck);
  if (now >= PREVENTIVE_RESTART_MS) requestRestart(Preventive);
  if (appRestartAt && now >= appRestartAt) { appRestartAt = 0; requestRestart(AppRequest); }
  int why = restartWhy.load();
  if (why == NoRestart) return;
  for (auto& ch : outlets) {
    auto st = ch.data.safety.state;
    if ((st != SocketState::Idle && st != SocketState::Disabled) || ch.sessionOpen) return;  // wait: a run is on
  }
  if (why == Preventive && !queuesEmpty()) return;
  Preferences p;
  if (p.begin("health", false)) { p.putString("last", restartText(why)); p.end(); }
  Serial.printf("Self-restart now (both outlets idle or off): %s\n", restartText(why));
  Serial.flush();
  ESP.restart();
}

// ==========================================
// FIREBASE REST (network task only)
// ==========================================
WiFiClientSecure tls;
HTTPClient http;
String firebaseHost;
CloudHealth firebaseHealth;

// One secure (HTTPS) connection at a time. Each needs about 40 KB of memory
// in one piece; with Firebase's connection kept open, Supabase's could not
// start (largest free block ~17 KB, every upload failed). Supabase takes
// this lock, closes Firebase's connection, sends, and closes its own; while
// it holds the lock the Firebase calls skip their turn (they run again a
// second later). Safety runs in loop() and never waits for it.
SemaphoreHandle_t tlsLock = nullptr;
struct TlsTurn {
  bool held;
  explicit TlsTurn(TickType_t wait) : held(tlsLock && xSemaphoreTakeRecursive(tlsLock, wait) == pdTRUE) {}
  ~TlsTurn() { if (held) xSemaphoreGiveRecursive(tlsLock); }
};

// G: the plug's own login. With FIREBASE_DEVICE_EMAIL in secrets.h the plug
// signs in to its own Firebase account, which the database rules let write
// only what the plug writes (database.rules.json, device_accounts). The login
// lasts an hour and is renewed 5 minutes before it ends. Without it the old
// database secret (FIREBASE_AUTH) is used, which can read and change
// everything. A login problem never touches safety: the outlets keep working.
#ifdef FIREBASE_DEVICE_EMAIL
String idToken, refreshToken;
uint64_t tokenUntil = 0, tokenRetryAt = 0;
constexpr uint64_t TOKEN_EARLY_MS = 5 * 60 * 1000, TOKEN_RETRY_MS = 60 * 1000;

// One login request (sign in, or renew); the connection is closed before and
// after because it goes to a different server.
bool loginRequest(const String& url, const char* type, const String& body) {
  http.end(); tls.stop();
  int code = -1; String reply;
  if (http.begin(tls, url)) {
    http.setTimeout(8000);
    http.addHeader("Content-Type", type);
    code = http.POST(body);
    if (code == HTTP_CODE_OK) reply = http.getString();
    http.end();
  }
  tls.stop();
  JsonDocument doc;
  if (code != HTTP_CODE_OK || deserializeJson(doc, reply)) {
    Serial.printf("Firebase login failed (%d)\n", code);
    if (code == 400) refreshToken = "";  // renewal refused: sign in again next time
    return false;
  }
  // Sign-in and renewal name the same values differently.
  idToken = doc["idToken"] | doc["id_token"] | "";
  const char* r = doc["refreshToken"] | doc["refresh_token"] | "";
  if (*r) refreshToken = r;
  uint32_t lifeS = atoi(doc["expiresIn"] | doc["expires_in"] | "3600");
  tokenUntil = monotonicMs() + uint64_t(lifeS) * 1000;
  return idToken.length() > 0;
}

bool haveLogin() {
  uint64_t now = monotonicMs();
  if (idToken.length() && now + TOKEN_EARLY_MS < tokenUntil) return true;
  if (now < tokenRetryAt) return idToken.length() && now < tokenUntil;
  bool ok = false;
  if (refreshToken.length()) {
    ok = loginRequest(String("https://securetoken.googleapis.com/v1/token?key=") + FIREBASE_API_KEY,
                      "application/x-www-form-urlencoded",
                      "grant_type=refresh_token&refresh_token=" + refreshToken);
  }
  if (!ok) {
    JsonDocument req;
    req["email"] = FIREBASE_DEVICE_EMAIL; req["password"] = FIREBASE_DEVICE_PASSWORD;
    req["returnSecureToken"] = true;
    String body; serializeJson(req, body);
    ok = loginRequest(String("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=") +
                      FIREBASE_API_KEY, "application/json", body);
  }
  if (!ok) { tokenRetryAt = now + TOKEN_RETRY_MS; idToken = ""; }
  return ok;
}
const String& firebaseAuth() { return idToken; }
void loginRejected(int code) { if (code == 401) tokenUntil = 0; }  // renew at the next call
#else
bool haveLogin() { return true; }
String firebaseAuth() { return FIREBASE_AUTH; }
void loginRejected(int) {}
#endif

// Free-plan quota: Firebase answers a write with the data it wrote, and that
// echo counts as download (the 1 s update alone was ~10 GB a month, the whole
// Spark allowance). print=silent makes a write answer 204 with no body; it is
// reported to the callers as 200, so "stored" still reads HTTP_CODE_OK.
int silentOk(int code) { return code == HTTP_CODE_NO_CONTENT ? HTTP_CODE_OK : code; }

int firebaseRequest(const char* method, const String& path, const String& body = "", String* response = nullptr) {
  if (WiFi.status() != WL_CONNECTED) return -1;
  TlsTurn turn(0);
  if (!turn.held || !haveLogin()) return -1;  // Supabase is sending: next time
  int code = -1;
  bool get = strcmp(method, "GET") == 0;
  if (http.begin(tls, "https://" + firebaseHost + "/" + path + ".json?auth=" + firebaseAuth() +
                          (get ? "" : "&print=silent"))) {
    http.setTimeout(5000);
    if (get) code = http.GET();
    else { http.addHeader("Content-Type", "application/json"); code = silentOk(http.sendRequest(method, body)); }
    if (response && code == HTTP_CODE_OK) *response = http.getString();
    http.end();  // keeps the TLS connection open for reuse
  }
  loginRejected(code);
  if (noteCloud(firebaseHealth, code, "Firebase")) tls.stop();  // A: a fresh connection next time
  return code;
}
// C: the once-a-second update is written into this fixed buffer instead of a
// new String each time, so the heap is not cut into pieces over the weeks.
char patchBuffer[6144];
int firebasePatch(const JsonDocument& root) {
  if (WiFi.status() != WL_CONNECTED) return -1;
  TlsTurn turn(0);
  if (!turn.held || !haveLogin()) return -1;  // Supabase is sending: next time
  size_t n = serializeJson(root, patchBuffer, sizeof patchBuffer);
  if (n == 0 || n >= sizeof patchBuffer - 1) {  // too big for the buffer (not expected): as before
    String body; serializeJson(root, body);
    return firebaseRequest("PATCH", "", body);
  }
  int code = -1;
  if (http.begin(tls, "https://" + firebaseHost + "/.json?auth=" + firebaseAuth() + "&print=silent")) {
    http.setTimeout(5000);
    http.addHeader("Content-Type", "application/json");
    code = silentOk(http.sendRequest("PATCH", reinterpret_cast<uint8_t*>(patchBuffer), n));
    http.end();
  }
  loginRejected(code);
  if (noteCloud(firebaseHealth, code, "Firebase")) tls.stop();
  return code;
}

char lastQueued[2][64] = {};
void readCommands() {
  String body;
  if (firebaseRequest("GET", "commands", "", &body) != HTTP_CODE_OK) return;
  JsonDocument doc;
  if (deserializeJson(doc, body)) return;
  for (int i = 0; i < 2; ++i) {
    JsonObjectConst j = doc[outlets[i].outlet];
    if (j.isNull()) continue;
    Command c;
    strlcpy(c.id, j["commandID"] | "", sizeof(c.id)); strlcpy(c.session, j["sessionID"] | "", sizeof(c.session));
    strlcpy(c.type, j["type"] | "", sizeof(c.type)); strlcpy(c.alertID, j["alertID"] | "", sizeof(c.alertID));
    c.revision = uint32_t(j["revision"].as<double>()); c.expires = j["expiresAt"].as<int64_t>();
    if (!c.id[0] || strcmp(c.id, lastQueued[i]) == 0) continue;
    if (xQueueSend(outlets[i].commands, &c, 0) == pdTRUE) strlcpy(lastQueued[i], c.id, sizeof(lastQueued[i]));
  }
}

const char* stateName(SocketState s) {
  switch (s) {
    case SocketState::Sampling: return "SAMPLING"; case SocketState::Active: return "ACTIVE";
    case SocketState::Warning: return "WARNING"; case SocketState::LockedOut: return "LOCKED_OUT";
    case SocketState::Disabled: return "DISABLED"; default: return "IDLE";
  }
}
void addOutlet(JsonDocument& root, int i, const Snapshot& s) {
  const auto& ch = outlets[i];
  String b = String("telemetry_logs/") + ch.outlet + "/";
  auto st = s.safety.state;
  bool running = st == SocketState::Active || st == SocketState::Sampling || st == SocketState::Warning;
  bool sensorOK = s.sensor.valid && s.capturedMono - s.sensor.captured < SENSOR_TIMEOUT_MS;
  root[b + "status"] = st == SocketState::LockedOut ? "LOCKED_OUT" : (running ? "Active" : "Idle");
  root[b + "currentState"] = stateName(st); root[b + "sessionID"] = sessionID;
  root[b + "revision"] = s.safety.revision; root[b + "runtime_warning"] = s.safety.runtimeWarning;
  root[b + "overridden"] = running && s.safety.overridden;
  // Off after a safety reset, waiting for the user to turn it on again.
  root[b + "safetyResetHold"] = st == SocketState::Disabled && s.safety.resetHold;
  root[b + "relay_on"] = relayOnNow(s); root[b + "storage_ok"] = ch.storageOK;
  root[b + "profileID"] = s.activeProfileID;  // Supabase appliance id, "" until recognized
  // Rule-based recognition: RECOGNIZING, UNKNOWN, AMBIGUOUS, SAME_TYPE_IN_USE,
  // MATCHED_PROVISIONAL or MATCHED_CONFIRMED (the app shows the prompt).
  root[b + "recognitionStatus"] = s.recognition; root[b + "applianceConfirmed"] = s.confirmed;
  // The effective deadline, including any accepted runtime override.
  root[b + "safetyDeadline"] = running && s.safety.deadline > s.capturedMono && s.capturedEpoch
      ? timestamp(s.capturedEpoch + int64_t(s.safety.deadline - s.capturedMono)) : String("N/A");
  root[b + "appliance"] = s.activeProfileID[0] ? s.activeName
      : running && (strcmp(s.recognition, "RECOGNIZING") == 0 || strcmp(s.recognition, "PENDING") == 0)
      ? "Recognizing appliance"
      : running ? "Unknown appliance" : "None";
  root[b + "sensor_valid"] = sensorOK;
  root[b + "power_W"] = sensorOK ? s.sensor.power : 0; root[b + "current_A"] = sensorOK ? s.sensor.current : 0;
  root[b + "voltage_V"] = sensorOK ? s.sensor.voltage : 0; root[b + "power_factor"] = sensorOK ? s.sensor.pf : 0;
  if (sensorOK && isfinite(s.sensor.energy)) root[b + "energy_kWh"] = s.sensor.energy;
  root[b + "peak_power_W"] = s.peak; root[b + "start_time"] = timestamp(running ? s.startEpoch : 0);
  root[b + "last_updated"] = timestamp(s.capturedEpoch); root[b + "last_updated_ms"] = s.capturedEpoch;
  root[b + "alertID"] = s.alert.id; root[b + "countdownExpiry"] = timestamp(s.alert.expiry);
  // Why: SAFETY_CEILING_EXCEEDED (safe time up: the app's pop-up),
  // SENSOR_UNAVAILABLE, OVERCURRENT, POWER_ANOMALY or POWER_CUT (a restart
  // during a run), shown on the card.
  root[b + "alertType"] = s.alert.type;
  root[b + "countdownRemaining"] = st == SocketState::Warning
      ? int((60000 - min(uint64_t(60000), s.capturedMono - s.safety.warningStarted) + 999) / 1000) : 0;
  if (s.commandID[0]) {
    String a = String("command_results/") + ch.outlet + "/" + s.commandID + "/";
    root[a + "result"] = s.commandResult; root[a + "revision"] = s.safety.revision;
  }
}
// Device summary at devices/gadget-1/status. The app treats a stale lastSeen
// as Offline, since a powered-off board cannot report it.
void addStatus(JsonDocument& root, const Snapshot* s) {
  String b = String("devices/") + DEVICE_ID + "/status/";
  float draw = 0; bool triggered = false;
  int64_t remainingMs = -1;  // -1: nothing running, so no limit applies
  for (int i = 0; i < 2; ++i) {
    auto st = s[i].safety.state;
    root[b + "outlet" + OUTLET_HW[i].letter] = relayOnNow(s[i]);
    if (s[i].sensor.valid && s[i].capturedMono - s[i].sensor.captured < SENSOR_TIMEOUT_MS) draw += s[i].sensor.power;
    if (st == SocketState::Warning || st == SocketState::LockedOut) { triggered = true; remainingMs = 0; }
    else if ((st == SocketState::Active || st == SocketState::Sampling) && remainingMs != 0) {
      int64_t left = s[i].safety.deadline > s[i].capturedMono ? int64_t(s[i].safety.deadline - s[i].capturedMono) : 0;
      if (remainingMs < 0 || left < remainingMs) remainingMs = left;
    }
  }
  root[b + "powerDraw"] = draw; root[b + "connectionStatus"] = "Online";
  root[b + "safetyTriggered"] = triggered; root[b + "lastSeen"][".sv"] = "timestamp";
  root[b + "wifiSSID"] = WiFi.SSID();  // lets the app confirm a Wi-Fi change
  // Health, for checking a plug that runs for weeks (not shown in the app).
  JsonObject h = root[b + "health"].to<JsonObject>();
  h["uptimeS"] = uint32_t(monotonicMs() / 1000);
  h["freeHeap"] = ESP.getFreeHeap();
  h["largestBlock"] = (uint32_t)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
  h["lastRestart"] = lastRestart;
  if (remainingMs >= 0) root[b + "remainingLimit"] = double(remainingMs) / 1000.0;
  else root[b + "remainingLimit"] = nullptr;  // null deletes the field
}

// ==========================================
// SUPABASE (optional): session summaries and safety reports to Edge Functions
// ==========================================
#ifdef SUPABASE_FUNCTIONS_URL
WiFiClientSecure supaTls;
HTTPClient supaHttp;

CloudHealth supabaseHealth;
// For the Serial Monitor when an upload fails: the last HTTP code (0: not
// sent, e.g. the clock is not set yet; -1: no connection) and the largest
// free memory block just before connecting.
int supaLastCode = 0;
uint32_t supaLastBlock = 0;
int supabasePost(const char* function, const String& body, String* response = nullptr) {
  int code = -1;
  TlsTurn turn(pdMS_TO_TICKS(10000));
  if (!turn.held) return supaLastCode = -1;
  http.end(); tls.stop();  // free Firebase's connection for this one
  supaLastBlock = heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
  if (supaHttp.begin(supaTls, String(SUPABASE_FUNCTIONS_URL) + "/" + function)) {
    supaHttp.setTimeout(8000);
    supaHttp.addHeader("Content-Type", "application/json");
    supaHttp.addHeader("x-device-key", SUPABASE_DEVICE_KEY);
    code = supaHttp.POST(body);
    if (response && code > 0) *response = supaHttp.getString();
    supaHttp.end();
  }
  supaTls.stop();  // and this one's, for Firebase's next call
  supaLastCode = code;
  if (WiFi.status() == WL_CONNECTED) noteCloud(supabaseHealth, code, "Supabase");
  return code;
}
// Sent, a duplicate (already stored) or rejected as malformed: either way done.
bool supabaseDone(int code) { return code == 200 || code == 201 || code == 409 || code == 400 || code == 422; }
// Epoch ms of an event recorded at monotonic [mono], or 0 while the clock is unknown.
int64_t datedAt(int64_t at, uint64_t mono) {
  if (at) return at;
  int64_t nowMs = epochMs();
  return nowMs ? nowMs - int64_t(monotonicMs() - mono) : 0;
}
// The report is still worth sending: its run is in progress on its outlet
// and no later stage of that run is waiting behind it.
bool stillNeeded(const RecognitionReport& r) {
  const auto& ch = outlets[r.outlet];
  return ch.runMono.load() == r.startMono && ch.stageQueued.load() <= r.stage;
}

// recognize-appliance: one stage of a run. Answers come back to loop() through
// recognitionReplies. Returns false to retry later.
bool sendRecognition(const RecognitionReport& r) {
  int64_t start = datedAt(r.startEpoch, r.startMono);
  if (!start) { supaLastCode = 0; return false; }  // clock not set yet
  JsonDocument doc;
  doc["deviceId"] = DEVICE_ID; doc["outlet"] = OUTLET_HW[r.outlet].key;
  doc["eventId"] = r.eventID; doc["startedAt"] = start; doc["stage"] = r.stage;
  JsonObject x = doc["features"].to<JsonObject>();
  // At the meter's resolution: 0.1 W, 0.01 PF, 0.1 V.
  x["avg_power_w"] = roundf(r.f.avgPowerW * 100) / 100; x["avg_pf"] = roundf(r.f.avgPf * 1000) / 1000;
  x["avg_voltage_v"] = roundf(r.f.avgVoltageV * 10) / 10;
  x["startup_peak_ratio"] = roundf(r.f.startupPeakRatio * 1000) / 1000;
  x["settling_time_s"] = roundf(r.f.settlingTimeS * 10) / 10;
  if (r.f.hasVariation) x["power_variation"] = roundf(r.f.powerVariation * 10000) / 10000;
  if (r.f.hasCycle) x["cycle_period_s"] = roundf(r.f.cyclePeriodS * 10) / 10;
  if (r.f.hasStandby) x["standby_power_w"] = roundf(r.f.standbyPowerW * 100) / 100;
  x["unstable"] = r.f.unstable;
  // The runs going on now (same event IDs as queueRecognition): Supabase then
  // closes any other run of this plug that has really ended, e.g. when an
  // appliance moves from A to B before A's end was reported, so it is not
  // seen as "still running on A" (stale_runs.ts).
  JsonArray running = doc["running"].to<JsonArray>();
  for (const auto& ch : outlets) {
    uint64_t run = ch.runMono.load();
    if (!run) continue;
    char id[88];
    snprintf(id, sizeof(id), "%s_%s_%llu", sessionID, ch.outlet, (unsigned long long)run);
    running.add(id);
  }
  String body, response; serializeJson(doc, body);
  int code = supabasePost("recognize-appliance", body, &response);
  if (code != 200 && code != 201) return supabaseDone(code);  // 4xx: malformed, never retried
  JsonDocument reply;
  if (deserializeJson(reply, response)) return true;
  // recognition_config's thermostat rest (kept as they are if missing).
  if (reply["restGapS"].is<uint32_t>()) restGapS = min(reply["restGapS"].as<uint32_t>(), uint32_t(900));
  if (reply["restGapMinW"].is<float>()) restGapMinW = uint32_t(max(50.0f, reply["restGapMinW"].as<float>()));
  if (!reply["cutoffS"].is<uint32_t>()) return true;
  RecognitionReply c;
  c.outlet = r.outlet; c.stage = r.stage; c.startMono = r.startMono; c.cutoffS = reply["cutoffS"];
  strlcpy(c.status, reply["status"] | "", sizeof(c.status));
  strlcpy(c.applianceID, reply["applianceId"] | "", sizeof(c.applianceID));
  strlcpy(c.name, reply["applianceName"] | "", sizeof(c.name));
  xQueueSend(recognitionReplies, &c, 0);
  return true;
}

// Run ends and safety reports go straight from memory, as in the 35th
// commit (the flash store of the 36th was removed: run ends stopped reaching
// Supabase with it, so no use was ever counted). They wait in RAM while the
// internet is down and are sent once it is back; a restart in between loses
// them (the safety cutoffs themselves never depend on them).
int postSafety(const SafetyReport& r, int64_t at) {
  JsonDocument doc;
  doc["deviceId"] = DEVICE_ID; doc["outlet"] = OUTLET_HW[r.outlet].key;
  doc["eventId"] = r.eventID; doc["type"] = r.type; doc["occurredAt"] = at;
  doc["profileId"] = ""; doc["applianceName"] = r.name;
  doc["runtimeS"] = r.runtimeS; doc["limitS"] = r.limitS; doc["baselineS"] = 0;
  doc["learned"] = false; doc["sessionCount"] = 0;
  doc["powerW"] = r.power; doc["currentA"] = r.current;
  String body; serializeJson(doc, body);
  return supabasePost("evaluate-safety-alert", body);
}

int postSession(const SessionSummary& s, int64_t end) {
  Serial.printf("[%s] Sending run end (%s, %lu s) to Supabase\n", OUTLET_HW[s.outlet].outlet, s.reason,
                (unsigned long)s.durationS);
  JsonDocument doc;
  doc["deviceId"] = DEVICE_ID; doc["outlet"] = OUTLET_HW[s.outlet].key;
  doc["profileId"] = ""; doc["applianceName"] = s.name;
  doc["startedAt"] = s.startEpoch ? s.startEpoch : end - int64_t(s.durationS) * 1000;
  doc["endedAt"] = end; doc["durationS"] = s.durationS; doc["endReason"] = s.reason;
  doc["energyWh"] = s.energyWh; doc["peakCurrentA"] = s.peakCurrent; doc["peakPowerW"] = s.peakPower;
  // The 7-use learning is done by Supabase (log-session) for confirmed appliances.
  JsonObject learning = doc["learning"].to<JsonObject>();
  learning["sessionCount"] = 0; learning["learned"] = false; learning["limitS"] = s.limitS;
  learning["countsTowardLearning"] = false;
  String body; serializeJson(doc, body);
  return supabasePost("log-session", body);
}

// Each kind of report has its own retry time, so a failing one never holds
// up the others: safety reports first, then recognition (a run is waiting
// for its cutoff), then run ends (after the run's recognition, which opens
// its outlet session).
void sendSupabase() {
  static uint64_t safetyRetryAt = 0, recognitionRetryAt = 0, sessionRetryAt = 0;
  SafetyReport r;
  while (monotonicMs() >= safetyRetryAt && xQueuePeek(safetyReports, &r, 0) == pdTRUE) {
    int64_t at = datedAt(r.at, r.mono);
    if (!at) break;  // clock not set yet
    if (!supabaseDone(postSafety(r, at))) {
      Serial.printf("Safety report not delivered yet (HTTP %d, largest free block %lu), retrying in 10 s\n",
                    supaLastCode, (unsigned long)supaLastBlock);
      safetyRetryAt = monotonicMs() + 10000;
      break;
    }
    xQueueReceive(safetyReports, &r, 0);
  }
  RecognitionReport f;
  while (monotonicMs() >= recognitionRetryAt && xQueuePeek(recognitionReports, &f, 0) == pdTRUE) {
    // A run that has ended needs no cutoff, and Stage 2 replaces Stage 1.
    if (!stillNeeded(f) || sendRecognition(f)) { xQueueReceive(recognitionReports, &f, 0); continue; }
    // Unreachable or failing: the run keeps its current (default) cutoff; try again soon.
    Serial.printf("[%s] Stage %d not delivered yet (HTTP %d, largest free block %lu), retrying\n",
                  outlets[f.outlet].outlet, f.stage, supaLastCode, (unsigned long)supaLastBlock);
    recognitionRetryAt = monotonicMs() + RECOGNITION_RETRY_MS;
    break;
  }
  SessionSummary sum;
  while (monotonicMs() >= sessionRetryAt && xQueuePeek(sessionReports, &sum, 0) == pdTRUE) {
    int64_t end = datedAt(sum.endEpoch, sum.endMono);
    if (!end) break;  // clock not set yet
    if (!supabaseDone(postSession(sum, end))) {
      Serial.printf("Run end not delivered yet (HTTP %d, largest free block %lu), retrying in 10 s\n",
                    supaLastCode, (unsigned long)supaLastBlock);
      sessionRetryAt = monotonicMs() + 10000;
      break;
    }
    xQueueReceive(sessionReports, &sum, 0);
  }
}
#endif

// ==========================================
// WI-FI: home network + local setup network
// Boot: try the saved router for 20 s. If that fails, or nothing is saved, the
// plug opens its own Wi-Fi "wisewp" (open, one tap to join). Phones then show
// the setup page by themselves (captive portal): it lists the 2.4 GHz networks
// the plug can see, so the user taps theirs, types its password and is done.
// The app can do the same through /status, /networks and /save-wifi. The
// station never searches while "wisewp" is up, so the setup network stays on
// one channel and phones stay joined. While nobody is joined, the saved
// router is retried every 2 minutes (after a power cut the router often boots
// slower than the plug). New details are saved only once they connect; a
// failed change made from the app rolls back to the saved network, one made
// from setup returns to "wisewp". No reboot: it would lock a running outlet.
// ==========================================
constexpr const char* SETUP_AP_SSID = "wisewp";
constexpr uint64_t CONNECT_TIMEOUT_MS = 20000, OFFLINE_TO_SETUP_MS = 60000, SETUP_RETRY_MS = 120000;

enum class NetMode { Connecting, Online, Setup };
NetMode netMode = NetMode::Connecting;
Preferences wifiPrefs;
String savedSsid, savedPass;  // last network that worked
String trialSsid, trialPass;  // being tried; saved once connected
bool trialFromSetup = false, legacyCredentials = false;
uint64_t modeSince = 0, lastConnected = 0;
int64_t appliedConfig = 0;
WebServer setupServer(80);
DNSServer setupDns;
String queuedSsid, queuedPass;  // received by /save-wifi
bool queued = false;
uint64_t queuedAt = 0;
String networksJson = "[]";  // last scan, for the setup page and the app
uint64_t scannedAt = 0;

// Credentials kept by the ESP-IDF itself (e.g. saved by an older firmware).
bool storedByEspIdf() {
  wifi_config_t conf = {};
  return esp_wifi_get_config(WIFI_IF_STA, &conf) == ESP_OK && conf.sta.ssid[0];
}
// Networks the plug can actually join (it only hears 2.4 GHz): strongest
// first, one entry per name, names exactly as broadcast (spaces included).
void scanNetworks() {
  int n = WiFi.scanNetworks();
  std::vector<int> order;
  for (int i = 0; i < n; ++i) if (WiFi.SSID(i).length()) order.push_back(i);
  std::sort(order.begin(), order.end(), [](int a, int b) { return WiFi.RSSI(a) > WiFi.RSSI(b); });
  JsonDocument doc; JsonArray list = doc.to<JsonArray>();
  std::vector<String> seen;
  for (int i : order) {
    String ssid = WiFi.SSID(i);
    if (std::find(seen.begin(), seen.end(), ssid) != seen.end()) continue;
    seen.push_back(ssid);
    JsonObject network = list.add<JsonObject>();
    network["ssid"] = ssid; network["rssi"] = WiFi.RSSI(i);
    network["secure"] = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
    if (list.size() >= 20) break;
  }
  WiFi.scanDelete();
  networksJson = ""; serializeJson(doc, networksJson); scannedAt = monotonicMs();
}
void startConnect(const String& ssid, const String& pass, bool trial, bool fromSetup) {
  if (netMode == NetMode::Setup) { setupServer.stop(); setupDns.stop(); WiFi.softAPdisconnect(true); }
  WiFi.mode(WIFI_STA); WiFi.disconnect(); WiFi.setAutoReconnect(true);
  trialSsid = trial ? ssid : ""; trialPass = trial ? pass : ""; trialFromSetup = fromSetup;
  if (ssid.length()) WiFi.begin(ssid.c_str(), pass.c_str());
  else WiFi.begin();  // whatever the ESP-IDF has stored
  netMode = NetMode::Connecting; modeSince = monotonicMs();
  Serial.printf("Wi-Fi: connecting to \"%s\"\n", ssid.length() ? ssid.c_str() : "stored network");
}
void startSetup() {
  WiFi.setAutoReconnect(false); WiFi.disconnect();
  WiFi.mode(WIFI_AP_STA);  // the station stays idle; it is only used to list networks
  scanNetworks();          // before the AP starts, so the scan cannot disturb phones
  WiFi.softAP(SETUP_AP_SSID);
  setupDns.start(53, "*", WiFi.softAPIP());  // captive portal: every name -> this page
  setupServer.begin();
  netMode = NetMode::Setup; modeSince = monotonicMs();
  Serial.printf("Wi-Fi: join \"%s\" and open http://%s\n", SETUP_AP_SSID, WiFi.softAPIP().toString().c_str());
}

const char SETUP_PAGE[] PROGMEM = R"HTML(<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>WisePlug setup</title>
<style>body{font-family:sans-serif;max-width:420px;margin:20px auto;padding:0 16px;color:#222}
button,input{width:100%;padding:14px;margin:5px 0;font-size:17px;box-sizing:border-box;border-radius:10px}
input{border:1px solid #bbb}.go{background:#00A4EF;color:#fff;border:0;font-weight:bold}
.net{background:#f1f3f5;border:0;text-align:left}a{color:#00A4EF}</style></head>
<body><h2>Connect your WisePlug</h2><p id="hint">Tap your home Wi-Fi:</p><div id="list">Searching&hellip;</div>
<form id="form" method="post" action="/save-wifi" hidden><p>Password for <b id="name"></b></p>
<input type="hidden" name="ssid" id="ssid"><input name="password" id="pw" type="password" maxlength="63" placeholder="Wi-Fi password">
<button class="go">Connect</button></form>
<p><a href="#" id="other">My network is not listed</a> &middot; <a href="#" id="again">Search again</a></p>
<p style="color:#888;font-size:13px">Only 2.4 GHz networks can be used. A "5G" network will not appear.</p>
<script>
const list=document.getElementById('list'),form=document.getElementById('form');
function pick(n,secure){form.hidden=false;ssid.value=n;document.getElementById('name').textContent='"'+n+'"';
pw.hidden=!secure;pw.required=secure;if(secure)pw.focus();form.scrollIntoView();}
function load(again){list.textContent='Searching…';fetch('/networks'+(again?'?refresh=1':'')).then(r=>r.json()).then(nets=>{
list.textContent=nets.length?'':'No 2.4 GHz networks found. Move closer to the router and search again.';
nets.forEach(w=>{const b=document.createElement('button');b.type='button';b.className='net';
b.textContent=(w.secure?'🔒 ':'')+w.ssid+(w.rssi>-60?'  (strong)':w.rssi>-75?'':'  (weak)');
b.onclick=()=>pick(w.ssid,w.secure);list.appendChild(b);});});}
other.onclick=e=>{e.preventDefault();const n=prompt('Network name, exactly as it is written:');if(n)pick(n,true);};
again.onclick=e=>{e.preventDefault();load(true);};load(false);
</script></body></html>)HTML";

// Lets the app (including the web build) read replies from this local address.
void sendCors() {
  setupServer.sendHeader("Access-Control-Allow-Origin", "*");
  setupServer.sendHeader("Access-Control-Allow-Private-Network", "true");
}
void handleSaveWifi() {
  sendCors();
  if (setupServer.method() == HTTP_OPTIONS) {
    setupServer.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    setupServer.sendHeader("Access-Control-Allow-Headers", "Content-Type");
    setupServer.send(204);
    return;
  }
  String ssid = setupServer.arg("ssid"), pass = setupServer.arg("password");
  const char* error = !ssid.length() || ssid.length() > 32 ? "Enter a network name up to 32 characters."
      : pass.length() && (pass.length() < 8 || pass.length() > 63) ? "Wi-Fi passwords are 8 to 63 characters."
      : nullptr;
  if (setupServer.hasArg("app")) {  // JSON for the app; the form gets a page
    JsonDocument doc; doc["ok"] = !error; doc["device"] = DEVICE_ID;
    if (error) doc["error"] = error;
    String body; serializeJson(doc, body);
    setupServer.send(error ? 400 : 200, "application/json", body);
  } else {
    setupServer.send(error ? 400 : 200, "text/html",
        String("<!doctype html><meta name=\"viewport\" content=\"width=device-width\"><p style=\"font-family:sans-serif\">") +
        (error ? error : "Saved. The WisePlug is joining your network now. Reconnect this phone to your home Wi-Fi.") + "</p>");
  }
  if (!error) { queuedSsid = ssid; queuedPass = pass; queued = true; queuedAt = monotonicMs(); }
}
void setupRoutes() {
  setupServer.on("/", HTTP_GET, [] { setupServer.send_P(200, "text/html", SETUP_PAGE); });
  setupServer.on("/status", HTTP_GET, [] {
    sendCors();
    setupServer.send(200, "application/json", String("{\"device\":\"") + DEVICE_ID + "\",\"mode\":\"setup\"}");
  });
  setupServer.on("/networks", HTTP_GET, [] {
    if (setupServer.hasArg("refresh") || !scannedAt) scanNetworks();
    sendCors();
    setupServer.send(200, "application/json", networksJson);
  });
  setupServer.on("/save-wifi", HTTP_ANY, handleSaveWifi);
  setupServer.on("/config", HTTP_ANY, handleSaveWifi);
  setupServer.onNotFound([] {  // phones probe a URL to detect captive portals
    setupServer.sendHeader("Location", "http://192.168.4.1/");
    setupServer.send(302);
  });
}

void updateWifi(uint64_t now) {
  bool connected = WiFi.status() == WL_CONNECTED;
  switch (netMode) {
    case NetMode::Connecting:
      if (connected) {
        netMode = NetMode::Online; lastConnected = now;
        String ssid = trialSsid.length() ? trialSsid : WiFi.SSID();
        String pass = trialSsid.length() ? trialPass : WiFi.psk();
        if (ssid.length() && (ssid != savedSsid || pass != savedPass)) {  // it works: keep it
          savedSsid = ssid; savedPass = pass;
          wifiPrefs.putString("ssid", ssid); wifiPrefs.putString("pass", pass);
        }
        trialSsid = "";
        Serial.printf("Wi-Fi: online on %s\n", WiFi.SSID().c_str());
        // Internet time, started once Wi-Fi works and only once (it keeps
        // itself up to date). Started at boot, while Wi-Fi was still
        // connecting, its first time request crashed the plug (lwIP assert
        // in sntp_request -> dns -> udp_new).
        static bool clockStarted = false;
        if (!clockStarted) {
          clockStarted = true;
          configTime(0, 0, "pool.ntp.org", "time.google.com");  // UTC; the app localizes
        }
      } else if (now - modeSince > CONNECT_TIMEOUT_MS) {
        bool rollback = trialSsid.length() && !trialFromSetup && savedSsid.length();
        if (rollback) startConnect(savedSsid, savedPass, false, false);
        else startSetup();
      }
      break;
    case NetMode::Online:
      if (connected) lastConnected = now;
      else if (now - lastConnected > OFFLINE_TO_SETUP_MS) startSetup();  // router gone
      break;
    case NetMode::Setup:
      setupDns.processNextRequest(); setupServer.handleClient();
      if (queued && now - queuedAt > 1000) {  // let the reply reach the phone first
        queued = false;
        startConnect(queuedSsid, queuedPass, true, true);
      } else if (now - modeSince > SETUP_RETRY_MS && WiFi.softAPgetStationNum() == 0 &&
                 (savedSsid.length() || legacyCredentials)) {
        startConnect(savedSsid, savedPass, false, false);
      }
      break;
  }
}

void checkWifiConfig() {
  String path = String("devices/") + DEVICE_ID + "/wifiConfig", body;
  if (firebaseRequest("GET", path, "", &body) != HTTP_CODE_OK) return;
  JsonDocument doc;
  if (deserializeJson(doc, body) || !doc["ssid"].is<const char*>() || !doc["password"].is<const char*>()) return;
  int64_t updatedAt = doc["updatedAt"].as<int64_t>();
  String ssid = doc["ssid"].as<const char*>(), pass = doc["password"].as<const char*>();
  if (!updatedAt || updatedAt == appliedConfig || !ssid.length() || ssid.length() > 32 || pass.length() > 63) return;
  appliedConfig = updatedAt; wifiPrefs.putLong64("applied", updatedAt);
  // ackAt (server time) marks the switch: later status updates come from the new attempt.
  JsonDocument ack; ack["receivedAt"] = updatedAt; ack["ackAt"][".sv"] = "timestamp";
  String ackBody; serializeJson(ack, ackBody);
  firebaseRequest("PATCH", path, ackBody);
  firebaseRequest("DELETE", path + "/password");  // keep the secret only on the device
  startConnect(ssid, pass, true, false);  // rolls back to the saved network if it fails
}

// ==========================================
// NETWORK TASK (core 0): never blocks the safety loop
// ==========================================
// E: firmware updates over Wi-Fi from the Arduino IDE (Arduino OTA), only when
// OTA_PASSWORD is set in secrets.h, and only while both outlets are idle or
// off: an update restarts the plug, which would lock a running outlet.
#ifdef OTA_PASSWORD
bool otaStarted = false;
void handleOta(bool connected, const Snapshot* latest, bool available) {
  if (!connected) return;
  if (!otaStarted) {
    ArduinoOTA.setHostname("wiseplug-" DEVICE_ID_TEXT);
    ArduinoOTA.setPassword(OTA_PASSWORD);
    ArduinoOTA.onStart([] { Serial.println("Update over Wi-Fi: starting"); });
    ArduinoOTA.onEnd([] { Serial.println("Update over Wi-Fi: done, restarting"); });
    ArduinoOTA.onError([](ota_error_t e) { Serial.printf("Update over Wi-Fi failed (%d)\n", int(e)); });
    ArduinoOTA.begin();
    otaStarted = true;
  }
  if (!available) return;
  for (int i = 0; i < 2; ++i) {
    auto st = latest[i].safety.state;
    if (st != SocketState::Idle && st != SocketState::Disabled) return;  // a run is on: later
  }
  ArduinoOTA.handle();
}
#endif

void networkTask(void*) {
  firebaseHost = FIREBASE_HOST;
  firebaseHost.replace("https://", ""); firebaseHost.replace("http://", "");
  while (firebaseHost.endsWith("/")) firebaseHost.remove(firebaseHost.length() - 1);
  // Encrypted, but the servers' certificates are not checked (setInsecure),
  // as in the 35th commit. Checking them against the ESP32's root
  // certificates (36th commit) needed more memory than the plug has: uploads
  // failed and a check crashed the plug. Known limitation: on an untrusted
  // Wi-Fi a fake server could pose as Firebase or Supabase.
  tls.setInsecure();
#ifdef SUPABASE_FUNCTIONS_URL
  supaTls.setInsecure();
#endif
  wifiPrefs.begin("wifi", false); appliedConfig = wifiPrefs.getLong64("applied", 0);
  savedSsid = wifiPrefs.getString("ssid", ""); savedPass = wifiPrefs.getString("pass", "");
  WiFi.mode(WIFI_STA); WiFi.setAutoReconnect(true);
  legacyCredentials = storedByEspIdf();
  setupRoutes();
  if (savedSsid.length() || legacyCredentials) startConnect(savedSsid, savedPass, false, false);
  else startSetup();  // nothing to connect to yet
  // The clock sync starts in updateWifi() once Wi-Fi is online, not here.
  static Snapshot latest[2]; bool available[2] = {false, false};
  uint64_t lastCommands = 0, lastPublish = 0, lastConfig = 0;
  for (;;) {
    uint64_t now = monotonicMs();
    netBeat = now;  // D: the safety loop checks this heartbeat
    updateWifi(now);
    bool connected = netMode == NetMode::Online && WiFi.status() == WL_CONNECTED;
    for (int i = 0; i < 2; ++i) {
      if (xQueueReceive(outlets[i].snapshots, &latest[i], 0) == pdTRUE) available[i] = true;
    }
    if (connected) {
      if (now - lastCommands >= 1000) { lastCommands = now; readCommands(); }
      if (available[0] && available[1] && now - lastPublish >= 1000) {
        lastPublish = now;
        JsonDocument root;
        for (int i = 0; i < 2; ++i) addOutlet(root, i, latest[i]);
        addStatus(root, latest);
        firebasePatch(root);
      }
      if (now - lastConfig >= 10000) { lastConfig = now; checkWifiConfig(); }
    }
#ifdef OTA_PASSWORD
    handleOta(connected, latest, available[0] && available[1]);
#endif
    vTaskDelay(pdMS_TO_TICKS(netMode == NetMode::Setup ? 10 : 100));  // snappy setup page
  }
}

#ifdef SUPABASE_FUNCTIONS_URL
// Supabase uploads get their own task: one POST (TLS handshake plus the Edge
// Function's database writes and push) can take many seconds, and inside the
// Firebase task that froze telemetry_logs, so the app saw stale outlets and
// refused Reset Safety while the device's commands went unread.
void supabaseTask(void*) {
  for (;;) {
    supaBeat = monotonicMs();  // D: the safety loop checks this heartbeat
    if (netMode == NetMode::Online && WiFi.status() == WL_CONNECTED) sendSupabase();
    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}
#endif

// ==========================================
// SETUP & CONTROL LOOP (core 1)
// ==========================================
void setup() {
  // Relays stay off until the persisted safety state is known.
  for (const auto& h : OUTLET_HW) { digitalWrite(h.relay, !h.relayOn); pinMode(h.relay, OUTPUT); }
  Serial.begin(115200);
  tlsLock = xSemaphoreCreateRecursiveMutex();
  configASSERT(tlsLock);
#ifdef SUPABASE_FUNCTIONS_URL
  sessionReports = xQueueCreate(8, sizeof(SessionSummary));
  safetyReports = xQueueCreate(8, sizeof(SafetyReport));
  recognitionReports = xQueueCreate(4, sizeof(RecognitionReport));
  recognitionReplies = xQueueCreate(4, sizeof(RecognitionReply));
#endif
  // The PZEM constructors open these ports before the core is fully started,
  // which is unreliable; open them again here so both meters respond.
  for (const auto& h : OUTLET_HW) h.port.begin(9600, SERIAL_8N1, h.rx, h.tx);
  snprintf(sessionID, sizeof(sessionID), "%08lx%08lx", (unsigned long)esp_random(), (unsigned long)esp_random());
  for (int i = 0; i < 2; ++i) {
    auto& ch = outlets[i];
    const auto& h = OUTLET_HW[i];
    ch.ns = h.ns; ch.outlet = h.outlet; ch.relay = h.relay; ch.relayOn = h.relayOn; ch.button = h.button;
    pinMode(ch.button, INPUT_PULLUP);
    ch.rawButton = ch.stableButton = digitalRead(ch.button); ch.buttonChanged = monotonicMs();
    ch.sensors = xQueueCreate(1, sizeof(SensorSample)); ch.commands = xQueueCreate(4, sizeof(Command));
    ch.snapshots = xQueueCreate(1, sizeof(Snapshot));
    configASSERT(ch.sensors && ch.commands && ch.snapshots);
    ch.storageOK = ch.prefs.begin(ch.ns, false);
    ch.prefs.getBytes("alert", &ch.data.alert, sizeof(AlertRecord));
    ch.data.alert.id[79] = 0; ch.data.alert.type[39] = 0; ch.data.alert.resolution[15] = 0;
    // A reboot during a running session (e.g. power cut) locks out: nothing restarts unattended.
    if (!ch.storageOK || ch.prefs.getBool("hazard", false)) {
      // Its own reason (not a saved, older one): the app shows a power cut on
      // the outlet card, never as the "safe time is up" pop-up.
      auto& a = ch.data.alert;
      snprintf(a.id, sizeof(a.id), "%s_%s_boot", sessionID, ch.outlet);
      strlcpy(a.type, "POWER_CUT", sizeof(a.type));
      a.resolution[0] = 0;  // not an unanswered warning: no LOCKED_OUT report
      a.trigger = a.expiry = 0;
      lock(ch);
    }
    else if (ch.prefs.getBool("disabled", false)) {
      ch.data.safety.state = SocketState::Disabled;
      ch.data.safety.resetHold = ch.prefs.getBool("hold", false);
    }
    applyRelay(ch);
  }
  configASSERT(xTaskCreatePinnedToCore(sensorTask, "meters", 4096, nullptr, 1, nullptr, 0) == pdPASS);
  configASSERT(xTaskCreatePinnedToCore(networkTask, "firebase", 16384, nullptr, 1, nullptr, 0) == pdPASS);
#ifdef SUPABASE_FUNCTIONS_URL
  configASSERT(xTaskCreatePinnedToCore(supabaseTask, "supabase", 12288, nullptr, 1, nullptr, 0) == pdPASS);
#endif
  {
    Preferences p;  // B: why the plug last restarted itself (shown once in the status)
    if (p.begin("health", false)) {
      strlcpy(lastRestart, p.getString("last", "").c_str(), sizeof(lastRestart));
      p.remove("last"); p.end();
    }
    if (!lastRestart[0] && esp_reset_reason() == ESP_RST_TASK_WDT) strlcpy(lastRestart, "watchdog", sizeof(lastRestart));
    if (!lastRestart[0] && esp_reset_reason() == ESP_RST_BROWNOUT) strlcpy(lastRestart, "brownout", sizeof(lastRestart));
    if (!lastRestart[0] && esp_reset_reason() == ESP_RST_PANIC) strlcpy(lastRestart, "crash", sizeof(lastRestart));
  }
  // D: the hardware watchdog restarts the plug if the safety loop freezes.
  enableLoopWDT();
  // 1 = power-on, 3 = software reset, 4/5 = crash, 6/7 = watchdog, 9 = brownout.
  // Any reboot while a session runs locks both outlets ("Power cut" in the app).
  Serial.printf("SYSTEM READY (reset reason %d, free heap %u)\n", int(esp_reset_reason()), ESP.getFreeHeap());
}

void loop() {
  uint64_t now = monotonicMs();
  // recognize-appliance's answer for a run (Stage 1 or 2).
  //  * MATCHED_CONFIRMED: the appliance's own cutoff (it may be longer than the
  //    default: Supabase, over authenticated HTTPS, has confirmed what it is).
  //  * any other status: the server's cutoff, but never above DEFAULT_LIMIT_S,
  //    so an unconfirmed load can never get another appliance's limit even if
  //    the server were wrong.
  // A confirmed cutoff already received stays for the rest of the run even if
  // Wi-Fi drops; a run that never got one keeps the default.
  RecognitionReply reply;
  while (recognitionReplies && xQueueReceive(recognitionReplies, &reply, 0) == pdTRUE) {
    auto& ch = outlets[reply.outlet];
    auto& d = ch.data;
    auto& safety = d.safety;
    if (!ch.sessionOpen || ch.sessionStartMono != reply.startMono || !reply.cutoffS ||
        (safety.state != SocketState::Active && safety.state != SocketState::Sampling)) continue;
    // A late Stage 1 answer never overrides what Stage 2 or the user decided.
    if (d.confirmed && strcmp(reply.status, "MATCHED_CONFIRMED") != 0) continue;
    bool confirmed = strcmp(reply.status, "MATCHED_CONFIRMED") == 0;
    uint32_t limit = min(reply.cutoffS, confirmed ? MAX_CONFIRMED_LIMIT_S : DEFAULT_LIMIT_S);
    // Time the user granted with "Yes, Override" is not taken back.
    if (!safety.overridden) { safety.deadline = safety.started + uint64_t(limit) * 1000; }
    ++safety.revision;
    strlcpy(d.recognition, reply.status[0] ? reply.status : "UNKNOWN", sizeof(d.recognition));
    d.confirmed = confirmed;
    bool matched = confirmed || strcmp(reply.status, "MATCHED_PROVISIONAL") == 0;
    strlcpy(d.activeProfileID, matched ? reply.applianceID : "", sizeof(d.activeProfileID));
    strlcpy(d.activeName, matched ? reply.name : "", sizeof(d.activeName));
    Serial.printf("[%s] Stage %d: %s%s%s, cutoff %lu s\n", ch.outlet, reply.stage, reply.status,
                  matched ? " " : "", matched ? reply.name : "", (unsigned long)limit);
  }
  for (auto& ch : outlets) {
    auto& d = ch.data;
    auto& safety = d.safety;
    // "Near limit" (runtime_warning) once the run reaches its current cutoff.
    if (safety.tick(now, currentLimitS(safety))) {
      if (safety.state == SocketState::Warning) beginAlert(ch, "SAFETY_CEILING_EXCEEDED", now); else lock(ch);
    }
    bool raw = digitalRead(ch.button);
    if (raw != ch.rawButton) { ch.rawButton = raw; ch.buttonChanged = now; }
    if (raw != ch.stableButton && now - ch.buttonChanged >= 50) {
      ch.stableButton = raw;
      if (!raw && ch.storageOK) {
        if (safety.state == SocketState::Warning) lock(ch);
        else {
          safety.physicalPress();
          endSession(ch, "TURNED_OFF"); persistSafety(ch);
        }
      }
    }
    SensorSample sample;
    if (xQueueReceive(ch.sensors, &sample, 0) == pdTRUE) {
      if (sample.valid) ch.lastValid = now;
      handleSensor(ch, sample, now);
      if (sample.valid) meterRecovered(ch);
    }
    // No good reading for SENSOR_TIMEOUT_MS (not just one spoiled reading).
    if ((safety.state == SocketState::Active || safety.state == SocketState::Sampling) &&
        now - ch.lastValid > SENSOR_TIMEOUT_MS) beginAlert(ch, "SENSOR_UNAVAILABLE", now);
    Command cmd;
    if (xQueueReceive(ch.commands, &cmd, 0) == pdTRUE) handleCommand(ch, cmd, now);
    applyRelay(ch);
    if (now - ch.lastSnapshot >= 250) {
      ch.lastSnapshot = now; d.capturedMono = now; d.capturedEpoch = epochMs();
      if (d.alert.id[0] && !d.alert.trigger && d.capturedEpoch && safety.state == SocketState::Warning) {
        d.alert.trigger = d.capturedEpoch - int64_t(now - safety.warningStarted);
        d.alert.expiry = d.alert.trigger + 60000; persistSafety(ch);
      }
      xQueueOverwrite(ch.snapshots, &d);
    }
  }
  healthCheck(now);  // A/B/D: memory, heartbeats, safe self-restart
  delay(10);
}