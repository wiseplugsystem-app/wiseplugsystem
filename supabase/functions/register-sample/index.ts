// POST /functions/v1/register-sample   (called by the app)
//
// Guided registration: the user names the appliance and plugs it in
// registration_samples times (3). Each run is one call:
//   first run:   { deviceId, eventId, typeName, name, iconKey? }  creates the appliance
//                and its first mode profile ("Normal")
//   next runs:   { deviceId, eventId, applianceId }      the profile still
//                collecting samples (the first, or a mode WisePlug started)
// The user sets only the type and the name. The safe operating time and the
// modes are set by the system: the type's default limit (then the 7-use
// learning), and a new mode when a confirmed run fits none (confirm-match).
// The run's Stage 2 summary becomes a sample, and the profile is recomputed as
// the plain mean and standard deviation of its samples (registration voltage
// = their mean voltage). The profile is used for matching only once it has
// all 3 samples.
//
// Registering a load is the user saying what it is, so its open run becomes
// MATCHED_CONFIRMED with the appliance's own cutoff.
//
// Auth: Authorization: Bearer <Firebase ID token> of the plug's owner.
// Reply: { appliance: { id, name, type }, profile: { id, modeName },
//          samplesCollected, samplesRequired, complete, cutoffS }
import { deviceIdOf, firebaseUser, requireOwner } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { type Appliance, confirmedCutoffS, tooPowerful } from "../_shared/matching.ts";
import {
  insertSample,
  loadAppliance,
  loadConfig,
  recomputeProfile,
  sessionFeatures,
} from "../_shared/recognition_db.ts";

const text = (v: unknown, max: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);

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
  // A registration sample needs the full measurement (power variation, cycling).
  if (session.stage < 2) throw new HttpError(409, "Keep it running: WisePlug finishes measuring about 60 s after switch-on.");
  const features = sessionFeatures(session);
  // Above what the plug can carry: never registered (the plug cuts it off).
  if (tooPowerful(features, config)) {
    throw new HttpError(409, `This appliance uses ${Math.round(features.avg_power_w!)} W, more than WisePlug ` +
      `can safely power (${config.maxApplianceW} W). Unplug it: it cannot be registered.`);
  }
  // The appliance: an existing one (its next plug-in), or a new one.
  let appliance: Appliance;
  if (body.applianceId) {
    appliance = await loadAppliance(uid, body.applianceId);
  } else {
    const typeName = text(body.typeName, 40);
    if (!typeName) throw new HttpError(400, "typeName is required, e.g. Fan");
    // Types are unique per user ignoring case ("fan" is "Fan").
    const { data: types, error: typesError } = await db.from("appliance_types").select("*").eq("owner_uid", uid);
    if (typesError) throw typesError;
    // Its icon ("What are you adding?"); the app maps unknown keys to "Other".
    const iconKey = typeof body.iconKey === "string" && /^[a-z_]{1,32}$/.test(body.iconKey) ? body.iconKey : null;
    let type = types.find((t) => String(t.name).toLowerCase() === typeName.toLowerCase());
    if (!type) {
      const { data, error } = await db.from("appliance_types")
        .insert({ device_id: deviceId, owner_uid: uid, name: typeName, icon_key: iconKey }).select("*").single();
      if (error) throw error;
      type = data;
    } else if (!type.icon_key && iconKey) {
      const { error } = await db.from("appliance_types").update({ icon_key: iconKey }).eq("id", type.id);
      if (error) throw error;
    }
    const name = text(body.name, 63);
    if (!name) throw new HttpError(400, "name is required, e.g. Fan 2");
    // The system sets the safe operating time: the type's default.
    const minutes = Number(type.default_max_runtime_mins);
    const { data: created, error } = await db.from("appliance_instances")
      .insert({ device_id: deviceId, owner_uid: uid, type_id: type.id, name, max_runtime_mins: minutes })
      .select("id").single();
    if (error?.code === "23505") throw new HttpError(409, `"${name}" already exists; choose another name.`);
    if (error) throw error;
    appliance = await loadAppliance(uid, created.id);
  }

  // The profile still collecting samples; a new appliance starts with "Normal".
  let profile = appliance.profiles.find((p) => p.sampleCount < config.registrationSamples);
  let profileId = profile?.id;
  if (!profileId) {
    if (appliance.profiles.length) {
      throw new HttpError(409, `${appliance.name} is already fully registered.`);
    }
    const { data, error } = await db.from("appliance_profiles")
      .insert({ appliance_id: appliance.id, mode_name: "Normal" }).select("id").single();
    if (error) throw error;
    profileId = data.id as string;
  }
  const modeName = profile?.modeName ?? "Normal";
  if (!(await insertSample(profileId, features, "registration", session.event_id))) {
    throw new HttpError(409, "This run is already recorded for that appliance; unplug it and plug it in again.");
  }
  const stats = await recomputeProfile(profileId);
  profile = { id: profileId, modeName: profile?.modeName ?? modeName, ...stats };

  // The user has just said what this load is: it is confirmed, and it is the
  // ground truth of this run for recognition_evaluation (even if it ended).
  const cutoffS = confirmedCutoffS(appliance, config);
  const { error: truthError } = await db.from("outlet_sessions")
    .update({ actual_appliance_id: appliance.id }).eq("id", session.id);
  if (truthError) throw truthError;
  if (!session.ended_at) {
    const { error } = await db.from("outlet_sessions").update({
      status: "MATCHED_CONFIRMED",
      confirmed_by: "registration",
      appliance_id: appliance.id,
      profile_id: profileId,
      cutoff_s: cutoffS,
      sample_recorded: true,
      prompt_text: `Registered ${appliance.name}: sample ${stats.sampleCount} of ${config.registrationSamples}.`,
      candidates: { candidates: [], applianceName: appliance.name, modeName: profile.modeName, reason: "Registered by the user" },
    }).eq("id", session.id);
    if (error?.code === "23505") {
      throw new HttpError(409, `${appliance.name} is running on another outlet, so this must be a different appliance.`);
    }
    if (error) throw error;
    await db.from("appliance_instances")
      .update({ last_device_id: deviceId, last_outlet: session.outlet, last_seen_at: new Date().toISOString() })
      .eq("id", appliance.id);
  }

  return json({
    appliance: { id: appliance.id, name: appliance.name, type: appliance.typeName },
    profile: { id: profileId, modeName: profile.modeName },
    samplesCollected: stats.sampleCount,
    samplesRequired: config.registrationSamples,
    complete: stats.sampleCount >= config.registrationSamples,
    cutoffS,
  }, 201);
});
