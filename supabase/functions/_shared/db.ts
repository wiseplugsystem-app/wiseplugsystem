// Service-role client: bypasses RLS, so it is only used inside Edge
// Functions after the caller has been checked. Both values are provided to
// every Edge Function by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

export const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
