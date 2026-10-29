// POST /functions/v1/recognize-appliance   (called by the ESP32, twice per run)
//
// Rule-based recognition of the load that just started on outlet_1 or
// outlet_2 (the rules are in _shared/matching.ts):
//   Stage 1 (~10 s after the load settles): power, PF, start-up -> provisional
//   Stage 2 (~60 s): + power variation and cycling -> confirms or corrects
// Results: UNKNOWN, AMBIGUOUS, SAME_TYPE_IN_USE, MATCHED_PROVISIONAL, or
// MATCHED_CONFIRMED when Stage 2 agrees with Stage 1.
//
// SAFETY: every status except MATCHED_CONFIRMED gets the conservative default
// cutoff (recognition_config.default_cutoff_minutes); the database refuses
// anything longer (outlet_sessions trigger).
//
// The run is stored in outlet_sessions (one open row per outlet; the app
// follows it live). Outlet exclusivity: an appliance in an open session on
// any other outlet of the user's plugs is not a candidate, and the database
// refuses a second open session for the same appliance.
//
// Body: { deviceId, outlet, eventId, startedAt (epoch ms), stage: 1 | 2,
//         features: { avg_power_w, avg_pf?, avg_voltage_v?, startup_peak_ratio?,
//                     settling_time_s?, power_variation?, cycle_period_s?,
//                     standby_power_w?, unstable? } }
// Auth: x-device-key. Idempotent per (eventId, stage).
// Reply: { status, applianceId, applianceName, candidates, suggested, registerAs,
//          promptText, cutoffS, stage, reason, ... } (see sessionReply)
import { deviceIdOf, requireDevice } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, outletOf, readJson, serve } from "../_shared/http.ts";
import { type Recognition, parseFeatures, recognize, type Stage } from "../_shared/matching.ts";
import {
  learnFromConfirmed,
  loadAppliance,
  loadAppliances,
  loadConfig,
  ownerOf,
  sessionReply,
} from "../_shared/recognition_db.ts";

type Row = Record<string, unknown>;

serve(async (req) => {
  requireDevice(req);
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  const outlet = outletOf(body.outlet);
  const eventId = typeof body.eventId === "string" && /^[A-Za-z0-9_-]{1,88}$/.test(body.eventId) ? body.eventId : null;
  if (!eventId) throw new HttpError(400, "eventId must match [A-Za-z0-9_-]{1,88}");
  const startedAt = Number(body.startedAt);
  if (!Number.isFinite(startedAt) || startedAt < 1_700_000_000_000) {
    throw new HttpError(400, "startedAt must be epoch ms after the plug's clock was set");
  }
  if (body.stage !== 1 && body.stage !== 2) throw new HttpError(400, "stage must be 1 or 2");
  const stage = body.stage as Stage;
  const features = parseFeatures(body.features);
  if (typeof features === "string") throw new HttpError(400, features);

  const [config, owner] = await Promise.all([loadConfig(), ownerOf(deviceId)]);
  const { data: existing, error: existingError } = await db.from("outlet_sessions")
    .select("*").eq("event_id", eventId).maybeSingle();
  if (existingError) throw existingError;
  if (existing && (existing.device_id !== deviceId || existing.outlet !== outlet)) {
    throw new HttpError(409, "eventId belongs to another outlet");
  }
  // A retry, a late Stage 1, or a run that has already ended: answer as before.
  if (existing && (existing.stage >= stage || existing.ended_at)) return json(sessionReply(existing));

  // The user (or registration) already said what this is: keep their answer.
  // At Stage 2 a user confirmation also teaches the profile (EMA), once.
  if (existing && (existing.confirmed_by === "user" || existing.confirmed_by === "registration")) {
    const update: Row = { stage, features };
    if (stage === 2 && existing.confirmed_by === "user" && !existing.sample_recorded && existing.appliance_id && owner) {
      const learned = await learnFromConfirmed(await loadAppliance(owner, existing.appliance_id), features, eventId, config);
      update.sample_recorded = learned != null;
      if (learned) update.profile_id = learned.profileId;
    }
    const { data, error } = await db.from("outlet_sessions").update(update).eq("id", existing.id).select("*").single();
    if (error) throw error;
    return json(sessionReply(data));
  }

  // A new run on this outlet means the previous one there has ended, even if
  // its end was never reported (e.g. the upload was lost).
  if (!existing) {
    const { error } = await db.from("outlet_sessions")
      .update({ ended_at: new Date().toISOString(), end_reason: "SUPERSEDED" })
      .eq("device_id", deviceId).eq("outlet", outlet).is("ended_at", null);
    if (error) throw error;
  }

  const decide = async (): Promise<Recognition> => {
    if (!owner) {
      return {
        status: "UNKNOWN", match: null, candidates: [], suggested: null, registerAs: null,
        promptText: "Link this WisePlug to your account to recognise appliances.",
        cutoffS: config.defaultCutoffS, reason: "The plug has no owner, so it has no registered appliances.",
      };
    }
    return recognize({
      features, stage, here: { deviceId, outlet },
      appliances: await loadAppliances(owner, eventId),
      previousApplianceId: (existing?.appliance_id as string | null) ?? null,
      config,
    });
  };
  const row = (r: Recognition): Row => ({
    device_id: deviceId,
    outlet,
    event_id: eventId,
    appliance_id: r.match?.appliance.id ?? null,
    profile_id: r.match?.profile.id ?? null,
    status: r.status,
    confirmed_by: r.status === "MATCHED_CONFIRMED" ? "stage2" : null,
    stage,
    started_at: new Date(startedAt).toISOString(),
    last_score: r.match ? Math.round(r.match.score * 1000) / 1000 : null,
    cutoff_s: r.cutoffS,
    candidates: {
      candidates: r.candidates,
      suggested: r.suggested,
      registerAs: r.registerAs,
      applianceName: r.match?.appliance.name ?? null,
      modeName: r.match?.profile.modeName ?? null,
      reason: r.reason,
    },
    prompt_text: r.promptText,
    features,
  });
  const write = (r: Recognition) => existing
    ? db.from("outlet_sessions").update(row(r)).eq("id", existing.id).select("*").single()
    : db.from("outlet_sessions").insert(row(r)).select("*").single();

  let result = await decide();
  let { data: saved, error } = await write(result);
  if (error?.code === "23505") {
    // Another outlet claimed the same appliance a moment ago (or this run was
    // inserted by a parallel retry): decide again with the latest sessions.
    const { data: again } = await db.from("outlet_sessions").select("*").eq("event_id", eventId).maybeSingle();
    if (again && !existing) return json(sessionReply(again));
    result = await decide();
    ({ data: saved, error } = await write(result));
  }
  if (error) throw error;

  if (result.status === "MATCHED_CONFIRMED" && result.match) {
    const { error: lastError } = await db.from("appliance_instances")
      .update({ last_device_id: deviceId, last_outlet: outlet, last_seen_at: new Date().toISOString() })
      .eq("id", result.match.appliance.id);
    if (lastError) throw lastError;
  }
  return json(sessionReply(saved!), existing ? 200 : 201);
});
