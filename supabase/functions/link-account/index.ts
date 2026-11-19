// POST /functions/v1/link-account   (called by the app once after sign-in)
// Single login: Firebase Auth is the only account system. This function
//  1. gives the Firebase user the `role: "authenticated"` claim that
//     Supabase third-party auth needs before RLS lets them read their data;
//  2. claims the device for this user if nobody owns it yet (first owner wins,
//     like the app's claimDevice() in Firebase).
// Reply `refreshToken: true` means: call getIdToken(true) to pick up the claim.
//
// Binding only when near: in Firebase the plug is claimed with a pairing code
// it gives only over its local network (database.rules.json). Firebase is the
// source of truth here: with FIREBASE_DATABASE_URL set, this reads
// device_owners with the user's own token, and the Firebase owner becomes the
// owner here too (this also replaces an owner whose account was deleted).
// Without FIREBASE_DATABASE_URL, the old "first owner wins" applies.
//
// Body: { deviceId }   Auth: Authorization: Bearer <Firebase ID token>.
// Body: { deviceId, release: true }: the owner releases the plug (account
// deletion), so the next owner can pair with it.
import { deviceIdOf, firebaseUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { setCustomClaims } from "../_shared/google.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";

/** Whether [uid] owns the plug in Firebase (null: cannot tell, e.g. not configured). */
async function ownsInFirebase(req: Request, uid: string): Promise<boolean | null> {
  const base = Deno.env.get("FIREBASE_DATABASE_URL");
  const token = /^Bearer (.+)$/.exec(req.headers.get("authorization") ?? "")?.[1];
  if (!base || !token) return null;
  try {
    const res = await fetch(`${base.replace(/\/+$/, "")}/device_owners.json?auth=${encodeURIComponent(token)}`);
    if (res.status === 401 || res.status === 403) return false;  // the rules: not the owner
    if (!res.ok) return null;
    const owners = await res.json() as Record<string, unknown> | null;
    return owners?.outlet_A === uid && owners?.outlet_B === uid;
  } catch {
    return null;
  }
}

serve(async (req) => {
  const { uid, claims } = await firebaseUser(req);
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId ?? "gadget-1");

  // Account deletion: the owner lets the plug go (nobody else can).
  if (body.release === true) {
    const { error } = await db.from("devices").update({ owner_uid: null })
      .eq("id", deviceId).eq("owner_uid", uid);
    if (error) throw error;
    return json({ ok: true, deviceId, released: true });
  }

  const firebaseOwner = await ownsInFirebase(req, uid);
  if (firebaseOwner === true) {
    // Paired (near the plug) in Firebase: the owner here too.
    const { error } = await db.from("devices").update({ owner_uid: uid }).eq("id", deviceId);
    if (error) throw error;
  } else if (firebaseOwner === null) {
    // Cannot check Firebase: as before, the first owner wins.
    const { error: claimError } = await db.from("devices").update({ owner_uid: uid })
      .eq("id", deviceId).is("owner_uid", null);
    if (claimError) throw claimError;
  }
  const { data: device, error } = await db.from("devices").select("owner_uid").eq("id", deviceId).maybeSingle();
  if (error) throw error;
  if (!device) throw new HttpError(404, `Unknown device ${deviceId}`);
  if (device.owner_uid === null && firebaseOwner === false) {
    throw new HttpError(403, "Pair with the WisePlug first: stand near it and tap Pair in the app");
  }
  if (device.owner_uid !== uid) throw new HttpError(403, "This WisePlug belongs to another account");

  let refreshToken = false;
  if (claims.role !== "authenticated") {
    await setCustomClaims(uid, { role: "authenticated" });
    refreshToken = true;
  }
  return json({ ok: true, deviceId, refreshToken });
});
