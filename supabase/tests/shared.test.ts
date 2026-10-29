// Run with: node --test supabase/tests/shared.test.ts   (Node 22.6+ runs TypeScript)
import assert from "node:assert/strict";
import test from "node:test";
import { evaluate } from "../functions/_shared/safety.ts";
import {
  boundsFromBaseline,
  matchSignature,
  parseReading,
  passesBounds,
  powerTriangle,
  type Reading,
  score,
  signatureColumns,
  signatureFromRow,
} from "../functions/_shared/signature.ts";

// A profile row as Postgres returns it, including the generated S and Q
// columns (same formulas as the migration). Numerics arrive as strings.
function row(id: string, p: [number, number, number], i: [number, number, number], pf: [number, number, number] | null) {
  const q = (v: number) => Math.sqrt(1 - v * v) / v;
  const r: Record<string, unknown> = {
    id, name: id,
    min_power: String(p[0]), target_power: String(p[1]), max_power: String(p[2]),
    min_current: String(i[0]), target_current: String(i[1]), max_current: String(i[2]),
    min_pf: pf ? String(pf[0]) : null, target_pf: pf ? String(pf[1]) : null, max_pf: pf ? String(pf[2]) : null,
  };
  if (pf) {
    r.min_apparent_power = String(p[0] / pf[2]);
    r.max_apparent_power = pf[0] > 0 ? String(p[2] / pf[0]) : null;
    r.min_reactive_power = String(p[0] * q(pf[2]));
    r.max_reactive_power = pf[0] > 0 ? String(p[2] * q(pf[0])) : null;
  }
  return { id, row: r, signature: signatureFromRow(r) };
}

// Seeded profiles (supabase/seed.sql) plus a learned power tool at light load.
const fan = row("fan", [35, 55, 75], [0.16, 0.25, 0.34], [0.85, 0.95, 1]);
const tv = row("tv", [40, 75, 110], [0.25, 0.475, 0.7], [0.45, 0.6, 0.75]);
const charger = row("charger", [5, 45, 90], [0.04, 0.345, 0.65], [0.3, 0.55, 0.8]);
const drill = row("drill", [44, 52, 60], [0.30, 0.37, 0.44], [0.52, 0.62, 0.72]);
const kettle = row("kettle", [1500, 1750, 2000], [6.5, 7.7, 8.9], [0.95, 1, 1]);
const profiles = [fan, tv, charger, drill, kettle];

const at = (power: number, current: number, powerFactor: number | null, voltage: number | null = 230): Reading =>
  ({ voltage, power, current, powerFactor });

test("power triangle: S = V x I and Q = sqrt(S^2 - P^2)", () => {
  const t = powerTriangle(at(48, 0.25, 0.83));
  assert.ok(Math.abs(t.apparent! - 57.5) < 1e-9);
  assert.ok(Math.abs(t.reactive! - Math.sqrt(57.5 ** 2 - 48 ** 2)) < 1e-9);
  // Without voltage, S comes from P / PF.
  assert.ok(Math.abs(powerTriangle(at(50, 0.25, 0.5, null)).apparent! - 100) < 1e-9);
  // A resistive load has no reactive power, even with rounding.
  assert.equal(powerTriangle(at(600, 2.6, 1, 230)).reactive, 0);
});

test("same wattage, different appliance: the fan is not the power tool", () => {
  // A desk fan and a drill at light load both draw about 52 W.
  const fanReading = at(52, 0.24, 0.94);
  const drillReading = at(52, 0.36, 0.63);
  assert.equal(matchSignature(fanReading, profiles).match?.item.id, "fan");
  assert.equal(matchSignature(drillReading, profiles).match?.item.id, "drill");
  // The drill fails the fan's PF bounds outright (step 1).
  assert.equal(passesBounds(fan.signature, drillReading), false);
});

test("normal run-to-run drift still matches confidently", () => {
  const r = matchSignature(at(56, 0.255, 0.94), profiles);
  assert.equal(r.match?.item.id, "fan");
  assert.ok(r.match!.score.confidence >= 0.88, `confidence ${r.match!.score.confidence}`);
});

test("inside the bounds but far from the target is unrecognized", () => {
  // At the edge of the fan's power, current and PF bands at once.
  const r = matchSignature(at(73, 0.33, 0.87), profiles);
  assert.equal(r.match, null, "below the 88 % cutoff");
  assert.equal(r.best?.item.id, "fan", "it was still the closest candidate");
  assert.ok(r.best!.score.confidence < 0.88);
});

test("nothing inside the bounds is unrecognized", () => {
  const r = matchSignature(at(3000, 13, 1), profiles);
  assert.equal(r.match, null);
  assert.equal(r.best, null);
});

test("weights are 40/30/20/10 and missing quantities are rescaled", () => {
  const exact = score(fan.signature, at(55, 0.25, 0.95, null));
  assert.equal(exact.axes.power, 1);
  assert.equal(exact.axes.current, 1);
  assert.equal(exact.axes.pf, 1);
  // Without PF and voltage there is no PF or Q: only P and I count.
  const noPf = score(fan.signature, at(55, 0.25, null, null));
  assert.equal(noPf.axes.pf, null);
  assert.equal(noPf.axes.reactive, null);
  assert.equal(noPf.confidence, 1);
});

test("a tiny meter-noise overshoot still passes the bounds", () => {
  assert.equal(passesBounds(fan.signature, at(75.4, 0.25, 0.95)), true);
  assert.equal(passesBounds(fan.signature, at(77, 0.25, 0.95)), false);
});

test("bounds from a baseline follow the firmware tolerances", () => {
  const b = boundsFromBaseline(at(100, 0.45, 0.98, null));
  assert.deepEqual(b.power, { min: 85, max: 115, target: 100 });
  assert.ok(Math.abs(b.current.min - 0.36) < 1e-9);
  assert.deepEqual(b.pf, { min: 0.88, max: 1, target: 0.98 });
  // No PF reported: derived from S = V x I.
  assert.ok(Math.abs(boundsFromBaseline(at(115, 1, null, 230)).pf!.target - 0.5) < 1e-9);
  assert.deepEqual(Object.keys(signatureColumns(b)), [
    "min_power", "max_power", "target_power",
    "min_current", "max_current", "target_current",
    "min_pf", "max_pf", "target_pf",
  ]);
});

test("readings are validated", () => {
  assert.equal(typeof parseReading({ power: -1, current: 0 }), "string");
  assert.equal(typeof parseReading({ power: 10, current: 0.1, powerFactor: 1.5 }), "string");
  assert.equal(typeof parseReading({ power: 10, current: 0.1, voltage: 20 }), "string");
  assert.deepEqual(parseReading({ power: 10, current: 0.1 }), { voltage: null, power: 10, current: 0.1, powerFactor: null });
});

const alert = {
  type: "RUNTIME_WARNING" as const,
  outlet: "outlet_2" as const,
  applianceName: "Rice Cooker",
  runtimeS: 3600,
  limitS: 2700,
  baselineS: 1800,
  learned: true,
  sessionCount: 9,
  powerW: 600,
  currentA: 2.6,
};

test("runtime is judged against the learned baseline", () => {
  const e = evaluate(alert);
  assert.equal(e.baselineRatio, 2);
  assert.equal(e.severity, "critical");
  assert.match(e.message, /typical use is 30 min \(learned from 7 uses\)/);
});

test("while learning, only the safety ceiling applies", () => {
  const e = evaluate({ ...alert, learned: false, sessionCount: 3, runtimeS: 14400, limitS: 14400 });
  assert.equal(e.severity, "warning");
  assert.match(e.message, /still learning \(3 of 7 uses\)/);
});

test("electrical trips are critical", () => {
  assert.equal(evaluate({ ...alert, type: "OVERCURRENT", currentA: 10.4 }).severity, "critical");
});
