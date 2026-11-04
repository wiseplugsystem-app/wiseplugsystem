// Analysis of the appliance measurements (docs/measurement-guide.md).
//
//   node tool/measure_analyze.ts export
//       reads the runs and the evaluation views from Supabase (read-only, the
//       linked project) into measurements/export/*.json
//   node tool/measure_analyze.ts analyze --sheet measurements/recording_sheet.csv
//       [--window 120] [--tz +08:00]
//       joins the recording sheet with the runs and writes measurements/results/:
//       dataset.csv, features_summary.csv, report.md and the charts (*.svg)
//
// Every number comes from the measurements: nothing here holds "typical"
// appliance values. Recognition uses the real rules
// (supabase/functions/_shared/matching.ts) and the project's
// recognition_config, with one profile per appliance mode built from that
// mode's registration runs, and the database views for what the plug did live.
import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import {
  type Appliance,
  type Config,
  configFromRow,
  evaluateProfile,
  type Feature,
  FEATURES,
  type Features,
  parseFeatures,
  type Profile,
  profileFromSamples,
  recognize,
  type Stage,
} from "../supabase/functions/_shared/matching.ts";

const EXPORT_DIR = "measurements/export";
const RESULTS_DIR = "measurements/results";
type Row = Record<string, unknown>;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}

// ---------------------------------------------------------------------------
// export
// ---------------------------------------------------------------------------

const QUERIES: Record<string, string> = {
  sessions: `select s.id, s.event_id, s.device_id, s.outlet, s.started_at, s.ended_at, s.stage, s.status,
      s.predicted_status, p.name as predicted_name, a.name as actual_name, s.features, s.raw_features
    from public.outlet_sessions s
    left join public.appliance_instances p on p.id = s.predicted_appliance_id
    left join public.appliance_instances a on a.id = s.actual_appliance_id
    order by s.started_at`,
  recognition_config: "select * from public.recognition_config",
  recognition_summary: "select * from public.recognition_summary",
  recognition_metrics: "select * from public.recognition_metrics",
  recognition_confusion: "select * from public.recognition_confusion",
};

function exportAll() {
  fs.mkdirSync(EXPORT_DIR, { recursive: true });
  for (const [name, sql] of Object.entries(QUERIES)) {
    const oneLine = sql.replace(/\s+/g, " ");
    const out = execSync(`npx supabase db query --remote --read-only --output-format json "${oneLine}"`, {
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
      stdio: ["ignore", "pipe", "inherit"],
    });
    const rows = JSON.parse(out.slice(out.indexOf("{"))).rows as Row[];
    fs.writeFileSync(path.join(EXPORT_DIR, `${name}.json`), JSON.stringify(rows, null, 1));
    console.log(`${name}: ${rows.length} rows`);
  }
  console.log(`Saved in ${EXPORT_DIR}/. Next: node tool/measure_analyze.ts analyze --sheet measurements/recording_sheet.csv`);
}

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

function parseCsv(text: string): Row[] {
  const rows: string[][] = [];
  let row: string[] = [], field = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") { row.push(field); field = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(field); field = "";
      if (row.some((c) => c.trim())) rows.push(row);
      row = [];
    } else field += ch;
  }
  row.push(field);
  if (row.some((c) => c.trim())) rows.push(row);
  const [head, ...body] = rows;
  const keys = head.map((h) => h.trim().replace(/^﻿/, ""));
  return body.map((r) => Object.fromEntries(keys.map((k, i) => [k, (r[i] ?? "").trim()])));
}

function toCsv(rows: Row[], columns: string[]): string {
  const cell = (v: unknown) => {
    const s = v == null ? "" : typeof v === "number" ? String(round(v, 4)) : String(v);
    return /[",\n]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
  };
  return [columns.join(","), ...rows.map((r) => columns.map((c) => cell(r[c])).join(","))].join("\n") + "\n";
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const round = (x: number, d = 3) => Math.round(x * 10 ** d) / 10 ** d;
const has = (x: unknown): x is number => typeof x === "number" && Number.isFinite(x);
const fmt = (x: number | null | undefined, d = 2) => (has(x) ? round(x, d).toString() : "-");

function stats(values: number[]) {
  const v = values.filter(has);
  if (!v.length) return null;
  const mean = v.reduce((a, b) => a + b, 0) / v.length;
  const sd = v.length > 1 ? Math.sqrt(v.reduce((a, x) => a + (x - mean) ** 2, 0) / (v.length - 1)) : 0;
  return { n: v.length, mean, sd, min: Math.min(...v), max: Math.max(...v), cv: mean ? sd / Math.abs(mean) : null };
}

function mdTable(head: string[], body: (string | number)[][]): string {
  if (!body.length) return "_(none)_\n";
  return [
    `| ${head.join(" | ")} |`,
    `|${head.map(() => "---").join("|")}|`,
    ...body.map((r) => `| ${r.map((c) => String(c).replaceAll("|", "/")).join(" | ")} |`),
  ].join("\n") + "\n";
}

const readExport = (name: string): Row[] => {
  const file = path.join(EXPORT_DIR, `${name}.json`);
  if (!fs.existsSync(file)) throw new Error(`${file} is missing: run "node tool/measure_analyze.ts export" first`);
  return JSON.parse(fs.readFileSync(file, "utf8"));
};

const OUTLET_KEY: Record<string, string> = { A: "outlet_1", B: "outlet_2" };
const FEATURE_LABEL: Record<Feature, string> = {
  avg_power_w: "Power (W)",
  avg_pf: "Power factor",
  startup_peak_ratio: "Start-up peak ratio",
  power_variation: "Power variation",
  settling_time_s: "Settling time (s)",
  cycle_period_s: "Cycle period (s)",
  standby_power_w: "Standby power (W)",
};

const DECIMALS: Record<Feature, number> = {
  avg_power_w: 1, avg_pf: 3, startup_peak_ratio: 3, power_variation: 4,
  settling_time_s: 1, cycle_period_s: 1, standby_power_w: 2,
};

// ---------------------------------------------------------------------------
// analyze
// ---------------------------------------------------------------------------

interface Run {
  sheet: Row;
  key: string;           // unit / mode
  unit: string;
  mode: string;
  type: string;
  outlet: "A" | "B";
  runType: string;
  session: Row | null;
  features: Features | null;
}

function analyze() {
  const sheetPath = arg("sheet");
  if (!sheetPath) throw new Error("Usage: node tool/measure_analyze.ts analyze --sheet measurements/recording_sheet.csv");
  const windowS = Number(arg("window") ?? 120);
  const tz = arg("tz") ?? "+08:00";
  const sheet = parseCsv(fs.readFileSync(sheetPath, "utf8"));
  const sessions = readExport("sessions");
  const configRow = readExport("recognition_config")[0];
  if (!configRow) throw new Error("recognition_config is empty in the export");
  const config: Config = configFromRow(configRow);
  fs.mkdirSync(RESULTS_DIR, { recursive: true });

  const problems: string[] = [];
  const used = new Set<unknown>();
  const byId = new Map(sessions.map((s) => [String(s.id), s]));

  // 1. Match each sheet row to its run: the session_id column, or else the
  //    run on that outlet that started nearest to the sheet's time.
  const runs: Run[] = [];
  sheet.forEach((r, i) => {
    const line = i + 2;
    const outlet = String(r.outlet).toUpperCase() as "A" | "B";
    const runType = String(r.run_type).toLowerCase();
    if (!["A", "B"].includes(outlet)) { problems.push(`Line ${line}: outlet must be A or B`); return; }
    if (!["registration", "test", "long_log"].includes(runType)) {
      problems.push(`Line ${line}: run_type must be registration, test or long_log`);
      return;
    }
    if (!r.unit || !r.mode || !r.appliance_type) { problems.push(`Line ${line}: appliance_type, unit and mode are required`); return; }
    const run: Run = {
      sheet: r, unit: String(r.unit), mode: String(r.mode), type: String(r.appliance_type),
      key: `${r.unit} / ${r.mode}`, outlet, runType, session: null, features: null,
    };
    runs.push(run);
    if (runType === "long_log") return;
    let s: Row | undefined;
    if (r.session_id) {
      s = byId.get(String(r.session_id));
      if (!s) problems.push(`Line ${line}: session_id ${r.session_id} is not in the export`);
    } else {
      const t = Date.parse(`${r.date}T${r.start_time}${tz}`);
      if (!Number.isFinite(t)) { problems.push(`Line ${line}: date / start_time not readable (YYYY-MM-DD, HH:MM:SS)`); return; }
      let best: Row | undefined, bestDiff = Infinity;
      for (const c of sessions) {
        if (c.outlet !== OUTLET_KEY[outlet] || used.has(c.id)) continue;
        const d = Math.abs(Date.parse(String(c.started_at).replace(" ", "T").replace(/\+00$/, "Z")) - t) / 1000;
        if (d < bestDiff) { bestDiff = d; best = c; }
      }
      if (best && bestDiff <= windowS) s = best;
      else problems.push(`Line ${line}: no run on Outlet ${outlet} within ${windowS} s of ${r.date} ${r.start_time} (fill in session_id)`);
    }
    if (!s) return;
    used.add(s.id);
    run.session = s;
    const x = parseFeatures(s.features);
    if (typeof x === "string") problems.push(`Line ${line}: run ${s.id} has no measurements (${x})`);
    else run.features = x;
    if (Number(s.stage) < 2) problems.push(`Line ${line}: run ${s.id} ended before the full measurement (stage ${s.stage}); keep it on 60 s or more`);
  });
  const measured = runs.filter((r) => r.features);

  // 2. dataset.csv: every sheet row with its run's features.
  const datasetColumns = ["run_no", "date", "start_time", "outlet", "appliance_type", "unit", "brand", "model",
    "nameplate_w", "mode", "run_type", "session_id", "started_at", "stage", "voltage_v", ...FEATURES, "unstable",
    "live_predicted_status", "live_predicted_name", "notes"];
  fs.writeFileSync(path.join(RESULTS_DIR, "dataset.csv"), toCsv(runs.map((r) => ({
    ...r.sheet,
    session_id: r.session?.id ?? r.sheet.session_id,
    started_at: r.session?.started_at,
    stage: r.session?.stage,
    voltage_v: r.features?.avg_voltage_v,
    ...Object.fromEntries(FEATURES.map((f) => [f, r.features?.[f]])),
    unstable: r.features?.unstable,
    live_predicted_status: r.session?.predicted_status,
    live_predicted_name: r.session?.predicted_name,
  })), datasetColumns));

  // 3. Per appliance / mode: mean and spread of every feature.
  const groups = new Map<string, Run[]>();
  for (const r of measured) groups.set(r.key, [...(groups.get(r.key) ?? []), r]);
  const summaryRows: Row[] = [];
  for (const [key, rs] of groups) {
    const row: Row = {
      appliance_type: rs[0].type, unit: rs[0].unit, mode: rs[0].mode, runs: rs.length,
      runs_a: rs.filter((r) => r.outlet === "A").length, runs_b: rs.filter((r) => r.outlet === "B").length,
    };
    for (const f of ["avg_voltage_v", ...FEATURES] as const) {
      const s = stats(rs.map((r) => r.features![f] as number));
      row[`${f}_n`] = s?.n ?? 0;
      row[`${f}_mean`] = s?.mean; row[`${f}_sd`] = s?.sd; row[`${f}_min`] = s?.min; row[`${f}_max`] = s?.max;
    }
    const a = stats(rs.filter((r) => r.outlet === "A").map((r) => r.features!.avg_power_w as number));
    const b = stats(rs.filter((r) => r.outlet === "B").map((r) => r.features!.avg_power_w as number));
    row.power_b_vs_a_pct = a && b && a.mean ? ((b.mean - a.mean) / a.mean) * 100 : null;
    row.key = key;
    summaryRows.push(row);
  }
  const statCols = ["avg_voltage_v", ...FEATURES].flatMap((f) => ["n", "mean", "sd", "min", "max"].map((s) => `${f}_${s}`));
  fs.writeFileSync(path.join(RESULTS_DIR, "features_summary.csv"), toCsv(summaryRows,
    ["appliance_type", "unit", "mode", "runs", "runs_a", "runs_b", ...statCols, "power_b_vs_a_pct"]));

  // 4. Profiles: one per unit / mode, from its registration runs (the real
  //    profileFromSamples), grouped into one appliance per unit.
  const appliances = new Map<string, Appliance>();
  for (const [key, rs] of groups) {
    const reg = rs.filter((r) => r.runType === "registration");
    if (!reg.length) continue;
    const unit = rs[0].unit;
    if (!appliances.has(unit)) {
      appliances.set(unit, {
        id: unit, name: unit, typeId: rs[0].type, typeName: rs[0].type,
        ownCutoffS: config.defaultCutoffS, isLearned: false, baselineRuntimeS: null,
        lastDeviceId: null, lastOutlet: null, activeOn: null, profiles: [],
      } as Appliance);
    }
    appliances.get(unit)!.profiles.push({
      id: key, modeName: rs[0].mode, ...profileFromSamples(reg.map((r) => r.features!)),
    } as Profile);
  }
  const allProfiles = [...appliances.values()].flatMap((a) => a.profiles.map((p) => ({ a, p })));

  // 5. Overlap: does one mode's average run pass another mode's rules?
  const asReading = (p: Profile): Features => ({ ...p.mean, avg_voltage_v: p.registrationVoltage });
  const overlapRows: (string | number)[][] = [];
  const fragileRows: (string | number)[][] = [];
  let separated = 0;
  for (let i = 0; i < allProfiles.length; i++) {
    for (let j = i + 1; j < allProfiles.length; j++) {
      const P = allProfiles[i], Q = allProfiles[j];
      const pq = evaluateProfile(asReading(P.p), Q.a, Q.p, 2, config); // P's average judged by Q
      const qp = evaluateProfile(asReading(Q.p), P.a, P.p, 2, config);
      const same = P.a.id === Q.a.id ? " (same appliance)" : "";
      // Features that tell them apart in both directions, strongest first.
      const sep = FEATURES.map((f) => {
        const a = pq.checks.find((k) => k.feature === f), b = qp.checks.find((k) => k.feature === f);
        return a && b ? { f, n: Math.min(a.normalized, b.normalized) } : null;
      }).filter((x): x is { f: Feature; n: number } => !!x && x.n > 1).sort((x, y) => y.n - x.n);
      const pair = `${P.p.id} vs ${Q.p.id}${same}`;
      if (pq.pass && qp.pass) overlapRows.push([pair, "Cannot be separated", "-"]);
      else if (pq.pass || qp.pass) {
        const inside = pq.pass ? `${P.p.id} fits ${Q.p.id}` : `${Q.p.id} fits ${P.p.id}`;
        overlapRows.push([pair, `One-way: ${inside}`, sep.map((s) => FEATURE_LABEL[s.f]).join(", ") || "-"]);
      } else {
        separated++;
        if (sep.length <= 1) {
          const best = sep[0] ?? FEATURES.map((f) => {
            const a = pq.checks.find((k) => k.feature === f), b = qp.checks.find((k) => k.feature === f);
            return { f, n: Math.max(a?.normalized ?? 0, b?.normalized ?? 0) };
          }).sort((x, y) => y.n - x.n)[0];
          fragileRows.push([pair, FEATURE_LABEL[best.f], fmt(best.n, 2)]);
        }
      }
    }
  }

  // 6. Recognition with the real rules: every test run against all profiles.
  const tests = measured.filter((r) => r.runType === "test");
  const results = tests.map((r) => {
    const out = recognize({
      features: r.features!, stage: (Number(r.session!.stage) >= 2 ? 2 : 1) as Stage,
      here: { deviceId: String(r.session!.device_id ?? "gadget-1"), outlet: OUTLET_KEY[r.outlet] },
      appliances: [...appliances.values()], config,
    });
    const matched = out.status === "MATCHED_PROVISIONAL" || out.status === "MATCHED_CONFIRMED";
    const predicted = matched ? out.match!.appliance.name : out.status === "AMBIGUOUS" ? "Asked the user" : "New appliance";
    const actual = appliances.has(r.unit) ? r.unit : "New appliance";
    const outcome = matched
      ? (predicted === actual ? "CORRECT" : "WRONG_APPLIANCE")
      : out.status === "AMBIGUOUS" ? "ASKED_USER"
      : actual === "New appliance" ? "NEW_DETECTED" : "MISSED_KNOWN";
    return {
      r, predicted, actual, outcome,
      modeRight: matched && predicted === actual && out.match!.profile.modeName === r.mode,
      askedRightAmongChoices: out.status === "AMBIGUOUS" && out.candidates.some((c) => c.applianceId === r.unit),
      reason: out.reason,
    };
  });
  const labels = [...new Set([...results.map((x) => x.actual), ...results.map((x) => x.predicted)])]
    .filter((l) => l !== "Asked the user").sort();
  const metricRows = labels.map((l) => {
    const tp = results.filter((x) => x.actual === l && x.predicted === l).length;
    const fp = results.filter((x) => x.actual !== l && x.predicted === l).length;
    const fn = results.filter((x) => x.actual === l && x.predicted !== l).length;
    const p = tp + fp ? tp / (tp + fp) : null, rc = tp + fn ? tp / (tp + fn) : null;
    const f1 = 2 * tp + fp + fn ? (2 * tp) / (2 * tp + fp + fn) : null;
    return [l, tp, fp, fn, fmt(p, 3), fmt(rc, 3), fmt(f1, 3)];
  });
  const cols = [...new Set(results.map((x) => x.predicted))].sort();
  const confusion = [...new Set(results.map((x) => x.actual))].sort().map((a) =>
    [a, ...cols.map((c) => results.filter((x) => x.actual === a && x.predicted === c).length)]);
  const count = (o: string) => results.filter((x) => x.outcome === o).length;
  const known = results.filter((x) => x.actual !== "New appliance").length;

  // 7. Long logs: on/off cycling.
  const logRows: (string | number)[][] = [];
  const logCharts: string[] = [];
  for (const r of runs.filter((x) => x.runType === "long_log")) {
    const file = String(r.sheet.log_file ?? "");
    if (!file || !fs.existsSync(file)) { problems.push(`Long log for ${r.key}: log_file "${file}" not found`); continue; }
    const pts = parseCsv(fs.readFileSync(file, "utf8"))
      .map((p) => ({ t: Number(p.timestamp_ms), w: Number(p.power_w) }))
      .filter((p) => has(p.t) && has(p.w));
    if (pts.length < 10) { problems.push(`Long log ${file}: fewer than 10 readings`); continue; }
    const c = cycles(pts);
    logRows.push([r.key, `Outlet ${r.outlet}`, pts.length, fmt((pts.at(-1)!.t - pts[0].t) / 60000, 1),
      fmt(c.stepS, 1), c.cycles, fmt(c.onS, 0), fmt(c.offS, 0), fmt(c.periodS, 0),
      c.duty == null ? "-" : `${fmt(c.duty * 100, 0)} %`, fmt(c.onW, 1), fmt(c.offW, 1)]);
    const name = `log_${path.basename(file, path.extname(file))}.svg`;
    fs.writeFileSync(path.join(RESULTS_DIR, name), traceSvg(pts, `${r.key}, Outlet ${r.outlet}`, c.threshold));
    logCharts.push(name);
  }

  // 8. Charts: watts vs power factor, every measured run.
  const chartFiles = scatterCharts(measured);

  // 9. The live system's own evaluation (database views).
  const live = (name: string) => {
    const rows = readExport(name);
    return rows.length ? mdTable(Object.keys(rows[0]), rows.map((x) => Object.values(x).map((v) => v == null ? "-" : String(v)))) : "_(no rows)_\n";
  };

  // 10. Targets of the guide: 3 registration (2 on A, 1 on B), 10 tests per outlet.
  const shortRows: (string | number)[][] = [];
  for (const [key, rs] of groups) {
    const regA = rs.filter((r) => r.runType === "registration" && r.outlet === "A").length;
    const regB = rs.filter((r) => r.runType === "registration" && r.outlet === "B").length;
    const tA = rs.filter((r) => r.runType === "test" && r.outlet === "A").length;
    const tB = rs.filter((r) => r.runType === "test" && r.outlet === "B").length;
    if (regA + regB < 3 || regB < 1 || tA < 10 || tB < 10) shortRows.push([key, `${regA} A + ${regB} B`, tA, tB]);
  }

  const summaryTable = summaryRows.map((s) => [
    String(s.unit), String(s.mode), Number(s.runs),
    ...FEATURES.map((f) => has(s[`${f}_mean`]) ? `${fmt(s[`${f}_mean`] as number, DECIMALS[f])} ± ${fmt(s[`${f}_sd`] as number, DECIMALS[f])}` : "-"),
    has(s.power_b_vs_a_pct) ? `${fmt(s.power_b_vs_a_pct as number, 1)} %` : "-",
  ]);

  const report = `# WisePlug appliance measurements: results

Made by \`node tool/measure_analyze.ts analyze\` on ${new Date().toISOString().slice(0, 10)} from
\`${sheetPath}\` (${sheet.length} rows) and the Supabase export (${sessions.length} runs).
All numbers are from these measurements. Recognition settings: recognition_config
(tolerance = max(${config.toleranceSigma} x standard deviation, floor)).

## 1. Data check

${problems.length ? problems.map((p) => `- ${p}`).join("\n") : "- Every row matched a run."}

Below the guide's targets (3 registration runs with at least 1 on Outlet B, 10 tests on each outlet):

${mdTable(["Appliance / mode", "Registration", "Tests A", "Tests B"], shortRows)}
## 2. Features per appliance and mode (mean ± standard deviation, all runs)

${mdTable(["Unit", "Mode", "Runs", ...FEATURES.map((f) => FEATURE_LABEL[f]), "Power B vs A"], summaryTable)}
Minimum, maximum, voltage and the per-outlet counts are in \`features_summary.csv\`.

## 3. Overlap between modes

Each mode's average run is checked against every other mode's rules
(evaluateProfile, Stage 2). **Cannot be separated**: each passes the other's
rules. **One-way**: one passes the other's. ${separated} pairs are separated.

${mdTable(["Pair", "Result", "Features that still differ"], overlapRows)}
Separated by only one feature (the margin is |difference| / tolerance; just above 1 is fragile):

${mdTable(["Pair", "Only separating feature", "Margin"], fragileRows)}
## 4. Recognition with the rules (test runs, profiles from the registration runs)

- Test runs: ${results.length} (registered appliances: ${known})
- **Accuracy (registered appliances):** ${known ? fmt(count("CORRECT") / known, 3) : "-"} (${count("CORRECT")} of ${known})
- Right mode as well: ${results.filter((x) => x.modeRight).length}
- Asked the user: ${count("ASKED_USER")} (right appliance among the choices: ${results.filter((x) => x.askedRightAmongChoices).length})
- Wrong appliance: ${count("WRONG_APPLIANCE")}; registered but not recognised: ${count("MISSED_KNOWN")}

Precision, recall and F1 per appliance (a question counts as not recognised, as in the recognition_metrics view):

${mdTable(["Appliance", "TP", "FP", "FN", "Precision", "Recall", "F1"], metricRows)}
Confusion table (rows: actual; columns: result):

${mdTable(["Actual", ...cols], confusion)}
## 5. What the plug decided live (database views)

recognition_summary:

${live("recognition_summary")}
recognition_metrics:

${live("recognition_metrics")}
recognition_confusion:

${live("recognition_confusion")}
## 6. Long logs: heating on/off cycles

${mdTable(["Appliance / mode", "Outlet", "Readings", "Minutes", "Seconds between readings", "Cycles", "On (s)", "Off (s)", "Period (s)", "On share", "On (W)", "Off (W)"], logRows)}
Readings come about every 3 s, so on and off times are accurate to about ±3 s.
${logCharts.map((c) => `- ${c}`).join("\n")}

## 7. Charts

${chartFiles.map((c) => `- ${c}`).join("\n")}
`;
  fs.writeFileSync(path.join(RESULTS_DIR, "report.md"), report);
  console.log(`${runs.length} rows, ${measured.length} measured, ${problems.length} problems. Results in ${RESULTS_DIR}/ (report.md).`);
}

// ---------------------------------------------------------------------------
// On/off cycles of a long log
// ---------------------------------------------------------------------------

function cycles(pts: { t: number; w: number }[]) {
  const ws = pts.map((p) => p.w);
  const hi = Math.max(...ws), lo = Math.min(...ws);
  const steps = pts.slice(1).map((p, i) => (p.t - pts[i].t) / 1000).sort((a, b) => a - b);
  const stepS = steps[Math.floor(steps.length / 2)] ?? null;
  const none = { threshold: null as number | null, cycles: 0, onS: null, offS: null, periodS: null, duty: null, onW: null, offW: null, stepS };
  // No cycling unless on and off differ clearly (more than 5 W and 20 %).
  if (hi - lo < Math.max(5, hi * 0.2)) return none;
  const threshold = (hi + lo) / 2;
  const segs: { on: boolean; start: number; end: number; w: number[] }[] = [];
  for (const p of pts) {
    const on = p.w >= threshold, last = segs.at(-1);
    if (last && last.on === on) { last.end = p.t; last.w.push(p.w); }
    else segs.push({ on, start: p.t, end: p.t, w: [p.w] });
  }
  // Durations of complete segments only (the first and last are cut off).
  const inner = segs.slice(1, -1);
  const dur = (on: boolean) => stats(inner.filter((s) => s.on === on).map((s) => (s.end - s.start) / 1000 + (stepS ?? 0)));
  const onD = dur(true), offD = dur(false);
  const level = (on: boolean) => stats(segs.filter((s) => s.on === on).flatMap((s) => s.w));
  const period = onD && offD ? onD.mean + offD.mean : null;
  return {
    threshold,
    cycles: Math.min(inner.filter((s) => s.on).length, inner.filter((s) => !s.on).length),
    onS: onD?.mean ?? null, offS: offD?.mean ?? null, periodS: period,
    duty: period && onD ? onD.mean / period : null,
    onW: level(true)?.mean ?? null, offW: level(false)?.mean ?? null, stepS,
  };
}

// ---------------------------------------------------------------------------
// Charts (plain SVG, light theme for print; a <title> on each dot is its tooltip)
// ---------------------------------------------------------------------------

const INK = "#0b0b0b", INK2 = "#52514e", GRID = "#e4e3df", SURFACE = "#fcfcfb";
// The validated categorical order (8 colours); never cycled: more appliance
// types go to the next chart, on the same axes.
const SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"];
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

function scatterCharts(measured: Run[]): string[] {
  const pts = measured.filter((r) => has(r.features!.avg_power_w) && has(r.features!.avg_pf) && (r.features!.avg_power_w as number) > 0);
  if (!pts.length) return [];
  const types = [...new Set(pts.map((r) => r.type))];
  const ws = pts.map((r) => r.features!.avg_power_w as number);
  const x0 = Math.floor(Math.log10(Math.min(...ws))), x1 = Math.ceil(Math.log10(Math.max(...ws)));
  const files: string[] = [];
  for (let k = 0; k * 8 < types.length; k++) {
    const group = types.slice(k * 8, k * 8 + 8);
    const name = types.length > 8 ? `watts_vs_pf_${k + 1}.svg` : "watts_vs_pf.svg";
    const title = types.length > 8 ? `Power vs power factor (${k + 1} of ${Math.ceil(types.length / 8)})` : "Power vs power factor";
    fs.writeFileSync(path.join(RESULTS_DIR, name), scatterSvg(pts.filter((r) => group.includes(r.type)), group, x0, x1, title));
    files.push(name);
  }
  return files;
}

function scatterSvg(pts: Run[], types: string[], x0: number, x1: number, title: string): string {
  const W = 900, H = 560, L = 70, R = 24, T = 64 + Math.ceil(types.length / 4) * 22, B = 60;
  const x = (w: number) => L + ((Math.log10(w) - x0) / (x1 - x0)) * (W - L - R);
  const y = (pf: number) => H - B - pf * (H - T - B);
  const parts: string[] = [];
  parts.push(`<rect width="${W}" height="${H}" fill="${SURFACE}"/>`);
  parts.push(`<text x="${L}" y="28" font-size="18" font-weight="600" fill="${INK}">${esc(title)}</text>`);
  // Legend: always present for 2+ types; a dot beside ink-coloured text.
  types.forEach((t, i) => {
    const lx = L + (i % 4) * 200, ly = 52 + Math.floor(i / 4) * 22;
    parts.push(`<circle cx="${lx + 5}" cy="${ly - 5}" r="5" fill="${SERIES[i]}"/>`);
    parts.push(`<text x="${lx + 16}" y="${ly}" font-size="13" fill="${INK2}">${esc(t)}</text>`);
  });
  for (let e = x0; e <= x1; e++) {
    for (const m of [1, 2, 5]) {
      const w = m * 10 ** e;
      if (Math.log10(w) > x1 + 1e-9) continue;
      parts.push(`<line x1="${x(w)}" x2="${x(w)}" y1="${T}" y2="${H - B}" stroke="${GRID}"/>`);
      parts.push(`<text x="${x(w)}" y="${H - B + 18}" font-size="12" fill="${INK2}" text-anchor="middle">${w >= 1 ? w : w.toFixed(1)}</text>`);
    }
  }
  for (let pf = 0; pf <= 1.0001; pf += 0.2) {
    parts.push(`<line x1="${L}" x2="${W - R}" y1="${y(pf)}" y2="${y(pf)}" stroke="${GRID}"/>`);
    parts.push(`<text x="${L - 8}" y="${y(pf) + 4}" font-size="12" fill="${INK2}" text-anchor="end">${pf.toFixed(1)}</text>`);
  }
  parts.push(`<text x="${(L + W - R) / 2}" y="${H - 16}" font-size="13" fill="${INK2}" text-anchor="middle">Average power (W, log scale)</text>`);
  parts.push(`<text transform="translate(18 ${(T + H - B) / 2}) rotate(-90)" font-size="13" fill="${INK2}" text-anchor="middle">Power factor</text>`);
  for (const r of pts) {
    const f = r.features!, c = SERIES[types.indexOf(r.type)];
    const tip = `${r.unit} · ${r.mode} · Outlet ${r.outlet} · ${r.runType}: ${fmt(f.avg_power_w as number, 1)} W, PF ${fmt(f.avg_pf as number, 3)}`;
    parts.push(`<circle cx="${x(f.avg_power_w as number).toFixed(1)}" cy="${y(f.avg_pf as number).toFixed(1)}" r="4.5" fill="${c}" stroke="${SURFACE}" stroke-width="2"><title>${esc(tip)}</title></circle>`);
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" font-family="Arial, sans-serif">\n${parts.join("\n")}\n</svg>\n`;
}

function traceSvg(pts: { t: number; w: number }[], title: string, threshold: number | null): string {
  const W = 900, H = 360, L = 70, R = 24, T = 48, B = 50;
  // Round steps on the power axis (1, 2 or 5 x 10^n).
  const top = Math.max(...pts.map((p) => p.w), 1);
  const mag = 10 ** Math.floor(Math.log10(top / 5));
  const step = [1, 2, 5, 10].map((m) => m * mag).find((v) => v >= top / 5)!;
  const ticks = Math.ceil(top / step);
  const t0 = pts[0].t, t1 = pts.at(-1)!.t, wMax = step * ticks;
  const x = (t: number) => L + ((t - t0) / Math.max(1, t1 - t0)) * (W - L - R);
  const y = (w: number) => H - B - (w / wMax) * (H - T - B);
  const parts: string[] = [`<rect width="${W}" height="${H}" fill="${SURFACE}"/>`,
    `<text x="${L}" y="28" font-size="18" font-weight="600" fill="${INK}">${esc(title)}</text>`];
  for (let i = 0; i <= ticks; i++) {
    const w = step * i;
    parts.push(`<line x1="${L}" x2="${W - R}" y1="${y(w)}" y2="${y(w)}" stroke="${GRID}"/>`);
    parts.push(`<text x="${L - 8}" y="${y(w) + 4}" font-size="12" fill="${INK2}" text-anchor="end">${Math.round(w)}</text>`);
  }
  const mins = (t1 - t0) / 60000;
  for (let m = 0; m <= mins + 1e-9; m += mins > 20 ? 5 : 1) {
    const t = t0 + m * 60000;
    parts.push(`<text x="${x(t)}" y="${H - B + 18}" font-size="12" fill="${INK2}" text-anchor="middle">${m}</text>`);
  }
  if (threshold != null) {
    parts.push(`<line x1="${L}" x2="${W - R}" y1="${y(threshold)}" y2="${y(threshold)}" stroke="${INK2}" stroke-dasharray="4 4"/>`);
    parts.push(`<text x="${W - R}" y="${y(threshold) - 8}" font-size="12" fill="${INK2}" text-anchor="end">on/off threshold ${Math.round(threshold)} W</text>`);
  }
  parts.push(`<polyline fill="none" stroke="${SERIES[0]}" stroke-width="2" stroke-linejoin="round" points="${pts.map((p) => `${x(p.t).toFixed(1)},${y(p.w).toFixed(1)}`).join(" ")}"/>`);
  parts.push(`<text x="${(L + W - R) / 2}" y="${H - 12}" font-size="13" fill="${INK2}" text-anchor="middle">Minutes</text>`);
  parts.push(`<text transform="translate(18 ${(T + H - B) / 2}) rotate(-90)" font-size="13" fill="${INK2}" text-anchor="middle">Power (W)</text>`);
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" font-family="Arial, sans-serif">\n${parts.join("\n")}\n</svg>\n`;
}

// ---------------------------------------------------------------------------

const command = process.argv[2];
if (command === "export") exportAll();
else if (command === "analyze") analyze();
else {
  console.error("Usage:\n  node tool/measure_analyze.ts export\n  node tool/measure_analyze.ts analyze --sheet measurements/recording_sheet.csv [--window 120] [--tz +08:00]");
  process.exit(2);
}
