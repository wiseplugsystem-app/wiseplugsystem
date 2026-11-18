// Run with: node --test supabase/tests/charger_no_register.test.ts
//      or: deno test supabase/tests/charger_no_register.test.ts
// A phone charger's reading is never offered as a new appliance: the pop-up
// only confirms the charger or picks which charger / phone it is
// (recognizeWithChargers, recognition_config.charger_no_register).
import assert from "node:assert/strict";
import test from "node:test";
import {
  type Appliance,
  configFromRow,
  type Features,
  type Profile,
  profileFromSamples,
  recognize,
  recognizeWithChargers,
  type Sample,
} from "../functions/_shared/matching.ts";

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
const C = configFromRow(CONFIG_ROW);
const A = { deviceId: "gadget-1", outlet: "outlet_1" };
const B = { deviceId: "gadget-1", outlet: "outlet_2" };

const profile = (id: string, samples: Sample[], requiredSamples?: number): Profile =>
  ({ id, modeName: "Charging", ...profileFromSamples(samples), ...(requiredSamples ? { requiredSamples } : {}) });
const appliance = (id: string, typeName: string, profiles: Profile[], extra: Partial<Appliance> = {}): Appliance => ({
  id, name: id, typeId: `type-${typeName}`, typeName, ownCutoffS: 4 * 3600, isLearned: false,
  baselineRuntimeS: null, lastDeviceId: null, lastOutlet: null, activeOn: null, profiles, ...extra,
});
const charger = (id: string, power: number, pf: number, extra: Partial<Appliance> = {}) =>
  appliance(id, "Phone charger", [profile(`${id}-p`, [{ avg_power_w: power, avg_pf: pf }], 1)],
    { varyingPower: true, ...extra });
const fan = () => appliance("Fan", "Fan", [profile("fan", [
  { avg_power_w: 56.7, avg_pf: 0.92, startup_peak_ratio: 1.45, settling_time_s: 4, power_variation: 0.02 },
  { avg_power_w: 57, avg_pf: 0.925, startup_peak_ratio: 1.5, settling_time_s: 5, power_variation: 0.025 },
  { avg_power_w: 57.3, avg_pf: 0.915, startup_peak_ratio: 1.55, settling_time_s: 4, power_variation: 0.022 },
])]);
const run = (features: Features, appliances: Appliance[], extra: { stage?: 1 | 2; here?: typeof A; config?: typeof C } = {}) =>
  recognizeWithChargers({ features, stage: extra.stage ?? 1, here: extra.here ?? A, appliances, config: extra.config ?? C });

test("one charger: 'Is this Purple charger?' with no register option", () => {
  const purple = charger("Purple charger", 10, 0.5);
  for (const stage of [1, 2] as const) {
    const r = run({ avg_power_w: 18, avg_pf: 0.55 }, [purple], { stage });
    assert.equal(r.status, "MATCHED_PROVISIONAL");
    assert.equal(r.chargerChoice, true);
    assert.equal(r.promptText, "Is this Purple charger?");
    assert.equal(r.candidates[0].charger, true);
    assert.equal(r.cutoffS, C.defaultCutoffS);  // safe default until confirmed
  }
});

test("several chargers: 'Which charger is this?' lists every free charger", () => {
  const purple = charger("Purple charger", 10, 0.5, { lastDeviceId: "gadget-1", lastOutlet: "outlet_1" });
  const samsung = charger("Samsung charger", 20, 0.62);
  const r = run({ avg_power_w: 10, avg_pf: 0.5 }, [samsung, purple]);
  assert.equal(r.status, "AMBIGUOUS");
  assert.equal(r.chargerChoice, true);
  assert.deepEqual(r.candidates.map((k) => k.applianceId), ["Purple charger", "Samsung charger"]);
  assert.equal(r.suggested?.applianceId, "Purple charger");  // last used here
  assert.equal(r.promptText, "Is this Purple charger or Samsung charger?");
  // Only one passes (Samsung PF 0.62 vs 0.30): both still offered, "Which charger is this?".
  const one = run({ avg_power_w: 3, avg_pf: 0.36 }, [samsung, purple]);
  assert.equal(one.status, "AMBIGUOUS");
  assert.equal(one.chargerChoice, true);
  assert.equal(one.promptText, "Which charger is this: Purple charger or Samsung charger?");
  assert.equal(r.registerAs, null);
});

test("a charger reading a little outside the PF range is that charger, not a new appliance", () => {
  const purple = charger("Purple charger", 10, 0.5);
  const nearlyFull = { avg_power_w: 2.5, avg_pf: 0.3 };  // PF 0.20 away (> 0.15)
  assert.equal(recognize({ features: nearlyFull, stage: 1, here: A, appliances: [purple], config: C }).status, "UNKNOWN");
  const r = run(nearlyFull, [purple]);
  assert.equal(r.status, "MATCHED_PROVISIONAL");
  assert.equal(r.chargerChoice, true);
  assert.equal(r.match?.appliance.id, "Purple charger");
});

test("not a charger's reading: unchanged (a fan, or far from any charger)", () => {
  const purple = charger("Purple charger", 10, 0.5);
  // The fan is still the fan, confirmed at Stage 2 as before.
  const f = run({ avg_power_w: 57.1, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 4 }, [fan(), purple]);
  assert.equal(f.match?.appliance.id, "Fan");
  assert.notEqual(f.chargerChoice, true);
  // PF 0.92 is far from the charger's 0.50: a new appliance, as before.
  const r = run({ avg_power_w: 12, avg_pf: 0.92 }, [purple]);
  assert.equal(r.status, "UNKNOWN");
  // Above any charger: a new appliance, as before.
  assert.equal(run({ avg_power_w: 300, avg_pf: 0.5 }, [purple]).status, "UNKNOWN");
  // No chargers registered: exactly recognize().
  const none = run({ avg_power_w: 12, avg_pf: 0.5 }, [fan()]);
  assert.equal(none.status, "UNKNOWN");
});

test("a charger running on the other outlet is not offered", () => {
  const purple = charger("Purple charger", 10, 0.5, { activeOn: B });
  const samsung = charger("Samsung charger", 12, 0.52);
  const r = run({ avg_power_w: 10, avg_pf: 0.5 }, [purple, samsung]);
  assert.deepEqual(r.candidates.map((k) => k.applianceId), ["Samsung charger"]);
  assert.equal(r.chargerChoice, true);
});

test("charger_no_register off: the previous prompts", () => {
  const purple = charger("Purple charger", 10, 0.5);
  const off = configFromRow({ ...CONFIG_ROW, charger_no_register: false });
  assert.equal(off.chargerNoRegister, false);
  const r = run({ avg_power_w: 2.5, avg_pf: 0.3 }, [purple], { config: off });
  assert.equal(r.status, "UNKNOWN");
  assert.equal(r.chargerChoice, undefined);
  assert.equal(C.chargerNoRegister, true);
  assert.equal(C.chargerNearPf, 0.25);
});

// User test with the live settings (after the pending migrations): floor_pf
// 0.05, floor_pf_charger 0.15, charger_max_power_w 140, both outlets.
test("user journey: a phone charger with different phones, both outlets, never 'register new'", () => {
  const LIVE = configFromRow({ ...CONFIG_ROW, floor_pf: "0.0500", floor_pf_charger: "0.15", charger_max_power_w: "140" });
  const purple = charger("Purple charger", 10, 0.5);
  const fanA = fan();
  const phones = [
    { avg_power_w: 10, avg_pf: 0.5 },    // the phone it was registered with
    { avg_power_w: 18, avg_pf: 0.6 },    // a fast-charging phone
    { avg_power_w: 4, avg_pf: 0.4 },     // nearly full
    { avg_power_w: 2.5, avg_pf: 0.3 },   // almost done (PF 0.20 away)
    { avg_power_w: 25, avg_pf: 0.68 },   // a tablet
  ];
  for (const here of [A, B]) {
    for (const reading of phones) {
      for (const stage of [1, 2] as const) {
        const r = recognizeWithChargers({ features: reading, stage, here, appliances: [purple, fanA], config: LIVE });
        assert.notEqual(r.status, "UNKNOWN", `${JSON.stringify(reading)} on ${here.outlet} stage ${stage}`);
        assert.notEqual(r.status, "SAME_TYPE_IN_USE");
        assert.notEqual(r.status, "MATCHED_CONFIRMED");  // only the user confirms a charger
        assert.equal(r.chargerChoice, true);
        assert.equal(r.cutoffS, LIVE.defaultCutoffS);    // safe default until confirmed
        assert.ok(r.candidates.every((k) => k.charger));  // the fan is never offered
      }
    }
  }
  // The fan on the other outlet is still the fan, confirmed at Stage 2.
  const f = recognizeWithChargers({
    features: { avg_power_w: 57.1, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 4, power_variation: 0.022 },
    stage: 2, here: B, appliances: [purple, fanA], previousApplianceId: "Fan", config: LIVE,
  });
  assert.equal(f.status, "MATCHED_CONFIRMED");
  assert.equal(f.match?.appliance.id, "Fan");
  // Something that is not a charger (a 1000 W iron, PF 1.0): still "new".
  const iron = recognizeWithChargers({ features: { avg_power_w: 1000, avg_pf: 1 }, stage: 1, here: A,
    appliances: [purple, fanA], config: LIVE });
  assert.equal(iron.status, "UNKNOWN");
});
