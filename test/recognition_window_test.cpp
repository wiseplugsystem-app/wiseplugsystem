// Unit tests for the plug's run measurement (recognition_window.h) and the
// default-cutoff safety rule (safety_state.h). Build and run on a PC:
//   g++ -std=c++17 -o recognition_window_test test/recognition_window_test.cpp && ./recognition_window_test
#include "../arduino/wiseplug_esp32/recognition_window.h"
#include "../arduino/wiseplug_esp32/safety_state.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static bool near(float a, float b, float eps = 0.01f) { return fabsf(a - b) <= eps; }

// Feeds one reading per second from second [from] with power p(k) at second k, PF 0.92,
// 230 V, until the window reports [stage]; returns the second it did.
template <typename F>
static int runUntil(RecognitionWindow& w, int stage, F power, int from = 0, int maxS = 120) {
  for (int k = from; k <= maxS; ++k) {
    int got = w.add(uint64_t(k) * 1000, power(k), 0.92f, 230.0f);
    if (got == stage) return k;
    assert(got == 0 || got < stage);  // stages come in order, once each
  }
  return -1;
}

int main() {
  {  // A heater: steady from the first reading. Settled after 5 readings (4 s).
    RecognitionWindow w; w.begin(0, 0);
    assert(runUntil(w, 1, [](int) { return 1000.0f; }) == 14);  // 10 s into STEADY
    RecFeatures s1 = w.features(1);
    assert(near(s1.avgPowerW, 1000) && near(s1.avgPf, 0.92f) && near(s1.avgVoltageV, 230));
    assert(near(s1.settlingTimeS, 4) && near(s1.startupPeakRatio, 1) && !s1.unstable);
    assert(!s1.hasVariation && !s1.hasCycle);  // Stage 1 has no variation / cycling
    assert(runUntil(w, 2, [](int) { return 1000.0f; }, 15) == 34);  // end of 30 s STEADY
    RecFeatures s2 = w.features(2);
    assert(s2.hasVariation && near(s2.powerVariation, 0) && !s2.hasCycle);
    assert(w.phase == RecPhase::Reported && w.add(35000, 1000, 0.92f, 230) == 0);
  }
  {  // A fan: 1.6 x its steady power for the first 3 s (motor start-up).
    RecognitionWindow w; w.begin(0, 0);
    auto fan = [](int k) { return k < 3 ? 91.2f : 57.0f; };
    assert(runUntil(w, 1, fan) == 17);  // settled at 7 s (5 readings of 57 W)
    RecFeatures f = w.features(1);
    assert(near(f.settlingTimeS, 7) && near(f.startupPeakRatio, 1.6f) && near(f.avgPowerW, 57));
  }
  {  // Never within 2 % for 5 readings: only Stage 2, at 60 s, unstable.
    RecognitionWindow w; w.begin(0, 0);
    assert(runUntil(w, 2, [](int k) { return k % 2 ? 110.0f : 100.0f; }) == 60);
    assert(!w.stage1Done);
    RecFeatures f = w.features(2);
    assert(f.unstable && near(f.settlingTimeS, 60) && near(f.avgPowerW, 105));
    assert(near(f.powerVariation, 10.0f / 105));
  }
  {  // Thermostat: 4 s on (1000 W), 4 s off (100 W): cycle period 8 s.
    RecognitionWindow w; w.begin(0, 0);
    assert(runUntil(w, 2, [](int k) { return k % 8 < 4 ? 1000.0f : 100.0f; }) == 60);
    RecFeatures f = w.features(2);
    assert(f.unstable && f.hasCycle && near(f.cyclePeriodS, 8));
  }
  {  // The sensor task samples every 200 ms; each meter update counts once.
    RecognitionWindow w; w.begin(0, 0);
    for (uint64_t ms = 0; ms < 4000; ms += 200) w.add(ms, 50, 0.9f, 230);
    assert(w.recentN == 4);  // t = 0, 1000, 2000, 3000
  }
  {  // Standby: known only above the meter's noise (0.5 W).
    RecognitionWindow a; a.begin(0, 0.8f);
    RecognitionWindow b; b.begin(0, 0.2f);
    assert(a.features(1).hasStandby && near(a.features(1).standbyPowerW, 0.8f));
    assert(!b.features(1).hasStandby);
  }
  {  // Cancelled when the run ends: nothing more is reported.
    RecognitionWindow w; w.begin(0, 0); w.add(0, 50, 0.9f, 230); w.cancel();
    assert(w.add(1000, 50, 0.9f, 230) == 0 && !w.measuring());
  }
  {  // Scenario 9: an unconfirmed load keeps the default 30 min cutoff and is cut.
    const uint32_t DEFAULT_LIMIT_S = 30 * 60;
    SafetyState s; s.begin(0, DEFAULT_LIMIT_S);  // plug-in; no MATCHED_CONFIRMED reply
    assert(!s.tick(uint64_t(DEFAULT_LIMIT_S) * 1000 - 1, DEFAULT_LIMIT_S));
    assert(s.tick(uint64_t(DEFAULT_LIMIT_S) * 1000, DEFAULT_LIMIT_S) && s.state == SocketState::Warning);
    assert(s.tick(uint64_t(DEFAULT_LIMIT_S) * 1000 + 60000, DEFAULT_LIMIT_S));
    assert(s.state == SocketState::LockedOut);  // relayEnergized() is false: power cut
  }
  printf("recognition_window_test: all tests passed\n");
  return 0;
}
