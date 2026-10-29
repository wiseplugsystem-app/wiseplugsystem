// Runs sample feature summaries through the rule-based recognizer
// (supabase/functions/_shared/matching.ts) and prints the results as a
// Markdown table, for the thesis.
//
//   node tool/recognition_table.ts                 the built-in scenarios
//   node tool/recognition_table.ts my-cases.json   your own readings
//
// my-cases.json: { "appliances": [...], "cases": [...] } in the same shape as
// APPLIANCES and CASES below (registration samples per mode; one reading per
// case, with the outlet it is on and what is running elsewhere).
import fs from "node:fs";
import {
  type Appliance,
  type Config,
  configFromRow,
  type Features,
  profileFromSamples,
  recognize,
  type Sample,
  type Stage,
} from "../supabase/functions/_shared/matching.ts";

// The defaults of the recognition_config table.
const CONFIG: Config = configFromRow({
  tolerance_sigma: 3, floor_power_pct: 0.02, floor_pf: 0.02, floor_startup_peak_ratio: 0.1,
  floor_power_variation: 0.02, floor_settling_time_s: 2, floor_cycle_period_pct: 0.1,
  floor_standby_power_w: 0.5, weight_power: 0.3, weight_pf: 0.3, weight_startup_peak_ratio: 0.15,
  weight_power_variation: 0.1, weight_settling_time: 0.1, weight_standby_power: 0.05,
  weight_cycle_period: 0, clear_winner_ratio: 1.5, tie_margin: 0.1, voltage_correction_min_pf: 0.95,
  default_cutoff_minutes: 30, ema_factor: 0.1, max_samples_per_profile: 20, registration_samples: 3,
  learning_uses: 7, learned_margin: 1.5, min_learned_cutoff_minutes: 5, min_session_s: 10,
});

interface ApplianceSpec {
  id: string;
  type: string;
  cutoffMinutes: number;
  lastOutlet?: string;
  /** Mode name -> its registration samples (the 3 guided plug-ins). */
  modes: Record<string, Sample[]>;
}
interface CaseSpec {
  scenario: string;
  outlet: "A" | "B";
  stage: Stage;
  reading: Features;
  /** Appliance ids running on the other outlet (outlet exclusivity). */
  runningElsewhere?: string[];
  /** Stage 1's provisional appliance, for Stage 2 cases. */
  previous?: string;
  /** Only these appliances are registered (default: all). */
  registered?: string[];
  expected?: string;
}

/** Three registration plug-ins around a centre, with realistic spread. */
const three = (s: Sample, spread: Partial<Record<keyof Sample, number>> = {}): Sample[] =>
  [-1, 0, 1].map((k) => {
    const out: Sample = { ...s };
    for (const [f, d] of Object.entries(spread)) {
      (out as Record<string, number>)[f] = (s as Record<string, number>)[f] + k * (d as number);
    }
    return out;
  });
const fan = (power: number, pf: number): Sample[] =>
  three({ avg_power_w: power, avg_pf: pf, startup_peak_ratio: 1.5, settling_time_s: 4.3, power_variation: 0.022, avg_voltage_v: 230 },
    { avg_power_w: 0.3, avg_pf: 0.005, startup_peak_ratio: 0.05, settling_time_s: 0.5, power_variation: 0.002 });

const APPLIANCES: ApplianceSpec[] = [
  { id: "Fan 1", type: "Fan", cutoffMinutes: 240, lastOutlet: "A", modes: { Low: fan(40, 0.9), High: fan(57, 0.92) } },
  { id: "Laptop charger", type: "Charger", cutoffMinutes: 180, modes: {
    Normal: three({ avg_power_w: 58, avg_pf: 0.55, startup_peak_ratio: 1.0, settling_time_s: 8, power_variation: 0.08, avg_voltage_v: 230 },
      { avg_power_w: 1, avg_pf: 0.01, settling_time_s: 1, power_variation: 0.01 }),
  } },
  { id: "Desk lamp", type: "Lamp", cutoffMinutes: 600, modes: {
    Normal: three({ avg_power_w: 57.2, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 4.3, power_variation: 0.022, avg_voltage_v: 230 },
      { avg_power_w: 0.4, avg_pf: 0.005 }),
  } },
  { id: "Heater", type: "Heater", cutoffMinutes: 60, modes: {
    Normal: three({ avg_power_w: 1000, avg_pf: 1.0, startup_peak_ratio: 1.02, settling_time_s: 3, power_variation: 0.01, avg_voltage_v: 220 },
      { avg_power_w: 1 }),
  } },
];

const CASES: CaseSpec[] = [
  { scenario: "1. Fan on A; 58 W charger-like load (PF 0.55) on B", outlet: "B", stage: 1, runningElsewhere: ["Fan 1"], registered: ["Fan 1"],
    reading: { avg_power_w: 58, avg_pf: 0.55, startup_peak_ratio: 1.0, settling_time_s: 2 }, expected: "UNKNOWN" },
  { scenario: "2. Fan on A; identical fan (56 W, PF 0.91) on B", outlet: "B", stage: 1, runningElsewhere: ["Fan 1"], registered: ["Fan 1"],
    reading: { avg_power_w: 56, avg_pf: 0.91, startup_peak_ratio: 1.5, settling_time_s: 4 }, expected: "SAME_TYPE_IN_USE" },
  // Limitation: a registered look-alike that is free is a valid candidate.
  { scenario: "2b. Same, but an electrically identical desk lamp is registered", outlet: "B", stage: 1, runningElsewhere: ["Fan 1"],
    reading: { avg_power_w: 56, avg_pf: 0.91, startup_peak_ratio: 1.5, settling_time_s: 4 }, expected: "MATCHED_PROVISIONAL" },
  { scenario: "3a. Fan moved from A to B (Stage 1)", outlet: "B", stage: 1,
    reading: { avg_power_w: 40.1, avg_pf: 0.9, startup_peak_ratio: 1.5, settling_time_s: 4 }, expected: "MATCHED_PROVISIONAL" },
  { scenario: "3b. ... Stage 2 agrees", outlet: "B", stage: 2, previous: "Fan 1",
    reading: { avg_power_w: 40.1, avg_pf: 0.9, startup_peak_ratio: 1.5, settling_time_s: 4, power_variation: 0.021 }, expected: "MATCHED_CONFIRMED" },
  { scenario: "4. Fan (High) vs desk lamp: close scores", outlet: "A", stage: 1,
    reading: { avg_power_w: 57.1, avg_pf: 0.92, startup_peak_ratio: 1.5, settling_time_s: 4.3 }, expected: "AMBIGUOUS" },
  { scenario: "5. Fan on its Low mode", outlet: "A", stage: 2, previous: "Fan 1",
    reading: { avg_power_w: 39.8, avg_pf: 0.9, startup_peak_ratio: 1.5, settling_time_s: 4, power_variation: 0.023 }, expected: "MATCHED_CONFIRMED" },
  { scenario: "6. Heater registered at 220 V, measured at 235 V", outlet: "A", stage: 1,
    reading: { avg_power_w: 1000 * (235 / 220) ** 2, avg_pf: 1.0, startup_peak_ratio: 1.02, settling_time_s: 3, avg_voltage_v: 235 },
    expected: "MATCHED_PROVISIONAL" },
  { scenario: "7. Never-seen kettle (1800 W)", outlet: "A", stage: 1,
    reading: { avg_power_w: 1800, avg_pf: 1.0, startup_peak_ratio: 1.0, settling_time_s: 2 }, expected: "UNKNOWN" },
  { scenario: "8. Noisy laptop charger (+0.8 W, +0.01 PF)", outlet: "B", stage: 1,
    reading: { avg_power_w: 58.8, avg_pf: 0.56, startup_peak_ratio: 1.0, settling_time_s: 8.5 }, expected: "MATCHED_PROVISIONAL" },
];

function appliances(specs: ApplianceSpec[], running: string[], here: string): Appliance[] {
  return specs.map((s) => ({
    id: s.id, name: s.id, typeId: s.type, typeName: s.type,
    ownCutoffS: s.cutoffMinutes * 60, isLearned: false, baselineRuntimeS: null,
    lastDeviceId: s.lastOutlet ? "gadget-1" : null,
    lastOutlet: s.lastOutlet ? (s.lastOutlet === "A" ? "outlet_1" : "outlet_2") : null,
    activeOn: running.includes(s.id)
      ? { deviceId: "gadget-1", outlet: here === "outlet_1" ? "outlet_2" : "outlet_1" }
      : null,
    profiles: Object.entries(s.modes).map(([mode, samples]) => ({
      id: `${s.id}/${mode}`, modeName: mode, ...profileFromSamples(samples),
    })),
  }));
}

const file = process.argv[2];
const input = file ? JSON.parse(fs.readFileSync(file, "utf8")) : { appliances: APPLIANCES, cases: CASES };
const minutes = (s: number) => (s % 3600 === 0 ? `${s / 3600} h` : `${Math.round(s / 60)} min`);
const rows: string[][] = [];
let passed = 0, checked = 0;
for (const c of input.cases as CaseSpec[]) {
  const here = c.outlet === "A" ? "outlet_1" : "outlet_2";
  const r = recognize({
    features: c.reading, stage: c.stage, here: { deviceId: "gadget-1", outlet: here },
    appliances: appliances(
      (input.appliances as ApplianceSpec[]).filter((a) => !c.registered || c.registered.includes(a.id)),
      c.runningElsewhere ?? [],
      here,
    ),
    previousApplianceId: c.previous ?? null, config: CONFIG,
  });
  const ok = c.expected == null ? "" : r.status === c.expected ? "yes" : `NO (expected ${c.expected})`;
  if (c.expected != null) { checked++; if (r.status === c.expected) passed++; }
  rows.push([
    c.scenario, c.outlet, String(c.stage),
    `${c.reading.avg_power_w!.toFixed(1)} W, PF ${c.reading.avg_pf ?? "-"}`,
    r.status, r.match ? `${r.match.appliance.name} (${r.match.profile.modeName})` : r.registerAs?.name ? `→ ${r.registerAs.name}` : "-",
    r.match ? r.match.score.toFixed(2) : r.candidates.map((x) => `${x.name} ${x.score}`).join(", ") || "-",
    minutes(r.cutoffS), r.promptText, ok,
  ]);
}

const header = ["Scenario", "Outlet", "Stage", "Reading", "Status", "Appliance", "Score", "Cutoff", "Prompt", "As expected"];
console.log(`| ${header.join(" | ")} |`);
console.log(`|${header.map(() => "---").join("|")}|`);
for (const r of rows) console.log(`| ${r.join(" | ")} |`);
if (checked) console.log(`\n${passed} of ${checked} scenarios as expected.`);
process.exitCode = passed === checked ? 0 : 1;
