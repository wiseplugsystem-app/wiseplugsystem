// POST /functions/v1/link-account   (called by the app once after sign-in)
// Single login: Firebase Auth is the only account system. This function
//  1. gives the Firebase user the `role: "authenticated"` claim that
//     Supabase third-party auth needs before RLS lets them read their data;
//  2. claims the device for this user if nobody owns it yet (first owner wins,
//     like the app's claimDevice() in Firebase).
// Reply `refreshToken: true` means: call getIdToken(true) to pick up the claim.
//
// Body: { deviceId }   Auth: Authorization: Bearer <Firebase ID token>.
import { deviceIdOf, firebaseUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { setCustomClaims } from "../_shared/google.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";

serve(async (req) => {
  const { uid, claims } = await firebaseUser(req);
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId ?? "gadget-1");

  const { error: claimError } = await db.from("devices").update({ owner_uid: uid })
    .eq("id", deviceId).is("owner_uid", null);
  if (claimError) throw claimError;
  const { data: device, error } = await db.from("devices").select("owner_uid").eq("id", deviceId).maybeSingle();
  if (error) throw error;
  if (!device) throw new HttpError(404, `Unknown device ${deviceId}`);
  if (device.owner_uid !== uid) throw new HttpError(403, "This WisePlug belongs to another account");

  let refreshToken = false;
  if (claims.role !== "authenticated") {
    await setCustomClaims(uid, { role: "authenticated" });
    refreshToken = true;
  }
  return json({ ok: true, deviceId, refreshToken });
});
