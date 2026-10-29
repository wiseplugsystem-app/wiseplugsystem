// Google APIs with the Firebase service account: the JSON key from Firebase
// console > Project settings > Service accounts, stored as the secret
// FIREBASE_SERVICE_ACCOUNT_B64 (base64, survives any shell) or
// FIREBASE_SERVICE_ACCOUNT (raw JSON).
// Works on the free Spark plan: FCM and Firebase Auth admin calls are free.
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

function rawServiceAccount(): string | undefined {
  const b64 = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_B64");
  if (b64) return new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));
  return Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
}

let account: ServiceAccount | null = null;
function serviceAccount(): ServiceAccount {
  if (account) return account;
  const raw = rawServiceAccount();
  if (!raw) throw new Error("FIREBASE_SERVICE_ACCOUNT_B64 secret is not set");
  const parsed = JSON.parse(raw) as ServiceAccount;
  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    throw new Error("FIREBASE_SERVICE_ACCOUNT is not a service-account JSON key");
  }
  return (account = parsed);
}

export const hasServiceAccount = () => !!rawServiceAccount();

const tokens = new Map<string, { token: string; expires: number }>();

/** OAuth 2.0 access token for [scope] (cached until a minute before expiry). */
async function accessToken(scope: string): Promise<string> {
  const cached = tokens.get(scope);
  if (cached && cached.expires > Date.now()) return cached.token;
  const sa = serviceAccount();
  const key = await importPKCS8(sa.private_key, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new SignJWT({ scope })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw new Error(`Google token request failed: ${res.status} ${await res.text()}`);
  const { access_token, expires_in } = await res.json();
  tokens.set(scope, { token: access_token, expires: Date.now() + (expires_in - 60) * 1000 });
  return access_token;
}

export interface PushResult {
  sent: number;
  invalidTokens: string[];
}

/** Sends one notification to each token with the FCM HTTP v1 API. */
export async function sendPush(
  deviceTokens: string[],
  notification: { title: string; body: string },
  data: Record<string, string>,
): Promise<PushResult> {
  const result: PushResult = { sent: 0, invalidTokens: [] };
  if (!deviceTokens.length) return result;
  const bearer = await accessToken("https://www.googleapis.com/auth/firebase.messaging");
  const url = `https://fcm.googleapis.com/v1/projects/${serviceAccount().project_id}/messages:send`;
  await Promise.all(deviceTokens.map(async (token) => {
    const res = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token,
          notification,
          data,
          android: { priority: "HIGH", notification: { sound: "default", tag: data.eventId } },
          apns: { headers: { "apns-priority": "10" }, payload: { aps: { sound: "default" } } },
        },
      }),
    });
    if (res.ok) {
      result.sent++;
      return;
    }
    const text = await res.text();
    // Uninstalled app or garbage token: remove it so it is not retried.
    if (res.status === 404 || text.includes("UNREGISTERED") ||
        (res.status === 400 && text.includes("registration token"))) {
      result.invalidTokens.push(token);
    } else {
      console.error(`FCM ${res.status}: ${text}`);
    }
  }));
  return result;
}

/**
 * Replaces the user's Firebase custom claims. Supabase third-party auth needs
 * `role: "authenticated"` in the Firebase ID token for RLS to apply.
 */
export async function setCustomClaims(uid: string, claims: Record<string, unknown>): Promise<void> {
  const bearer = await accessToken("https://www.googleapis.com/auth/identitytoolkit");
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/projects/${serviceAccount().project_id}/accounts:update`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
      body: JSON.stringify({ localId: uid, customAttributes: JSON.stringify(claims) }),
    },
  );
  if (!res.ok) throw new Error(`Setting custom claims failed: ${res.status} ${await res.text()}`);
}
