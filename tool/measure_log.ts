// Records one outlet's live readings to a CSV file, for the long logs of the
// measurement guide (docs/measurement-guide.md): thermostat cycling of a flat
// iron, rice cooker or refrigerator over about 10 minutes.
//
//   node tool/measure_log.ts --outlet A --minutes 10 --out measurements/logs/iron1_high.csv
//   node tool/measure_log.ts ... --email you@example.com [--device gadget-1]
//
// It reads devices/<device>/live_telemetry/outlet_1|2 from the Firebase
// Realtime Database, which the plug replaces about every 3 s, and keeps each new
// reading once. It signs in as you (the app's e-mail and password, so the
// database rules allow it); the password is typed in and never saved. No
// firmware change: the plug's own per-second readings are not stored anywhere.
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}

const outlet = (arg("outlet") ?? "").toUpperCase();
const minutes = Number(arg("minutes") ?? 10);
const out = arg("out");
const device = arg("device") ?? "gadget-1";
if (!["A", "B"].includes(outlet) || !(minutes > 0) || !out) {
  console.error("Usage: node tool/measure_log.ts --outlet A|B --minutes 10 --out measurements/logs/name.csv [--email you@example.com]");
  process.exit(2);
}

/** The web app's public Firebase settings, from lib/firebase_options.dart. */
function firebaseWeb(): { apiKey: string; databaseURL: string } {
  const src = fs.readFileSync("lib/firebase_options.dart", "utf8");
  const web = src.slice(src.indexOf("FirebaseOptions web"));
  const apiKey = /apiKey:\s*'([^']+)'/.exec(web)?.[1];
  const databaseURL = /databaseURL:\s*'([^']+)'/.exec(web)?.[1];
  if (!apiKey || !databaseURL) throw new Error("Could not read the web settings in lib/firebase_options.dart");
  return { apiKey, databaseURL };
}

function ask(question: string, hidden = false): Promise<string> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  if (hidden) {
    const write = (rl as unknown as { _writeToOutput: (s: string) => void });
    write._writeToOutput = (s: string) => {
      if (s.startsWith(question)) process.stdout.write(question);
      else if (s.includes("\n")) process.stdout.write("\n");
    };
  }
  return new Promise((resolve) => rl.question(question, (a) => { rl.close(); resolve(a.trim()); }));
}

const { apiKey, databaseURL } = firebaseWeb();
const email = arg("email") ?? process.env.WISEPLUG_EMAIL ?? (await ask("App e-mail: "));
const password = process.env.WISEPLUG_PASSWORD ?? (await ask("App password (not shown): ", true));

interface Token { idToken: string; refreshToken: string; expiresAt: number }

async function signIn(): Promise<Token> {
  const res = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${apiKey}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password, returnSecureToken: true }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`Sign-in failed: ${body?.error?.message ?? res.status}`);
  return { idToken: body.idToken, refreshToken: body.refreshToken, expiresAt: Date.now() + Number(body.expiresIn) * 1000 };
}

async function refresh(t: Token): Promise<Token> {
  const res = await fetch(`https://securetoken.googleapis.com/v1/token?key=${apiKey}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: t.refreshToken }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`Could not stay signed in: ${body?.error?.message ?? res.status}`);
  return { idToken: body.id_token, refreshToken: body.refresh_token, expiresAt: Date.now() + Number(body.expires_in) * 1000 };
}

const COLUMNS = ["time_iso", "timestamp_ms", "outlet", "state", "relay_on", "appliance", "status",
  "voltage_v", "current_a", "power_w", "pf", "frequency_hz"];
const cell = (v: unknown) => {
  const s = v == null ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
};

let token = await signIn();
fs.mkdirSync(path.dirname(out), { recursive: true });
const file = fs.createWriteStream(out, { flags: "w" });
file.write(COLUMNS.join(",") + "\n");

const url = () => `${databaseURL}/devices/${device}/live_telemetry/${outlet === "A" ? "outlet_1" : "outlet_2"}.json?auth=${token.idToken}`;
const end = Date.now() + minutes * 60_000;
let last = -1, rows = 0, noSignal = 0;
console.log(`Recording Outlet ${outlet} for ${minutes} min into ${out}. Ctrl+C stops early (the file is kept).`);

while (Date.now() < end) {
  if (token.expiresAt - Date.now() < 5 * 60_000) token = await refresh(token);
  try {
    const res = await fetch(url());
    if (res.status === 401 || res.status === 403) throw new Error("The database refused the reading: is this the plug owner's account?");
    const r = await res.json();
    const ts = Number(r?.timestamp_ms);
    if (r && Number.isFinite(ts) && ts !== last) {
      last = ts;
      if (r.status !== "OK") noSignal++;
      file.write([new Date(ts).toISOString(), ts, outlet, r.state, r.relayOn, r.appliance, r.status,
        r.voltage_V, r.current_A, r.power_W, r.powerFactor, r.frequency_Hz].map(cell).join(",") + "\n");
      rows++;
      if (rows % 20 === 0) console.log(`  ${rows} readings, now ${r.power_W ?? "-"} W`);
    }
  } catch (e) {
    if (String(e).includes("refused")) throw e;
    console.log(`  (no answer: ${(e as Error).message}; retrying)`);
  }
  await new Promise((r) => setTimeout(r, 1000));
}
file.end();
console.log(`Done: ${rows} readings${noSignal ? `, ${noSignal} without a meter signal` : ""}.`);
if (rows < minutes * 10) console.log("Fewer readings than expected (about 20 per minute): check the plug's Wi-Fi.");
