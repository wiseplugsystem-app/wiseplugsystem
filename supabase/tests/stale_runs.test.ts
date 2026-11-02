// Run with: node --test supabase/tests/stale_runs.test.ts
import assert from "node:assert/strict";
import test from "node:test";
import { parseRunning, staleRuns } from "../functions/_shared/stale_runs.ts";

const run = (id: string, event_id: string, outlet: string) => ({ id, event_id, outlet });

test("a fan left open on A (lost end report) frees up when it is plugged into B", () => {
  const open = [run("1", "boot1_outlet_A_100", "outlet_1")];
  // Same boot, the plug says only B is running: A's run has ended.
  assert.deepEqual(
    staleRuns(open, { eventId: "boot1_outlet_B_900", outlet: "outlet_2", running: ["boot1_outlet_B_900"] }),
    [{ id: "1", reason: "NOT_RUNNING" }],
  );
  // The plug restarted since: A's run is from the old boot.
  assert.deepEqual(staleRuns(open, { eventId: "boot2_outlet_B_50", outlet: "outlet_2" }), [{ id: "1", reason: "REBOOT" }]);
});

test("a run still going on the other outlet stays open", () => {
  const open = [run("1", "boot1_outlet_A_100", "outlet_1")];
  const current = { eventId: "boot1_outlet_B_900", outlet: "outlet_2" };
  assert.deepEqual(staleRuns(open, { ...current, running: ["boot1_outlet_A_100", "boot1_outlet_B_900"] }), []);
  assert.deepEqual(staleRuns(open, current), []); // older firmware: no list
});

test("a new run supersedes the earlier one on the same outlet, never itself", () => {
  const open = [run("1", "boot1_outlet_A_100", "outlet_1"), run("2", "boot1_outlet_A_900", "outlet_1")];
  assert.deepEqual(staleRuns(open, { eventId: "boot1_outlet_A_900", outlet: "outlet_1" }), [{ id: "1", reason: "SUPERSEDED" }]);
});

test("running list: only strings", () => {
  assert.equal(parseRunning(undefined), null);
  assert.deepEqual(parseRunning(["a", 3, "b"]), ["a", "b"]);
});
