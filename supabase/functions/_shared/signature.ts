// Multi-parameter appliance signatures and the weighted matching algorithm.
// Pure logic (no Deno APIs): runs in Edge Functions and in `node --test`.
//
// A signature describes one appliance with every PZEM-004T quantity:
//   active power P (W), current I (A), power factor PF, and the derived
//   apparent power S = V x I (VA) and reactive power Q = sqrt(S^2 - P^2) (VAR).
// Two appliances with the same wattage rarely share current, PF and Q too, so
// using all of them separates e.g. a desk fan from a power tool at low load.

/** Weights of the composite score (sum to 1). */
export const WEIGHTS = { power: 0.4, current: 0.3, pf: 0.2, reactive: 0.1 } as const;

/** A match must be at least this confident; below it the device is unrecognized. */
export const DEFAULT_THRESHOLD = 0.88;

// Learning bands, identical to the firmware (POWER_TOLERANCE, CURRENT_TOLERANCE,
// PF_TOLERANCE and band() in wiseplug_esp32.ino), so plug and server agree.
export const POWER_TOLERANCE = 0.15;
export const CURRENT_TOLERANCE = 0.2;
export const PF_TOLERANCE = 0.1;
const MIN_BAND = 0.05;

// Dynamic tolerance offsets for the strict bound check: PZEM-004T accuracy is
// about 0.5 % with 0.1 W / 0.001 A / 0.01 PF resolution, so a reading a hair
// outside a band because of meter noise still counts as inside.
const offsets = {
  power: (target: number) => Math.max(Math.abs(target) * 0.01, 0.5),
  current: (target: number) => Math.max(Math.abs(target) * 0.01, 0.005),
  pf: () => 0.02,
  reactive: (target: number) => Math.max(Math.abs(target) * 0.05, 2),
};

export interface Range {
  min: number;
  max: number;
  target: number;
}

export interface Signature {
  power: Range;
  current: Range;
  pf: Range | null; // null: the profile has no power factor
  apparent: { min: number; max: number | null } | null;
  reactive: { min: number; max: number | null } | null;
}

export interface Reading {
  voltage: number | null;
  power: number;
  current: number;
  powerFactor: number | null;
}

export interface Candidate {
  id: string;
  signature: Signature;
}

export interface Score {
  /** 0..1 composite similarity; 1 = every quantity exactly on target. */
  confidence: number;
  /** Per-quantity similarity (null when that quantity is unavailable). */
  axes: { power: number; current: number; pf: number | null; reactive: number | null };
  apparentPower: number | null;
  reactivePower: number | null;
}

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/** S and Q of a reading. S from V x I, else from P / PF; never below P. */
export function powerTriangle(r: Reading): { apparent: number | null; reactive: number | null } {
  let s: number | null = null;
  if (r.voltage != null && r.voltage > 0) s = r.voltage * r.current;
  else if (r.powerFactor != null && r.powerFactor > 0) s = r.power / r.powerFactor;
  if (s == null) return { apparent: null, reactive: null };
  s = Math.max(s, r.power); // meter rounding can put V x I a hair below P
  return { apparent: s, reactive: Math.sqrt(Math.max(s * s - r.power * r.power, 0)) };
}

const within = (x: number, lo: number, hi: number, off: number) => x >= lo - off && x <= hi + off;

/**
 * Similarity of one quantity: 1 on target, falling quadratically to 0 at the
 * edge of the band (plus its offset). Quadratic, so normal run-to-run drift
 * of a few percent costs little while a different appliance costs a lot.
 */
function similarity(x: number, lo: number, target: number, hi: number, off: number): number {
  const half = Math.max(target - lo, hi - target) + off;
  if (half <= 0) return x === target ? 1 : 0;
  const d = Math.abs(x - target) / half;
  return Math.max(0, 1 - d * d);
}

/** Step 1: strict filter. Live P, I and PF must lie inside the bounds. */
export function passesBounds(s: Signature, r: Reading): boolean {
  if (!within(r.power, s.power.min, s.power.max, offsets.power(s.power.target))) return false;
  if (!within(r.current, s.current.min, s.current.max, offsets.current(s.current.target))) return false;
  if (s.pf && r.powerFactor != null && r.powerFactor > 0) {
    if (!within(r.powerFactor, s.pf.min, s.pf.max, offsets.pf())) return false;
  }
  return true;
}

/** Step 2: weighted composite similarity (P 40 %, I 30 %, PF 20 %, Q 10 %). */
export function score(s: Signature, r: Reading): Score {
  const { apparent, reactive } = powerTriangle(r);
  const power = similarity(r.power, s.power.min, s.power.target, s.power.max, offsets.power(s.power.target));
  const current = similarity(
    r.current, s.current.min, s.current.target, s.current.max, offsets.current(s.current.target));
  const pf = s.pf && r.powerFactor != null && r.powerFactor > 0
    ? similarity(r.powerFactor, s.pf.min, s.pf.target, s.pf.max, offsets.pf())
    : null;
  let q: number | null = null;
  if (s.reactive && s.reactive.max != null && reactive != null) {
    const target = (s.reactive.min + s.reactive.max) / 2;
    q = similarity(reactive, s.reactive.min, target, s.reactive.max, offsets.reactive(target));
  }
  // Missing quantities drop out and the remaining weights are rescaled.
  let sum = WEIGHTS.power * power + WEIGHTS.current * current, weight = WEIGHTS.power + WEIGHTS.current;
  if (pf != null) { sum += WEIGHTS.pf * pf; weight += WEIGHTS.pf; }
  if (q != null) { sum += WEIGHTS.reactive * q; weight += WEIGHTS.reactive; }
  return {
    confidence: sum / weight,
    axes: { power, current, pf, reactive: q },
    apparentPower: apparent,
    reactivePower: reactive,
  };
}

export interface Ranked<T> {
  item: T;
  score: Score;
}

export interface MatchResult<T> {
  /** Best candidate at or above the threshold, else null (unrecognized). */
  match: Ranked<T> | null;
  /** Best candidate that passed the bounds, even if below the threshold. */
  best: Ranked<T> | null;
  /** Every candidate that passed the bounds, most confident first. */
  ranked: Ranked<T>[];
  threshold: number;
}

/** Step 3: filter, score, and apply the strict confidence cutoff. */
export function matchSignature<T extends Candidate>(
  r: Reading,
  candidates: T[],
  threshold = DEFAULT_THRESHOLD,
): MatchResult<T> {
  const ranked = candidates
    .filter((c) => passesBounds(c.signature, r))
    .map((item) => ({ item, score: score(item.signature, r) }))
    .sort((a, b) => b.score.confidence - a.score.confidence);
  const best = ranked[0] ?? null;
  return { match: best && best.score.confidence >= threshold ? best : null, best, ranked, threshold };
}

/** P, I and PF bounds around a measured baseline, as the firmware learns them. */
export function boundsFromBaseline(r: Reading): {
  power: Range;
  current: Range;
  pf: Range | null;
} {
  const p = Math.max(Math.abs(r.power) * POWER_TOLERANCE, MIN_BAND);
  const c = Math.max(Math.abs(r.current) * CURRENT_TOLERANCE, MIN_BAND);
  // No PF from the meter: derive it from S when the voltage is known.
  const { apparent } = powerTriangle(r);
  const pf = r.powerFactor != null && r.powerFactor > 0
    ? r.powerFactor
    : apparent != null && apparent > 0 ? r.power / apparent : null;
  return {
    power: { min: Math.max(r.power - p, 0), max: r.power + p, target: r.power },
    current: { min: Math.max(r.current - c, 0), max: r.current + c, target: r.current },
    pf: pf == null || pf <= 0
      ? null
      : { min: Math.max(pf - PF_TOLERANCE, 0), max: Math.min(pf + PF_TOLERANCE, 1), target: Math.min(pf, 1) },
  };
}

const round = (v: number, d: number) => Math.round(v * 10 ** d) / 10 ** d;

/** Columns to insert into `appliances` (S and Q are generated by Postgres). */
export function signatureColumns(b: ReturnType<typeof boundsFromBaseline>): Record<string, number | null> {
  return {
    min_power: round(b.power.min, 2),
    max_power: round(b.power.max, 2),
    target_power: round(b.power.target, 2),
    min_current: round(b.current.min, 3),
    max_current: round(b.current.max, 3),
    target_current: round(b.current.target, 3),
    min_pf: b.pf ? round(b.pf.min, 2) : null,
    max_pf: b.pf ? round(b.pf.max, 2) : null,
    target_pf: b.pf ? round(b.pf.target, 2) : null,
  };
}

/** An `appliances` row (numeric columns may arrive as strings) to a Signature. */
export function signatureFromRow(row: Record<string, unknown>): Signature {
  const n = (k: string) => (row[k] == null ? null : Number(row[k]));
  const range = (prefix: string): Range | null => {
    const min = n(`min_${prefix}`), max = n(`max_${prefix}`);
    if (min == null || max == null) return null;
    return { min, max, target: n(`target_${prefix}`) ?? (min + max) / 2 };
  };
  const minS = n("min_apparent_power"), minQ = n("min_reactive_power");
  return {
    power: range("power")!,
    current: range("current")!,
    pf: range("pf"),
    apparent: minS == null ? null : { min: minS, max: n("max_apparent_power") },
    reactive: minQ == null ? null : { min: minQ, max: n("max_reactive_power") },
  };
}

/** Validates the live reading in a request body; returns an error string. */
export function parseReading(body: Record<string, unknown>): Reading | string {
  const { voltage, power, current, powerFactor } = body;
  if (!isNum(power) || power < 0 || power > 5000) return "power must be a number from 0 to 5000 W";
  if (!isNum(current) || current < 0 || current > 100) return "current must be a number from 0 to 100 A";
  if (powerFactor != null && (!isNum(powerFactor) || powerFactor < 0 || powerFactor > 1)) {
    return "powerFactor must be between 0 and 1";
  }
  if (voltage != null && (!isNum(voltage) || voltage < 80 || voltage > 300)) {
    return "voltage must be between 80 and 300 V";
  }
  return {
    voltage: (voltage as number | undefined) ?? null,
    power,
    current,
    powerFactor: (powerFactor as number | undefined) ?? null,
  };
}
