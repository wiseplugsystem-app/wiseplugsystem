// POST /functions/v1/confirm-match   (called by the app)
//
// The user's answer to a recognition prompt for the run on one outlet:
// "Yes, this is Fan 1" (AMBIGUOUS dialog, a MATCHED_PROVISIONAL label, or a
// correction of any label). The run becomes MATCHED_CONFIRMED with that
// appliance's own cutoff (the 7-use learned cutoff once learned).
//
// Signature updating (only ever from a user confirmation): the run is added
// to the mode profile it fits and that profile's means move by the EMA
// (new = 0.9 x old + 0.1 x run). This needs the Stage 2 summary; if the user
// answers earlier, recognize-appliance does it when Stage 2 arrives. A run that
// fits none of the appliance's modes starts a new mode (set by the system,
// never by the user), recognised once it has its registration samples.
//
// "Register new" in a dialog calls register-sample instead.
//
// Body: { deviceId, eventId, applianceId }
// Auth: Authorization: Bearer <Firebase ID token> of the plug's owner.
// Reply: { status, applianceId, applianceName, cutoffS, learned, newMode, hint }
import { deviceIdOf, firebaseUser, requireOwner } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { closestProfile, confirmedCutoffS, type Stage } from "../_shared/matching.ts";
import { learnFromConfirmed, loadAppliance, loadConfig, sessionFeatures } from "../_shared/recognition_db.ts";

serve(async (req) => {
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  const uid = (await firebaseUser(req)).uid;
  await requireOwner(deviceId, uid);
  const config = await loadConfig();

  const { data: session, error: sessionError } = await db.from("outlet_sessions")
    .select("*").eq("event_id", String(body.eventId ?? "")).eq("device_id", deviceId).maybeSingle();
  if (sessionError) throw sessionError;
  if (!session) throw new HttpError(404, "That run was never reported by the plug");
  if (session.ended_at) throw new HttpError(409, "That run has already ended");
  const features = sessionFeatures(session);
  const stage = (session.stage >= 2 ? 2 : 1) as Stage;

  const appliance = await loadAppliance(uid, body.applianceId);
  // Outlet exclusivity: the database refuses it too (unique open session).
  if (appliance.activeOn && !(appliance.activeOn.deviceId === deviceId && appliance.activeOn.outlet === session.outlet)) {
    throw new HttpError(409, `${appliance.name} is running on another outlet, so this must be a different appliance.`);
  }
  const fit = closestProfile(features, appliance, stage, config);
  const cutoffS = confirmedCutoffS(appliance, config);

  const { error: claimError } = await db.from("outlet_sessions").update({
    status: "MATCHED_CONFIRMED",
    confirmed_by: "user",
    appliance_id: appliance.id,
    actual_appliance_id: appliance.id,  // ground truth for recognition_evaluation
    profile_id: fit?.profile.id ?? null,
    last_score: fit ? Math.round(fit.score * 1000) / 1000 : null,
    cutoff_s: cutoffS,
    prompt_text: `${appliance.name} (confirmed by you).`,
    candidates: {
      candidates: [], applianceName: appliance.name, modeName: fit?.profile.modeName ?? null,
      reason: "Confirmed by the user",
    },
  }).eq("id", session.id);
  if (claimError?.code === "23505") {
    throw new HttpError(409, `${appliance.name} is running on another outlet, so this must be a different appliance.`);
  }
  if (claimError) throw claimError;
  await db.from("appliance_instances")
    .update({ last_device_id: deviceId, last_outlet: session.outlet, last_seen_at: new Date().toISOString() })
    .eq("id", appliance.id);

  // EMA update now if Stage 2 is in; otherwise recognize-appliance does it at Stage 2.
  let learned = false;
  let newMode: string | null = null;
  if (stage === 2 && !session.sample_recorded) {
    const r = await learnFromConfirmed(appliance, features, session.event_id, config);
    learned = r != null;
    if (r?.newMode) newMode = r.modeName;
    const { error } = await db.from("outlet_sessions")
      .update({ sample_recorded: learned, profile_id: r?.profileId ?? fit?.profile.id ?? null }).eq("id", session.id);
    if (error) throw error;
  }
  return json({
    status: "MATCHED_CONFIRMED",
    applianceId: appliance.id,
    applianceName: appliance.name,
    cutoffS,
    learned,
    newMode,
    hint: newMode
      ? `${appliance.name} ran differently from before, so WisePlug started learning a new mode for it.`
      : null,
  });
});
