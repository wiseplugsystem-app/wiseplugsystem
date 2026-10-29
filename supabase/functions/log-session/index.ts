// POST /functions/v1/log-session   (called by the ESP32 when a run ends)
// Stores one finished session for outlet_1 or outlet_2 and mirrors the
// firmware's learning state (7-use baseline) onto the appliance profile.
// Idempotent: a retried upload of the same run is ignored.
//
// Body: { deviceId, outlet, profileId, applianceName, startedAt, endedAt (epoch ms),
//         durationS, energyWh, peakCurrentA, peakPowerW, endReason,
//         learning: { sessionCount, learned, baselineS, limitS, countsTowardLearning },
//         signature?: { power, current, powerFactor } }
// Auth: x-device-key.
import { deviceIdOf, requireDevice } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, outletOf, readJson, serve } from "../_shared/http.ts";
import { LEARNING_SESSIONS } from "../_shared/safety.ts";
import { boundsFromBaseline, signatureColumns } from "../_shared/signature.ts";

const END_REASONS = ["APPLIANCE_OFF", "TURNED_OFF", "LOCKED_OUT", "RESET", "ENDED"];

function num(v: unknown, name: string, max: number): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > max) {
    throw new HttpError(400, `${name} must be a number from 0 to ${max}`);
  }
  return v;
}
const time = (v: unknown, name: string) => {
  const ms = num(v, name, 4_102_444_800_000); // year 2100
  if (ms < 1_700_000_000_000) throw new HttpError(400, `${name} is before the plug's clock was set`);
  return new Date(ms).toISOString();
};
const round = (v: number, d: number) => Math.round(v * 10 ** d) / 10 ** d;

serve(async (req) => {
  requireDevice(req);
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  const outlet = outletOf(body.outlet);
  const startedAt = time(body.startedAt, "startedAt");
  const endedAt = time(body.endedAt, "endedAt");
  if (endedAt < startedAt) throw new HttpError(400, "endedAt is before startedAt");
  const endReason = String(body.endReason);
  if (!END_REASONS.includes(endReason)) throw new HttpError(400, `endReason must be one of ${END_REASONS}`);
  const learning = (body.learning ?? {}) as Record<string, unknown>;
  const sessionCount = Math.trunc(num(learning.sessionCount ?? 0, "learning.sessionCount", 1e9));
  const counts = learning.countsTowardLearning === true;
  const profileId = typeof body.profileId === "string" && body.profileId ? body.profileId.slice(0, 63) : null;
  const applianceName = typeof body.applianceName === "string" ? body.applianceName.slice(0, 63) : "Unknown appliance";

  const { data: device, error: deviceError } = await db.from("devices")
    .update({ last_seen_at: new Date().toISOString() }).eq("id", deviceId).select("id").maybeSingle();
  if (deviceError) throw deviceError;
  if (!device) throw new HttpError(404, `Unknown device ${deviceId}; add it to the devices table`);

  // Keep a Postgres copy of the firmware's profile and learning progress.
  let applianceId: string | null = null;
  if (profileId) {
    const learned = learning.learned === true;
    const baseline = learned ? Math.trunc(num(learning.baselineS ?? 0, "learning.baselineS", 604800)) : null;
    const { data: existing, error } = await db.from("appliances").select("id")
      .eq("device_id", deviceId).eq("profile_id", profileId).maybeSingle();
    if (error) throw error;
    if (existing) {
      applianceId = existing.id;
      const { error: updateError } = await db.from("appliances").update({
        name: applianceName,
        session_count: sessionCount,
        is_learned: learned,
        baseline_runtime_s: baseline,
      }).eq("id", existing.id);
      if (updateError) throw updateError;
    } else {
      const sig = (body.signature ?? {}) as Record<string, unknown>;
      const power = Number(sig.power), current = Number(sig.current), pf = Number(sig.powerFactor);
      if (Number.isFinite(power) && Number.isFinite(current)) {
        // The firmware's learned baseline, with the same bands it matches by.
        const bounds = boundsFromBaseline({
          voltage: null,
          power,
          current,
          powerFactor: Number.isFinite(pf) && pf > 0 ? pf : null,
        });
        const limitS = Number(learning.limitS) || 4 * 3600;
        const { data: created, error: insertError } = await db.from("appliances").insert({
          device_id: deviceId,
          profile_id: profileId,
          name: applianceName,
          ...signatureColumns(bounds),
          max_runtime_mins: Math.min(Math.max(Math.ceil(limitS / 60), 1), 10080),
          is_learned: learned,
          session_count: sessionCount,
          baseline_runtime_s: baseline,
          source: "firmware",
        }).select("id").single();
        if (insertError) throw insertError;
        applianceId = created.id;
      }
    }
  }

  const { data: inserted, error: sessionError } = await db.from("sessions").upsert({
    device_id: deviceId,
    outlet,
    appliance_id: applianceId,
    profile_id: profileId,
    appliance_name: applianceName,
    started_at: startedAt,
    ended_at: endedAt,
    duration_s: Math.trunc(num(body.durationS, "durationS", 604800 * 4)),
    energy_wh: round(num(body.energyWh, "energyWh", 1e7), 3),
    peak_current_a: round(num(body.peakCurrentA ?? 0, "peakCurrentA", 100), 3),
    peak_power_w: round(num(body.peakPowerW ?? 0, "peakPowerW", 25000), 2),
    end_reason: endReason,
    counts_toward_learning: counts,
    learning_use: counts ? Math.min(Math.max(sessionCount, 1), LEARNING_SESSIONS) : null,
  }, { onConflict: "device_id,outlet,started_at", ignoreDuplicates: true }).select("id");
  if (sessionError) throw sessionError;

  // The run is over: free its outlet and instance for identify-appliance. A
  // newer run already reported on this outlet (uploads can lag) is kept.
  const { error: endError } = await db.from("active_sessions").delete()
    .eq("device_id", deviceId).eq("outlet", outlet).lte("started_at", endedAt);
  if (endError) throw endError;

  return json({ ok: true, sessionId: inserted[0]?.id ?? null, duplicate: inserted.length === 0 });
});
