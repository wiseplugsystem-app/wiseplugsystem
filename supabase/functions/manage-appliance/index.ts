// POST /functions/v1/manage-appliance   (called by the app)
//
// Changes one of the user's registered appliances:
//   { action: "rename", applianceId, name }   "Fan 2" -> "Bedroom fan"
//   { action: "change-type", applianceId, typeName, iconKey? }
//                                             "Other" -> "Flat iron"
//   { action: "delete", applianceId }         forget the appliance
// The safe time and the modes are set by the system only (the type's
// default, the 7-use learning, and modes added by confirm-match). A new type
// brings its own safe time (heating types are shorter); its fingerprint and
// learned uses are kept.
//
// An appliance that is running now (an open outlet session) cannot be
// deleted or change its type: switch it off first.
//
// Body: { deviceId, action, applianceId, ... }
// Auth: Authorization: Bearer <Firebase ID token> of the plug's owner, who must
// also own the appliance.
// Reply: { ok: true }
import { deviceIdOf, firebaseUser, requireOwner } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { findOrCreateType, iconKeyOf } from "../_shared/recognition_db.ts";

const text = (v: unknown, max: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);

serve(async (req) => {
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  const uid = (await firebaseUser(req)).uid;
  await requireOwner(deviceId, uid);

  const { data: appliance, error } = await db.from("appliance_instances")
    .select("id, name").eq("id", String(body.applianceId ?? "")).eq("owner_uid", uid).maybeSingle();
  if (error) throw error;
  if (!appliance) throw new HttpError(404, "Unknown appliance");

  const { data: open, error: runningError } = await db.from("outlet_sessions")
    .select("id, outlet").eq("appliance_id", appliance.id).is("ended_at", null).maybeSingle();
  if (runningError) throw runningError;
  // A run whose end never arrived (the plug restarted or was offline) stays
  // open here although nothing is plugged in. The app sends the outlets the
  // online plug shows with nothing running ("idleOutlets"); such a run is
  // closed as NOT_RUNNING, as recognize-appliance does. Safety is not
  // affected: the plug times and cuts off its outlets by itself.
  const idle = Array.isArray(body.idleOutlets) ? body.idleOutlets.map(String) : [];
  let running = open;
  if (open && idle.includes(open.outlet)) {
    const { error: e } = await db.from("outlet_sessions")
      .update({ ended_at: new Date().toISOString(), end_reason: "NOT_RUNNING" })
      .eq("id", open.id).is("ended_at", null);
    if (e) throw e;
    running = null;
  }
  const busy = () => {
    throw new HttpError(409, `${appliance.name} is running now; switch it off or unplug it first.`);
  };

  switch (body.action) {
    case "rename": {
      const name = text(body.name, 63);
      if (!name) throw new HttpError(400, "name is required");
      const { error: e } = await db.from("appliance_instances").update({ name }).eq("id", appliance.id);
      if (e?.code === "23505") throw new HttpError(409, `"${name}" already exists; choose another name.`);
      if (e) throw e;
      break;
    }
    case "change-type": {
      if (running) busy();
      const typeName = text(body.typeName, 40);
      if (!typeName) throw new HttpError(400, "typeName is required, e.g. Fan");
      const type = await findOrCreateType(deviceId, uid, typeName, iconKeyOf(body.iconKey));
      // The new type's safe time (the database caps a heating type's).
      const { error: e } = await db.from("appliance_instances")
        .update({ type_id: type.id, max_runtime_mins: Number(type.default_max_runtime_mins) })
        .eq("id", appliance.id);
      if (e) throw e;
      break;
    }
    case "delete": {
      if (running) busy();
      // Its modes and samples go with it (on delete cascade).
      const { error: d } = await db.from("appliance_instances").delete().eq("id", appliance.id);
      if (d) throw d;
      break;
    }
    default:
      throw new HttpError(400, 'action must be "rename", "change-type" or "delete"');
  }
  return json({ ok: true });
});
