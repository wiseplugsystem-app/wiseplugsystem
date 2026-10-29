// Appliance signature embedding: a small multiple-parallel-structure 1D CNN
// (MPS-CNN, after Matindife, Sun & Wang 2020) run in plain TypeScript, so an
// Edge Function needs no TensorFlow. Pure logic: runs in Deno and `node --test`.
//
// Input: the first 32 readings (1 per second) after switch-on, three channels
// P (W), I_rms (A), PF. Each channel has its own branch:
//   Conv1D(8, k=5, ReLU) -> AvgPool(2) -> Conv1D(16, k=3, ReLU) -> AvgPool(2)
//   -> [global average, global max]                         (32 values)
// The three branches are concatenated (96) -> Dense(32, ReLU) -> Dense(16)
// -> unit length. Appliances that look alike end up close together; the
// open-set matching (_shared/knn.ts decide) works on these vectors.
//
// The weights come from the Colab notebook (training/wiseplug_embedding.ipynb),
// trained with a triplet loss, and must give the same numbers as Keras: the
// export includes parity vectors that tests/embedder.test.ts checks.
import type { Instance, Scored } from "./knn.ts";
import { K } from "./knn.ts";

export interface Signal { power: number[]; current: number[]; pf: number[] }
/** Keras Conv1D weights: kernel[k][in][out]. */
export interface Conv { kernel: number[][][]; bias: number[] }
/** Keras Dense weights: kernel[in][out]. */
export interface Dense { kernel: number[][]; bias: number[] }
export const CHANNELS = ["power", "current", "pf"] as const;

export interface EmbedderModel {
  version: string;
  architecture: "mps-cnn-v1";
  windowLength: number;
  /** Fixed scaling (not fitted to the data), identical in the notebook. */
  norm: { powerMaxW: number; currentRefA: number; currentMaxA: number; minPfPowerW: number };
  /** Set from validation data in the notebook (embedding distance units, 0..2). */
  thresholds: { t1: number; t2: number; tieMargin: number };
  branches: Record<(typeof CHANNELS)[number], { conv1: Conv; conv2: Conv }>;
  fc1: Dense;
  embedding: Dense;
  parity?: { inputs: Signal[]; outputs: number[][] };
}

/** Fewer readings than this (meter dropouts): no embedding, features are used. */
export const MIN_SIGNAL = 24;
export const MAX_SIGNAL = 64;

/** Returns the model, or null for the placeholder shipped before training. */
export function parseModel(raw: unknown): EmbedderModel | null {
  const m = raw as Partial<EmbedderModel> | null;
  if (!m || typeof m.version !== "string" || m.architecture !== "mps-cnn-v1") return null;
  if (!m.branches || !m.fc1 || !m.embedding || !m.norm || !m.thresholds || !m.windowLength) {
    throw new Error("embedder.json is incomplete: export it again from the notebook");
  }
  return m as EmbedderModel;
}

/** Validates a request's signal; null when absent, a string on error. */
export function parseSignal(v: unknown): Signal | null | string {
  if (v == null) return null;
  if (typeof v !== "object") return "signal must be an object";
  const s = v as Record<string, unknown>;
  const limits = { power: 25000, current: 100, pf: 1 };
  let n = -1;
  for (const c of CHANNELS) {
    const a = s[c];
    if (!Array.isArray(a) || a.length < MIN_SIGNAL || a.length > MAX_SIGNAL) {
      return `signal.${c} must be an array of ${MIN_SIGNAL}-${MAX_SIGNAL} readings`;
    }
    if (n >= 0 && a.length !== n) return "signal channels must have the same length";
    n = a.length;
    if (!a.every((x) => typeof x === "number" && Number.isFinite(x) && x >= 0 && x <= limits[c])) {
      return `signal.${c} values must be 0..${limits[c]}`;
    }
  }
  return { power: s.power as number[], current: s.current as number[], pf: s.pf as number[] };
}

/**
 * Model input, [time][channel]: the first windowLength readings (a short
 * signal is padded with its last reading), each channel scaled to about 0..1:
 *   P  -> ln(1 + P) / ln(1 + powerMaxW)                     (5 W and 2 kW both fit)
 *   I  -> ln(1 + I / currentRefA) / ln(1 + currentMaxA / currentRefA)
 *   PF -> PF, or 0 below minPfPowerW where the meter cannot measure it
 */
export function preprocess(s: Signal, m: EmbedderModel): number[][] {
  const { powerMaxW, currentRefA, currentMaxA, minPfPowerW } = m.norm;
  const out: number[][] = [];
  for (let t = 0; t < m.windowLength; t++) {
    const j = Math.min(t, s.power.length - 1);
    const p = s.power[j], i = s.current[j], pf = s.pf[j];
    out.push([
      Math.log1p(p) / Math.log1p(powerMaxW),
      Math.log1p(i / currentRefA) / Math.log1p(currentMaxA / currentRefA),
      p >= minPfPowerW ? Math.min(Math.max(pf, 0), 1) : 0,
    ]);
  }
  return out;
}

const relu = (v: number) => (v > 0 ? v : 0);

/** Keras Conv1D, stride 1, padding "same" (odd kernel), ReLU. x[time][in]. */
export function conv1d(x: number[][], c: Conv): number[][] {
  const k = c.kernel.length, pad = (k - 1) / 2, outN = c.bias.length;
  return x.map((_, t) => {
    const y = [...c.bias];
    for (let j = 0; j < k; j++) {
      const row = x[t + j - pad];
      if (!row) continue;  // zero padding
      for (let a = 0; a < row.length; a++) {
        const w = c.kernel[j][a], v = row[a];
        for (let o = 0; o < outN; o++) y[o] += v * w[o];
      }
    }
    return y.map(relu);
  });
}

/** Keras AveragePooling1D(2), padding "valid". */
export function avgPool2(x: number[][]): number[][] {
  const out: number[][] = [];
  for (let t = 0; t + 1 < x.length; t += 2) out.push(x[t].map((v, i) => (v + x[t + 1][i]) / 2));
  return out;
}

export function dense(v: number[], d: Dense, activation: "relu" | "linear"): number[] {
  const y = [...d.bias];
  for (let a = 0; a < v.length; a++) for (let o = 0; o < y.length; o++) y[o] += v[a] * d.kernel[a][o];
  return activation === "relu" ? y.map(relu) : y;
}

export function unitLength(v: number[]): number[] {
  const n = Math.sqrt(v.reduce((a, b) => a + b * b, 0));
  return n > 1e-12 ? v.map((x) => x / n) : v.map(() => 0);
}

/** The 16-number signature of one run (unit length). */
export function embed(m: EmbedderModel, s: Signal): number[] {
  const x = preprocess(s, m);
  const merged: number[] = [];
  CHANNELS.forEach((c, ci) => {
    const b = m.branches[c];
    const h = avgPool2(conv1d(avgPool2(conv1d(x.map((r) => [r[ci]]), b.conv1)), b.conv2));
    const width = h[0].length;
    const mean = Array.from({ length: width }, (_, i) => h.reduce((a, r) => a + r[i], 0) / h.length);
    const max = Array.from({ length: width }, (_, i) => Math.max(...h.map((r) => r[i])));
    merged.push(...mean, ...max);
  });
  return unitLength(dense(dense(merged, m.fc1, "relu"), m.embedding, "linear"));
}

/** Euclidean distance of two unit vectors: 0 identical .. 2 opposite. */
export function embeddingDistance(a: number[], b: number[]): number {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += (a[i] - b[i]) ** 2;
  return Math.sqrt(s);
}

/**
 * Like knn.ts rank, in embedding space: an instance's distance is the mean of
 * its k = 3 nearest sample embeddings, in its closest mode. T1 / T2 are the
 * model's validation thresholds. Samples without an embedding are skipped.
 */
export function rankEmbedding(q: number[], instances: Instance[], m: EmbedderModel): Scored[] {
  const scored: Scored[] = [];
  for (const instance of instances) {
    const modes = new Map<number, number[]>();
    for (const s of instance.samples) {
      if (!s.embedding) continue;
      modes.set(s.mode, [...(modes.get(s.mode) ?? []), embeddingDistance(q, s.embedding)]);
    }
    let best: Scored | null = null;
    for (const [mode, d] of modes) {
      d.sort((a, b) => a - b);
      const n = Math.min(K, d.length);
      const distance = d.slice(0, n).reduce((a, b) => a + b, 0) / n;
      if (!best || distance < best.distance) best = { instance, mode, distance, t1: m.thresholds.t1, t2: m.thresholds.t2 };
    }
    if (best) scored.push(best);
  }
  return scored.sort((a, b) => a.distance - b.distance);
}

/**
 * The embedding is used only when every instance can be compared that way
 * (each has at least one recorded signal). Otherwise the whole device stays on
 * the feature k-NN, so the two kinds of distance are never mixed in one ranking.
 */
export function canUseEmbedding(instances: Instance[]): boolean {
  return instances.every((i) => i.samples.some((s) => s.signal));
}
