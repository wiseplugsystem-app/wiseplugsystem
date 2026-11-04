// Rule-based appliance recognition. Pure logic (no database, no Deno APIs):
// runs in the Edge Functions, in `node --test` and in `deno test`.
//
// No machine learning: an appliance is recognised by explicit rules on
// averages, standard deviations and tolerances, which the thesis can state as:
//
//   1. Tolerance of a feature  = max(3 x std_dev, floor)            (per profile)
//   2. Pass/fail               : every feature |new - mean| <= tolerance
//   3. Score of a candidate    = weighted average of |new - mean| / tolerance
//                                (0 = identical, 1 = at the edge of the tolerance)
//   4. Outlet exclusivity      : an appliance running on another outlet is removed
//   5. Decision                : clear winner / ambiguous / same type in use / unknown
//   6. Safety                  : only a CONFIRMED load gets the appliance's own cutoff
//
// Every number (sigma, floors, weights, ratio, margin, cutoffs) comes from the
// recognition_config table (configFromRow), not from this file.
//
// Current is not a feature: I = P / (V x PF), so it adds no independent
// information beyond power, voltage and power factor.

export const FEATURES = [
  "avg_power_w",
  "avg_pf",
  "startup_peak_ratio",
  "power_variation",
  "settling_time_s",
  "cycle_period_s",
  "standby_power_w",
] as const;
export type Feature = (typeof FEATURES)[number];

/**
 * Stage 1 (about 10 s after the load settles) knows power, PF and the
 * start-up. Stage 2 (about 60 s) adds the steady-state variation and, for
 * thermostat loads, the on/off cycle period.
 */
export const STAGE_FEATURES: Record<1 | 2, readonly Feature[]> = {
  1: ["avg_power_w", "avg_pf", "startup_peak_ratio", "settling_time_s", "standby_power_w"],
  2: FEATURES,
};
export type Stage = 1 | 2;

/** One summary from the plug. Null / missing = not measured (skipped). */
export type Features = Partial<Record<Feature, number | null>> & {
  avg_voltage_v?: number | null;
  /** The load never settled within 60 s: averages are less reliable. */
  unstable?: boolean;
};

export interface Profile {
  id: string;
  modeName: string;
  mean: Partial<Record<Feature, number | null>>;
  std: Partial<Record<Feature, number | null>>;
  registrationVoltage: number | null;
  sampleCount: number;
}

export interface Appliance {
  id: string;
  name: string;
  typeId: string;
  typeName: string;
  /** The appliance's own safe operating time (appliance_instances.max_runtime_mins). */
  ownCutoffS: number;
  /** 7-use learning: average runtime once learned. */
  isLearned: boolean;
  baselineRuntimeS: number | null;
  lastDeviceId: string | null;
  lastOutlet: string | null;
  /** The outlet it is running on right now (an open outlet session), or null. */
  activeOn: { deviceId: string; outlet: string } | null;
  profiles: Profile[];
}

export interface Config {
  toleranceSigma: number;
  floorPowerPct: number;
  floorPf: number;
  floorStartupPeakRatio: number;
  floorPowerVariation: number;
  floorSettlingTimeS: number;
  floorCyclePeriodPct: number;
  floorStandbyPowerW: number;
  weights: Record<Feature, number>;
  clearWinnerRatio: number;
  tieMargin: number;
  voltageCorrectionMinPf: number;
  defaultCutoffS: number;
  emaFactor: number;
  maxSamplesPerProfile: number;
  registrationSamples: number;
  learningUses: number;
  learnedMargin: number;
  minLearnedCutoffS: number;
  minSessionS: number;
  /** recognition_config.max_appliance_w: above it an appliance is not registered. */
  maxApplianceW: number;
}

type Row = Record<string, unknown>;
const num = (v: unknown): number | null => (v == null || v === "" ? null : Number(v));
const has = (v: number | null | undefined): v is number => typeof v === "number" && Number.isFinite(v);

/** The recognition_config row (numerics arrive as strings) as a Config. */
export function configFromRow(r: Row): Config {
  const n = (k: string) => {
    const v = Number(r[k]);
    if (!Number.isFinite(v)) throw new Error(`recognition_config.${k} is missing`);
    return v;
  };
  return {
    toleranceSigma: n("tolerance_sigma"),
    floorPowerPct: n("floor_power_pct"),
    floorPf: n("floor_pf"),
    floorStartupPeakRatio: n("floor_startup_peak_ratio"),
    floorPowerVariation: n("floor_power_variation"),
    floorSettlingTimeS: n("floor_settling_time_s"),
    floorCyclePeriodPct: n("floor_cycle_period_pct"),
    floorStandbyPowerW: n("floor_standby_power_w"),
    weights: {
      avg_power_w: n("weight_power"),
      avg_pf: n("weight_pf"),
      startup_peak_ratio: n("weight_startup_peak_ratio"),
      power_variation: n("weight_power_variation"),
      settling_time_s: n("weight_settling_time"),
      cycle_period_s: n("weight_cycle_period"),
      standby_power_w: n("weight_standby_power"),
    },
    clearWinnerRatio: n("clear_winner_ratio"),
    tieMargin: n("tie_margin"),
    voltageCorrectionMinPf: n("voltage_correction_min_pf"),
    defaultCutoffS: n("default_cutoff_minutes") * 60,
    emaFactor: n("ema_factor"),
    maxSamplesPerProfile: n("max_samples_per_profile"),
    registrationSamples: n("registration_samples"),
    learningUses: n("learning_uses"),
    learnedMargin: n("learned_margin"),
    minLearnedCutoffS: n("min_learned_cutoff_minutes") * 60,
    minSessionS: n("min_session_s"),
    // Older rows (and the tools' fixed settings) without it: the plug's limit.
    maxApplianceW: Number.isFinite(Number(r.max_appliance_w)) ? Number(r.max_appliance_w) : 1760,
  };
}

// ---------------------------------------------------------------------------
// Rule 1: tolerance
// ---------------------------------------------------------------------------

/**
 * The smallest tolerance of a feature. Without it, three nearly identical
 * registration samples (std_dev ~ 0) would make an appliance reject its own
 * next reading because of ordinary meter noise. Power and cycle period are
 * relative (a 2 % change matters the same for 10 W and 1000 W).
 */
export function floorOf(f: Feature, mean: number, c: Config): number {
  switch (f) {
    case "avg_power_w": return Math.abs(mean) * c.floorPowerPct;
    case "avg_pf": return c.floorPf;
    case "startup_peak_ratio": return c.floorStartupPeakRatio;
    case "power_variation": return c.floorPowerVariation;
    case "settling_time_s": return c.floorSettlingTimeS;
    case "cycle_period_s": return Math.abs(mean) * c.floorCyclePeriodPct;
    case "standby_power_w": return c.floorStandbyPowerW;
  }
}

/** tolerance = max(3 x std_dev, floor). A 0 W mean still gets a tiny tolerance. */
export function tolerance(f: Feature, p: Profile, c: Config): number {
  const mean = p.mean[f] ?? 0;
  const sd = p.std[f] ?? 0;
  return Math.max(c.toleranceSigma * sd, floorOf(f, mean, c), 1e-6);
}

// ---------------------------------------------------------------------------
// Voltage correction (resistive loads only)
// ---------------------------------------------------------------------------

/**
 * A heater's power follows V squared (P = V^2 / R): the same heater draws
 * 1000 W at 220 V but 1141 W at 235 V. For a resistive profile (mean PF at or
 * above voltage_correction_min_pf) the new power is scaled back to the
 * profile's registration voltage before comparing:
 *   adjusted = measured x (registered_V / measured_V)^2
 * Motors and electronics do not follow this law, so they are compared as measured.
 */
export function comparablePower(x: Features, p: Profile, c: Config): number | null {
  const power = x.avg_power_w;
  if (!has(power)) return null;
  const pf = p.mean.avg_pf, vReg = p.registrationVoltage, v = x.avg_voltage_v;
  if (has(pf) && pf >= c.voltageCorrectionMinPf && has(vReg) && has(v) && v > 0) {
    return power * (vReg / v) ** 2;
  }
  return power;
}

// ---------------------------------------------------------------------------
// Rules 2 and 3: pass/fail and score of one profile
// ---------------------------------------------------------------------------

export interface FeatureCheck {
  feature: Feature;
  value: number;
  mean: number;
  tolerance: number;
  /** |value - mean| / tolerance: 0 identical, 1 at the edge, > 1 fails. */
  normalized: number;
  pass: boolean;
}

export interface ProfileResult {
  appliance: Appliance;
  profile: Profile;
  pass: boolean;
  /** Weighted average of the normalized differences; lower is better. */
  score: number;
  checks: FeatureCheck[];
  voltageCorrected: boolean;
}

/** A tiny allowance for floating-point rounding at the tolerance edge. */
const EDGE = 1e-9;

/**
 * Compares one reading with one profile. A feature is compared only when
 * both the reading and the profile have it (null on either side: skipped).
 * Power must always be compared: it is the one feature every reading and
 * every profile has, so a profile is never accepted on PF alone.
 */
export function evaluateProfile(x: Features, a: Appliance, p: Profile, stage: Stage, c: Config): ProfileResult {
  const checks: FeatureCheck[] = [];
  const power = comparablePower(x, p, c);
  for (const f of STAGE_FEATURES[stage]) {
    const value = f === "avg_power_w" ? power : x[f];
    const mean = p.mean[f];
    if (!has(value) || !has(mean)) continue;
    const tol = tolerance(f, p, c);
    const normalized = Math.abs(value - mean) / tol;
    checks.push({ feature: f, value, mean, tolerance: tol, normalized, pass: normalized <= 1 + EDGE });
  }
  let sum = 0, weight = 0;
  for (const k of checks) {
    sum += c.weights[k.feature] * k.normalized;
    weight += c.weights[k.feature];
  }
  const comparedPower = checks.some((k) => k.feature === "avg_power_w");
  return {
    appliance: a,
    profile: p,
    pass: comparedPower && checks.every((k) => k.pass),
    score: weight > 0 ? sum / weight : Infinity,
    checks,
    voltageCorrected: power !== x.avg_power_w,
  };
}

/**
 * Too much for WisePlug's hardware (above max_appliance_w, 80 % of the
 * plug's 10 A): such an appliance is not registered.
 */
export const tooPowerful = (x: Features, c: Config): boolean =>
  has(x.avg_power_w) && x.avg_power_w > c.maxApplianceW;

/** A profile is matched only after its registration plug-ins are complete. */
export const isReady = (p: Profile, c: Config) => p.sampleCount >= c.registrationSamples && has(p.mean.avg_power_w);

/** Rule 3c: the best passing profile of an appliance (any mode matches the appliance). */
export function bestProfile(x: Features, a: Appliance, stage: Stage, c: Config): ProfileResult | null {
  let best: ProfileResult | null = null;
  for (const p of a.profiles) {
    if (!isReady(p, c)) continue;
    const r = evaluateProfile(x, a, p, stage, c);
    if (r.pass && (!best || r.score < best.score)) best = r;
  }
  return best;
}

/** The closest profile, passing or not (to know which mode a user-confirmed run belongs to). */
export function closestProfile(x: Features, a: Appliance, stage: Stage, c: Config): ProfileResult | null {
  let best: ProfileResult | null = null;
  for (const p of a.profiles) {
    if (!has(p.mean.avg_power_w)) continue;
    const r = evaluateProfile(x, a, p, stage, c);
    if (!best || (r.pass && !best.pass) || (r.pass === best.pass && r.score < best.score)) best = r;
  }
  return best;
}

// ---------------------------------------------------------------------------
// Rules 4 to 6: context, decision, cutoff
// ---------------------------------------------------------------------------

export type Status =
  | "UNKNOWN"
  | "AMBIGUOUS"
  | "SAME_TYPE_IN_USE"
  | "MATCHED_PROVISIONAL"
  | "MATCHED_CONFIRMED";

export interface Candidate {
  applianceId: string;
  name: string;
  typeName: string;
  profileId: string;
  modeName: string;
  score: number;
}

export interface Recognition {
  status: Status;
  /** Set for MATCHED_PROVISIONAL and MATCHED_CONFIRMED. */
  match: ProfileResult | null;
  /** AMBIGUOUS: the contenders (best first). Otherwise the passing ones. */
  candidates: Candidate[];
  /** AMBIGUOUS: the one pre-selected in the dialog (last used on this outlet). */
  suggested: Candidate | null;
  /** SAME_TYPE_IN_USE: the type and the name to offer ("Fan 2"). */
  registerAs: { typeId: string; typeName: string; name: string; resembles: string } | null;
  promptText: string;
  /** The cutoff the plug must apply (seconds). */
  cutoffS: number;
  reason: string;
}

export interface RecognizeInput {
  features: Features;
  stage: Stage;
  /** The outlet the load is on. */
  here: { deviceId: string; outlet: string };
  /** Every appliance of the plug's owner. */
  appliances: Appliance[];
  /** Stage 1's provisional appliance for this run, if any. */
  previousApplianceId?: string | null;
  config: Config;
}

const candidate = (r: ProfileResult): Candidate => ({
  applianceId: r.appliance.id,
  name: r.appliance.name,
  typeName: r.appliance.typeName,
  profileId: r.profile.id,
  modeName: r.profile.modeName,
  score: Math.round(r.score * 1000) / 1000,
});

/**
 * The cutoff of a CONFIRMED appliance: its own safe operating time, or, once
 * it has learned its typical use (the existing 7-use rule), the average
 * runtime x learned_margin, at least min_learned_cutoff, never above its own.
 */
export function confirmedCutoffS(a: Appliance, c: Config): number {
  if (!a.isLearned || !has(a.baselineRuntimeS)) return a.ownCutoffS;
  const learned = Math.max(a.baselineRuntimeS * c.learnedMargin, c.minLearnedCutoffS);
  return Math.round(Math.min(learned, a.ownCutoffS));
}

/** "Fan 2" when one Fan exists; fills gaps; case-insensitive. */
export function nextInstanceName(typeName: string, existing: string[], sameTypeCount: number): string {
  const taken = new Set(existing.map((n) => n.trim().toLowerCase()));
  for (let i = Math.max(sameTypeCount + 1, 1); ; i++) {
    const name = `${typeName} ${i}`;
    if (!taken.has(name.toLowerCase())) return name;
  }
}

const isAt = (a: Appliance, here: RecognizeInput["here"]) =>
  a.activeOn != null && a.activeOn.deviceId === here.deviceId && a.activeOn.outlet === here.outlet;
const lastUsedHere = (a: Appliance, here: RecognizeInput["here"]) =>
  a.lastDeviceId === here.deviceId && a.lastOutlet === here.outlet;

export function recognize(input: RecognizeInput): Recognition {
  const { features: x, stage, here, appliances, config: c } = input;

  // Rules 2-3: every appliance whose best profile passes, best score first.
  const passing = appliances
    .map((a) => bestProfile(x, a, stage, c))
    .filter((r): r is ProfileResult => r != null)
    .sort((a, b) => a.score - b.score);

  // Rule 4, outlet exclusivity: one physical appliance cannot be in two
  // sockets, so an appliance running on another outlet is not a candidate.
  const busy = passing.filter((r) => r.appliance.activeOn != null && !isAt(r.appliance, here));
  const eligible = passing.filter((r) => !busy.includes(r));

  const unconfirmed = (status: Status, promptText: string, reason: string, extra: Partial<Recognition> = {}): Recognition => ({
    status, match: null, candidates: eligible.slice(0, 3).map(candidate), suggested: null, registerAs: null,
    promptText, cutoffS: c.defaultCutoffS, reason, ...extra,
  });

  if (!eligible.length) {
    if (busy.length) {
      // It passes as an appliance that is running elsewhere: another unit of that type.
      const twin = busy[0].appliance;
      const sameType = appliances.filter((a) => a.typeId === twin.typeId).length;
      const name = nextInstanceName(twin.typeName, appliances.map((a) => a.name), sameType);
      return unconfirmed(
        "SAME_TYPE_IN_USE",
        `This looks like another ${twin.typeName}. Register as ${name}?`,
        `Matches ${twin.name}, which is running on another outlet; one appliance cannot be in two sockets.`,
        { registerAs: { typeId: twin.typeId, typeName: twin.typeName, name, resembles: twin.name } },
      );
    }
    return unconfirmed("UNKNOWN", "New appliance detected. Register it?",
      "No registered appliance passes every feature check.");
  }

  const [best, second] = eligible;
  // Clear winner: the runner-up scores at least clear_winner_ratio times worse
  // AND is more than tie_margin away. The margin matters when both scores are
  // tiny: 0.01 vs 0.02 is "twice as far" but both are practically identical.
  const clear = !second ||
    (second.score >= c.clearWinnerRatio * best.score && second.score - best.score > c.tieMargin);

  if (!clear) {
    const contenders = eligible.filter((r) => r.score < c.clearWinnerRatio * best.score || r.score - best.score <= c.tieMargin)
      .slice(0, 3);
    // Last-known outlet: among the tied ones, pre-select the one last used here.
    // Readings decide the TYPE; they cannot tell two identical units apart.
    const tied = contenders.filter((r) => r.score - best.score <= c.tieMargin);
    const here1 = tied.find((r) => lastUsedHere(r.appliance, here));
    const names = contenders.map((r) => r.appliance.name);
    const question = names.length === 2
      ? `Is this ${names[0]} or ${names[1]}?`
      : `Is this ${names.slice(0, -1).join(", ")} or ${names[names.length - 1]}?`;
    const identical = contenders.every((r) => r.appliance.typeId === best.appliance.typeId);
    return unconfirmed("AMBIGUOUS", question,
      identical
        ? `${names.join(" and ")} give near-identical readings; WisePlug cannot tell identical units apart.`
        : `${names.join(" and ")} score too close to choose (${contenders.map((r) => r.score.toFixed(2)).join(" vs ")}).`,
      { candidates: contenders.map(candidate), suggested: candidate(here1 ?? best) });
  }

  // A clear winner. Stage 2 agreeing with Stage 1 confirms it; otherwise it
  // stays provisional (a Stage 2 that changes the answer corrects it).
  const confirmed = stage === 2 && input.previousApplianceId === best.appliance.id;
  return {
    status: confirmed ? "MATCHED_CONFIRMED" : "MATCHED_PROVISIONAL",
    match: best,
    candidates: eligible.slice(0, 3).map(candidate),
    suggested: null,
    registerAs: null,
    promptText: confirmed ? `${best.appliance.name} confirmed.` : `Looks like ${best.appliance.name}.`,
    // Rule 6, safety: a provisional label never gets the appliance's limit.
    cutoffS: confirmed ? confirmedCutoffS(best.appliance, c) : c.defaultCutoffS,
    reason: `${best.appliance.name} (${best.profile.modeName}), score ${best.score.toFixed(2)}` +
      (second ? `; next ${second.appliance.name} ${second.score.toFixed(2)}` : "") +
      (best.voltageCorrected ? "; voltage-corrected" : "") +
      (stage === 2 && !confirmed && input.previousApplianceId ? "; corrected at Stage 2" : ""),
  };
}

// ---------------------------------------------------------------------------
// Registration and signature updating
// ---------------------------------------------------------------------------

export interface Sample extends Features {
  avg_voltage_v?: number | null;
}

/** Sample mean and standard deviation (n - 1); std 0 for a single value. */
function meanStd(values: number[]): { mean: number | null; std: number | null } {
  if (!values.length) return { mean: null, std: null };
  const m = values.reduce((a, b) => a + b, 0) / values.length;
  const v = values.length > 1 ? values.reduce((a, x) => a + (x - m) ** 2, 0) / (values.length - 1) : 0;
  return { mean: m, std: Math.sqrt(v) };
}

/**
 * Registration: the profile is the plain mean and standard deviation of its
 * samples (the 3 guided plug-ins), and its registration voltage is the mean
 * voltage of those samples.
 */
export function profileFromSamples(samples: Sample[]): Pick<Profile, "mean" | "std" | "registrationVoltage" | "sampleCount"> {
  const mean: Profile["mean"] = {}, std: Profile["std"] = {};
  for (const f of FEATURES) {
    const r = meanStd(samples.map((s) => s[f]).filter(has));
    mean[f] = r.mean;
    std[f] = r.std;
  }
  return {
    mean,
    std,
    registrationVoltage: meanStd(samples.map((s) => s.avg_voltage_v).filter(has)).mean,
    sampleCount: samples.length,
  };
}

/**
 * Signature updating after a USER-CONFIRMED match (never an unconfirmed one):
 *   new_mean = (1 - f) x old_mean + f x new_value        (f = ema_factor, 0.1)
 * so one unusual run moves the signature only 10 %, while slow drift (motor
 * wear, a new charger) is followed over many uses. The standard deviation is
 * recomputed from the newest samples ([recent], including the new one).
 */
export function emaUpdate(p: Profile, x: Sample, recent: Sample[], c: Config): Pick<Profile, "mean" | "std" | "sampleCount"> {
  const mean: Profile["mean"] = {}, std: Profile["std"] = {};
  for (const f of FEATURES) {
    const old = p.mean[f], v = x[f];
    mean[f] = has(old) && has(v) ? (1 - c.emaFactor) * old + c.emaFactor * v : has(old) ? old : has(v) ? v : null;
    const s = meanStd(recent.slice(0, c.maxSamplesPerProfile).map((r) => r[f]).filter(has));
    std[f] = s.std ?? p.std[f] ?? null;
  }
  return { mean, std, sampleCount: p.sampleCount + 1 };
}

// ---------------------------------------------------------------------------
// 7-use learning (existing feature, now on the server)
// ---------------------------------------------------------------------------

export interface Learning {
  useCount: number;
  recentRuntimesS: number[];
  isLearned: boolean;
  baselineRuntimeS: number | null;
}

/**
 * Records one normal use (the user or the appliance switched it off; lock-outs
 * are not typical use). After learning_uses uses, the baseline is their
 * average runtime; the newest learning_uses runtimes are kept for display.
 */
export function recordUse(l: Learning, runtimeS: number, c: Config): Learning {
  if (runtimeS < c.minSessionS) return l;  // a blip teaches nothing
  const recentRuntimesS = [...l.recentRuntimesS, Math.round(runtimeS)].slice(-c.learningUses);
  const useCount = l.useCount + 1;
  if (l.isLearned || recentRuntimesS.length < c.learningUses) {
    return { ...l, useCount, recentRuntimesS };
  }
  const baseline = Math.round(recentRuntimesS.reduce((a, b) => a + b, 0) / recentRuntimesS.length);
  return { useCount, recentRuntimesS, isLearned: true, baselineRuntimeS: baseline };
}

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------

const LIMITS: Record<Feature | "avg_voltage_v", [number, number]> = {
  avg_power_w: [0, 25000],
  avg_pf: [0, 1],
  avg_voltage_v: [80, 300],
  startup_peak_ratio: [0, 50],
  power_variation: [0, 10],
  settling_time_s: [0, 600],
  cycle_period_s: [1, 86400],
  standby_power_w: [0, 100],
};

/** Validates the plug's features; returns an error string. avg_power_w is required. */
export function parseFeatures(v: unknown): Features | string {
  if (!v || typeof v !== "object") return "features must be an object";
  const f = v as Record<string, unknown>;
  const out: Features = {};
  for (const [k, [lo, hi]] of Object.entries(LIMITS)) {
    const x = f[k];
    if (x == null) continue;
    if (typeof x !== "number" || !Number.isFinite(x) || x < lo || x > hi) return `features.${k} must be ${lo}..${hi}`;
    (out as Record<string, number>)[k] = x;
  }
  if (!has(out.avg_power_w)) return "features.avg_power_w is required";
  out.unstable = f.unstable === true;
  return out;
}

/** A profile row (numerics arrive as strings) as a Profile. */
export function profileFromRow(r: Row): Profile {
  const mean: Profile["mean"] = {}, std: Profile["std"] = {};
  for (const f of FEATURES) {
    mean[f] = num(r[`${f}_mean`]);
    std[f] = num(r[`${f}_std`]);
  }
  return {
    id: String(r.id),
    modeName: String(r.mode_name),
    mean,
    std,
    registrationVoltage: num(r.registration_voltage_v),
    sampleCount: Number(r.sample_count ?? 0),
  };
}

/** A Profile's statistics as appliance_profiles columns. */
export function profileColumns(p: Pick<Profile, "mean" | "std">) {
  const out: Record<string, number | null> = {};
  for (const f of FEATURES) {
    out[`${f}_mean`] = p.mean[f] ?? null;
    out[`${f}_std`] = p.std[f] ?? null;
  }
  return out;
}
