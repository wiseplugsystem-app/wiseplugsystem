// Which open runs of a plug have really ended, though their end was never
// reported (the upload was lost, or the plug restarted mid-run). A run left
// open keeps its appliance "in use" there, and outlet exclusivity would then
// refuse that appliance on the other outlet.
//
// Event IDs are "{boot}_{outlet_A|outlet_B}_{start}"; {boot} is new on every
// start of the plug.

export interface OpenRun {
  id: string;
  event_id: string;
  outlet: string;
}

export type StaleReason = "SUPERSEDED" | "REBOOT" | "NOT_RUNNING";

export const bootOf = (eventId: string): string => eventId.split("_")[0];

/**
 * The open runs of the plug that sent [eventId] on [outlet] that have ended:
 * an earlier run on the same outlet, a run from before the plug restarted,
 * and (when the plug lists its running runs) any run it no longer runs.
 */
export function staleRuns(
  open: OpenRun[],
  current: { eventId: string; outlet: string; running?: string[] | null },
): { id: string; reason: StaleReason }[] {
  const boot = bootOf(current.eventId);
  const out: { id: string; reason: StaleReason }[] = [];
  for (const r of open) {
    if (r.event_id === current.eventId) continue;
    if (r.outlet === current.outlet) out.push({ id: r.id, reason: "SUPERSEDED" });
    else if (bootOf(r.event_id) !== boot) out.push({ id: r.id, reason: "REBOOT" });
    else if (current.running && !current.running.includes(r.event_id)) out.push({ id: r.id, reason: "NOT_RUNNING" });
  }
  return out;
}

/** The plug's optional list of event IDs it is running now. */
export function parseRunning(v: unknown): string[] | null {
  if (!Array.isArray(v)) return null;
  return v.filter((x): x is string => typeof x === "string").slice(0, 8);
}
