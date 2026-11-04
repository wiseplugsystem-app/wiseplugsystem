// Database side of rule-based recognition: loads what _shared/matching.ts
// compares, and writes signatures back. The rules themselves are in matching.ts.
import { db } from "./db.ts";
import { HttpError } from "./http.ts";
import {
  type Appliance,
  closestProfile,
  type Config,
  configFromRow,
  emaUpdate,
  FEATURES,
  type Features,
  parseFeatures,
  profileColumns,
  profileFromRow,
  profileFromSamples,
  type Sample,
  requiredSamples,
} from "./matching.ts";

type Row = Record<string, unknown>;

export async function loadConfig(): Promise<Config> {
  const { data, error } = await db.from("recognition_config").select("*").single();
  if (error) throw error;
  return configFromRow(data);
}

/** The Firebase uid that owns [deviceId], or null while the plug is not linked. */
export async function ownerOf(deviceId: string): Promise<string | null> {
  const { data, error } = await db.from("devices").select("owner_uid").eq("id", deviceId).maybeSingle();
  if (error) throw error;
  if (!data) throw new HttpError(404, `Unknown device ${deviceId}; add it to the devices table`);
  return (data.owner_uid as string | null) ?? null;
}

/**
 * Every appliance of [ownerUid] with its mode profiles and the outlet it is
 * running on (an open outlet session on any of the user's plugs). The session
 * of [exceptEventId] (the run being recognised) does not count as running.
 */
export async function loadAppliances(ownerUid: string, exceptEventId?: string): Promise<Appliance[]> {
  const [instances, profiles, open] = await Promise.all([
    db.from("appliance_instances")
      .select("id, name, type_id, max_runtime_mins, is_learned, baseline_runtime_s, last_device_id, last_outlet, appliance_types(name)")
      .eq("owner_uid", ownerUid),
    db.from("appliance_profiles").select("*, appliance_instances!inner(owner_uid)")
      .eq("appliance_instances.owner_uid", ownerUid),
    db.from("outlet_sessions").select("device_id, outlet, appliance_id, event_id")
      .is("ended_at", null).not("appliance_id", "is", null),
  ]);
  for (const r of [instances, profiles, open]) if (r.error) throw r.error;
  const activeOn = new Map<string, { deviceId: string; outlet: string }>();
  for (const s of open.data!) {
    if (s.event_id !== exceptEventId) activeOn.set(String(s.appliance_id), { deviceId: s.device_id, outlet: s.outlet });
  }
  return instances.data!.map((r: Row) => applianceFromRow(r, profiles.data!, activeOn));
}

export function applianceFromRow(
  r: Row,
  profileRows: Row[],
  activeOn: Map<string, { deviceId: string; outlet: string }> = new Map(),
): Appliance {
  return {
    id: String(r.id),
    name: String(r.name),
    typeId: String(r.type_id),
    typeName: String((r.appliance_types as Row | null)?.name ?? "Appliance"),
    ownCutoffS: Number(r.max_runtime_mins) * 60,
    isLearned: r.is_learned === true,
    baselineRuntimeS: r.baseline_runtime_s == null ? null : Number(r.baseline_runtime_s),
    lastDeviceId: (r.last_device_id as string | null) ?? null,
    lastOutlet: (r.last_outlet as string | null) ?? null,
    activeOn: activeOn.get(String(r.id)) ?? null,
    profiles: profileRows.filter((p) => p.appliance_id === r.id).map(profileFromRow),
  };
}

/** One of the owner's appliances, or 404. */
export async function loadAppliance(ownerUid: string, applianceId: unknown): Promise<Appliance> {
  const all = await loadAppliances(ownerUid);
  const a = all.find((x) => x.id === applianceId);
  if (!a) throw new HttpError(404, "Unknown appliance");
  return a;
}

/** The plug's features as signature_samples columns. */
export function sampleColumns(x: Features) {
  const out: Record<string, unknown> = { avg_voltage_v: x.avg_voltage_v ?? null, unstable: x.unstable === true };
  for (const f of FEATURES) out[f] = x[f] ?? null;
  return out;
}

const sampleFromRow = (r: Row): Sample => {
  const s: Sample = { avg_voltage_v: r.avg_voltage_v == null ? null : Number(r.avg_voltage_v) };
  for (const f of FEATURES) s[f] = r[f] == null ? null : Number(r[f]);
  return s;
};

/** The newest samples of a profile (the trigger keeps max_samples_per_profile). */
export async function recentSamples(profileId: string): Promise<Sample[]> {
  const { data, error } = await db.from("signature_samples").select("*")
    .eq("profile_id", profileId).order("created_at", { ascending: false }).order("id", { ascending: false });
  if (error) throw error;
  return data.map(sampleFromRow);
}

/** Stores one sample of a run; false when this run was already recorded for the profile. */
export async function insertSample(profileId: string, x: Features, source: "registration" | "confirmed_match", eventId: string) {
  const { error } = await db.from("signature_samples")
    .insert({ profile_id: profileId, ...sampleColumns(x), source, event_id: eventId });
  if (error?.code === "23505") return false;
  if (error) throw error;
  return true;
}

/** Registration: the profile becomes the plain mean / std of its samples. */
export async function recomputeProfile(profileId: string) {
  const stats = profileFromSamples(await recentSamples(profileId));
  const { error } = await db.from("appliance_profiles").update({
    ...profileColumns(stats),
    registration_voltage_v: stats.registrationVoltage,
    sample_count: stats.sampleCount,
  }).eq("id", profileId);
  if (error) throw error;
  return stats;
}

/**
 * Signature updating after a USER-confirmed match (never an unconfirmed one).
 * The modes are set by the system, not the user:
 *   - the run fits a complete mode: that mode's means move by the EMA
 *   - it fits a mode still collecting samples: the sample is added and that
 *     mode is the plain mean / std of its samples (as at registration)
 *   - it fits none (e.g. fan speed 3 never seen): WisePlug starts a new mode
 *     "Mode N" with this run; like any mode it is matched once it has
 *     registration_samples samples
 * Returns the profile updated.
 */
export async function learnFromConfirmed(
  appliance: Appliance,
  x: Features,
  eventId: string,
  config: Config,
): Promise<{ profileId: string; modeName: string; newMode: boolean } | null> {
  const fit = closestProfile(x, appliance, 2, config);
  if (!fit || !fit.pass) {
    const modeName = `Mode ${appliance.profiles.length + 1}`;
    const { data, error } = await db.from("appliance_profiles")
      .insert({ appliance_id: appliance.id, mode_name: modeName }).select("id").single();
    if (error) throw error;
    if (!(await insertSample(data.id, x, "confirmed_match", eventId))) return null;
    await recomputeProfile(data.id);
    return { profileId: data.id, modeName, newMode: true };
  }
  if (!(await insertSample(fit.profile.id, x, "confirmed_match", eventId))) return null;
  if (fit.profile.sampleCount + 1 <= requiredSamples(fit.profile, config)) {
    await recomputeProfile(fit.profile.id);
  } else {
    const updated = emaUpdate(fit.profile, x, await recentSamples(fit.profile.id), config);
    const { error } = await db.from("appliance_profiles")
      .update({ ...profileColumns(updated), sample_count: updated.sampleCount }).eq("id", fit.profile.id);
    if (error) throw error;
  }
  return { profileId: fit.profile.id, modeName: fit.profile.modeName, newMode: false };
}

/** The stored features of an outlet session. */
export function sessionFeatures(row: Row): Features {
  const x = parseFeatures(row.features);
  if (typeof x === "string") throw new HttpError(409, "WisePlug has not reported this run's measurements yet");
  return x;
}

/** What every function returns about an outlet session (the app and the plug read it). */
export function sessionReply(row: Row) {
  const extra = (row.candidates ?? {}) as Row;
  return {
    eventId: row.event_id,
    deviceId: row.device_id,
    outlet: row.outlet,
    stage: row.stage,
    status: row.status,
    applianceId: row.appliance_id ?? null,
    applianceName: extra.applianceName ?? null,
    profileId: row.profile_id ?? null,
    modeName: extra.modeName ?? null,
    confirmedBy: row.confirmed_by ?? null,
    candidates: extra.candidates ?? [],
    suggested: extra.suggested ?? null,
    registerAs: extra.registerAs ?? null,
    promptText: row.prompt_text ?? null,
    cutoffS: row.cutoff_s,
    score: row.last_score ?? null,
    reason: extra.reason ?? null,
  };
}
