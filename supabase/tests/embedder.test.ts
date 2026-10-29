// Run with: node --test supabase/tests/embedder.test.ts
// The TypeScript CNN runtime (_shared/embedder.ts) and open-set matching on
// embeddings. Once a trained embedder.json is deployed, the parity test checks
// it reproduces the Keras outputs exported by the notebook.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import {
  avgPool2,
  canUseEmbedding,
  conv1d,
  dense,
  embed,
  type EmbedderModel,
  embeddingDistance,
  parseModel,
  parseSignal,
  preprocess,
  rankEmbedding,
  type Signal,
} from "../functions/_shared/embedder.ts";
import { CONSERVATIVE_CUTOFF_S, decide, type Instance } from "../functions/_shared/knn.ts";

function rng(seed: number) {
  return () => {
    seed = (seed * 1664525 + 1013904223) % 2 ** 32;
    return seed / 2 ** 32 - 0.5;
  };
}
const conv = (r: () => number, k: number, inN: number, outN: number) => ({
  kernel: Array.from({ length: k }, () => Array.from({ length: inN }, () => Array.from({ length: outN }, r))),
  bias: Array.from({ length: outN }, () => r() * 0.1),
});
const denseW = (r: () => number, inN: number, outN: number) => ({
  kernel: Array.from({ length: inN }, () => Array.from({ length: outN }, r)),
  bias: Array.from({ length: outN }, () => r() * 0.1),
});

/** A random (untrained) model with the real shapes. */
function randomModel(seed = 1): EmbedderModel {
  const r = rng(seed);
  const branch = () => ({ conv1: conv(r, 5, 1, 8), conv2: conv(r, 3, 8, 16) });
  return {
    version: "test",
    architecture: "mps-cnn-v1",
    windowLength: 32,
    norm: { powerMaxW: 3000, currentRefA: 0.005, currentMaxA: 15, minPfPowerW: 5 },
    thresholds: { t1: 0.3, t2: 0.6, tieMargin: 0.075 },
    branches: { power: branch(), current: branch(), pf: branch() },
    fc1: denseW(r, 96, 32),
    embedding: denseW(r, 32, 16),
  };
}

const steady = (power: number, pf: number, n = 32): Signal => ({
  power: Array(n).fill(power),
  current: Array(n).fill(power / (230 * pf)),
  pf: Array(n).fill(pf),
});

test("conv1d matches Keras 'same' cross-correlation", () => {
  // y[t] = x[t-1]*w0 + x[t]*w1 + x[t+1]*w2, zero outside
  const y = conv1d([[1], [2], [3]], { kernel: [[[1]], [[10]], [[100]]], bias: [0] });
  assert.deepEqual(y, [[210], [321], [32]]);
  // ReLU and bias
  assert.deepEqual(conv1d([[1]], { kernel: [[[-1]]], bias: [0.5] }), [[0]]);
});

test("avgPool2 drops an odd last step, dense is kernel[in][out]", () => {
  assert.deepEqual(avgPool2([[1], [3], [5], [7], [9]]), [[2], [6]]);
  assert.deepEqual(dense([1, 2], { kernel: [[1, 10], [100, 1000]], bias: [0, 1] }, "linear"), [201, 2011]);
  assert.deepEqual(dense([1], { kernel: [[-1]], bias: [0] }, "relu"), [0]);
});

test("preprocess: fixed log scaling, PF ignored below 5 W, short signals padded", () => {
  const m = randomModel();
  const x = preprocess({ power: [3000, 2], current: [15, 0.01], pf: [0.9, 0.5] }, m);
  assert.equal(x.length, 32);
  assert.ok(Math.abs(x[0][0] - 1) < 1e-12 && Math.abs(x[0][1] - 1) < 1e-12);
  assert.equal(x[0][2], 0.9);
  assert.equal(x[1][2], 0);  // 2 W: no PF
  assert.deepEqual(x[31], x[1]);  // padded with the last reading
});

test("embed returns a deterministic unit vector", () => {
  const m = randomModel();
  const e = embed(m, steady(57, 0.92));
  assert.equal(e.length, 16);
  assert.ok(Math.abs(Math.hypot(...e) - 1) < 1e-9);
  assert.deepEqual(embed(m, steady(57, 0.92)), e);
  assert.ok(embeddingDistance(e, embed(m, steady(1800, 1))) > 0);
});

// Instances whose sample embeddings are given directly (as if computed by a trained model).
const unit = (v: number[]) => v.map((x) => x / Math.hypot(...v));
function inst(id: string, typeName: string, centre: number[], opts: Partial<Instance> = {}, n = 5): Instance {
  const r = rng(id.length * 31);
  return {
    id, name: id, typeId: `type-${typeName}`, typeName, cutoffS: 4 * 3600,
    lastOutlet: null, activeOn: null, ...opts,
    samples: Array.from({ length: n }, () => ({
      mode: 0, features: { power: 57, current: 0.27 }, signal: steady(57, 0.9),
      embedding: unit(centre.map((c) => c + r() * 0.05)),
    })),
  };
}
const M = randomModel();
const tie = M.thresholds.tieMargin;
const FAN = [1, 0, 0, 0];

test("embedding: Fan running on outlet_1, a look-alike on outlet_2 is not Fan", () => {
  const fan = inst("Fan 1", "Fan", FAN, { activeOn: "outlet_1" });
  const q = unit([1, 0.02, 0, 0]);
  const r = decide(rankEmbedding(q, [fan], M), "outlet_2", tie);
  assert.equal(r.outcome, "UNKNOWN");
  assert.equal(r.cutoffS, CONSERVATIVE_CUTOFF_S);
  assert.equal(r.registerAs?.typeName, "Fan");
  // Same reading on outlet_1 itself, the Fan being idle: confident.
  const idle = decide(rankEmbedding(q, [{ ...fan, activeOn: null }], M), "outlet_1", tie);
  assert.equal(idle.outcome, "CONFIDENT");
  assert.equal(idle.match?.instance.id, "Fan 1");
});

test("embedding: identical units are AMBIGUOUS, the last-seen outlet is pre-selected", () => {
  const a = inst("Fan 1", "Fan", FAN, { lastOutlet: "outlet_1" });
  const b = inst("Fan 2", "Fan", FAN, { lastOutlet: "outlet_2" });
  const r = decide(rankEmbedding(unit([1, 0.01, 0, 0]), [a, b], M), "outlet_2", tie);
  assert.equal(r.outcome, "AMBIGUOUS");
  assert.equal(r.suggested?.instance.id, "Fan 2");
  // With Fan 1 running next door, exclusivity decides.
  const busy = decide(rankEmbedding(unit([1, 0.01, 0, 0]), [{ ...a, activeOn: "outlet_1" }, b], M), "outlet_2", tie);
  assert.equal(busy.outcome, "CONFIDENT");
  assert.equal(busy.match?.instance.id, "Fan 2");
});

test("embedding: far from every instance is UNKNOWN, in between AMBIGUOUS", () => {
  const fan = inst("Fan 1", "Fan", FAN);
  assert.equal(decide(rankEmbedding(unit([0, 1, 0, 0]), [fan], M), "outlet_1", tie).outcome, "UNKNOWN");
  // ~0.45 from the fan: between T1 = 0.3 and T2 = 0.6
  const mid = decide(rankEmbedding(unit([1, 0.47, 0, 0]), [fan], M), "outlet_1", tie);
  assert.equal(mid.outcome, "AMBIGUOUS");
  assert.equal(mid.cutoffS, CONSERVATIVE_CUTOFF_S);
});

test("embedding is used only when every instance has a recorded signal", () => {
  const fan = inst("Fan 1", "Fan", FAN);
  const migrated: Instance = { ...inst("Lamp", "Lamp", [0, 1, 0, 0]), samples: [{ mode: 0, features: { power: 20, current: 0.1 } }] };
  assert.equal(canUseEmbedding([fan]), true);
  assert.equal(canUseEmbedding([fan, migrated]), false);
  assert.equal(canUseEmbedding([]), true);
});

test("parseSignal validates the plug's upload", () => {
  assert.equal(parseSignal(undefined), null);
  assert.deepEqual(parseSignal(steady(57, 0.9)), steady(57, 0.9));
  assert.match(String(parseSignal({ ...steady(57, 0.9), pf: Array(31).fill(0.9) })), /same length/);
  assert.match(String(parseSignal(steady(57, 0.9, 10))), /24-64/);
  assert.match(String(parseSignal({ ...steady(57, 0.9), pf: Array(32).fill(1.5) })), /0\.\.1/);
});

test("deployed embedder.json: placeholder, or reproduces Keras (parity vectors)", () => {
  const raw = JSON.parse(fs.readFileSync(new URL("../functions/_shared/model/embedder.json", import.meta.url), "utf8"));
  const m = parseModel(raw);
  if (!m) {
    assert.equal(raw.version, null, "an unparseable model must be the placeholder");
    return;
  }
  assert.ok(m.parity && m.parity.inputs.length, "export the model with its parity vectors");
  m.parity.inputs.forEach((input, i) => {
    const got = embed(m, input), want = m.parity!.outputs[i];
    const err = Math.max(...got.map((v, j) => Math.abs(v - want[j])));
    assert.ok(err < 1e-4, `parity vector ${i}: max error ${err}`);
  });
  assert.ok(m.thresholds.t1 > 0 && m.thresholds.t2 >= m.thresholds.t1);
});
