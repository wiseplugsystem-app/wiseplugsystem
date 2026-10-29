// POST /functions/v1/manage-appliance   (called by the app)
//
// Changes one of the user's registered appliances:
//   { action: "rename",     applianceId, name }            "Fan 2" -> "Bedroom fan"
//   { action: "setCutoff",  applianceId, cutoffMinutes }   its safe operating time
//   { action: "deleteMode", applianceId, profileId }       forget one mode ("High")
//   { action: "delete",     applianceId }                  forget the appliance
// Adding a mode is a registration: register-sample with a new modeName.
//
// An appliance that is running now (an open outlet session) cannot be deleted,
// and neither can its last mode: switch it off first.
//
// Body: { deviceId, action, applianceId, ... }
// Auth: Authorization: Bearer <Firebase ID token> of the plug's owner, who must
// also own the appliance.
// Reply: { ok: true }
import { deviceIdOf, firebaseUser, requireOwner } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";

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

  const { data: running, error: runningError } = await db.from("outlet_sessions")
    .select("outlet").eq("appliance_id", appliance.id).is("ended_at", null).maybeSingle();
  if (runningError) throw runningError;
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
    case "setCutoff": {
      const minutes = Number(body.cutoffMinutes);
      if (!Number.isInteger(minutes) || minutes < 1 || minutes > 10080) {
        throw new HttpError(400, "cutoffMinutes must be a whole number from 1 to 10080");
      }
      // Applies from its next confirmed run; a run in progress keeps its cutoff.
      const { error: e } = await db.from("appliance_instances").update({ max_runtime_mins: minutes }).eq("id", appliance.id);
      if (e) throw e;
      break;
    }
    case "deleteMode": {
      if (running) busy();
      const { data: modes, error: e } = await db.from("appliance_profiles")
        .select("id").eq("appliance_id", appliance.id);
      if (e) throw e;
      if (!modes.some((m) => m.id === body.profileId)) throw new HttpError(404, "Unknown mode");
      if (modes.length === 1) throw new HttpError(409, "This is its only mode; delete the appliance instead.");
      const { error: d } = await db.from("appliance_profiles").delete().eq("id", body.profileId);
      if (d) throw d;
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
      throw new HttpError(400, 'action must be "rename", "setCutoff", "deleteMode" or "delete"');
  }
  return json({ ok: true });
});
