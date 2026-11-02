// Run with: node --test supabase/tests/shared_outlets.test.ts
// Outlet A and Outlet B as one system: an appliance registered or learned on
// one outlet is recognised, limited and counted the same on the other, and
// the only outlet rules are exclusivity and the AMBIGUOUS pre-selection.
import assert from "node:assert/strict";
import test from "node:test";
import { calibrate, calibrationFromRow, factorsFrom, NO_CALIBRATION } from "../functions/_shared/calibration.ts";
import {
  type Appliance,
  type Config,
  configFromRow,
  type Features,
  type Learning,
  profileFromSamples,
  recognize,
  recordUse,
  type Sample,
} from "../functions/_shared/matching.ts";
import { staleRuns } from "../functions/_shared/stale_runs.ts";

// The defaults of the recognition_config table.
const C: Config = configFromRow({
  tolerance_sigma: 3, floor_power_pct: 0.02, floor_pf: 0.02, floor_startup_peak_ratio: 0.1,
  floor_power_variation: 0.02, floor_settling_time_s: 2, floor_cycle_period_pct: 0.1,
  floor_standby_power_w: 0.5, weight_power: 0.3, weight_pf: 0.3, weight_startup_peak_ratio: 0.15,
  weight_power_variation: 0.1, weight_settling_time: 0.1, weight_standby_power: 0.05,
  weight_cycle_period: 0, clear_winner_ratio: 1.5, tie_margin: 0.1, voltage_correction_min_pf: 0.95,
  default_cutoff_minutes: 30, ema_factor: 0.1, max_samples_per_profile: 20, registration_samples: 3,
  learning_uses: 7, learned_margin: 1.5, min_learned_cutoff_minutes: 5, min_session_s: 10,
});
const A = { deviceId: "gadget-1", outlet: "outlet_1" };
const B = { deviceId: "gadget-1", outlet: "outlet_2" };

const plugIn = (power: number): Sample =>
  ({ avg_power_w: power, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 4.5, power_variation: 0.022, avg_voltage_v: 230 });
const reading: Features = { avg_power_w: 57.1, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 4, avg_voltage_v: 230 };

function fan(id: string, samples: Sample[], extra: Partial<Appliance> = {}): Appliance {
  return {
    id, name: id, typeId: "type-fan", typeName: "Fan", ownCutoffS: 4 * 3600, isLearned: false,
    baselineRuntimeS: null, lastDeviceId: null, lastOutlet: null, activeOn: null,
    profiles: [{ id: `${id}/Normal`, modeName: "Normal", ...profileFromSamples(samples) }], ...extra,
  };
}
const registeredOnA = (extra: Partial<Appliance> = {}) =>
  fan("Fan", [plugIn(56.7), plugIn(57), plugIn(57.3)], { lastDeviceId: "gadget-1", lastOutlet: "outlet_1", ...extra });
const run = (here: typeof A, appliances: Appliance[], stage: 1 | 2 = 1, previous: string | null = null, x = reading) =>
  recognize({ features: x, stage, here, appliances, previousApplianceId: previous, config: C });

test("1. Fan registered entirely on A is recognised on B with no re-registration", () => {
  const onB1 = run(B, [registeredOnA()]);
  assert.equal(onB1.status, "MATCHED_PROVISIONAL");
  assert.equal(onB1.match?.appliance.id, "Fan");
  const onB2 = run(B, [registeredOnA()], 2, "Fan", { ...reading, power_variation: 0.021 });
  assert.equal(onB2.status, "MATCHED_CONFIRMED");
  assert.equal(onB2.cutoffS, 4 * 3600);
});

test("2. Plug-ins split over the outlets (1 on A, 2-3 on B) make one profile that works on both", () => {
  const split = fan("Fan", [plugIn(56.7) /* A */, plugIn(57) /* B */, plugIn(57.3) /* B */]);
  assert.equal(split.profiles[0].sampleCount, 3);
  for (const here of [A, B]) assert.equal(run(here, [split]).match?.appliance.id, "Fan");
  // The same samples give the same profile, whatever outlet measured them.
  assert.deepEqual(split.profiles[0].mean, registeredOnA().profiles[0].mean);
});

test("3. The 7-use learning counts uses from both outlets together, and the limit applies on both", () => {
  let l: Learning = { useCount: 0, recentRuntimesS: [], isLearned: false, baselineRuntimeS: null };
  for (const runtime of [1800, 1800, 1800, 1800, 1800, 1800, 1800]) l = recordUse(l, runtime, C); // A, B, A, B, ...
  assert.equal(l.useCount, 7);
  assert.equal(l.isLearned, true);
  const learned = registeredOnA({ isLearned: true, baselineRuntimeS: l.baselineRuntimeS });
  const onA = run(A, [learned], 2, "Fan", { ...reading, power_variation: 0.021 });
  const onB = run(B, [learned], 2, "Fan", { ...reading, power_variation: 0.021 });
  assert.equal(onA.cutoffS, 45 * 60); // 30 min x 1.5
  assert.equal(onB.cutoffS, onA.cutoffS);
});

test("4. Exclusivity stays: Fan running on A, an identical fan on B -> SAME_TYPE_IN_USE", () => {
  const r = run(B, [registeredOnA({ activeOn: A })]);
  assert.equal(r.status, "SAME_TYPE_IN_USE");
  assert.equal(r.registerAs?.name, "Fan 2");
  assert.equal(r.cutoffS, C.defaultCutoffS);
});

test("5. A run left open on A (end never reported) does not block the Fan on B", () => {
  const open = [{ id: "a", event_id: "boot1_outlet_A_100", outlet: "outlet_1" }];
  const closed = staleRuns(open, { eventId: "boot1_outlet_B_900", outlet: "outlet_2", running: ["boot1_outlet_B_900"] });
  assert.deepEqual(closed, [{ id: "a", reason: "NOT_RUNNING" }]);
  // With that run closed the Fan is no longer active anywhere, so it matches on B.
  assert.equal(run(B, [registeredOnA()]).status, "MATCHED_PROVISIONAL");
});

test("6. The unconfirmed default (30 min) is the same on both outlets", () => {
  const unknown: Features = { avg_power_w: 1800, avg_pf: 1, startup_peak_ratio: 1, settling_time_s: 2 };
  assert.equal(run(A, [registeredOnA()], 1, null, unknown).cutoffS, C.defaultCutoffS);
  assert.equal(run(B, [registeredOnA()], 1, null, unknown).cutoffS, C.defaultCutoffS);
});

test("7. Last used on this outlet only pre-selects an AMBIGUOUS answer, on either outlet", () => {
  const twins = [registeredOnA(), fan("Fan 2", [plugIn(56.7), plugIn(57), plugIn(57.3)], { lastDeviceId: "gadget-1", lastOutlet: "outlet_2" })];
  const onA = run(A, twins), onB = run(B, twins);
  assert.equal(onA.status, "AMBIGUOUS");
  assert.equal(onB.status, "AMBIGUOUS");
  assert.equal(onA.suggested?.applianceId, "Fan");
  assert.equal(onB.suggested?.applianceId, "Fan 2");
});

test("8. Calibration: B's meter reads 4 % low; once calibrated, B's reading matches the profile from A", () => {
  const onB = { ...reading, avg_power_w: 57.1 * 0.96 };
  assert.equal(run(B, [registeredOnA()], 1, null, onB).status, "UNKNOWN"); // 2.3 W off: outside the tolerance
  const cal = factorsFrom({ voltage: 230, power: 60, pf: 1 }, { voltage: 230, power: 57.6, pf: 1 });
  assert.equal(cal.power, 1.0417);
  assert.equal(run(B, [registeredOnA()], 1, null, calibrate(onB, cal)).status, "MATCHED_PROVISIONAL");
});

test("calibration scales power, standby, voltage and PF, and leaves ratios and times alone", () => {
  const x: Features = { avg_power_w: 100, standby_power_w: 2, avg_voltage_v: 220, avg_pf: 0.99, startup_peak_ratio: 1.6,
    power_variation: 0.05, settling_time_s: 7, cycle_period_s: 30, unstable: false };
  const y = calibrate(x, { power: 1.02, voltage: 1.01, pf: 1.02 });
  assert.equal(y.avg_power_w, 102);
  assert.equal(y.standby_power_w, 2.04);
  assert.equal(y.avg_voltage_v, 222.2);
  assert.equal(y.avg_pf, 1); // never above 1
  for (const k of ["startup_peak_ratio", "power_variation", "settling_time_s", "cycle_period_s", "unstable"] as const) {
    assert.equal(y[k], x[k]);
  }
  assert.deepEqual(calibrate(x, NO_CALIBRATION), x);
});

test("calibration factors from the outlets row default to 1.0", () => {
  assert.deepEqual(calibrationFromRow(null), NO_CALIBRATION);
  assert.deepEqual(calibrationFromRow({ power_cal: "1.0200", voltage_cal: "0.9950", pf_cal: "1.0000" }),
    { power: 1.02, voltage: 0.995, pf: 1 });
  assert.throws(() => factorsFrom({ voltage: 230, power: 60, pf: 1 }, { voltage: 230, power: 0, pf: 1 }));
});
