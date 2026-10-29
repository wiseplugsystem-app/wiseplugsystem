// Open-set appliance identification with k-nearest neighbours.
// Pure logic (no Deno APIs): runs in Edge Functions and in `node --test`.
//
// Model: an appliance TYPE ("Fan") has INSTANCES ("Fan 1", "Fan 2"). Each
// instance keeps up to 20 signature samples per MODE (fan speed 1, speed 3),
// one sample per confirmed use. A sample summarises the steady part of a run:
//   power P, current I, power factor PF, reactive power Q = sqrt(S^2 - P^2)
//   with S = V x I, the coefficient of variation of P (how steady the load
//   is) and the start-up peak ratio (highest P in the first seconds / P).
//
// Distance: each feature is z-scored with the candidate mode's own mean and
// standard deviation, so a 2 W difference is large for a phone charger and
// small for a kettle. The distance to an instance is the mean of its k nearest
// samples (k-NN), taken over its closest mode.
//
// Three outcomes (open set): CONFIDENT (distance <= T1), AMBIGUOUS (T1..T2, or
// two candidates nearly tied) and UNKNOWN (> T2). Instances running on another
// outlet are excluded: one physical appliance cannot be in two sockets.

export const FEATURES = ["power", "current", "pf", "reactive", "cv", "peakRatio"] as const;
export type Feature = (typeof FEATURES)[number];
export type FeatureVector = { power: number; current: number } & Partial<Record<Feature, number | null>>;

/**
 * Feature weights. P, I and PF are measured directly and are the most
 * reliable at 1 reading per second. Q is derived (noisy when PF is near 1),
 * the variation needs a full window, and the start-up peak is only
 * approximate because a 1 s meter averages away most of the inrush.
 */
export const WEIGHTS: Record<Feature, number> = {
  power: 1, current: 1, pf: 1, reactive: 0.5, cv: 0.5, peakRatio: 0.25,
};

/**
 * Smallest standard deviation per feature: PZEM-004T resolution and accuracy
 * (0.1 W, 0.001 A, 0.01 PF, about 0.5 %) plus normal run-to-run drift. A floor
 * stops an instance with near-identical samples from rejecting itself.
 */
export const SIGMA_FLOOR: Record<Feature, (mean: number) => number> = {
  power: (m) => Math.max(0.5, Math.abs(m) * 0.02),
  current: (m) => Math.max(0.005, Math.abs(m) * 0.02),
  pf: () => 0.02,
  reactive: (m) => Math.max(2, Math.abs(m) * 0.05),
  cv: () => 0.01,
  peakRatio: () => 0.1,
};

/** Below this power the meter's PF (and so Q) is unreliable: they are ignored. */
export const MIN_PF_POWER_W = 5;

/**
 * Default thresholds in standard-deviation units, used until an instance has
 * enough samples to calibrate its own. For Gaussian features the weighted RMS
 * z-score of a genuine reading stays below about 2 for ~95 % of runs.
 */
export const DEFAULT_T1 = 2.0;
export const DEFAULT_T2 = 3.5;
/** Samples a mode needs before its thresholds come from its own data. */
export const CALIBRATE_AFTER = 5;
export const K = 3;
/** Two candidates closer than this (in distance units) are "nearly tied". */
export const TIE_MARGIN = 0.5;
/** Conservative cutoff for UNKNOWN / AMBIGUOUS loads (firmware DEFAULT_LIMIT_S). */
export const CONSERVATIVE_CUTOFF_S = 30 * 60;
export const MAX_SAMPLES_PER_MODE = 20;

export interface Sample {
  mode: number;
  features: FeatureVector;
  /** signature_samples.id, when loaded from the database. */
  id?: number;
  /** First seconds of the run, for the CNN embedding (_shared/embedder.ts). */
  signal?: { power: number[]; current: number[]; pf: number[] } | null;
  /** Embedding of [signal] by the deployed model, when computed. */
  embedding?: number[] | null;
}

export interface Instance {
  id: string;
  name: string;
  typeId: string;
  typeName: string;
  cutoffS: number;
  /** Outlet it last ran on, or null. */
  lastOutlet: string | null;
  /** Outlet it is running on right now, or null. */
  activeOn: string | null;
  samples: Sample[];
}

interface ModeStats {
  mode: number;
  samples: FeatureVector[];
  mean: Partial<Record<Feature, number>>;
  sigma: Partial<Record<Feature, number>>;
}

const has = (v: number | null | undefined): v is number => typeof v === "number" && Number.isFinite(v);

/** Drops PF and Q of tiny loads, where the meter cannot measure them. */
export function clean(x: FeatureVector): FeatureVector {
  if (x.power >= MIN_PF_POWER_W) return x;
  return { ...x, pf: null, reactive: null };
}

/** Mean and standard deviation of each feature of one mode. */
export function modeStats(mode: number, samples: FeatureVector[]): ModeStats {
  const mean: ModeStats["mean"] = {}, sigma: ModeStats["sigma"] = {};
  for (const f of FEATURES) {
    const values = samples.map((s) => s[f]).filter(has);
    if (!values.length) continue;
    const m = values.reduce((a, b) => a + b, 0) / values.length;
    const variance = values.length > 1
      ? values.reduce((a, v) => a + (v - m) ** 2, 0) / (values.length - 1)
      : 0;
    const floor = SIGMA_FLOOR[f](m);
    // sqrt(1 + 1/n): a NEW reading varies more than the mean of n readings
    // (prediction interval), so a mode with few samples is judged leniently.
    mean[f] = m;
    sigma[f] = Math.sqrt(variance + floor * floor) * Math.sqrt(1 + 1 / values.length);
  }
  return { mode, samples, mean, sigma };
}

/** Weighted RMS z-distance between a reading and one sample, using [s]'s sigmas. */
export function zDistance(x: FeatureVector, y: FeatureVector, s: ModeStats): number {
  let sum = 0, weight = 0;
  for (const f of FEATURES) {
    const a = x[f], b = y[f], sd = s.sigma[f];
    if (!has(a) || !has(b) || !has(sd)) continue;
    sum += WEIGHTS[f] * ((a - b) / sd) ** 2;
    weight += WEIGHTS[f];
  }
  return weight ? Math.sqrt(sum / weight) : Infinity;
}

/** k-NN distance: mean of the k smallest distances to the mode's samples. */
export function knnDistance(x: FeatureVector, s: ModeStats, k = K): number {
  const d = s.samples.map((y) => zDistance(x, y, s)).sort((a, b) => a - b);
  const n = Math.min(k, d.length);
  return n ? d.slice(0, n).reduce((a, b) => a + b, 0) / n : Infinity;
}

function percentile(values: number[], p: number): number {
  const v = [...values].sort((a, b) => a - b);
  const i = Math.min(v.length - 1, Math.max(0, Math.ceil(p * v.length) - 1));
  return v[i];
}

/**
 * T1 / T2 of one mode. With fewer than CALIBRATE_AFTER samples: the defaults.
 * Then leave-one-out: each sample is matched against the others, and T1 is the
 * 95th percentile of those genuine distances (T2 = 1.75 x T1). As samples
 * accumulate the sigmas shrink towards the real spread, so both tighten.
 */
export function thresholds(s: ModeStats): { t1: number; t2: number } {
  if (s.samples.length < CALIBRATE_AFTER) return { t1: DEFAULT_T1, t2: DEFAULT_T2 };
  const loo = s.samples.map((x, i) => {
    const rest = modeStats(s.mode, s.samples.filter((_, j) => j !== i));
    return knnDistance(x, rest);
  });
  const t1 = Math.min(Math.max(percentile(loo, 0.95), 1.0), DEFAULT_T1 * 1.5);
  return { t1, t2: Math.max(t1 * 1.75, t1 + 1) };
}

export interface Scored {
  instance: Instance;
  mode: number;
  distance: number;
  t1: number;
  t2: number;
}

/** Distance from [x] to every instance (its closest mode), nearest first. */
export function rank(x: FeatureVector, instances: Instance[]): Scored[] {
  const q = clean(x);
  const scored: Scored[] = [];
  for (const instance of instances) {
    const modes = new Map<number, FeatureVector[]>();
    for (const s of instance.samples) modes.set(s.mode, [...(modes.get(s.mode) ?? []), clean(s.features)]);
    let best: Scored | null = null;
    for (const [mode, samples] of modes) {
      const stats = modeStats(mode, samples);
      const distance = knnDistance(q, stats);
      if (!best || distance < best.distance) best = { instance, mode, distance, ...thresholds(stats) };
    }
    if (best) scored.push(best);
  }
  return scored.sort((a, b) => a.distance - b.distance);
}

export type Outcome = "CONFIDENT" | "AMBIGUOUS" | "UNKNOWN";

export interface Identification {
  outcome: Outcome;
  /** Set only for CONFIDENT. */
  match: Scored | null;
  /** Up to 3 eligible candidates within their T2, nearest first. */
  candidates: Scored[];
  /** Pre-selected candidate for AMBIGUOUS (outlet context), else null. */
  suggested: Scored | null;
  /** "Register as Fan 2?": the load looks like a type that is busy elsewhere. */
  registerAs: { typeId: string; typeName: string; resembles: string } | null;
  /** Cutoff the plug must use until the user confirms. */
  cutoffS: number;
  reason: string;
}

/**
 * Identifies the load that just started on [outlet].
 * Never returns an instance that is active on another outlet, and never gives
 * an unconfirmed load (AMBIGUOUS / UNKNOWN) another appliance's cutoff.
 */
export function identify(x: FeatureVector, outlet: string, instances: Instance[]): Identification {
  return decide(rank(x, instances), outlet, TIE_MARGIN);
}

/**
 * The open-set decision on a ranking (nearest first), shared by the feature
 * k-NN above and the CNN embedding (_shared/embedder.ts). [tieMargin] is in
 * the ranking's distance units.
 */
export function decide(all: Scored[], outlet: string, tieMargin: number): Identification {
  const busy = (s: Scored) => s.instance.activeOn != null && s.instance.activeOn !== outlet;
  const eligible = all.filter((s) => !busy(s));
  const candidates = eligible.filter((s) => s.distance <= s.t2).slice(0, 3);
  // The load resembles an appliance that is running elsewhere: same type, new unit.
  const twin = all.find((s) => busy(s) && s.distance <= s.t2);
  const registerAs = twin
    ? { typeId: twin.instance.typeId, typeName: twin.instance.typeName, resembles: twin.instance.name }
    : null;
  const unconfirmed = (outcome: Outcome, reason: string, suggested: Scored | null = null): Identification => ({
    outcome, match: null, candidates, suggested, registerAs, cutoffS: CONSERVATIVE_CUTOFF_S, reason,
  });

  const [first, second] = eligible;
  if (!first || first.distance > first.t2) {
    return unconfirmed("UNKNOWN", twin
      ? `Looks like ${twin.instance.name}, which is running on the other outlet: a different unit.`
      : "No registered appliance is close to this load.");
  }
  if (first.distance > first.t1) {
    return unconfirmed("AMBIGUOUS", `Closest is ${first.instance.name}, but not close enough to be sure.`, first);
  }
  const tied = eligible.filter((s) => s.distance <= s.t1 && s.distance - first.distance < tieMargin);
  if (tied.length > 1) {
    // Identical units cannot be told apart by their signature. Outlet context
    // only pre-selects one; the user still confirms.
    const here = tied.filter((s) => s.instance.lastOutlet === outlet);
    const sameType = tied.every((s) => s.instance.typeId === first.instance.typeId);
    return unconfirmed(
      "AMBIGUOUS",
      sameType
        ? `Matches ${tied.length} ${first.instance.typeName} units equally; they are electrically identical.`
        : `${first.instance.name} and ${second.instance.name} are nearly tied.`,
      here.length === 1 ? here[0] : first,
    );
  }
  return {
    outcome: "CONFIDENT",
    match: first,
    candidates,
    suggested: null,
    registerAs,
    cutoffS: first.instance.cutoffS,
    reason: `${first.instance.name} (distance ${first.distance.toFixed(2)} <= ${first.t1.toFixed(2)}).`,
  };
}

/**
 * Mode a confirmed sample belongs to: the instance's closest mode when the
 * reading lies within that mode's T2, otherwise a new mode (e.g. a fan speed
 * not seen before). Returns null when the instance already has 8 modes.
 */
export function modeFor(x: FeatureVector, instance: Instance): number | null {
  return modeFrom(rank(x, [instance])[0], instance);
}

/** modeFor on a ranking of [instance] alone (feature or embedding distance). */
export function modeFrom(best: Scored | undefined, instance: Instance): number | null {
  if (best && best.distance <= best.t2) return best.mode;
  const used = new Set(instance.samples.map((s) => s.mode));
  for (let m = 0; m < 8; m++) if (!used.has(m)) return m;
  return null;
}

/** "Fan 3" when "Fan 1" and "Fan 2" exist (fills gaps, case-insensitive). */
export function nextInstanceName(typeName: string, existing: string[]): string {
  const taken = new Set(existing.map((n) => n.trim().toLowerCase()));
  for (let i = 1; ; i++) {
    const name = `${typeName} ${i}`;
    if (!taken.has(name.toLowerCase())) return name;
  }
}

/** Validates the features in a request body; returns an error string. */
export function parseFeatures(v: unknown): FeatureVector | string {
  if (!v || typeof v !== "object") return "features must be an object";
  const f = v as Record<string, unknown>;
  const num = (k: string, lo: number, hi: number, required = false): number | null | string => {
    const x = f[k];
    if (x == null) return required ? `features.${k} is required` : null;
    if (typeof x !== "number" || !Number.isFinite(x) || x < lo || x > hi) return `features.${k} must be ${lo}..${hi}`;
    return x;
  };
  const out: Record<string, number | null> = {};
  for (const [k, lo, hi, req] of [
    ["power", 0, 5000, true], ["current", 0, 100, true], ["pf", 0, 1, false],
    ["reactive", 0, 10000, false], ["cv", 0, 10, false], ["peakRatio", 0, 50, false],
  ] as const) {
    const r = num(k, lo, hi, req);
    if (typeof r === "string") return r;
    out[k] = r;
  }
  return out as FeatureVector;
}
