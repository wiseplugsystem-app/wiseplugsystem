// POST /functions/v1/evaluate-safety-alert   (called by the ESP32)
// Rates a safety event against the appliance's adaptive baseline, logs it in
// alert_logs once, and sends a push notification (FCM HTTP v1) to the owner.
// The plug has already acted; this function never switches anything.
//
// Body: { deviceId, outlet, eventId, type, occurredAt (epoch ms), profileId,
//         applianceName, runtimeS, limitS, baselineS, learned, sessionCount,
//         powerW, currentA }
// Auth: x-device-key.
import { deviceIdOf, requireDevice } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { hasServiceAccount, sendPush } from "../_shared/google.ts";
import { HttpError, json, outletOf, readJson, serve } from "../_shared/http.ts";
import { ALERT_TYPES, type AlertType, evaluate } from "../_shared/safety.ts";

const n = (v: unknown, max: number) =>
  typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.min(v, max) : 0;

serve(async (req) => {
  requireDevice(req);
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  const outlet = outletOf(body.outlet);
  const type = body.type as AlertType;
  if (!ALERT_TYPES.includes(type)) throw new HttpError(400, `type must be one of ${ALERT_TYPES}`);
  const eventId = typeof body.eventId === "string" ? body.eventId.slice(0, 120) : "";
  if (!eventId) throw new HttpError(400, "eventId is required");
  const occurredMs = n(body.occurredAt, 4_102_444_800_000);
  if (occurredMs < 1_700_000_000_000) throw new HttpError(400, "occurredAt is before the plug's clock was set");
  const profileId = typeof body.profileId === "string" && body.profileId ? body.profileId.slice(0, 63) : null;
  const applianceName = typeof body.applianceName === "string" && body.applianceName
    ? body.applianceName.slice(0, 63)
    : "Unknown appliance";

  const input = {
    type,
    outlet,
    applianceName,
    runtimeS: n(body.runtimeS, 604800 * 4),
    limitS: n(body.limitS, 604800),
    baselineS: n(body.baselineS, 604800),
    learned: body.learned === true,
    sessionCount: n(body.sessionCount, 1e9),
    powerW: n(body.powerW, 25000),
    currentA: n(body.currentA, 100),
  };
  const result = evaluate(input);

  const { data: device, error: deviceError } = await db.from("devices")
    .update({ last_seen_at: new Date().toISOString() }).eq("id", deviceId).select("owner_uid").maybeSingle();
  if (deviceError) throw deviceError;
  if (!device) throw new HttpError(404, `Unknown device ${deviceId}`);

  let applianceId: string | null = null;
  if (profileId) {
    const { data } = await db.from("appliances").select("id")
      .eq("device_id", deviceId).eq("profile_id", profileId).maybeSingle();
    applianceId = data?.id ?? null;
  }

  // event_id is unique: a retried report is stored and notified only once.
  const { data: logged, error: logError } = await db.from("alert_logs").upsert({
    event_id: eventId,
    device_id: deviceId,
    outlet,
    appliance_id: applianceId,
    profile_id: profileId,
    appliance_name: applianceName,
    alert_type: type,
    severity: result.severity,
    runtime_s: Math.trunc(input.runtimeS),
    limit_s: Math.trunc(input.limitS),
    baseline_s: input.learned ? Math.trunc(input.baselineS) : null,
    baseline_ratio: result.baselineRatio == null ? null : Math.round(result.baselineRatio * 100) / 100,
    power_w: input.powerW,
    current_a: input.currentA,
    message: result.message,
    occurred_at: new Date(occurredMs).toISOString(),
  }, { onConflict: "event_id", ignoreDuplicates: true }).select("id");
  if (logError) throw logError;
  if (!logged.length) return json({ ok: true, duplicate: true, severity: result.severity });

  let notified = 0;
  if (device.owner_uid && hasServiceAccount()) {
    const { data: rows, error } = await db.from("push_tokens").select("token").eq("owner_uid", device.owner_uid);
    if (error) throw error;
    try {
      const push = await sendPush(rows.map((r) => r.token), { title: result.title, body: result.message }, {
        eventId,
        type,
        outlet,
        severity: result.severity,
      });
      notified = push.sent;
      if (push.invalidTokens.length) await db.from("push_tokens").delete().in("token", push.invalidTokens);
    } catch (error) {
      console.error("Push failed; the alert is still logged:", error);
    }
    await db.from("alert_logs").update({ notified_count: notified }).eq("id", logged[0].id);
  }
  return json({ ok: true, severity: result.severity, notified, message: result.message });
});
