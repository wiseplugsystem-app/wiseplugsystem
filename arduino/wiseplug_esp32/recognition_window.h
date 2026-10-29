// Per-outlet measurement for rule-based recognition: turns the 1 Hz PZEM-004T
// readings of one run into the feature summaries the Supabase
// recognize-appliance function compares (supabase/functions/_shared/matching.ts).
// Pure C++ (no Arduino APIs): unit-tested in test/recognition_window_test.cpp.
//
// One run goes through these phases:
//   STARTUP   the first 5 s after plug-in: the highest power is kept
//             (startup_peak_ratio = that peak / steady average power)
//   SETTLING  until the load is steady: 5 consecutive readings whose
//             spread (max - min) is under 2 % of their mean
//             (settling_time_s = seconds from plug-in until then)
//   STEADY    30 s of steady readings: average power, PF and voltage, and
//             power_variation = (max - min) / mean power
//   REPORTED  both stages produced; nothing more is measured
//
// Stage 1 is ready 10 s into STEADY (power, PF, start-up, settling, standby);
// Stage 2 at the end of STEADY adds the power variation and, if the load
// switched on and off at least twice, the cycle period. A load that never
// settles within 60 s (a thermostat cycling, a varying load) produces only
// Stage 2, from everything after the start-up, marked unstable.
//
// Limits at 1 reading per second: millisecond inrush is averaged away, so the
// peak only reflects slow start-ups (motor spin-up, a charger's soft start); a
// thermostat is seen cycling only if it does so within the first minute.
#pragma once
#include <math.h>
#include <stdint.h>

enum class RecPhase : uint8_t { Idle, Startup, Settling, Steady, Reported };

struct RecFeatures {
  float avgPowerW = 0, avgPf = 0, avgVoltageV = 0;
  float startupPeakRatio = 1, settlingTimeS = 0;
  float powerVariation = 0, cyclePeriodS = 0, standbyPowerW = 0;
  bool hasVariation = false, hasCycle = false, hasStandby = false, unstable = false;
  uint32_t readings = 0;
};

struct RecognitionWindow {
  static constexpr uint64_t READING_MS = 900;        // the meter updates about once a second
  static constexpr uint64_t STARTUP_MS = 5000;
  static constexpr uint32_t SETTLE_READINGS = 5;
  static constexpr float SETTLE_FRACTION = 0.02f;    // "changes < 2 %"
  static constexpr uint64_t STAGE1_AFTER_MS = 10000; // into STEADY
  static constexpr uint64_t STEADY_MS = 30000;
  static constexpr uint64_t MAX_SETTLE_MS = 60000;   // from plug-in
  // Below this the meter cannot tell an appliance's standby from an empty socket.
  static constexpr float MIN_STANDBY_W = 0.5f;
  // On/off cycling, relative to the highest power seen in the run (hysteresis).
  static constexpr float CYCLE_HIGH = 0.5f, CYCLE_LOW = 0.3f;
  static constexpr uint32_t MIN_CYCLES = 2;          // complete on-to-on periods

  struct Reading { float p, pf, v; };
  // Running sums for averages, and the power range for the variation.
  struct Stats {
    double sumP = 0, sumPf = 0, sumV = 0;
    float minP = 0, maxP = 0;
    uint32_t n = 0;
    void add(const Reading& r) {
      minP = n ? fminf(minP, r.p) : r.p;
      maxP = n ? fmaxf(maxP, r.p) : r.p;
      sumP += r.p; sumPf += r.pf; sumV += r.v; ++n;
    }
    float meanP() const { return n ? float(sumP / n) : 0; }
  };

  RecPhase phase = RecPhase::Idle;
  uint64_t start = 0, lastReading = 0, settledAt = 0;
  float startupPeak = 0, standby = 0;
  bool standbyKnown = false, stage1Done = false, unstable = false, anyReading = false;
  Reading recent[SETTLE_READINGS] = {};  // the last readings, oldest first
  uint32_t recentN = 0;
  Stats steady, afterStartup;
  // Cycling: rising edges (low -> high) and the time between them.
  float maxSeen = 0;
  bool high = false, wasLow = false;
  uint64_t lastRise = 0;
  double cycleSumMs = 0;
  uint32_t cycles = 0;

  // A run starts. [idleW]: the smoothed power the outlet drew before it.
  void begin(uint64_t now, float idleW) {
    *this = RecognitionWindow{};
    phase = RecPhase::Startup; start = now;
    standby = idleW; standbyKnown = idleW >= MIN_STANDBY_W;
  }
  void cancel() { phase = RecPhase::Idle; }
  bool measuring() const { return phase == RecPhase::Startup || phase == RecPhase::Settling || phase == RecPhase::Steady; }

  // Feeds one valid reading. Returns 1 or 2 once, when that stage's features
  // are ready (features(stage)), otherwise 0.
  int add(uint64_t now, float p, float pf, float v) {
    if (!measuring()) return 0;
    if (anyReading && now - lastReading < READING_MS) return 0;  // count each meter update once
    anyReading = true; lastReading = now;
    const Reading r{p, pf, v};
    const uint64_t t = now - start;
    if (t < STARTUP_MS) startupPeak = fmaxf(startupPeak, p);
    else afterStartup.add(r);
    trackCycle(now, p);

    if (phase != RecPhase::Steady) {
      push(r);
      if (recentN == SETTLE_READINGS && settled()) {
        // Steady from here; the readings that proved it count as its start.
        phase = RecPhase::Steady; settledAt = now;
        for (const auto& x : recent) steady.add(x);
      } else {
        if (t >= STARTUP_MS) phase = RecPhase::Settling;
        if (t >= MAX_SETTLE_MS) { phase = RecPhase::Reported; unstable = true; return 2; }
        return 0;
      }
    } else {
      steady.add(r);
    }
    const uint64_t s = now - settledAt;
    if (!stage1Done && s >= STAGE1_AFTER_MS) { stage1Done = true; return 1; }
    if (s >= STEADY_MS) { phase = RecPhase::Reported; return 2; }
    return 0;
  }

  RecFeatures features(int stage) const {
    RecFeatures f;
    // Unstable: the steady window never started, so use everything after the start-up.
    const Stats& s = unstable || !steady.n ? afterStartup : steady;
    const float mean = s.meanP();
    f.avgPowerW = mean;
    f.avgPf = s.n ? float(s.sumPf / s.n) : 0;
    f.avgVoltageV = s.n ? float(s.sumV / s.n) : 0;
    f.startupPeakRatio = mean > 0 && startupPeak > 0 ? startupPeak / mean : 1;
    f.settlingTimeS = unstable ? float(MAX_SETTLE_MS) / 1000 : float(settledAt - start) / 1000;
    f.unstable = unstable;
    f.readings = s.n;
    f.hasStandby = standbyKnown; f.standbyPowerW = standby;
    if (stage == 2) {
      f.hasVariation = mean > 0;
      f.powerVariation = mean > 0 ? (s.maxP - s.minP) / mean : 0;
      f.hasCycle = cycles >= MIN_CYCLES;
      f.cyclePeriodS = f.hasCycle ? float(cycleSumMs / cycles / 1000) : 0;
    }
    return f;
  }

 private:
  void push(const Reading& r) {
    if (recentN < SETTLE_READINGS) { recent[recentN++] = r; return; }
    for (uint32_t i = 1; i < SETTLE_READINGS; ++i) recent[i - 1] = recent[i];
    recent[SETTLE_READINGS - 1] = r;
  }
  // "Settled": the last 5 readings lie within 2 % of their mean power.
  bool settled() const {
    float lo = recent[0].p, hi = recent[0].p, sum = 0;
    for (const auto& x : recent) { lo = fminf(lo, x.p); hi = fmaxf(hi, x.p); sum += x.p; }
    const float mean = sum / SETTLE_READINGS;
    return mean > 0 && hi - lo <= SETTLE_FRACTION * mean;
  }
  // A thermostat load swings between high (heating) and low. Each rise from
  // low to high after the first starts a new cycle; the period is the mean
  // time between rises.
  void trackCycle(uint64_t now, float p) {
    maxSeen = fmaxf(maxSeen, p);
    if (p >= CYCLE_HIGH * maxSeen) {
      if (!high && wasLow) {
        if (lastRise) { cycleSumMs += double(now - lastRise); ++cycles; }
        lastRise = now;
      }
      high = true;
    } else if (p <= CYCLE_LOW * maxSeen) {
      high = false; wasLow = true;
    }
  }
};
