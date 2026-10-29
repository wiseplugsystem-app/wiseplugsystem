// POST /functions/v1/identify-appliance   (called by the ESP32 once per run)
//
// The plug sends the first 32 readings (signal) and a steady-state summary
// (features) of a load that just started on outlet_1 or outlet_2. With a
// trained model (_shared/model.ts) and every instance having a recorded signal,
// the signal's CNN embedding is matched (_shared/embedder.ts); otherwise the
// features are, with k-NN (_shared/knn.ts). Either way, open set:
//   CONFIDENT  -> labelled, the instance's own cutoff applies
//   AMBIGUOUS  -> the app asks the user to pick a candidate or register new
//   UNKNOWN    -> the app asks the user to register a new appliance
// Instances running on the other outlet are excluded (outlet exclusivity;
// also enforced by a unique key on active_sessions.instance_id). Until the
// user confirms, AMBIGUOUS and UNKNOWN loads use the conservative 30 min cutoff.
//
// Every decision is logged in identification_events (evaluation, training data).
//
// Body: { deviceId, outlet, eventId, startedAt (epoch ms), windowS?, readings?,
//         features: { power, current, pf?, reactive?, cv?, peakRatio? },
//         signal?: { power: [W], current: [A], pf: [] }   (1 per second from switch-on) }
// Auth: x-device-key. Idempotent per eventId.
// Reply: { outcome, cutoffS, instance | null, candidates: [{ id, name, distance }],
//          suggested | null, registerAs | null, reason }
import { deviceIdOf, requireDevice } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, outletOf, readJson, serve } from "../_shared/http.ts";
import { canUseEmbedding, embed, parseSignal, rankEmbedding } from "../_shared/embedder.ts";
import { ensureEmbeddings, loadInstances } from "../_shared/instances.ts";
import {
  CONSERVATIVE_CUTOFF_S,
  decide,
  type Identification,
  parseFeatures,
  rank,
  type Scored,
  TIE_MARGIN,
} from "../_shared/knn.ts";
import { model } from "../_shared/model.ts";

const brief = (s: Scored) => ({
  id: s.instance.id,
  name: s.instance.name,
  type: s.instance.typeName,
  distance: Math.round(s.distance * 100) / 100,
});

function reply(row: Record<string, unknown>) {
  return {
    eventId: row.event_id,
    outcome: row.state,
    cutoffS: row.cutoff_s,
    instanceId: row.instance_id,
    ...(row.candidates as Record<string, unknown>),
    reason: row.reason,
  };
}

serve(async (req) => {
  requireDevice(req);
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  const outlet = outletOf(body.outlet);
  const eventId = typeof body.eventId === "string" && /^[A-Za-z0-9_-]{1,88}$/.test(body.eventId)
    ? body.eventId
    : null;
  if (!eventId) throw new HttpError(400, "eventId must match [A-Za-z0-9_-]{1,88}");
  const startedAt = Number(body.startedAt);
  if (!Number.isFinite(startedAt) || startedAt < 1_700_000_000_000) {
    throw new HttpError(400, "startedAt must be epoch ms after the plug's clock was set");
  }
  const features = parseFeatures(body.features);
  if (typeof features === "string") throw new HttpError(400, features);
  const signal = parseSignal(body.signal);
  if (typeof signal === "string") throw new HttpError(400, signal);

  // A retried upload gets the answer it already got.
  const { data: existing, error: existingError } = await db.from("active_sessions")
    .select("*").eq("event_id", eventId).maybeSingle();
  if (existingError) throw existingError;
  if (existing) return json(reply(existing));

  // A new run on this outlet means the previous one there has ended.
  const instances = await loadInstances(deviceId, outlet, model);
  let ranking: Scored[], tieMargin = TIE_MARGIN, modelVersion: string | null = null;
  if (model && signal && canUseEmbedding(instances)) {
    await ensureEmbeddings(deviceId, instances, model);
    ranking = rankEmbedding(embed(model, signal), instances, model);
    tieMargin = model.thresholds.tieMargin;
    modelVersion = model.version;
  } else {
    ranking = rank(features, instances);
  }
  let result: Identification = decide(ranking, outlet, tieMargin);
  const method = modelVersion ? "embedding" : "features";

  const row = (r: Identification) => ({
    device_id: deviceId,
    outlet,
    event_id: eventId,
    instance_id: r.match?.instance.id ?? null,
    state: r.outcome,
    cutoff_s: r.cutoffS,
    features: { ...features, windowS: body.windowS ?? null, readings: body.readings ?? null },
    candidates: {
      instance: r.match ? brief(r.match) : null,
      candidates: r.candidates.map(brief),
      suggested: r.suggested ? brief(r.suggested) : null,
      registerAs: r.registerAs,
      method,
    },
    suggestion: r.registerAs,
    reason: r.reason,
    started_at: new Date(startedAt).toISOString(),
  });

  const { error: clearError } = await db.from("active_sessions").delete().eq("device_id", deviceId).eq("outlet", outlet);
  if (clearError) throw clearError;
  let { data: saved, error } = await db.from("active_sessions").insert(row(result)).select("*").single();
  if (error?.code === "23505" && result.match) {
    // Raced with the other outlet claiming the same instance: do not guess.
    result = {
      ...result,
      outcome: "AMBIGUOUS",
      suggested: result.match,
      match: null,
      cutoffS: CONSERVATIVE_CUTOFF_S,
      reason: `${result.match.instance.name} was just claimed by the other outlet.`,
    };
    ({ data: saved, error } = await db.from("active_sessions").insert(row(result)).select("*").single());
  }
  if (error) throw error;

  // The permanent record (active_sessions rows go when the run ends).
  const { error: logError } = await db.from("identification_events").upsert({
    event_id: eventId,
    device_id: deviceId,
    outlet,
    started_at: new Date(startedAt).toISOString(),
    signal,
    features,
    method,
    model_version: modelVersion,
    outcome: result.outcome,
    instance_id: result.match?.instance.id ?? null,
    nearest_instance_id: ranking[0]?.instance.id ?? null,
    nearest_distance: ranking[0] ? Math.round(ranking[0].distance * 1e4) / 1e4 : null,
    candidates: saved!.candidates,
  }, { onConflict: "event_id", ignoreDuplicates: true });
  if (logError) throw logError;

  if (result.match) {
    const { error: seenError } = await db.from("appliance_instances")
      .update({ last_outlet: outlet, last_seen_at: new Date().toISOString() }).eq("id", result.match.instance.id);
    if (seenError) throw seenError;
  }
  return json(reply(saved!), 201);
});
