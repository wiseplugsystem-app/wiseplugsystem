// WisePlug ESP32 firmware: two PZEM-004T v3 meters, two relays, Firebase
// Realtime Database over REST. Matches the Flutter app's protocol:
//   telemetry_logs/outlet_A|B              live state, read by the app
//   appliance_profiles/OUTLET_A|B/<id>     learned appliance catalog
//   commands/outlet_A|B -> command_results confirmed app commands
//   alerts/<alertID>                       push-notification records
//   devices/gadget-1/status, /wifiConfig   gadget summary, Wi-Fi provisioning
//
// Libraries: PZEM004Tv30, WiFiManager (tzapu), ArduinoJson 7.
#include <PZEM004Tv30.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
// Exact 64-bit millisecond timestamps (doubles would be rounded in JSON).
#define ARDUINOJSON_USE_LONG_LONG 1
#include <ArduinoJson.h>
#include <esp_timer.h>
#include <time.h>
#include "secrets.h"        // FIREBASE_HOST, FIREBASE_AUTH. Never commit or share.
#include "safety_state.h"   // shared state machine, unit-tested in test/

// ==========================================
// CONFIGURATION
// ==========================================
constexpr const char* DEVICE_ID = "gadget-1";  // must match the app's DeviceBinding

// Relay polarity. This board is active-low: a LOW pin closes the relay
// (confirmed: "relay off" passed 68 W, "relay on" passed 0 W).
#define RELAY_ON  LOW
#define RELAY_OFF HIGH

constexpr int PZEM_A_RX = 32, PZEM_A_TX = 33, PZEM_B_RX = 25, PZEM_B_TX = 26;
constexpr int RELAY_A_PIN = 18, RELAY_B_PIN = 19;
constexpr int BUTTON_A_PIN = 4, BUTTON_B_PIN = 5;  // optional reset buttons to GND

constexpr float START_W_THRESHOLD = 3.5f, IDLE_W_THRESHOLD = 1.5f;
constexpr float POWER_TOLERANCE = 0.15f, CURRENT_TOLERANCE = 0.20f, PF_TOLERANCE = 0.10f;
constexpr uint32_t SAMPLE_TIME_MS = 1500, MAX_APPLIANCES = 20;
constexpr uint32_t DEFAULT_LIMIT_S = 30 * 60;  // runtime warning and safety ceiling for new appliances
constexpr uint64_t SENSOR_TIMEOUT_MS = 5000;

// ==========================================
// DATA STRUCTURES
// ==========================================
struct ApplianceSignature {
  char name[64] = {}, profileID[64] = {};
  float steadyPower = 0, peakPower = 0, current = 0, voltage = 0, pf = 0;
  uint32_t maxRunTime = DEFAULT_LIMIT_S, safetyCeilingDuration = DEFAULT_LIMIT_S, totalSessions = 0;
  int64_t registeredAt = 0;
};
// Record layout written by the previous sketch ("app_N" keys), migrated once.
struct LegacySignature {
  char name[32]; float steadyPower, peakPower, current, voltage, pf; int safetyLimitMinutes;
};
struct SensorSample { float power, current, voltage, pf, energy; bool valid; uint64_t captured; };
struct Command {
  char id[64] = {}, session[40] = {}, type[24] = {}, alertID[80] = {}, profileID[64] = {}, name[64] = {};
  uint32_t revision = 0, extension = 0, maxRunTime = 0, ceiling = 0;
  int64_t expires = 0;
};
struct AlertRecord {
  char id[80] = {}, type[40] = {}, resolution[16] = {};
  int64_t trigger = 0, expiry = 0;
};
struct Snapshot {
  SafetyState safety;
  SensorSample sensor = {};
  ApplianceSignature profiles[MAX_APPLIANCES];
  uint32_t count = 0, profilesVersion = 0;
  int activeID = -1;
  float peak = 0;
  int64_t startEpoch = 0, capturedEpoch = 0;
  uint64_t capturedMono = 0;
  AlertRecord alert;
  char commandID[64] = {}, commandResult[40] = {};
};
struct SocketChannel {
  Preferences prefs;
  const char *ns, *outlet, *catalog, *legacyCatalog;
  int relay, button;
  Snapshot data;
  ApplianceSignature pending;
  uint32_t samples = 0;
  uint64_t buttonChanged = 0, lastSnapshot = 0;
  bool rawButton = true, stableButton = true, storageOK = true;
  QueueHandle_t sensors, commands, snapshots;
};

PZEM004Tv30 pzemA(Serial2, PZEM_A_RX, PZEM_A_TX), pzemB(Serial1, PZEM_B_RX, PZEM_B_TX);
SocketChannel outlets[2];
char sessionID[40];

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
void applyRelay(SocketChannel& ch) {
  digitalWrite(ch.relay, relayEnergized(ch.data.safety.state) ? RELAY_ON : RELAY_OFF);
}
bool persistSafety(SocketChannel& ch) {
  auto state = ch.data.safety.state;
  bool hazardous = state == SocketState::Sampling || state == SocketState::Active || state == SocketState::Warning || state == SocketState::LockedOut;
  bool ok = ch.prefs.putBool("hazard", hazardous) == 1;
  ok = (ch.prefs.putBool("disabled", state == SocketState::Disabled) == 1) && ok;
  if (ch.data.alert.id[0]) ok = (ch.prefs.putBytes("alert", &ch.data.alert, sizeof(AlertRecord)) == sizeof(AlertRecord)) && ok;
  if (!ok) { ch.storageOK = false; ch.data.safety.state = SocketState::LockedOut; }
  applyRelay(ch);
  return ok;
}
void endSession(SocketChannel& ch) { ch.data.activeID = -1; ch.data.peak = 0; }
void lock(SocketChannel& ch) {
  ch.data.safety.state = SocketState::LockedOut; ++ch.data.safety.revision;
  if (ch.data.alert.id[0]) strlcpy(ch.data.alert.resolution, "SHUTDOWN", sizeof(ch.data.alert.resolution));
  endSession(ch); persistSafety(ch);
  Serial.printf("[%s] LOCKED OUT, relay off\n", ch.outlet);
}
bool saveProfiles(SocketChannel& ch) {
  if (ch.prefs.putBytes("profiles_v3", ch.data.profiles, sizeof(ch.data.profiles)) != sizeof(ch.data.profiles) ||
      ch.prefs.putUInt("count_v3", ch.data.count) != sizeof(uint32_t)) {
    ch.storageOK = false; lock(ch); return false;
  }
  ++ch.data.profilesVersion;
  return true;
}
void beginAlert(SocketChannel& ch, const char* type, uint64_t now) {
  ch.data.safety.state = SocketState::Warning;
  ch.data.safety.warningStarted = now; ++ch.data.safety.revision;
  auto& a = ch.data.alert;
  snprintf(a.id, sizeof(a.id), "%s_%s_%lu", sessionID, ch.outlet, (unsigned long)ch.data.safety.revision);
  strlcpy(a.type, type, sizeof(a.type)); strlcpy(a.resolution, "PENDING", sizeof(a.resolution));
  a.trigger = epochMs(); a.expiry = a.trigger ? a.trigger + 60000 : 0;
  persistSafety(ch);
  Serial.printf("[%s] WARNING %s: 60 s until lockout\n", ch.outlet, type);
}
void loadProfiles(SocketChannel& ch) {
  auto& d = ch.data;
  d.count = ch.prefs.getUInt("count_v3", 0);
  if (d.count > MAX_APPLIANCES || (d.count && ch.prefs.getBytes("profiles_v3", d.profiles, sizeof(d.profiles)) != sizeof(d.profiles))) {
    d.count = 0; ch.storageOK = false; return;
  }
  for (uint32_t n = 0; n < d.count; ++n) {
    auto& p = d.profiles[n];
    if (!memchr(p.name, 0, sizeof(p.name)) || !memchr(p.profileID, 0, sizeof(p.profileID)) || !p.maxRunTime ||
        p.safetyCeilingDuration < p.maxRunTime || p.safetyCeilingDuration > 604800) ch.storageOK = false;
    p.name[63] = 0; p.profileID[63] = 0;
  }
  // One-time migration of appliances learned by the previous sketch.
  int legacy = ch.prefs.getInt("count", 0);
  if (legacy <= 0) return;
  for (int n = 0; n < legacy && n < int(MAX_APPLIANCES) && d.count < MAX_APPLIANCES; ++n) {
    char key[16]; snprintf(key, sizeof(key), "app_%d", n);
    LegacySignature old;
    if (ch.prefs.getBytes(key, &old, sizeof(old)) != sizeof(old)) continue;
    old.name[31] = 0;
    auto& p = d.profiles[d.count++]; p = ApplianceSignature{};
    strlcpy(p.name, old.name[0] ? old.name : "Migrated appliance", sizeof(p.name));
    snprintf(p.profileID, sizeof(p.profileID), "%s_LEGACY_%d", ch.catalog, n);
    p.steadyPower = old.steadyPower; p.peakPower = old.peakPower; p.current = old.current;
    p.voltage = old.voltage; p.pf = old.pf;
    uint32_t limit = old.safetyLimitMinutes > 0 ? uint32_t(old.safetyLimitMinutes) * 60 : DEFAULT_LIMIT_S;
    p.maxRunTime = p.safetyCeilingDuration = min(limit, uint32_t(604800));
  }
  if (saveProfiles(ch)) ch.prefs.remove("count");
}

// ==========================================
// APPLIANCE RECOGNITION
// ==========================================
bool within(float live, float stored, float tolerance) {
  return isfinite(live) && isfinite(stored) && fabsf(live - stored) <= max(fabsf(stored) * tolerance, 0.05f);
}
bool matches(const ApplianceSignature& scan, const ApplianceSignature& p) {
  return within(scan.steadyPower, p.steadyPower, POWER_TOLERANCE) &&
         within(scan.current, p.current, CURRENT_TOLERANCE) &&
         isfinite(scan.pf) && fabsf(scan.pf - p.pf) <= PF_TOLERANCE;
}
void finishSampling(SocketChannel& ch) {
  auto& d = ch.data; auto& sig = ch.pending;
  if (!ch.samples) return;
  sig.steadyPower /= ch.samples; sig.current /= ch.samples; sig.voltage /= ch.samples; sig.pf /= ch.samples;
  d.activeID = -1;
  float best = INFINITY;  // closest power match wins
  for (uint32_t i = 0; i < d.count; ++i) {
    float diff = fabsf(sig.steadyPower - d.profiles[i].steadyPower);
    if (matches(sig, d.profiles[i]) && diff < best) { best = diff; d.activeID = i; }
  }
  if (d.activeID < 0 && d.count < MAX_APPLIANCES) {
    // Unknown appliance: add it to the catalog so the app prompts the user to register it.
    snprintf(sig.profileID, sizeof(sig.profileID), "UNNAMED_DEVICE_%lld_%08lx",
             (long long)(epochMs() ? epochMs() : monotonicMs()), (unsigned long)esp_random());
    strlcpy(sig.name, sig.profileID, sizeof(sig.name)); sig.registeredAt = epochMs();
    d.activeID = d.count; d.profiles[d.count++] = sig;
  }
  if (d.activeID >= 0) {
    ++d.profiles[d.activeID].totalSessions;
    if (!saveProfiles(ch)) return;
  }
  uint32_t ceiling = d.activeID >= 0 ? d.profiles[d.activeID].safetyCeilingDuration : DEFAULT_LIMIT_S;
  d.safety.state = SocketState::Active; ++d.safety.revision;
  d.safety.deadline = d.safety.started + uint64_t(ceiling) * 1000;
  Serial.printf("[%s] Active: %s (limit %lu s)\n", ch.outlet,
                d.activeID >= 0 ? d.profiles[d.activeID].name : "unrecognized, catalog full", (unsigned long)ceiling);
}
void handleSensor(SocketChannel& ch, const SensorSample& sample, uint64_t now) {
  auto& d = ch.data;
  d.sensor = sample;
  if (!sample.valid) return;
  auto state = d.safety.state;
  if (state == SocketState::Disabled || state == SocketState::LockedOut || state == SocketState::Warning) return;
  if (state == SocketState::Idle) {
    if (sample.power <= START_W_THRESHOLD) return;
    d.safety.begin(now, DEFAULT_LIMIT_S); ch.pending = ApplianceSignature{};
    ch.samples = 0; d.startEpoch = epochMs(); d.peak = 0;
    if (!persistSafety(ch)) return;
  } else if (sample.power < IDLE_W_THRESHOLD) {
    d.safety.state = SocketState::Idle; ++d.safety.revision;  // appliance switched off
    endSession(ch); persistSafety(ch);
    return;
  }
  d.peak = max(d.peak, sample.power);
  if (d.safety.state == SocketState::Sampling) {
    ch.pending.steadyPower += sample.power; ch.pending.peakPower = max(ch.pending.peakPower, sample.power);
    ch.pending.current += sample.current; ch.pending.voltage += sample.voltage; ch.pending.pf += sample.pf;
    ++ch.samples;
    if (now - d.safety.started >= SAMPLE_TIME_MS) finishSampling(ch);
  }
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
  if (strcmp(cmd.type, "RESET_SAFETY") == 0) {
    // The only remote command accepted while locked out.
    if (!fresh) result = "REJECTED_STALE";
    else if (!ch.storageOK) result = "REJECTED_STORAGE_FAILURE";
    else if (!d.safety.remoteReset()) result = "REJECTED_INVALID";
    else {
      endSession(ch);
      if (d.alert.id[0]) strlcpy(d.alert.resolution, "RESET", sizeof(d.alert.resolution));
      result = persistSafety(ch) ? "ACCEPTED" : "REJECTED_STORAGE_FAILURE";
    }
  } else if (d.safety.state == SocketState::LockedOut) result = "REJECTED_PHYSICAL_RESET_REQUIRED";
  else if (fresh) {
    result = "REJECTED_INVALID";
    if (strcmp(cmd.type, "SMART_OVERRIDE") == 0) {
      if (strcmp(cmd.alertID, d.alert.id) == 0 && d.safety.overrideRuntime(now, cmd.extension)) {
        strlcpy(d.alert.resolution, "OVERRIDDEN", sizeof(d.alert.resolution)); result = "ACCEPTED";
      }
    } else if (strcmp(cmd.type, "TURN_OFF") == 0 && d.safety.state == SocketState::Warning) {
      lock(ch); result = "ACCEPTED";
    } else if (strcmp(cmd.type, "TURN_ON") == 0 || strcmp(cmd.type, "TURN_OFF") == 0) {
      if (d.safety.remotePower(strcmp(cmd.type, "TURN_ON") == 0)) {
        if (d.safety.state == SocketState::Disabled) endSession(ch);
        result = "ACCEPTED";
      }
    } else if (strcmp(cmd.type, "REMOVE_PROFILE") == 0 &&
        (d.safety.state == SocketState::Idle || d.safety.state == SocketState::Disabled)) {
      for (uint32_t i = 0; i < d.count; ++i) {
        if (strcmp(cmd.profileID, d.profiles[i].profileID) != 0) continue;
        for (uint32_t j = i + 1; j < d.count; ++j) d.profiles[j - 1] = d.profiles[j];
        --d.count; d.activeID = -1;
        if (saveProfiles(ch)) { ++d.safety.revision; result = "ACCEPTED"; }
        break;
      }
    } else if (strcmp(cmd.type, "EDIT_PROFILE") == 0 && d.safety.state != SocketState::Warning) {
      for (uint32_t i = 0; i < d.count; ++i) {
        if (strcmp(cmd.profileID, d.profiles[i].profileID) != 0) continue;
        if (!cmd.maxRunTime || cmd.ceiling < cmd.maxRunTime || cmd.ceiling > 604800 || !cmd.name[0]) break;
        auto& p = d.profiles[i]; strlcpy(p.name, cmd.name, sizeof(p.name));
        p.maxRunTime = cmd.maxRunTime; p.safetyCeilingDuration = cmd.ceiling;
        if (saveProfiles(ch)) {
          if (d.activeID == int(i)) d.safety.deadline = d.safety.started + uint64_t(cmd.ceiling) * 1000;
          ++d.safety.revision; result = "ACCEPTED";
        }
        break;
      }
    }
    if (!persistSafety(ch)) result = "REJECTED_STORAGE_FAILURE";
  }
  strlcpy(d.commandResult, result, sizeof(d.commandResult));
  Serial.printf("[%s] %s -> %s\n", ch.outlet, cmd.type, result);
}

// ==========================================
// SENSOR TASK (core 0)
// ==========================================
void sensorTask(void*) {
  PZEM004Tv30* meters[] = {&pzemA, &pzemB};
  uint64_t lastWarning[2] = {0, 0};
  for (;;) {
    for (int i = 0; i < 2; ++i) {
      SensorSample s;
      s.power = meters[i]->power(); s.current = meters[i]->current(); s.voltage = meters[i]->voltage();
      s.pf = meters[i]->pf(); s.energy = meters[i]->energy();
      s.valid = isfinite(s.power) && s.power >= 0 && isfinite(s.current) && s.current >= 0 &&
                isfinite(s.voltage) && s.voltage > 0 && isfinite(s.pf) && s.pf >= 0 && s.pf <= 1;
      s.captured = monotonicMs(); xQueueOverwrite(outlets[i].sensors, &s);
      // Without valid readings an outlet can never detect or learn an appliance.
      if (!s.valid && s.captured - lastWarning[i] >= 5000) {
        lastWarning[i] = s.captured;
        Serial.printf("[%s] PZEM not responding (V=%.1f): check its RX/TX wiring, 5V/GND and mains supply\n",
                      outlets[i].outlet, s.voltage);
      }
    }
    vTaskDelay(pdMS_TO_TICKS(200));
  }
}

// ==========================================
// FIREBASE REST (network task only)
// ==========================================
WiFiClientSecure tls;
HTTPClient http;
String firebaseHost;
int firebaseRequest(const char* method, const String& path, const String& body = "", String* response = nullptr) {
  if (WiFi.status() != WL_CONNECTED) return -1;
  if (!http.begin(tls, "https://" + firebaseHost + "/" + path + ".json?auth=" + FIREBASE_AUTH)) return -1;
  http.setTimeout(5000);
  int code;
  if (strcmp(method, "GET") == 0) code = http.GET();
  else { http.addHeader("Content-Type", "application/json"); code = http.sendRequest(method, body); }
  if (response && code == HTTP_CODE_OK) *response = http.getString();
  http.end();  // keeps the TLS connection open for reuse
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
    strlcpy(c.profileID, j["profileID"] | "", sizeof(c.profileID)); strlcpy(c.name, j["name"] | "", sizeof(c.name));
    c.revision = uint32_t(j["revision"].as<double>()); c.expires = j["expiresAt"].as<int64_t>();
    c.extension = uint32_t(j["extensionDuration"].as<double>());
    c.maxRunTime = uint32_t(j["maxRunTime"].as<double>()); c.ceiling = uint32_t(j["safetyCeilingDuration"].as<double>());
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
void addOutlet(JsonDocument& root, int i, const Snapshot& s, bool includeCatalog) {
  const auto& ch = outlets[i];
  String b = String("telemetry_logs/") + ch.outlet + "/";
  auto st = s.safety.state;
  bool running = st == SocketState::Active || st == SocketState::Sampling || st == SocketState::Warning;
  bool sensorOK = s.sensor.valid && s.capturedMono - s.sensor.captured < SENSOR_TIMEOUT_MS;
  root[b + "status"] = st == SocketState::LockedOut ? "LOCKED_OUT" : (running ? "Active" : "Idle");
  root[b + "currentState"] = stateName(st); root[b + "sessionID"] = sessionID;
  root[b + "revision"] = s.safety.revision; root[b + "runtime_warning"] = s.safety.runtimeWarning;
  root[b + "relay_on"] = relayEnergized(st);
  root[b + "profileID"] = s.activeID >= 0 ? s.profiles[s.activeID].profileID : "";
  // The effective deadline, including any accepted runtime override.
  root[b + "safetyDeadline"] = running && s.safety.deadline > s.capturedMono && s.capturedEpoch
      ? timestamp(s.capturedEpoch + int64_t(s.safety.deadline - s.capturedMono)) : String("N/A");
  root[b + "appliance"] = s.activeID >= 0 ? s.profiles[s.activeID].name : (running ? "Recognizing appliance" : "None");
  root[b + "sensor_valid"] = sensorOK;
  root[b + "power_W"] = sensorOK ? s.sensor.power : 0; root[b + "current_A"] = sensorOK ? s.sensor.current : 0;
  root[b + "voltage_V"] = sensorOK ? s.sensor.voltage : 0; root[b + "power_factor"] = sensorOK ? s.sensor.pf : 0;
  if (sensorOK && isfinite(s.sensor.energy)) root[b + "energy_kWh"] = s.sensor.energy;
  root[b + "peak_power_W"] = s.peak; root[b + "start_time"] = timestamp(running ? s.startEpoch : 0);
  root[b + "last_updated"] = timestamp(s.capturedEpoch); root[b + "last_updated_ms"] = s.capturedEpoch;
  root[b + "alertID"] = s.alert.id; root[b + "countdownExpiry"] = timestamp(s.alert.expiry);
  root[b + "countdownRemaining"] = st == SocketState::Warning
      ? int((60000 - min(uint64_t(60000), s.capturedMono - s.safety.warningStarted) + 999) / 1000) : 0;
  if (s.commandID[0]) {
    String a = String("command_results/") + ch.outlet + "/" + s.commandID + "/";
    root[a + "result"] = s.commandResult; root[a + "revision"] = s.safety.revision;
  }
  if (s.alert.id[0]) {
    String a = String("alerts/") + s.alert.id + "/";
    root[a + "deviceID"] = ch.outlet; root[a + "alertType"] = s.alert.type;
    root[a + "triggerTime"] = timestamp(s.alert.trigger); root[a + "countdownExpiry"] = timestamp(s.alert.expiry);
    root[a + "resolution"] = s.alert.resolution;
  }
  if (includeCatalog) {
    String path = String("appliance_profiles/") + ch.catalog;
    root[String("appliance_profiles/") + ch.legacyCatalog] = nullptr;  // drop the old sketch's catalog
    if (!s.count) { root[path] = nullptr; return; }
    JsonObject catalog = root[path].to<JsonObject>();
    for (uint32_t n = 0; n < s.count; ++n) {
      const auto& p = s.profiles[n];
      JsonObject profile = catalog[p.profileID].to<JsonObject>();
      profile["name"] = p.name; profile["steadyPower_W"] = p.steadyPower; profile["peakPower_W"] = p.peakPower;
      profile["current_A"] = p.current; profile["voltage_V"] = p.voltage; profile["powerFactor"] = p.pf;
      profile["maxRunTime"] = p.maxRunTime; profile["safetyCeilingDuration"] = p.safetyCeilingDuration;
      profile["totalSessions"] = p.totalSessions; profile["registered_at"] = timestamp(p.registeredAt);
    }
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
    root[b + (i == 0 ? "outletA" : "outletB")] = relayEnergized(st);
    if (s[i].sensor.valid && s[i].capturedMono - s[i].sensor.captured < SENSOR_TIMEOUT_MS) draw += s[i].sensor.power;
    if (st == SocketState::Warning || st == SocketState::LockedOut) { triggered = true; remainingMs = 0; }
    else if ((st == SocketState::Active || st == SocketState::Sampling) && remainingMs != 0) {
      int64_t left = s[i].safety.deadline > s[i].capturedMono ? int64_t(s[i].safety.deadline - s[i].capturedMono) : 0;
      if (remainingMs < 0 || left < remainingMs) remainingMs = left;
    }
  }
  root[b + "powerDraw"] = draw; root[b + "connectionStatus"] = "Online";
  root[b + "safetyTriggered"] = triggered; root[b + "lastSeen"][".sv"] = "timestamp";
  if (remainingMs >= 0) root[b + "remainingLimit"] = double(remainingMs) / 1000.0;
  else root[b + "remainingLimit"] = nullptr;  // null deletes the field
}

// ==========================================
// WI-FI PROVISIONING
// First setup: WiFiManager portal "WisePlug-AP". Later changes: the app writes
// devices/gadget-1/wifiConfig; new credentials are tried for 20 s and rolled
// back to the previous network if they fail.
// ==========================================
Preferences wifiPrefs;
int64_t appliedConfig = 0;
String previousSsid, previousPass;
uint64_t trialStarted = 0;
bool trialActive = false;
void checkWifiConfig() {
  String path = String("devices/") + DEVICE_ID + "/wifiConfig", body;
  if (firebaseRequest("GET", path, "", &body) != HTTP_CODE_OK) return;
  JsonDocument doc;
  if (deserializeJson(doc, body) || !doc["ssid"].is<const char*>() || !doc["password"].is<const char*>()) return;
  int64_t updatedAt = doc["updatedAt"].as<int64_t>();
  String ssid = doc["ssid"].as<const char*>(), pass = doc["password"].as<const char*>();
  if (!updatedAt || updatedAt == appliedConfig || !ssid.length() || ssid.length() > 32 || pass.length() > 63) return;
  appliedConfig = updatedAt; wifiPrefs.putLong64("applied", updatedAt);
  JsonDocument ack; ack["receivedAt"] = updatedAt; String ackBody; serializeJson(ack, ackBody);
  firebaseRequest("PATCH", path, ackBody);
  firebaseRequest("DELETE", path + "/password");  // keep the secret only on the device
  previousSsid = WiFi.SSID(); previousPass = WiFi.psk();
  Serial.printf("Switching Wi-Fi to %s\n", ssid.c_str());
  WiFi.disconnect(); WiFi.begin(ssid.c_str(), pass.c_str());  // persisted for reboot
  trialStarted = monotonicMs(); trialActive = true;
}

// ==========================================
// NETWORK TASK (core 0): never blocks the safety loop
// ==========================================
void networkTask(void*) {
  firebaseHost = FIREBASE_HOST;
  firebaseHost.replace("https://", ""); firebaseHost.replace("http://", "");
  while (firebaseHost.endsWith("/")) firebaseHost.remove(firebaseHost.length() - 1);
  tls.setInsecure();  // TODO: pin Google's root CA before production use
  wifiPrefs.begin("wifi", false); appliedConfig = wifiPrefs.getLong64("applied", 0);
  WiFi.mode(WIFI_STA); WiFi.setAutoReconnect(true);
  static WiFiManager wm;
  wm.setConfigPortalBlocking(false);
  wm.autoConnect("WisePlug-AP");
  configTime(0, 0, "pool.ntp.org", "time.google.com");  // UTC; the app localizes
  static Snapshot latest[2]; bool available[2] = {false, false};
  uint32_t publishedVersion[2] = {UINT32_MAX, UINT32_MAX};
  uint64_t lastConnected = monotonicMs(), lastCommands = 0, lastPublish = 0, lastCatalog = 0, lastConfig = 0;
  for (;;) {
    wm.process();
    uint64_t now = monotonicMs();
    bool connected = WiFi.status() == WL_CONNECTED;
    if (connected) lastConnected = now;
    if (trialActive && (connected || now - trialStarted > 20000)) {
      trialActive = false;
      if (!connected && previousSsid.length()) {
        Serial.println("New Wi-Fi failed, restoring previous network");
        WiFi.disconnect(); WiFi.begin(previousSsid.c_str(), previousPass.c_str());
      }
    }
    if (connected && wm.getConfigPortalActive()) wm.stopConfigPortal();
    if (!connected && !trialActive && now - lastConnected > 60000 && !wm.getConfigPortalActive()) {
      wm.startConfigPortal("WisePlug-AP");  // let the user re-provision locally
    }
    for (int i = 0; i < 2; ++i) {
      if (xQueueReceive(outlets[i].snapshots, &latest[i], 0) == pdTRUE) available[i] = true;
    }
    if (connected) {
      if (now - lastCommands >= 1000) { lastCommands = now; readCommands(); }
      if (available[0] && available[1] && now - lastPublish >= 1000) {
        lastPublish = now;
        bool catalog = now - lastCatalog >= 60000 || latest[0].profilesVersion != publishedVersion[0] ||
                       latest[1].profilesVersion != publishedVersion[1];
        JsonDocument root;
        for (int i = 0; i < 2; ++i) addOutlet(root, i, latest[i], catalog);
        addStatus(root, latest);
        String body; serializeJson(root, body);
        if (firebaseRequest("PATCH", "", body) == HTTP_CODE_OK && catalog) {
          lastCatalog = now;
          for (int i = 0; i < 2; ++i) publishedVersion[i] = latest[i].profilesVersion;
        }
      }
      if (now - lastConfig >= 10000) { lastConfig = now; checkWifiConfig(); }
    }
    vTaskDelay(pdMS_TO_TICKS(100));
  }
}

// ==========================================
// SETUP & CONTROL LOOP (core 1)
// ==========================================
void setup() {
  // Relays stay off until the persisted safety state is known.
  for (int pin : {RELAY_A_PIN, RELAY_B_PIN}) { digitalWrite(pin, RELAY_OFF); pinMode(pin, OUTPUT); }
  Serial.begin(115200);
  // The PZEM constructors open these ports before the core is fully started,
  // which is unreliable; open them again here so both meters respond.
  Serial2.begin(9600, SERIAL_8N1, PZEM_A_RX, PZEM_A_TX);
  Serial1.begin(9600, SERIAL_8N1, PZEM_B_RX, PZEM_B_TX);
  snprintf(sessionID, sizeof(sessionID), "%08lx%08lx", (unsigned long)esp_random(), (unsigned long)esp_random());
  for (int i = 0; i < 2; ++i) {
    auto& ch = outlets[i];
    ch.ns = i == 0 ? "apps_a" : "apps_b"; ch.outlet = i == 0 ? "outlet_A" : "outlet_B";
    ch.catalog = i == 0 ? "OUTLET_A" : "OUTLET_B"; ch.legacyCatalog = i == 0 ? "OUTLET A" : "OUTLET B";
    ch.relay = i == 0 ? RELAY_A_PIN : RELAY_B_PIN; ch.button = i == 0 ? BUTTON_A_PIN : BUTTON_B_PIN;
    pinMode(ch.button, INPUT_PULLUP);
    ch.rawButton = ch.stableButton = digitalRead(ch.button); ch.buttonChanged = monotonicMs();
    ch.sensors = xQueueCreate(1, sizeof(SensorSample)); ch.commands = xQueueCreate(4, sizeof(Command));
    ch.snapshots = xQueueCreate(1, sizeof(Snapshot));
    configASSERT(ch.sensors && ch.commands && ch.snapshots);
    ch.storageOK = ch.prefs.begin(ch.ns, false);
    if (ch.storageOK) loadProfiles(ch);
    ch.prefs.getBytes("alert", &ch.data.alert, sizeof(AlertRecord));
    ch.data.alert.id[79] = 0; ch.data.alert.type[39] = 0; ch.data.alert.resolution[15] = 0;
    // A reboot during a running session (e.g. power cut) locks out: nothing restarts unattended.
    if (!ch.storageOK || ch.prefs.getBool("hazard", false)) lock(ch);
    else if (ch.prefs.getBool("disabled", false)) ch.data.safety.state = SocketState::Disabled;
    applyRelay(ch);
  }
  configASSERT(xTaskCreatePinnedToCore(sensorTask, "meters", 4096, nullptr, 1, nullptr, 0) == pdPASS);
  configASSERT(xTaskCreatePinnedToCore(networkTask, "firebase", 16384, nullptr, 1, nullptr, 0) == pdPASS);
  Serial.println("SYSTEM READY");
}

void loop() {
  uint64_t now = monotonicMs();
  for (auto& ch : outlets) {
    auto& d = ch.data;
    auto& safety = d.safety;
    uint32_t maxRun = d.activeID >= 0 ? d.profiles[d.activeID].maxRunTime : DEFAULT_LIMIT_S;
    if (safety.tick(now, maxRun)) {
      if (safety.state == SocketState::Warning) beginAlert(ch, "SAFETY_CEILING_EXCEEDED", now); else lock(ch);
    }
    bool raw = digitalRead(ch.button);
    if (raw != ch.rawButton) { ch.rawButton = raw; ch.buttonChanged = now; }
    if (raw != ch.stableButton && now - ch.buttonChanged >= 50) {
      ch.stableButton = raw;
      if (!raw && ch.storageOK) {
        if (safety.state == SocketState::Warning) lock(ch);
        else { safety.physicalPress(); endSession(ch); persistSafety(ch); }
      }
    }
    SensorSample sample;
    if (xQueueReceive(ch.sensors, &sample, 0) == pdTRUE) handleSensor(ch, sample, now);
    if ((safety.state == SocketState::Active || safety.state == SocketState::Sampling) &&
        (!d.sensor.valid || now - d.sensor.captured > SENSOR_TIMEOUT_MS)) beginAlert(ch, "SENSOR_UNAVAILABLE", now);
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
  delay(10);
}
