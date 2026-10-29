// Who is calling: the ESP32 (shared device key) or an app user (Firebase ID
// token, verified against Google's public keys; no Supabase login needed).
import { createRemoteJWKSet, type JWTPayload, jwtVerify } from "npm:jose@5.9.6";
import { db } from "./db.ts";
import { HttpError } from "./http.ts";

export const firebaseProjectId = () => Deno.env.get("FIREBASE_PROJECT_ID") ?? "wise-46f92";

const googleKeys = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** True when the request carries the correct device key; throws on a wrong one. */
export function isDevice(req: Request): boolean {
  const given = req.headers.get("x-device-key");
  if (given == null) return false;
  const expected = Deno.env.get("DEVICE_KEY");
  if (!expected) throw new HttpError(503, "DEVICE_KEY secret is not set");
  if (!sameSecret(expected, given)) throw new HttpError(401, "Invalid device key");
  return true;
}

export function requireDevice(req: Request): void {
  if (!isDevice(req)) throw new HttpError(401, "Missing x-device-key");
}

export interface FirebaseUser {
  uid: string;
  claims: JWTPayload;
}

/** Verifies `Authorization: Bearer <Firebase ID token>`. */
export async function firebaseUser(req: Request): Promise<FirebaseUser> {
  const token = /^Bearer (.+)$/.exec(req.headers.get("authorization") ?? "")?.[1];
  if (!token) throw new HttpError(401, "Sign in first");
  const project = firebaseProjectId();
  try {
    const { payload } = await jwtVerify(token, googleKeys, {
      issuer: `https://securetoken.google.com/${project}`,
      audience: project,
    });
    if (!payload.sub) throw new Error("no subject");
    return { uid: payload.sub, claims: payload };
  } catch {
    throw new HttpError(401, "Invalid or expired Firebase ID token");
  }
}

/** Throws unless [uid] owns [deviceId] in Postgres. */
export async function requireOwner(deviceId: string, uid: string): Promise<void> {
  const { data, error } = await db.from("devices").select("owner_uid").eq("id", deviceId).maybeSingle();
  if (error) throw error;
  if (!data) throw new HttpError(404, `Unknown device ${deviceId}`);
  if (data.owner_uid !== uid) throw new HttpError(403, "This account does not own the device");
}

export function deviceIdOf(v: unknown): string {
  if (typeof v === "string" && /^[a-z0-9-]{1,32}$/.test(v)) return v;
  throw new HttpError(400, "deviceId is required, e.g. gadget-1");
}
