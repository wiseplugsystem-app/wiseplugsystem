// Steady-state signature of one run, built from 1 Hz PZEM-004T readings and
// sent to the identify-appliance Edge Function (supabase/functions).
//
//   0 s .. PEAK_MS              start-up: only the highest power is kept
//                               (approximate: a 1 s meter averages the inrush)
//   PEAK_MS .. PEAK_MS+WINDOW_MS steady window: running mean and standard
//                               deviation (Welford) of P, I, PF and Q = sqrt(S^2 - P^2), S = V x I
//   0 s .. SIGNAL_N readings     raw signal: P, I, PF once per second from
//                               switch-on, for the server's CNN embedding
//
// Pure C++ (no Arduino APIs), so it can be unit-tested on a PC.
#pragma once
#include <math.h>
#include <stdint.h>

// Running mean and variance in one pass without storing readings (Welford 1962).
struct Welford {
  uint32_t n = 0;
  double mean = 0, m2 = 0;
  void add(double x) { ++n; double d = x - mean; mean += d / n; m2 += d * (x - mean); }
  double sd() const { return n > 1 ? sqrt(m2 / (n - 1)) : 0; }
};

struct SignatureFeatures {
  float power, current, pf, reactive, cv, peakRatio;
  uint32_t readings, windowS;
};

// The first readings of a run as the model sees them (start-up included).
struct SignatureSignal {
  static constexpr uint32_t N = 32;
  float power[N], current[N], pf[N];
  uint32_t n;
};

struct SignatureWindow {
  static constexpr uint64_t PEAK_MS = 5000, WINDOW_MS = 30000, READING_MS = 900;
  static constexpr uint32_t MIN_READINGS = 20;  // fewer: the meter dropped out, do not report
  bool open = false;
  uint64_t start = 0, lastReading = 0, lastSignal = 0;
  float peak = 0;
  Welford p, i, pf, q;
  SignatureSignal signal = {};

  void begin(uint64_t now) { *this = SignatureWindow{}; open = true; start = now; }
  void cancel() { open = false; }

  // Feeds one valid reading. Returns true once, when the window has closed
  // with enough readings; then features() is ready.
  bool add(uint64_t now, float power, float current, float voltage, float powerFactor) {
    if (!open) return false;
    auto& s = signal;
    if (s.n < SignatureSignal::N && (!s.n || now - lastSignal >= READING_MS)) {
      s.power[s.n] = power; s.current[s.n] = current; s.pf[s.n] = powerFactor; ++s.n;
      lastSignal = now;
    }
    uint64_t t = now - start;
    if (t < PEAK_MS) { if (power > peak) peak = power; return false; }
    if (t >= PEAK_MS + WINDOW_MS) { open = false; return p.n >= MIN_READINGS; }
    // The meter updates about once a second: count each reading once.
    if (lastReading && now - lastReading < READING_MS) return false;
    lastReading = now;
    double va = double(voltage) * current;
    p.add(power); i.add(current); pf.add(powerFactor);
    q.add(sqrt(fmax(va * va - double(power) * power, 0.0)));
    return false;
  }

  SignatureFeatures features() const {
    SignatureFeatures f;
    f.power = float(p.mean); f.current = float(i.mean); f.pf = float(pf.mean); f.reactive = float(q.mean);
    f.cv = p.mean > 0 ? float(p.sd() / p.mean) : 0;
    f.peakRatio = p.mean > 0 && peak > 0 ? float(peak / p.mean) : 1;
    f.readings = p.n; f.windowS = uint32_t(WINDOW_MS / 1000);
    return f;
  }
};
