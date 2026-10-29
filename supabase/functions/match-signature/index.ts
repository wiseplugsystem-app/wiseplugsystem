// POST /functions/v1/match-signature
//
// Identifies the appliance on outlet_1 or outlet_2 from one live PZEM-004T
// reading. Profiles belong to the device, not to an outlet, so a reading from
// either socket is compared with every profile of that device.
//
// Algorithm (_shared/signature.ts):
//  1. Filter: live P, I and PF must lie inside the profile's bounds
//     (plus small offsets for meter accuracy).
//  2. Score: weighted similarity P 40 %, I 30 %, PF 20 %, Q 10 %.
//  3. Cutoff: the best profile counts only at >= 88 % confidence
//     (MATCH_THRESHOLD secret, 0..1); otherwise `unrecognized_device`.
//
// Body: { deviceId, outlet?, voltage?, power, current, powerFactor?,
//         register?: { name, applianceType?, profileId?, maxRuntimeMins? } }
//   With `register`, a new profile is saved only when the reading is
//   unrecognized; a confident match is refused as a duplicate (409).
// Auth: x-device-key (ESP32) or Authorization: Bearer <Firebase ID token>.
//
// Reply: { status: matched | learning | unrecognized_device | registered | duplicate,
//          outlet, confidence (0-100), threshold (0-100), appliance | null,
//          scores: { power, current, pf, reactive }, reading: { apparentPower, reactivePower },
//          candidates: [{ id, name, confidence }] }
import { deviceIdOf, firebaseUser, isDevice, requireOwner } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, outletOf, readJson, serve } from "../_shared/http.ts";
import { LEARNING_SESSIONS } from "../_shared/safety.ts";
import {
  boundsFromBaseline,
  DEFAULT_THRESHOLD,
  matchSignature,
  parseReading,
  type Ranked,
  type Score,
  signatureColumns,
  signatureFromRow,
} from "../_shared/signature.ts";

type Row = Record<string, unknown>;
interface ProfileCandidate {
  id: string;
  row: Row;
  signature: ReturnType<typeof signatureFromRow>;
}

const pct = (v: number) => Math.round(v * 1000) / 10;

function threshold(): number {
  const t = Number(Deno.env.get("MATCH_THRESHOLD"));
  return Number.isFinite(t) && t > 0 && t <= 1 ? t : DEFAULT_THRESHOLD;
}

/** The ApplianceProfile returned to clients. */
function profile(row: Row) {
  const sig = signatureFromRow(row);
  const sessions = Number(row.session_count ?? 0);
  const learned = row.is_learned === true;
  return {
    id: row.id,
    profileId: row.profile_id,
    name: row.name,
    applianceType: row.appliance_type,
    maxRuntimeMins: row.max_runtime_mins,
    signature: {
      power: sig.power,
      current: sig.current,
      powerFactor: sig.pf,
      apparentPower: sig.apparent,
      reactivePower: sig.reactive,
    },
    learning: {
      learned,
      sessionCount: sessions,
      required: LEARNING_SESSIONS,
      usesLeft: learned ? 0 : Math.max(LEARNING_SESSIONS - sessions, 0),
      baselineRuntimeS: row.baseline_runtime_s,
    },
  };
}

function scores(s: Score | undefined) {
  if (!s) return null;
  const r = (v: number | null) => (v == null ? null : pct(v));
  return { power: r(s.axes.power), current: r(s.axes.current), pf: r(s.axes.pf), reactive: r(s.axes.reactive) };
}

serve(async (req) => {
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  const outlet = body.outlet == null ? null : outletOf(body.outlet);
  if (!isDevice(req)) await requireOwner(deviceId, (await firebaseUser(req)).uid);

  const reading = parseReading(body);
  if (typeof reading === "string") throw new HttpError(400, reading);

  // Every profile of the device, whichever outlet it was calibrated on.
  const { data: rows, error } = await db.from("appliances").select("*").eq("device_id", deviceId);
  if (error) throw error;
  const candidates: ProfileCandidate[] = rows.map((row) => ({
    id: String(row.id),
    row,
    signature: signatureFromRow(row),
  }));

  const result = matchSignature(reading, candidates, threshold());
  const top: Ranked<ProfileCandidate> | null = result.match ?? result.best;
  const triangle = top
    ? { apparentPower: top.score.apparentPower, reactivePower: top.score.reactivePower }
    : null;
  const reply = {
    outlet,
    threshold: pct(result.threshold),
    confidence: top ? pct(top.score.confidence) : 0,
    scores: scores(top?.score),
    reading: triangle,
    candidates: result.ranked.slice(0, 3).map((c) => ({
      id: c.item.id,
      name: c.item.row.name,
      confidence: pct(c.score.confidence),
    })),
  };

  const register = body.register as Row | undefined;
  if (result.match) {
    const appliance = profile(result.match.item.row);
    if (register) {
      return json({
        ...reply,
        status: "duplicate",
        message: `This reading is ${reply.confidence}% "${appliance.name}"; not saved again.`,
        appliance,
      }, 409);
    }
    return json({ ...reply, status: appliance.learning.learned ? "matched" : "learning", appliance });
  }

  if (!register) {
    return json({
      ...reply,
      status: "unrecognized_device",
      message: result.best
        ? `Closest profile "${result.best.item.row.name}" is only ${reply.confidence}% similar.`
        : "No saved profile has these readings.",
      appliance: null,
    });
  }

  // Unrecognized and asked to register: save a new profile from this reading.
  const name = typeof register.name === "string" ? register.name.trim() : "";
  if (!name || name.length > 63) throw new HttpError(400, "register.name must be 1-63 characters");
  const applianceType = typeof register.applianceType === "string" ? register.applianceType.slice(0, 40) : "Other";
  const profileId = register.profileId == null ? null : String(register.profileId);
  if (profileId != null && !/^[A-Za-z0-9_-]{1,63}$/.test(profileId)) {
    throw new HttpError(400, "register.profileId must match [A-Za-z0-9_-]{1,63}");
  }
  const maxRuntimeMins = register.maxRuntimeMins == null ? 240 : Number(register.maxRuntimeMins);
  if (!Number.isInteger(maxRuntimeMins) || maxRuntimeMins < 1 || maxRuntimeMins > 10080) {
    throw new HttpError(400, "register.maxRuntimeMins must be 1-10080");
  }
  const { data: created, error: insertError } = await db.from("appliances").insert({
    device_id: deviceId,
    profile_id: profileId,
    name,
    appliance_type: applianceType,
    ...signatureColumns(boundsFromBaseline(reading)),
    max_runtime_mins: maxRuntimeMins,
    source: "registered",
  }).select("*").single();
  if (insertError) {
    if (insertError.code === "23505") throw new HttpError(409, "That profileId is already saved");
    throw insertError;
  }
  return json({ ...reply, status: "registered", appliance: profile(created) }, 201);
});
