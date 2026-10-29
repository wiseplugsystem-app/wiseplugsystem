// POST /functions/v1/confirm-appliance   (called by the app)
//
// The user's answer to an identification prompt for the load on one outlet:
//   { action: "confirm", instanceId }   "Yes, this is Fan 1" (also a thumbs-up
//                                       on a CONFIDENT match)
//   { action: "register", typeName, name?, maxRuntimeMins? }
//                                       "This is a new appliance" ("Fan 2")
// Either way the run's features and signal become a new signature sample of
// that instance (continuous learning, newest 20 per mode), in its closest mode
// or a new mode when it differs (fan speed 3), and the answer is stored as the
// run's label in identification_events (ground truth for evaluation). The instance's own cutoff then
// replaces the conservative one; the app forwards it to the plug.
//
// Body: { deviceId, eventId, action, instanceId? | typeName, name?, maxRuntimeMins? }
// Auth: Authorization: Bearer <Firebase ID token> of the device owner.
// Reply: { instance: { id, name, type, mode }, cutoffS, sampleCount }
import { deviceIdOf, firebaseUser, requireOwner } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { canUseEmbedding, embed, parseSignal, rankEmbedding, type Signal } from "../_shared/embedder.ts";
import { ensureEmbeddings, loadInstances, sampleColumns } from "../_shared/instances.ts";
import { type FeatureVector, type Instance, modeFor, modeFrom, nextInstanceName, parseFeatures } from "../_shared/knn.ts";
import { model } from "../_shared/model.ts";

const text = (v: unknown, max: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);

serve(async (req) => {
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  await requireOwner(deviceId, (await firebaseUser(req)).uid);

  const { data: session, error: sessionError } = await db.from("active_sessions")
    .select("*").eq("event_id", String(body.eventId ?? "")).eq("device_id", deviceId).maybeSingle();
  if (sessionError) throw sessionError;
  if (!session) throw new HttpError(404, "That run has ended or was never reported");
  const features = parseFeatures(session.features);
  if (typeof features === "string") throw new HttpError(500, `Stored features invalid: ${features}`);

  const { data: event, error: eventError } = await db.from("identification_events")
    .select("signal").eq("event_id", session.event_id).maybeSingle();
  if (eventError) throw eventError;
  const parsed = parseSignal(event?.signal);
  const signal: Signal | null = parsed && typeof parsed !== "string" ? parsed : null;

  const instances = await loadInstances(deviceId, session.outlet, model);
  let instance: Instance;
  let source: "confirmed" | "registration";
  if (body.action === "confirm") {
    const found = instances.find((i) => i.id === body.instanceId);
    if (!found) throw new HttpError(404, "Unknown appliance");
    if (found.activeOn) {
      throw new HttpError(409, `${found.name} is running on the other outlet, so this must be a different appliance.`);
    }
    instance = found;
    source = "confirmed";
  } else if (body.action === "register") {
    const typeName = text(body.typeName, 40);
    if (!typeName) throw new HttpError(400, "typeName is required, e.g. Fan");
    // Types are unique per device ignoring case ("fan" is "Fan"): reuse one.
    const { data: types, error: typesError } = await db.from("appliance_types").select("*").eq("device_id", deviceId);
    if (typesError) throw typesError;
    let type = types.find((t) => String(t.name).toLowerCase() === typeName.toLowerCase());
    if (!type) {
      const { data, error } = await db.from("appliance_types")
        .insert({ device_id: deviceId, name: typeName }).select("*").single();
      if (error) throw error;
      type = data;
    }
    const mins = body.maxRuntimeMins == null ? Number(type.default_max_runtime_mins) : Number(body.maxRuntimeMins);
    if (!Number.isInteger(mins) || mins < 1 || mins > 10080) throw new HttpError(400, "maxRuntimeMins must be 1-10080");
    const name = text(body.name, 63) ?? nextInstanceName(typeName, instances.map((i) => i.name));
    const { data: created, error } = await db.from("appliance_instances")
      .insert({ device_id: deviceId, type_id: type.id, name, max_runtime_mins: mins })
      .select("id, name, max_runtime_mins").single();
    if (error?.code === "23505") throw new HttpError(409, `"${name}" already exists; choose another name.`);
    if (error) throw error;
    instance = {
      id: created.id, name: created.name, typeId: type.id, typeName: type.name,
      cutoffS: created.max_runtime_mins * 60, lastOutlet: null, activeOn: null, samples: [],
    };
    source = "registration";
  } else {
    throw new HttpError(400, 'action must be "confirm" or "register"');
  }

  // Same distance as identification: the embedding once the instance's samples have one.
  let mode: number | null;
  if (model && signal && instance.samples.length && canUseEmbedding([instance])) {
    await ensureEmbeddings(deviceId, [instance], model);
    mode = modeFrom(rankEmbedding(embed(model, signal), [instance], model)[0], instance);
  } else {
    mode = modeFor(features as FeatureVector, instance);
  }
  if (mode == null) throw new HttpError(409, `${instance.name} already has 8 modes; edit it in the app first.`);

  const { error: claimError } = await db.from("active_sessions")
    .update({ instance_id: instance.id, state: "CONFIRMED", cutoff_s: instance.cutoffS, reason: "Confirmed by the user" })
    .eq("id", session.id);
  if (claimError?.code === "23505") {
    throw new HttpError(409, `${instance.name} is running on the other outlet, so this must be a different appliance.`);
  }
  if (claimError) throw claimError;

  const extra = session.features as Record<string, unknown>;
  const { data: sample, error: sampleError } = await db.from("signature_samples").insert({
    instance_id: instance.id,
    mode,
    ...sampleColumns(features as FeatureVector),
    window_signal: signal,
    window_s: extra.windowS ?? null,
    readings: extra.readings ?? null,
    source,
    event_id: session.event_id,
  }).select("id").single();
  if (sampleError) throw sampleError;
  if (model && signal) {
    const { error } = await db.from("signature_embeddings").insert({
      sample_id: sample.id, device_id: deviceId, model_version: model.version, embedding: embed(model, signal),
    });
    if (error) throw error;
  }
  const { error: labelError } = await db.from("identification_events")
    .update({ confirmed_instance_id: instance.id, confirmed_mode: mode, confirmed_at: new Date().toISOString() })
    .eq("event_id", session.event_id);
  if (labelError) throw labelError;
  await db.from("appliance_instances")
    .update({ last_outlet: session.outlet, last_seen_at: new Date().toISOString() }).eq("id", instance.id);

  const { count } = await db.from("signature_samples")
    .select("id", { count: "exact", head: true }).eq("instance_id", instance.id);
  return json({
    instance: { id: instance.id, name: instance.name, type: instance.typeName, mode },
    cutoffS: instance.cutoffS,
    sampleCount: count ?? null,
  });
});
