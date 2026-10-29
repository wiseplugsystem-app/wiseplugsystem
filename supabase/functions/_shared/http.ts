// Small HTTP helpers shared by the Edge Functions.

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-device-key, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export class HttpError extends Error {
  constructor(public status: number, message: string, public details: Record<string, unknown> = {}) {
    super(message);
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > 16_384) throw new HttpError(413, "Body too large");
  try {
    const value = JSON.parse(text);
    if (value && typeof value === "object" && !Array.isArray(value)) return value;
  } catch { /* fall through */ }
  throw new HttpError(400, "Body must be a JSON object");
}

/** Wraps a handler with CORS preflight, POST-only and uniform error replies. */
export function serve(handler: (req: Request) => Promise<Response>) {
  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
    if (req.method !== "POST") return json({ error: "Use POST" }, 405);
    try {
      return await handler(req);
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.message, ...error.details }, error.status);
      console.error(error);
      return json({ error: "Internal error" }, 500);
    }
  });
}

export const OUTLETS = ["outlet_1", "outlet_2"] as const;
export type Outlet = (typeof OUTLETS)[number];

export function outletOf(v: unknown): Outlet {
  if (v === "outlet_1" || v === "outlet_2") return v;
  throw new HttpError(400, "outlet must be outlet_1 or outlet_2");
}
