// POST /functions/v1/ingest-batch   (called by the ESP32 with stored reports)
//
// The plug keeps its run summaries and safety reports in flash until they
// are stored here (store and forward). After an outage it sends them in
// batches, oldest first, instead of one request (and TLS handshake) each.
// Each report is handed, in order, to the function that already handles that
// kind, so the rules and the duplicate protection stay in one place:
//   log-session            (unique per device, outlet and start time)
//   evaluate-safety-alert  (unique per event_id)
// Processing stops at the first report that should be retried (server error,
// timeout, rate limit), so the plug resends from there and order is kept.
//
// Body: { deviceId, items: [{ id, fn, body }] }   (at most 20 items)
// Auth: x-device-key (passed on to each function).
// Reply: { results: [{ id, status }] }   one per report processed, in order.
import { deviceIdOf, requireDevice } from "../_shared/auth.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";

const FUNCTIONS = ["log-session", "evaluate-safety-alert"];
const MAX_ITEMS = 20;
/** Worth retrying later: the report was not stored. */
export const retryable = (status: number) => status >= 500 || status === 408 || status === 429;

serve(async (req) => {
  requireDevice(req);
  const body = await readJson(req);
  const deviceId = deviceIdOf(body.deviceId);
  if (!Array.isArray(body.items) || body.items.length > MAX_ITEMS) {
    throw new HttpError(400, `items must be a list of at most ${MAX_ITEMS} reports`);
  }
  const base = Deno.env.get("SUPABASE_URL");
  if (!base) throw new HttpError(500, "SUPABASE_URL is not set");
  const results: { id: string; status: number }[] = [];
  for (const raw of body.items as Record<string, unknown>[]) {
    const id = typeof raw?.id === "string" ? raw.id.slice(0, 64) : "";
    const fn = String(raw?.fn ?? "");
    const item = raw?.body;
    if (!FUNCTIONS.includes(fn) || !item || typeof item !== "object" || Array.isArray(item) ||
        (item as Record<string, unknown>).deviceId !== deviceId) {
      results.push({ id, status: 400 });  // malformed: the plug drops it
      continue;
    }
    let status: number;
    try {
      const res = await fetch(`${base}/functions/v1/${fn}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-device-key": req.headers.get("x-device-key") ?? "" },
        body: JSON.stringify(item),
      });
      status = res.status;
      await res.body?.cancel();
    } catch {
      status = 503;
    }
    results.push({ id, status });
    if (retryable(status)) break;  // keep the order: the plug resends from here
  }
  return json({ results });
});
