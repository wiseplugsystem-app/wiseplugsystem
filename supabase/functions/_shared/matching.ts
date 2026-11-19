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
/** Not compared for a charger (Appliance.varyingPower): they follow its battery. */
export const CHARGER_SKIPPED: readonly Feature[] = ["startup_peak_ratio", "power_variation", "settling_time_s"];

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
  /** Samples this profile needs to be matched (a setting: samples_per_level); null: registration_samples. */
  requiredSamples?: number | null;
  /** A setting's place in its appliance's list (Low, Medium, High); null otherwise. */
  levelPosition?: number | null;
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
  /** A charger: its power follows the battery (fast when low, slow when nearly
   * full), so its power is compared with floor_power_pct_charger. */
  varyingPower?: boolean;
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
  /** recognition_config.samples_per_level: samples for each setting at registration. */
  samplesPerLevel: number;
  /** recognition_config.samples_per_charger: a charger's samples (its power varies). */
  samplesPerCharger: number;
  /** recognition_config.floor_power_pct_charger: a charger's power tolerance
   * (its power drops as the battery fills: 120 W -> 50 W in one charge). */
  floorPowerPctCharger: number;
  /** recognition_config.floor_pf_charger: a charger's power-factor tolerance
   * (its PF follows the load, i.e. the phone or laptop on it). */
  floorPfCharger: number;
  /** recognition_config.charger_max_power_w: a charger's power passes from 0
   * up to this, whatever phone or laptop is on it. */
  chargerMaxPowerW: number;
  /** recognition_config.ask_when_several_match: several registered appliances
   * pass -> the user picks (AMBIGUOUS), instead of the best score winning. */
  askWhenSeveralMatch: boolean;
  /** recognition_config.ask_chargers: a charger match is never confirmed by
   * itself at Stage 2; it stays "Is this …?" until the user answers. */
  askChargers: boolean;
  /** recognition_config.charger_no_register: a reading that is a registered
   * charger's (it passes, or its PF is within charger_near_pf) is never
   * offered as a new appliance: the pop-up only confirms the charger or picks
   * which charger / phone it is. Optional: undefined counts as on. */
  chargerNoRegister?: boolean;
  /** recognition_config.charger_near_pf: how far a reading's PF may be from a
   * registered charger's and still be "that charger" instead of a new one. */
  chargerNearPf?: number;
  /** recognition_config.max_overrides: "Keep it on" extensions allowed per run (the plug enforces it). */
  maxOverrides: number;
  /** recognition_config.rest_gap_s: a heating load may rest at 0 W this long and stay on. */
  restGapS: number;
  /** recognition_config.rest_gap_min_w: a run peaking at or above this is a heating load. */
  restGapMinW: number;
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
    samplesPerLevel: Number.isFinite(Number(r.samples_per_level)) ? Number(r.samples_per_level) : 1,
    samplesPerCharger: Number.isFinite(Number(r.samples_per_charger)) ? Number(r.samples_per_charger) : 3,
    restGapS: Number.isFinite(Number(r.rest_gap_s)) ? Number(r.rest_gap_s) : 180,
    floorPowerPctCharger: Number.isFinite(Number(r.floor_power_pct_charger)) ? Number(r.floor_power_pct_charger) : 0.5,
    floorPfCharger: Number.isFinite(Number(r.floor_pf_charger)) ? Number(r.floor_pf_charger) : 0.15,
    chargerMaxPowerW: Number.isFinite(Number(r.charger_max_power_w)) ? Number(r.charger_max_power_w) : 140,
    askWhenSeveralMatch: r.ask_when_several_match !== false,
    askChargers: r.ask_chargers !== false,
    chargerNoRegister: r.charger_no_register !== false,
    chargerNearPf: r.charger_near_pf != null && Number.isFinite(Number(r.charger_near_pf))
      ? Number(r.charger_near_pf) : 0.25,
    maxOverrides: Number.isFinite(Number(r.max_overrides)) ? Number(r.max_overrides) : 3,
    restGapMinW: Number.isFinite(Number(r.rest_gap_min_w)) ? Number(r.rest_gap_min_w) : 500,
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
/** A charger's icon keys: its power depends on the battery, so it gets
 * samples_per_charger registration samples. */
export const isCharger = (iconKey: unknown): boolean =>
  iconKey === "laptop_charger" || iconKey === "phone_charger";

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
 * The settling time the plug reports for a load that never settled (its
 * MAX_SETTLE_MS, 60 s): "it never got steady", not a measured time. Such a
 * value cannot be compared with a real settling time, so settling time is
 * skipped when either the reading or the profile says "never steady"
 * (a laptop charger can settle in 8 s one day and never the next).
 */
export const NEVER_SETTLED_S = 60;
const neverSettled = (v: number | null | undefined) => has(v) && v >= NEVER_SETTLED_S - 0.5;

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
    if (f === "settling_time_s" && (x.unstable || neverSettled(value) || neverSettled(mean))) continue;
    // A charger's startup peak, steadiness (power tapers as the battery
    // fills) and on/off cycling follow the phone on it, not the charger: so
    // Stage 2 judges a charger exactly as Stage 1 did.
    if (a.varyingPower && (f === "startup_peak_ratio" || f === "power_variation" || f === "cycle_period_s")) continue;
    // Also the remote rule: settling follows the battery too (CHARGER_SKIPPED).
    if (a.varyingPower && CHARGER_SKIPPED.includes(f)) continue;
    // A charger's power follows its battery and the phone on it, and its
    // power factor follows that load: the wide charger floors apply.
    // Its power also follows whichever phone or laptop is on it: anything
    // from 0 to charger_max_power_w passes (mean +- tol covers that range).
    const tol = f === "avg_power_w" && a.varyingPower
      ? Math.max(
        tolerance(f, p, c),
        Math.abs(mean) * c.floorPowerPctCharger,
        Math.abs(mean),
        c.chargerMaxPowerW - mean,
      )
      : f === "avg_pf" && a.varyingPower
      ? Math.max(tolerance(f, p, c), c.floorPfCharger)
      : tolerance(f, p, c);
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
export const requiredSamples = (p: Profile, c: Config) => p.requiredSamples ?? c.registrationSamples;
export const isReady = (p: Profile, c: Config) => p.sampleCount >= requiredSamples(p, c) && has(p.mean.avg_power_w);

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
  /** A charger (phone or laptop): the app offers it as "which charger". */
  charger?: boolean;
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
  /** Charger readings: the pop-up only confirms or picks the charger, it
   * never offers "Register new appliance" (recognizeWithChargers). */
  chargerChoice?: boolean;
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
  /** The appliances Stage 1 asked the user to choose from (AMBIGUOUS), if any
   * and not answered yet: Stage 2 keeps offering them. */
  previousCandidateIds?: string[];
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
  // Still learning: the default, or a heating cap if shorter (a kettle: 15 min).
  if (!a.isLearned || !has(a.baselineRuntimeS)) return Math.min(c.defaultCutoffS, a.ownCutoffS);
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

  // "Is this A or B?" with the same appliances in the same order every time
  // (by name; the 3 best scores), "Last used here" pre-selected.
  const askAmong = (fits: ProfileResult[], reason: string): Recognition => {
    const contenders = [...fits].sort((a, b) => a.score - b.score).slice(0, 3)
      .sort((a, b) => a.appliance.name.localeCompare(b.appliance.name));
    const names = contenders.map((r) => r.appliance.name);
    const question = names.length === 2
      ? `Is this ${names[0]} or ${names[1]}?`
      : `Is this ${names.slice(0, -1).join(", ")} or ${names[names.length - 1]}?`;
    const best = [...contenders].sort((a, b) => a.score - b.score)[0];
    return unconfirmed("AMBIGUOUS", question, reason, {
      candidates: contenders.map(candidate),
      suggested: candidate(contenders.find((r) => lastUsedHere(r.appliance, here)) ?? best),
    });
  };

  // Consistency: Stage 1 asked "A or B?" and the user has not answered.
  // Stage 2 measures more (e.g. how steady the power is) and may leave only
  // one of them; it keeps asking about all of them instead of switching to
  // "Is this A?" or confirming A by itself. (An appliance now running on
  // another outlet is dropped: it cannot be in two sockets.)
  const earlier = stage === 2 && c.askWhenSeveralMatch ? (input.previousCandidateIds ?? []) : [];
  if (earlier.length >= 2) {
    const kept = appliances
      .filter((a) => earlier.includes(a.id) && !eligible.some((r) => r.appliance.id === a.id))
      .filter((a) => a.activeOn == null || isAt(a, here))
      .map((a) => closestProfile(x, a, stage, c))
      .filter((r): r is ProfileResult => r != null);
    const fits = [...eligible, ...kept];
    if (fits.length >= 2) {
      return askAmong(fits, `${fits.map((r) => r.appliance.name).join(" and ")} were offered at Stage 1; ` +
        "still the user's choice.");
    }
  }

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

  // Several registered appliances fit (e.g. the same wattage): the user picks
  // one of them, or registers a new appliance, instead of the best score.
  if (clear && second && c.askWhenSeveralMatch) {
    return askAmong(eligible,
      `${eligible.slice(0, 3).map((r) => r.appliance.name).join(" and ")} all fit this reading ` +
        `(best ${best.appliance.name}, score ${best.score.toFixed(2)}); the user chooses.`);
  }

  if (!clear) {
    const contenders = eligible.filter((r) => r.score < c.clearWinnerRatio * best.score || r.score - best.score <= c.tieMargin)
      .slice(0, 3)
      // Same order every time (by name), as askAmong.
      .sort((a, b) => a.appliance.name.localeCompare(b.appliance.name));
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
  // A charger is only ever confirmed by the user (ask_chargers): the meter
  // sees the phone on it, so another charger can look the same.
  const confirmed = stage === 2 && input.previousApplianceId === best.appliance.id &&
    !(best.appliance.varyingPower && c.askChargers);
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
// Chargers: never "a new appliance" (charger_no_register)
// ---------------------------------------------------------------------------

/**
 * recognize(), plus one rule for chargers. A wall meter sees the phone on a
 * charger, not the charger, so the same charger gives a different reading
 * with every phone. When the reading is a registered charger's, WisePlug does
 * not ask to register a new appliance: the pop-up only confirms the charger
 * ("Is this Purple charger?") or lets the user pick which charger / phone it
 * is ("Which charger is this?"), with every registered charger that is free.
 *
 * A charger's reading is one that recognize() matched to a charger, offered a
 * charger among its choices, or (UNKNOWN) whose PF is within charger_near_pf
 * of a registered charger at up to charger_max_power_w. Everything else is
 * exactly what recognize() decided. Unconfirmed runs keep the default cutoff.
 */
export function recognizeWithChargers(input: RecognizeInput): Recognition {
  const r = recognize(input);
  const { features: x, stage, here, appliances, config: c } = input;
  if (c.chargerNoRegister === false) return r;
  const chargerIds = new Set(appliances.filter((a) => a.varyingPower).map((a) => a.id));
  if (!chargerIds.size) return r;
  const mark = (k: Candidate): Candidate => chargerIds.has(k.applianceId) ? { ...k, charger: true } : k;
  const nearPf = c.chargerNearPf ?? 0.25;

  // Every registered charger that is ready and not running on another outlet.
  const free = appliances.filter((a) =>
    a.varyingPower && (a.activeOn == null || isAt(a, here)) && a.profiles.some((p) => isReady(p, c)));

  // The charger(s) offered: one -> "Is this X?"; several -> "Which charger?".
  const offer = (first: Appliance | null, why: string): Recognition | null => {
    const results = free
      .map((a) => closestProfile(x, a, stage, c))
      .filter((k): k is ProfileResult => k != null);
    if (!results.length) return null;
    const top = (first && results.find((k) => k.appliance.id === first.id)) ??
      [...results].sort((a, b) => a.score - b.score)[0];
    if (results.length === 1) {
      return {
        status: "MATCHED_PROVISIONAL", match: top, candidates: [mark(candidate(top))], suggested: null,
        registerAs: null, promptText: `Is this ${top.appliance.name}?`, cutoffS: c.defaultCutoffS,
        reason: why, chargerChoice: true,
      };
    }
    // Same order every time (by name), "Last used here" pre-selected.
    const sorted = [...results].sort((a, b) => a.appliance.name.localeCompare(b.appliance.name));
    const names = sorted.map((k) => k.appliance.name);
    return {
      status: "AMBIGUOUS", match: null, candidates: sorted.map((k) => mark(candidate(k))),
      suggested: mark(candidate(sorted.find((k) => lastUsedHere(k.appliance, here)) ?? top)), registerAs: null,
      promptText: `Which charger is this: ${names.slice(0, -1).join(", ")} or ${names[names.length - 1]}?`,
      cutoffS: c.defaultCutoffS, reason: why, chargerChoice: true,
    };
  };

  switch (r.status) {
    case "MATCHED_PROVISIONAL":
      if (r.match && chargerIds.has(r.match.appliance.id)) {
        return offer(r.match.appliance, `${r.reason}; a charger: confirm it or pick the charger, no new appliance.`) ??
          { ...r, candidates: r.candidates.map(mark), chargerChoice: true };
      }
      return r;
    case "AMBIGUOUS":
      if (r.candidates.some((k) => chargerIds.has(k.applianceId))) {
        return { ...r, candidates: r.candidates.map(mark), suggested: r.suggested && mark(r.suggested),
          chargerChoice: true };
      }
      return r;
    case "UNKNOWN": {
      // Close to a registered charger (its PF a little outside
      // floor_pf_charger, e.g. a nearly full phone): that charger, not new.
      const pf = x.avg_pf, w = x.avg_power_w;
      const near = has(w) && w <= c.chargerMaxPowerW && has(pf)
        ? free.filter((a) => a.profiles.some((p) => {
          const m = p.mean.avg_pf;
          return isReady(p, c) && has(m) && Math.abs(pf - m) <= nearPf;
        }))
        : [];
      if (!near.length) return r;
      const closest = near
        .map((a) => closestProfile(x, a, stage, c))
        .filter((k): k is ProfileResult => k != null)
        .sort((a, b) => a.score - b.score)[0];
      return offer(closest?.appliance ?? near[0],
        `Close to ${near.map((a) => a.name).join(" and ")} (charger PF within ${nearPf}); ` +
          "a charger: confirm it or pick the charger, no new appliance.") ?? r;
    }
    default:
      return r;
  }
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
 * are not typical use). Once there are learning_uses uses, EVERY use updates
 * the baseline: the average runtime of the LAST learning_uses uses (a rolling
 * window), so the safe time follows how the appliance is used now (it was
 * computed once at the 7th use and then frozen).
 */
export function recordUse(l: Learning, runtimeS: number, c: Config): Learning {
  if (runtimeS < c.minSessionS) return l;  // a blip teaches nothing
  const recentRuntimesS = [...l.recentRuntimesS, Math.round(runtimeS)].slice(-c.learningUses);
  const useCount = l.useCount + 1;
  if (recentRuntimesS.length < c.learningUses) {
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
    requiredSamples: num(r.required_samples),
    levelPosition: num(r.level_position),
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
