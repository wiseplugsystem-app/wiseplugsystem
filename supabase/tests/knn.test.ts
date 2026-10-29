// Run with: node --test supabase/tests/knn.test.ts   (Node 22.6+ runs TypeScript)
// One test per scenario of the identification test plan
// (docs/appliance-identification.md, section 6).
import assert from "node:assert/strict";
import test from "node:test";
import {
  CONSERVATIVE_CUTOFF_S,
  DEFAULT_T1,
  type FeatureVector,
  identify,
  type Instance,
  modeFor,
  modeStats,
  nextInstanceName,
  parseFeatures,
  thresholds,
} from "../functions/_shared/knn.ts";

// Deterministic noise, so every run of the suite gives the same numbers.
function rng(seed: number) {
  return () => {
    seed = (seed * 1664525 + 1013904223) % 2 ** 32;
    return seed / 2 ** 32;
  };
}
const gauss = (r: () => number) => Math.sqrt(-2 * Math.log(r() || 1e-9)) * Math.cos(2 * Math.PI * r());

/** One steady-state window of an appliance drawing [power] W at [pf], with [noise] relative spread. */
function reading(r: () => number, power: number, pf: number, noise = 0.01, cv = 0.01, peakRatio = 1.3): FeatureVector {
  const p = power * (1 + noise * gauss(r));
  const f = Math.min(1, Math.max(0.01, pf + 0.005 * gauss(r)));
  const v = 230 * (1 + 0.005 * gauss(r));
  const current = p / (v * f);
  const s = v * current;
  return {
    power: p, current, pf: f, reactive: Math.sqrt(Math.max(s * s - p * p, 0)),
    cv: Math.max(0, cv + 0.002 * gauss(r)), peakRatio: peakRatio * (1 + 0.05 * gauss(r)),
  };
}

function instance(
  id: string, typeName: string, power: number, pf: number,
  opts: Partial<Instance> & { n?: number; seed?: number; mode?: number } = {},
): Instance {
  const r = rng(opts.seed ?? id.length * 97);
  return {
    id, name: opts.name ?? id, typeId: `type-${typeName}`, typeName,
    cutoffS: opts.cutoffS ?? 4 * 3600, lastOutlet: opts.lastOutlet ?? null, activeOn: opts.activeOn ?? null,
    samples: Array.from({ length: opts.n ?? 10 }, () => ({ mode: opts.mode ?? 0, features: reading(r, power, pf) })),
  };
}

const FAN = { power: 57, pf: 0.92 };

test("1. Fan running on outlet_1: a similar load on outlet_2 is NOT labelled Fan", () => {
  const fan = instance("fan-1", "Fan", FAN.power, FAN.pf, { name: "Fan", activeOn: "outlet_1", lastOutlet: "outlet_1" });
  const y = reading(rng(7), FAN.power, FAN.pf);
  const result = identify(y, "outlet_2", [fan]);
  assert.equal(result.outcome, "UNKNOWN");
  assert.equal(result.match, null);
  assert.deepEqual(result.registerAs, { typeId: "type-Fan", typeName: "Fan", resembles: "Fan" });
  assert.equal(result.cutoffS, CONSERVATIVE_CUTOFF_S, "unconfirmed load uses the conservative cutoff");
  // Control: the same reading on the Fan's own outlet, Fan idle, is the Fan.
  assert.equal(identify(y, "outlet_1", [{ ...fan, activeOn: null }]).outcome, "CONFIDENT");
});

test("2. Same wattage, different power factor: told apart", () => {
  const fan = instance("fan", "Fan", 57, 0.92);
  const charger = instance("charger", "Laptop charger", 57, 0.55, { cutoffS: 3 * 3600 });
  const r = rng(11);
  const asFan = identify(reading(r, 57, 0.92), "outlet_1", [fan, charger]);
  const asCharger = identify(reading(r, 57, 0.55), "outlet_1", [fan, charger]);
  assert.equal(asFan.match?.instance.id, "fan");
  assert.equal(asCharger.match?.instance.id, "charger");
  assert.equal(asCharger.cutoffS, 3 * 3600);
  // With only the fan registered, the charger is unknown, never "Fan".
  assert.equal(identify(reading(r, 57, 0.55), "outlet_1", [fan]).outcome, "UNKNOWN");
});

test("3a. Two identical fans, both idle: AMBIGUOUS, outlet context pre-selects", () => {
  const fan1 = instance("fan-1", "Fan", 57, 0.92, { seed: 1, lastOutlet: "outlet_1" });
  const fan2 = instance("fan-2", "Fan", 57, 0.92, { seed: 2, lastOutlet: "outlet_2" });
  const result = identify(reading(rng(5), 57, 0.92), "outlet_2", [fan1, fan2]);
  assert.equal(result.outcome, "AMBIGUOUS");
  assert.equal(result.suggested?.instance.id, "fan-2", "last seen on outlet_2");
  assert.equal(result.cutoffS, CONSERVATIVE_CUTOFF_S);
  assert.match(result.reason, /electrically identical/);
});

test("3b. Two identical fans, Fan 1 running on outlet_1: outlet_2 is Fan 2", () => {
  const fan1 = instance("fan-1", "Fan", 57, 0.92, { seed: 1, activeOn: "outlet_1" });
  const fan2 = instance("fan-2", "Fan", 57, 0.92, { seed: 2, cutoffS: 7200 });
  const result = identify(reading(rng(5), 57, 0.92), "outlet_2", [fan1, fan2]);
  assert.equal(result.outcome, "CONFIDENT");
  assert.equal(result.match?.instance.id, "fan-2");
  assert.equal(result.cutoffS, 7200);
});

test("4. Fan changes mode: speed 3 is learned as a second mode of the same fan", () => {
  const fan = instance("fan", "Fan", 40, 0.9, { mode: 0 });
  const r = rng(13);
  const speed3 = reading(r, 57, 0.93);
  assert.notEqual(identify(speed3, "outlet_1", [fan]).outcome, "CONFIDENT", "an unseen speed is not guessed");
  assert.equal(modeFor(speed3, fan), 1, "the user's confirmation starts mode 1");
  const learned: Instance = {
    ...fan,
    samples: [...fan.samples, ...Array.from({ length: 5 }, () => ({ mode: 1, features: reading(r, 57, 0.93) }))],
  };
  const later = identify(reading(r, 57, 0.93), "outlet_1", [learned]);
  assert.equal(later.outcome, "CONFIDENT");
  assert.equal(later.match?.mode, 1);
  assert.equal(identify(reading(r, 40, 0.9), "outlet_1", [learned]).match?.mode, 0, "speed 1 still recognized");
});

test("5. Sensor noise: genuine runs stay recognized and are never mislabelled", () => {
  const fan = instance("fan", "Fan", 57, 0.92, { n: 20 });
  const kettle = instance("kettle", "Kettle", 1800, 1.0, { n: 20 });
  const charger = instance("charger", "Laptop charger", 57, 0.55, { n: 20 });
  const r = rng(17);
  let confident = 0, wrong = 0;
  for (let i = 0; i < 200; i++) {
    const result = identify(reading(r, 57, 0.92), "outlet_1", [fan, kettle, charger]);
    if (result.outcome === "CONFIDENT") confident++;
    if (result.match && result.match.instance.id !== "fan") wrong++;
  }
  assert.equal(wrong, 0);
  assert.ok(confident >= 180, `recognized ${confident}/200 noisy runs`);
});

test("thresholds calibrate from the instance's own samples and tighten", () => {
  const few = instance("a", "Fan", 57, 0.92, { n: 3 });
  const many = instance("b", "Fan", 57, 0.92, { n: 20 });
  const t = (i: Instance) => thresholds(modeStats(0, i.samples.map((s) => s.features)));
  assert.deepEqual(t(few), { t1: DEFAULT_T1, t2: 3.5 });
  assert.ok(t(many).t1 <= DEFAULT_T1 * 1.5 && t(many).t2 > t(many).t1);
});

test("unconfirmed loads never inherit a candidate's longer cutoff", () => {
  const heater = instance("heater", "Heater", 900, 1.0, { cutoffS: 8 * 3600 });
  const result = identify(reading(rng(3), 1000, 0.99, 0.01), "outlet_1", [heater]);
  assert.notEqual(result.outcome, "CONFIDENT");
  assert.equal(result.cutoffS, CONSERVATIVE_CUTOFF_S);
});

test("tiny loads ignore PF, which the meter cannot measure", () => {
  const charger = instance("phone", "Phone charger", 3, 0.5);
  const r = rng(19);
  const result = identify({ ...reading(r, 3, 0.5), pf: 0.95, reactive: 0 }, "outlet_1", [charger]);
  assert.notEqual(result.outcome, "UNKNOWN");
});

test("helpers", () => {
  assert.equal(nextInstanceName("Fan", ["Fan 1", "fan 2"]), "Fan 3");
  assert.equal(nextInstanceName("Fan", ["Fan 2"]), "Fan 1");
  assert.equal(typeof parseFeatures({ power: 57 }), "string");
  assert.deepEqual(parseFeatures({ power: 57, current: 0.27, pf: 0.92 }), {
    power: 57, current: 0.27, pf: 0.92, reactive: null, cv: null, peakRatio: null,
  });
});
