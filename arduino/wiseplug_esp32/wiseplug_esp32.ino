#include <PZEM004Tv30.h>
#include <Preferences.h>
#include <WiFi.h>
#include <FirebaseESP32.h>
#include <esp_timer.h>
#include <time.h>
#include "secrets.h"
#include "safety_state.h"

constexpr float START_W_THRESHOLD = 3.5f, TOLERANCE = 0.15f;
constexpr uint32_t SAMPLE_TIME = 2000, MAX_APPLIANCES = 20;
struct ApplianceSignature {
  char name[64] = {}, profileID[64] = {};
  float steadyPower = 0, peakPower = 0, current = 0, voltage = 0, pf = 0;
  uint32_t maxRunTime = 3600, safetyCeilingDuration = 3600;
  int64_t registeredAt = 0;
};
struct SensorSample { float power, current, voltage, pf; bool valid; uint64_t captured; };
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
  uint32_t count = 0;
  int activeID = -1;
  float peak = 0;
  int64_t startEpoch = 0, capturedEpoch = 0;
  uint64_t capturedMono = 0;
  AlertRecord alert;
  char commandID[64] = {}, commandResult[40] = {};
};
struct SocketChannel {
  Preferences prefs;
  const char* ns; const char* outlet; const char* catalog;
  int button;
  Snapshot data;
  ApplianceSignature pending;
  uint32_t samples = 0;
  uint64_t buttonChanged = 0, lastSnapshot = 0;
  bool rawButton = true, stableButton = true, storageOK = true;
  QueueHandle_t sensors, commands, snapshots;
};
PZEM004Tv30 pzemA(Serial2, 32, 33), pzemB(Serial1, 25, 26);
SocketChannel outlets[2];
FirebaseData fbdo; FirebaseAuth auth; FirebaseConfig config;
char sessionID[40];
uint64_t monotonicMs() { return esp_timer_get_time() / 1000; }
int64_t epochMs() { time_t t = time(nullptr); return t > 1700000000 ? int64_t(t) * 1000 : 0; }
String timestamp(int64_t ms) {
  if (!ms) return "N/A";
  time_t t = ms / 1000; struct tm utc; gmtime_r(&t, &utc);
  char buffer[32]; strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return String(buffer);
}
bool persistSafety(SocketChannel& ch) {
  auto state = ch.data.safety.state;
  bool hazardous = state == SocketState::Sampling || state == SocketState::Active || state == SocketState::Warning || state == SocketState::LockedOut;
  bool ok = ch.prefs.putBool("hazard", hazardous) == 1;
  ok = (ch.prefs.putBool("disabled", state == SocketState::Disabled) == 1) && ok;
  if (ch.data.alert.id[0]) ok = (ch.prefs.putBytes("alert", &ch.data.alert, sizeof(AlertRecord)) == sizeof(AlertRecord)) && ok;
  if (!ok) { ch.storageOK = false; ch.data.safety.state = SocketState::LockedOut; }
  return ok;
}
void lock(SocketChannel& ch) {
  ch.data.safety.state = SocketState::LockedOut; ++ch.data.safety.revision;
  if (ch.data.alert.id[0]) strlcpy(ch.data.alert.resolution, "SHUTDOWN", sizeof(ch.data.alert.resolution));
  persistSafety(ch);
}
bool saveProfiles(SocketChannel& ch) {
  if (ch.prefs.putBytes("profiles_v2", ch.data.profiles, sizeof(ch.data.profiles)) != sizeof(ch.data.profiles) ||
      ch.prefs.putUInt("count_v2", ch.data.count) != sizeof(uint32_t)) {
    ch.storageOK = false; lock(ch); return false;
  }
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
}
bool closeEnough(float live, float stored) {
  return isfinite(live) && isfinite(stored) && fabsf(live - stored) <= max(fabsf(stored) * TOLERANCE, 0.001f);
}
void finishSampling(SocketChannel& ch) {
  auto& sig = ch.pending;
  if (!ch.samples) { lock(ch); return; }
  sig.steadyPower /= ch.samples; sig.current /= ch.samples; sig.voltage /= ch.samples; sig.pf /= ch.samples;
  ch.data.activeID = -1;
  for (uint32_t i = 0; i < ch.data.count; ++i) {
    const auto& p = ch.data.profiles[i];
    if (closeEnough(sig.steadyPower, p.steadyPower) && closeEnough(sig.peakPower, p.peakPower) &&
        closeEnough(sig.current, p.current) && closeEnough(sig.voltage, p.voltage) && closeEnough(sig.pf, p.pf)) {
      ch.data.activeID = i; break;
    }
  }
  if (ch.data.activeID < 0) {
    if (ch.data.count == MAX_APPLIANCES) { beginAlert(ch, "PROFILE_STORAGE_FULL", monotonicMs()); return; }
    snprintf(sig.name, sizeof(sig.name), "UNNAMED_DEVICE_%lld_%08lx", (long long)(epochMs() ? epochMs() : monotonicMs()), (unsigned long)esp_random());
    strlcpy(sig.profileID, sig.name, sizeof(sig.profileID)); sig.registeredAt = epochMs();
    ch.data.activeID = ch.data.count; ch.data.profiles[ch.data.count++] = sig;
    if (!saveProfiles(ch)) return;
  }
  ch.data.safety.state = SocketState::Active; ++ch.data.safety.revision;
  ch.data.safety.deadline = ch.data.safety.started + uint64_t(ch.data.profiles[ch.data.activeID].safetyCeilingDuration) * 1000;
}
void handleSensor(SocketChannel& ch, const SensorSample& sample, uint64_t now) {
  ch.data.sensor = sample;
  if (!sample.valid) return;
  auto state = ch.data.safety.state;
  if (state == SocketState::Disabled || state == SocketState::LockedOut) return;
  if (state != SocketState::Warning && sample.power < START_W_THRESHOLD) {
    if (state != SocketState::Idle) {
      ch.data.safety.state = SocketState::Idle; ++ch.data.safety.revision;
      ch.data.activeID = -1; ch.data.peak = 0; persistSafety(ch);
    }
    return;
  }
  if (state == SocketState::Idle && sample.power > START_W_THRESHOLD) {
    ch.data.safety.begin(now, 3600); ch.pending = ApplianceSignature{};
    ch.samples = 0; ch.data.startEpoch = epochMs();
    if (!persistSafety(ch)) return;
  }
  ch.data.peak = max(ch.data.peak, sample.power);
  if (ch.data.safety.state == SocketState::Sampling) {
    ch.pending.steadyPower += sample.power; ch.pending.peakPower = max(ch.pending.peakPower, sample.power);
    ch.pending.current += sample.current; ch.pending.voltage += sample.voltage; ch.pending.pf += sample.pf;
    ++ch.samples;
    if (now - ch.data.safety.started >= SAMPLE_TIME) finishSampling(ch);
  }
}
void handleCommand(SocketChannel& ch, const Command& cmd, uint64_t now) {
  if (!cmd.id[0] || strcmp(cmd.id, ch.data.commandID) == 0) return;
  strlcpy(ch.data.commandID, cmd.id, sizeof(ch.data.commandID));
  const char* result = "REJECTED_STALE";
  if (ch.data.safety.state == SocketState::LockedOut) result = "REJECTED_PHYSICAL_RESET_REQUIRED";
  else if (strcmp(cmd.session, sessionID) == 0 && cmd.revision == ch.data.safety.revision &&
      epochMs() && cmd.expires > epochMs() && cmd.expires <= epochMs() + 30000) {
    result = "REJECTED_INVALID";
    if (strcmp(cmd.type, "SMART_OVERRIDE") == 0) {
      if (strcmp(cmd.alertID, ch.data.alert.id) == 0 && ch.data.safety.overrideRuntime(now, cmd.extension)) {
        strlcpy(ch.data.alert.resolution, "OVERRIDDEN", sizeof(ch.data.alert.resolution)); result = "ACCEPTED";
      }
    } else if (strcmp(cmd.type, "TURN_OFF") == 0 && ch.data.safety.state == SocketState::Warning) {
      lock(ch); result = "ACCEPTED";
    } else if (strcmp(cmd.type, "TURN_ON") == 0 || strcmp(cmd.type, "TURN_OFF") == 0) {
      if (ch.data.safety.remotePower(strcmp(cmd.type, "TURN_ON") == 0)) result = "ACCEPTED";
    } else if (strcmp(cmd.type, "REMOVE_PROFILE") == 0 &&
        (ch.data.safety.state == SocketState::Idle || ch.data.safety.state == SocketState::Disabled)) {
      for (uint32_t i = 0; i < ch.data.count; ++i) {
        if (strcmp(cmd.profileID, ch.data.profiles[i].profileID) != 0) continue;
        for (uint32_t j = i + 1; j < ch.data.count; ++j) ch.data.profiles[j - 1] = ch.data.profiles[j];
        --ch.data.count; ch.data.activeID = -1;
        if (saveProfiles(ch)) { ++ch.data.safety.revision; result = "ACCEPTED"; }
        break;
      }
    } else if (strcmp(cmd.type, "EDIT_PROFILE") == 0 && ch.data.safety.state != SocketState::Warning) {
      for (uint32_t i = 0; i < ch.data.count; ++i) {
        if (strcmp(cmd.profileID, ch.data.profiles[i].profileID) != 0) continue;
        if (!cmd.maxRunTime || cmd.ceiling < cmd.maxRunTime || cmd.ceiling > 604800 || !cmd.name[0]) break;
        auto& p = ch.data.profiles[i]; strlcpy(p.name, cmd.name, sizeof(p.name));
        p.maxRunTime = cmd.maxRunTime; p.safetyCeilingDuration = cmd.ceiling;
        if (saveProfiles(ch)) {
          if (ch.data.activeID == int(i)) ch.data.safety.deadline = ch.data.safety.started + uint64_t(cmd.ceiling) * 1000;
          ++ch.data.safety.revision; result = "ACCEPTED";
        }
        break;
      }
    }
    if (!persistSafety(ch)) result = "REJECTED_STORAGE_FAILURE";
  }
  strlcpy(ch.data.commandResult, result, sizeof(ch.data.commandResult));
}
void sensorTask(void*) {
  PZEM004Tv30* meters[] = {&pzemA, &pzemB};
  for (;;) {
    for (int i = 0; i < 2; ++i) {
      SensorSample s;
      s.power = meters[i]->power(); s.current = meters[i]->current(); s.voltage = meters[i]->voltage(); s.pf = meters[i]->pf();
      s.valid = isfinite(s.power) && s.power >= 0 && isfinite(s.current) && s.current >= 0 && isfinite(s.voltage) && s.voltage > 0 && isfinite(s.pf) && s.pf >= 0 && s.pf <= 1;
      s.captured = monotonicMs(); xQueueOverwrite(outlets[i].sensors, &s);
    }
    vTaskDelay(pdMS_TO_TICKS(200));
  }
}
String jsonString(FirebaseJson& j, const char* key) { FirebaseJsonData d; j.get(d, key); return d.success ? d.to<String>() : String(); }
int64_t jsonInt(FirebaseJson& j, const char* key) { FirebaseJsonData d; j.get(d, key); return d.success ? int64_t(d.to<double>()) : 0; }
void readCommand(int i) {
  if (!Firebase.getJSON(fbdo, String("commands/") + outlets[i].outlet)) return;
  FirebaseJson& j = fbdo.jsonObject(); Command c;
  jsonString(j, "commandID").toCharArray(c.id, sizeof(c.id)); jsonString(j, "sessionID").toCharArray(c.session, sizeof(c.session));
  jsonString(j, "type").toCharArray(c.type, sizeof(c.type)); jsonString(j, "alertID").toCharArray(c.alertID, sizeof(c.alertID));
  jsonString(j, "profileID").toCharArray(c.profileID, sizeof(c.profileID)); jsonString(j, "name").toCharArray(c.name, sizeof(c.name));
  c.revision = jsonInt(j, "revision"); c.expires = jsonInt(j, "expiresAt"); c.extension = jsonInt(j, "extensionDuration");
  c.maxRunTime = jsonInt(j, "maxRunTime"); c.ceiling = jsonInt(j, "safetyCeilingDuration");
  xQueueSend(outlets[i].commands, &c, 0);
}
const char* stateName(SocketState s) {
  switch (s) {
    case SocketState::Sampling: return "SAMPLING"; case SocketState::Active: return "ACTIVE";
    case SocketState::Warning: return "WARNING"; case SocketState::LockedOut: return "LOCKED_OUT";
    case SocketState::Disabled: return "DISABLED"; default: return "IDLE";
  }
}
bool publish(int i, const Snapshot& s) {
  FirebaseJson root; String b = String("telemetry_logs/") + outlets[i].outlet + "/";
  bool running = s.safety.state == SocketState::Active || s.safety.state == SocketState::Sampling || s.safety.state == SocketState::Warning;
  root.add(b + "status", s.safety.state == SocketState::LockedOut ? "LOCKED_OUT" : (running ? "Active" : "Idle"));
  root.add(b + "currentState", stateName(s.safety.state)); root.add(b + "sessionID", sessionID);
  root.add(b + "revision", int(s.safety.revision)); root.add(b + "runtime_warning", s.safety.runtimeWarning);
  root.add(b + "profileID", s.activeID >= 0 ? s.profiles[s.activeID].profileID : "");
  // Publish the effective deadline, including any accepted runtime override.
  root.add(b + "safetyDeadline", running && s.safety.deadline > s.capturedMono
      ? timestamp(s.capturedEpoch + (s.safety.deadline - s.capturedMono)) : "N/A");
  root.add(b + "appliance", s.activeID >= 0 ? s.profiles[s.activeID].name : (running ? "Recognizing appliance" : "None"));
  root.add(b + "sensor_valid", s.sensor.valid && s.capturedMono - s.sensor.captured < 5000);
  root.add(b + "power_W", s.sensor.valid ? s.sensor.power : 0); root.add(b + "current_A", s.sensor.valid ? s.sensor.current : 0);
  root.add(b + "voltage_V", s.sensor.valid ? s.sensor.voltage : 0); root.add(b + "power_factor", s.sensor.valid ? s.sensor.pf : 0);
  root.add(b + "peak_power_W", s.peak); root.add(b + "start_time", timestamp(s.startEpoch));
  root.add(b + "last_updated", timestamp(s.capturedEpoch)); root.add(b + "last_updated_ms", double(s.capturedEpoch));
  root.add(b + "alertID", s.alert.id); root.add(b + "countdownExpiry", timestamp(s.alert.expiry));
  root.add(b + "countdownRemaining", s.safety.state == SocketState::Warning ? int((60000 - min(uint64_t(60000), s.capturedMono - s.safety.warningStarted) + 999) / 1000) : 0);
  if (s.commandID[0]) {
    String a = String("command_results/") + outlets[i].outlet + "/" + s.commandID + "/";
    root.add(a + "result", s.commandResult); root.add(a + "revision", int(s.safety.revision));
  }
  FirebaseJson catalog;
  for (uint32_t n = 0; n < s.count; ++n) {
    const auto& p = s.profiles[n]; FirebaseJson profile; String path;
    profile.add(path + "name", p.name); profile.add(path + "steadyPower_W", p.steadyPower); profile.add(path + "peakPower_W", p.peakPower);
    profile.add(path + "current_A", p.current); profile.add(path + "voltage_V", p.voltage); profile.add(path + "powerFactor", p.pf);
    profile.add(path + "maxRunTime", int(p.maxRunTime)); profile.add(path + "safetyCeilingDuration", int(p.safetyCeilingDuration));
    profile.add(path + "registered_at", timestamp(p.registeredAt));
    catalog.add(p.profileID, profile);
  }
  root.add(String("appliance_profiles/") + outlets[i].catalog, catalog);
  if (s.alert.id[0]) {
    String path = String("alerts/") + s.alert.id + "/";
    root.add(path + "deviceID", outlets[i].outlet); root.add(path + "alertType", s.alert.type);
    root.add(path + "triggerTime", timestamp(s.alert.trigger)); root.add(path + "countdownExpiry", timestamp(s.alert.expiry));
    root.add(path + "resolution", s.alert.resolution);
  }
  return Firebase.updateNode(fbdo, "/", root);
}
void networkTask(void*) {
  WiFi.setAutoReconnect(true); WiFi.begin(WIFI_SSID, WIFI_PASSWORD); configTime(0, 0, "pool.ntp.org");
  config.host = FIREBASE_HOST; config.signer.tokens.legacy_token = FIREBASE_AUTH;
  Firebase.begin(&config, &auth); Firebase.reconnectWiFi(true);
  static Snapshot latest[2]; bool available[2] = {false, false};
  for (;;) {
    if (WiFi.status() == WL_CONNECTED && Firebase.ready()) {
      for (int i = 0; i < 2; ++i) {
        readCommand(i);
        if (xQueueReceive(outlets[i].snapshots, &latest[i], 0) == pdTRUE) available[i] = true;
        if (available[i]) publish(i, latest[i]);
      }
    }
    vTaskDelay(pdMS_TO_TICKS(500));
  }
}
void setup() {
  Serial.begin(115200); Serial2.begin(9600, SERIAL_8N1, 32, 33); Serial1.begin(9600, SERIAL_8N1, 25, 26);
  snprintf(sessionID, sizeof(sessionID), "%08lx%08lx", (unsigned long)esp_random(), (unsigned long)esp_random());
  for (int i = 0; i < 2; ++i) {
    auto& ch = outlets[i]; ch.ns = i == 0 ? "apps_a" : "apps_b"; ch.outlet = i == 0 ? "outlet_A" : "outlet_B";
    ch.catalog = i == 0 ? "OUTLET_A" : "OUTLET_B"; ch.button = i == 0 ? 4 : 5; pinMode(ch.button, INPUT_PULLUP);
    ch.rawButton = ch.stableButton = digitalRead(ch.button); ch.buttonChanged = monotonicMs();
    ch.sensors = xQueueCreate(1, sizeof(SensorSample)); ch.commands = xQueueCreate(4, sizeof(Command)); ch.snapshots = xQueueCreate(1, sizeof(Snapshot));
    configASSERT(ch.sensors && ch.commands && ch.snapshots);
    ch.storageOK = ch.prefs.begin(ch.ns, false); ch.data.count = ch.prefs.getUInt("count_v2", 0);
    if (ch.data.count > MAX_APPLIANCES || (ch.data.count && ch.prefs.getBytes("profiles_v2", ch.data.profiles, sizeof(ch.data.profiles)) != sizeof(ch.data.profiles))) {
      ch.data.count = 0; ch.storageOK = false;
    }
    for (uint32_t n = 0; n < ch.data.count; ++n) {
      auto& p = ch.data.profiles[n];
      if (!memchr(p.name, 0, sizeof(p.name)) || !memchr(p.profileID, 0, sizeof(p.profileID)) || !p.maxRunTime || p.safetyCeilingDuration < p.maxRunTime || p.safetyCeilingDuration > 604800) ch.storageOK = false;
      p.name[63] = 0; p.profileID[63] = 0;
    }
    ch.prefs.getBytes("alert", &ch.data.alert, sizeof(AlertRecord));
    ch.data.alert.id[79] = 0; ch.data.alert.type[39] = 0; ch.data.alert.resolution[15] = 0;
    if (!ch.storageOK || ch.prefs.getBool("hazard", false)) lock(ch);
    else if (ch.prefs.getBool("disabled", false)) ch.data.safety.state = SocketState::Disabled;
  }
  configASSERT(xTaskCreatePinnedToCore(sensorTask, "meters", 4096, nullptr, 1, nullptr, 0) == pdPASS);
  configASSERT(xTaskCreatePinnedToCore(networkTask, "firebase", 16384, nullptr, 1, nullptr, 0) == pdPASS);
}
void loop() {
  uint64_t now = monotonicMs();
  for (auto& ch : outlets) {
    auto& safety = ch.data.safety;
    uint32_t maxRun = ch.data.activeID >= 0 ? ch.data.profiles[ch.data.activeID].maxRunTime : 3600;
    if (safety.tick(now, maxRun)) {
      if (safety.state == SocketState::Warning) beginAlert(ch, "SAFETY_CEILING_EXCEEDED", now); else lock(ch);
    }
    bool raw = digitalRead(ch.button);
    if (raw != ch.rawButton) { ch.rawButton = raw; ch.buttonChanged = now; }
    if (raw != ch.stableButton && now - ch.buttonChanged >= 50) {
      ch.stableButton = raw;
      if (!raw && ch.storageOK) {
        if (safety.state == SocketState::Warning) lock(ch);
        else { safety.physicalPress(); ch.data.activeID = -1; ch.data.peak = 0; persistSafety(ch); }
      }
    }
    SensorSample sample; if (xQueueReceive(ch.sensors, &sample, 0) == pdTRUE) handleSensor(ch, sample, now);
    if ((safety.state == SocketState::Active || safety.state == SocketState::Sampling) &&
        (!ch.data.sensor.valid || now - ch.data.sensor.captured > 5000)) beginAlert(ch, "SENSOR_UNAVAILABLE", now);
    Command cmd; if (xQueueReceive(ch.commands, &cmd, 0) == pdTRUE) handleCommand(ch, cmd, now);
    if (now - ch.lastSnapshot >= 250) {
      ch.lastSnapshot = now; ch.data.capturedMono = now; ch.data.capturedEpoch = epochMs();
      if (ch.data.alert.id[0] && !ch.data.alert.trigger && ch.data.capturedEpoch && safety.state == SocketState::Warning) {
        ch.data.alert.trigger = ch.data.capturedEpoch - (now - safety.warningStarted); ch.data.alert.expiry = ch.data.alert.trigger + 60000; persistSafety(ch);
      }
      xQueueOverwrite(ch.snapshots, &ch.data);
    }
  }
  delay(10);
}
