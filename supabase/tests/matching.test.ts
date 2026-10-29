// Run with: node --test supabase/tests/matching.test.ts
//      or: deno test supabase/tests/matching.test.ts
// The rule-based recognizer (_shared/matching.ts), without a database.
// Tests 1-9 are the required scenarios (registered Fan: 57 W, PF 0.92).
import assert from "node:assert/strict";
import test from "node:test";
import {
  type Appliance,
  type Config,
  configFromRow,
  confirmedCutoffS,
  emaUpdate,
  evaluateProfile,
  type Features,
  nextInstanceName,
  parseFeatures,
  type Profile,
  profileFromSamples,
  recognize,
  type RecognizeInput,
  recordUse,
  type Sample,
  tolerance,
} from "../functions/_shared/matching.ts";

// The defaults of the recognition_config table, as Postgres returns them (strings).
const CONFIG_ROW = {
  tolerance_sigma: "3.00", floor_power_pct: "0.0200", floor_pf: "0.0200", floor_startup_peak_ratio: "0.1000",
  floor_power_variation: "0.0200", floor_settling_time_s: "2.00", floor_cycle_period_pct: "0.1000",
  floor_standby_power_w: "0.50", weight_power: "0.300", weight_pf: "0.300", weight_startup_peak_ratio: "0.150",
  weight_power_variation: "0.100", weight_settling_time: "0.100", weight_standby_power: "0.050",
  weight_cycle_period: "0.000", clear_winner_ratio: "1.50", tie_margin: "0.100",
  voltage_correction_min_pf: "0.950", default_cutoff_minutes: 30, ema_factor: "0.100",
  max_samples_per_profile: 20, registration_samples: 3, learning_uses: 7, learned_margin: "1.50",
  min_learned_cutoff_minutes: 5, min_session_s: 10,
};
const C: Config = configFromRow(CONFIG_ROW);
const HOUR = 3600;

/** A registered profile built like registration does: from 3 plug-ins. */
function profile(id: string, modeName: string, samples: Sample[]): Profile {
  return { id, modeName, ...profileFromSamples(samples) };
}
const fanSamples = (power: number, pf: number): Sample[] => [
  { avg_power_w: power - 0.3, avg_pf: pf, startup_peak_ratio: 1.45, settling_time_s: 4, power_variation: 0.020, avg_voltage_v: 229 },
  { avg_power_w: power, avg_pf: pf + 0.005, startup_peak_ratio: 1.50, settling_time_s: 5, power_variation: 0.025, avg_voltage_v: 230 },
  { avg_power_w: power + 0.3, avg_pf: pf - 0.005, startup_peak_ratio: 1.55, settling_time_s: 4, power_variation: 0.022, avg_voltage_v: 231 },
];

function appliance(id: string, typeName: string, profiles: Profile[], extra: Partial<Appliance> = {}): Appliance {
  return {
    id, name: id, typeId: `type-${typeName}`, typeName, ownCutoffS: 4 * HOUR, isLearned: false,
    baselineRuntimeS: null, lastDeviceId: null, lastOutlet: null, activeOn: null, profiles, ...extra,
  };
}
const A = { deviceId: "gadget-1", outlet: "outlet_1" };
const B = { deviceId: "gadget-1", outlet: "outlet_2" };
const fan = (extra: Partial<Appliance> = {}) =>
  appliance("Fan", "Fan", [profile("fan-normal", "Normal", fanSamples(57, 0.92))], extra);
const run = (features: Features, appliances: Appliance[], here = B, stage: 1 | 2 = 1, previousApplianceId: string | null = null) =>
  recognize({ features, stage, here, appliances, previousApplianceId, config: C } satisfies RecognizeInput);
const fanReading: Features = { avg_power_w: 57.1, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 4, avg_voltage_v: 230 };

test("1. Fan active on A; 58 W charger with PF 0.55 on B -> UNKNOWN (PF fails)", () => {
  const r = run({ avg_power_w: 58, avg_pf: 0.55, startup_peak_ratio: 1.0, settling_time_s: 2 }, [fan({ activeOn: A })]);
  assert.equal(r.status, "UNKNOWN");
  assert.equal(r.match, null);
  assert.equal(r.cutoffS, C.defaultCutoffS);
  assert.equal(r.promptText, "New appliance detected. Register it?");
  // Why: the PF check alone fails (|0.55 - 0.92| / 0.02 = 18.5 > 1).
  const check = evaluateProfile({ avg_power_w: 58, avg_pf: 0.55 }, fan(), fan().profiles[0], 1, C);
  assert.equal(check.checks.find((k) => k.feature === "avg_pf")!.pass, false);
  assert.equal(check.checks.find((k) => k.feature === "avg_power_w")!.pass, true);
});

test("2. Fan active on A; identical fan (56 W, PF 0.91) on B -> SAME_TYPE_IN_USE, 'Register as Fan 2?'", () => {
  const r = run({ avg_power_w: 56, avg_pf: 0.91, startup_peak_ratio: 1.5, settling_time_s: 4 }, [fan({ activeOn: A })]);
  assert.equal(r.status, "SAME_TYPE_IN_USE");
  assert.equal(r.registerAs?.name, "Fan 2");
  assert.equal(r.promptText, "This looks like another Fan. Register as Fan 2?");
  assert.equal(r.cutoffS, C.defaultCutoffS);  // never the Fan's 4 h
});

test("3. Fan unplugged from A, plugged into B -> MATCHED_PROVISIONAL, confirmed at Stage 2", () => {
  const stage1 = run(fanReading, [fan({ lastDeviceId: A.deviceId, lastOutlet: A.outlet })]);
  assert.equal(stage1.status, "MATCHED_PROVISIONAL");
  assert.equal(stage1.match?.appliance.id, "Fan");
  assert.equal(stage1.cutoffS, C.defaultCutoffS);  // provisional: still the safe default
  const stage2 = run({ ...fanReading, power_variation: 0.023 }, [fan()], B, 2, stage1.match!.appliance.id);
  assert.equal(stage2.status, "MATCHED_CONFIRMED");
  assert.equal(stage2.cutoffS, 4 * HOUR);  // now its own limit
});

test("4. Two registered appliances pass with close scores -> AMBIGUOUS", () => {
  const lamp = appliance("Desk lamp", "Lamp", [profile("lamp", "Normal", [
    { avg_power_w: 56.4, avg_pf: 0.925, startup_peak_ratio: 1.5, settling_time_s: 4 },
    { avg_power_w: 57.0, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 5 },
    { avg_power_w: 57.6, avg_pf: 0.915, startup_peak_ratio: 1.5, settling_time_s: 4 },
  ])]);
  const r = run(fanReading, [fan(), lamp]);
  assert.equal(r.status, "AMBIGUOUS");
  assert.match(r.promptText, /^Is this (Fan or Desk lamp|Desk lamp or Fan)\?$/);
  assert.equal(r.candidates.length, 2);
  assert.equal(r.cutoffS, C.defaultCutoffS);
});

test("4b. Identical idle units -> AMBIGUOUS with the one last used here pre-selected", () => {
  const fan1 = appliance("Fan 1", "Fan", [profile("f1", "Normal", fanSamples(57, 0.92))], { lastDeviceId: A.deviceId, lastOutlet: A.outlet });
  const fan2 = appliance("Fan 2", "Fan", [profile("f2", "Normal", fanSamples(57, 0.92))], { lastDeviceId: B.deviceId, lastOutlet: B.outlet });
  const r = run(fanReading, [fan1, fan2], B);
  assert.equal(r.status, "AMBIGUOUS");
  assert.equal(r.suggested?.applianceId, "Fan 2");
  assert.match(r.reason, /cannot tell identical units apart/);
  // With Fan 1 running on A, exclusivity decides: Fan 2.
  const busy = run(fanReading, [{ ...fan1, activeOn: A }, fan2], B);
  assert.equal(busy.status, "MATCHED_PROVISIONAL");
  assert.equal(busy.match?.appliance.id, "Fan 2");
});

test("5. Fan with Low and High modes, plugged in on High -> matches Fan (High)", () => {
  const twoSpeed = appliance("Fan", "Fan", [
    profile("low", "Low", fanSamples(40, 0.90)),
    profile("high", "High", fanSamples(57, 0.92)),
  ]);
  const r = run(fanReading, [twoSpeed]);
  assert.equal(r.status, "MATCHED_PROVISIONAL");
  assert.equal(r.match?.profile.modeName, "High");
});

test("6. 1000 W heater registered at 220 V, measured at 235 V -> matches after voltage correction", () => {
  const heaterSamples: Sample[] = [999, 1000, 1001].map((p) => ({
    avg_power_w: p, avg_pf: 1.0, startup_peak_ratio: 1.02, settling_time_s: 3, avg_voltage_v: 220,
  }));
  const heater = appliance("Heater", "Heater", [profile("heater", "Normal", heaterSamples)]);
  const measured = 1000 * (235 / 220) ** 2;  // 1141 W: P = V^2 / R
  const r = run({ avg_power_w: measured, avg_pf: 1.0, startup_peak_ratio: 1.02, settling_time_s: 3, avg_voltage_v: 235 }, [heater]);
  assert.equal(r.status, "MATCHED_PROVISIONAL");
  assert.ok(r.match?.voltageCorrected);
  // Without the voltage the same reading fails (141 W > 2 % of 1000 W).
  assert.equal(run({ avg_power_w: measured, avg_pf: 1.0 }, [heater]).status, "UNKNOWN");
  // A motor (PF < 0.95) is never corrected.
  assert.equal(evaluateProfile({ ...fanReading, avg_voltage_v: 240 }, fan(), fan().profiles[0], 1, C).voltageCorrected, false);
});

test("7. Never-seen appliance -> UNKNOWN, default cutoff applied", () => {
  const r = run({ avg_power_w: 1500, avg_pf: 0.99, startup_peak_ratio: 1.0 }, [fan()]);
  assert.equal(r.status, "UNKNOWN");
  assert.equal(r.cutoffS, 30 * 60);
});

test("8. Noisy readings within tolerance -> still matches (200 seeded runs)", () => {
  let seed = 11;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 2 ** 32; return seed / 2 ** 32 - 0.5; };
  let matched = 0;
  for (let i = 0; i < 200; i++) {
    // PZEM-like noise: +-0.4 W, +-0.008 PF, start-up +-0.05, settling +-1 s
    const r = run({
      avg_power_w: 57 + rnd() * 0.8, avg_pf: 0.92 + rnd() * 0.016,
      startup_peak_ratio: 1.5 + rnd() * 0.1, settling_time_s: 4.3 + rnd() * 2,
    }, [fan()]);
    if (r.status === "MATCHED_PROVISIONAL" && r.match?.appliance.id === "Fan") matched++;
  }
  assert.equal(matched, 200);
});

test("9. Unconfirmed load: only the default cutoff, whatever it resembles", () => {
  const longFan = fan({ ownCutoffS: 8 * HOUR, activeOn: A });
  for (const r of [
    run(fanReading, [longFan]),                         // SAME_TYPE_IN_USE
    run({ avg_power_w: 300, avg_pf: 0.6 }, [longFan]),  // UNKNOWN
    run(fanReading, [fan({ ownCutoffS: 8 * HOUR })]),   // MATCHED_PROVISIONAL
  ]) {
    assert.notEqual(r.status, "MATCHED_CONFIRMED");
    assert.equal(r.cutoffS, C.defaultCutoffS);
  }
  // The plug cuts power when that default runs out: firmware test (Phase 3).
});

test("Stage 2 that disagrees with Stage 1 corrects it but stays provisional", () => {
  const lampSamples: Sample[] = fanSamples(57, 0.92).map((s) => ({ ...s, power_variation: 0.2 }));
  const fan2 = appliance("Fan", "Fan", [profile("f", "Normal", fanSamples(57, 0.92))]);
  const lamp = appliance("Lamp", "Lamp", [profile("l", "Normal", lampSamples)]);
  const r = run({ ...fanReading, power_variation: 0.2 }, [fan2, lamp], B, 2, "Fan");
  assert.equal(r.match?.appliance.id, "Lamp");
  assert.equal(r.status, "MATCHED_PROVISIONAL");
  assert.match(r.reason, /corrected at Stage 2/);
});

test("Rule 1: tolerance = max(3 x std, floor)", () => {
  const p: Profile = { id: "p", modeName: "x", mean: { avg_power_w: 100, avg_pf: 0.9 }, std: { avg_power_w: 1, avg_pf: 0 }, registrationVoltage: null, sampleCount: 3 };
  assert.equal(tolerance("avg_power_w", p, C), 3);  // 3 x 1 W beats 2 % of 100 W
  assert.equal(tolerance("avg_pf", p, C), 0.02);    // std 0: the floor
});

test("Null features are skipped; power is always required", () => {
  const r = evaluateProfile({ avg_power_w: 57, avg_pf: null }, fan(), fan().profiles[0], 1, C);
  assert.deepEqual(r.checks.map((k) => k.feature), ["avg_power_w"]);  // PF null: skipped
  assert.ok(r.pass);
  assert.equal(evaluateProfile({ avg_pf: 0.92 } as Features, fan(), fan().profiles[0], 1, C).pass, false);
});

test("A profile is matched only after its 3 registration plug-ins", () => {
  const incomplete = appliance("Fan", "Fan", [profile("f", "Normal", fanSamples(57, 0.92).slice(0, 2))]);
  assert.equal(run(fanReading, [incomplete]).status, "UNKNOWN");
});

test("Scores close to zero are not a 'clear winner' (tie margin)", () => {
  const twin = appliance("Fan B", "Fan", [profile("fb", "Normal", fanSamples(57.05, 0.92))]);
  assert.equal(run({ ...fanReading, avg_power_w: 57.02 }, [fan(), twin]).status, "AMBIGUOUS");
});

test("Signature updating: EMA mean, std from the newest samples", () => {
  const p = fan().profiles[0];
  const x: Sample = { avg_power_w: 58, avg_pf: 0.93, startup_peak_ratio: 1.5, settling_time_s: 4 };
  const u = emaUpdate(p, x, [x, ...fanSamples(57, 0.92)], C);
  assert.ok(Math.abs(u.mean.avg_power_w! - (0.9 * 57 + 0.1 * 58)) < 1e-9);
  assert.equal(u.sampleCount, 4);
  assert.ok(u.std.avg_power_w! > p.std.avg_power_w!);
});

test("Registration: mean, std and voltage from the samples", () => {
  const p = profileFromSamples(fanSamples(57, 0.92));
  assert.ok(Math.abs(p.mean.avg_power_w! - 57) < 1e-9);
  assert.ok(Math.abs(p.std.avg_power_w! - 0.3) < 1e-9);
  assert.equal(p.registrationVoltage, 230);
  assert.equal(p.mean.cycle_period_s, null);
});

test("7-use learning: baseline after 7 uses, cutoff = baseline x 1.5 within limits", () => {
  let l = { useCount: 0, recentRuntimesS: [] as number[], isLearned: false, baselineRuntimeS: null as number | null };
  l = recordUse(l, 5, C);  // under 10 s: ignored
  assert.equal(l.useCount, 0);
  for (let i = 0; i < 7; i++) l = recordUse(l, 1200, C);
  assert.equal(l.isLearned, true);
  assert.equal(l.baselineRuntimeS, 1200);
  assert.equal(confirmedCutoffS(fan({ isLearned: true, baselineRuntimeS: 1200 }), C), 1800);
  assert.equal(confirmedCutoffS(fan({ isLearned: true, baselineRuntimeS: 60 }), C), 300);        // at least 5 min
  assert.equal(confirmedCutoffS(fan({ isLearned: true, baselineRuntimeS: 4 * HOUR }), C), 4 * HOUR);  // never above its own
  assert.equal(confirmedCutoffS(fan(), C), 4 * HOUR);  // not learned yet: its own
});

test("Names: 'Fan 2' after 'Fan'; gaps filled; case-insensitive", () => {
  assert.equal(nextInstanceName("Fan", ["Fan"], 1), "Fan 2");
  assert.equal(nextInstanceName("Fan", ["fan 2", "Fan"], 2), "Fan 3");
  assert.equal(nextInstanceName("Kettle", [], 0), "Kettle 1");
});

test("parseFeatures validates the plug's summary", () => {
  assert.equal(parseFeatures({ avg_pf: 0.9 }), "features.avg_power_w is required");
  assert.equal(parseFeatures({ avg_power_w: 57, avg_pf: 1.4 }), "features.avg_pf must be 0..1");
  assert.deepEqual(parseFeatures({ avg_power_w: 57, unstable: true, extra: 1 }), { avg_power_w: 57, unstable: true });
});
