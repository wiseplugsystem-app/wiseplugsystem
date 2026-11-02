// Computes the per-outlet calibration factors from the same steady resistive
// load (an incandescent bulb, a kettle, a heater) measured on Outlet A and
// then on Outlet B, and prints the SQL that stores them. The procedure is in
// docs/appliance-identification.md, "Calibrating the outlets".
//
//   node tool/calibrate.ts --a 230.4,60.2,1.00 --b 229.6,58.9,0.99
//   node tool/calibrate.ts --a ... --b ... --ref 231.0,60.5,1.00 --device gadget-1
//
// Each reading is "volts,watts,pf" as measured (the raw values: the outlet
// card, or raw_features of the run). Without --ref, Outlet A is the reference
// (its factors stay 1.0) and B is brought to A; with --ref (a trusted meter's
// reading of the same load) both outlets are brought to that meter.
import { type CalibrationReading, factorsFrom } from "../supabase/functions/_shared/calibration.ts";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}
function reading(name: string): CalibrationReading | undefined {
  const v = arg(name);
  if (v == null) return undefined;
  const [voltage, power, pf] = v.split(",").map(Number);
  if (![voltage, power, pf].every(Number.isFinite)) throw new Error(`--${name} must be volts,watts,pf, e.g. 230.4,60.2,1.00`);
  return { voltage, power, pf };
}

const a = reading("a"), b = reading("b");
if (!a || !b) {
  console.error("Usage: node tool/calibrate.ts --a V,W,PF --b V,W,PF [--ref V,W,PF] [--device gadget-1]");
  process.exit(2);
}
const ref = reading("ref") ?? a;
const device = arg("device") ?? "gadget-1";
const rows = [["outlet_1", "A", factorsFrom(ref, a)], ["outlet_2", "B", factorsFrom(ref, b)]] as const;

const diff = (x: number, y: number) => `${(((x - y) / y) * 100).toFixed(2)} %`;
console.log(`Outlet B reads ${diff(b.power, a.power)} power, ${diff(b.voltage, a.voltage)} voltage, ` +
  `${diff(b.pf, a.pf)} PF compared with Outlet A.\n`);
let ok = true;
for (const [, letter, f] of rows) {
  const bad = Object.values(f).some((k) => k < 0.8 || k > 1.2);
  if (bad) ok = false;
  console.log(`Outlet ${letter}: power x${f.power}, voltage x${f.voltage}, pf x${f.pf}${bad ? "  <- outside 0.8..1.2" : ""}`);
}
if (!ok) {
  console.log("\nA factor outside 0.8..1.2 means a faulty meter or wiring (or a load that was not steady):");
  console.log("check the PZEM and measure again. The database refuses such factors.");
  process.exit(1);
}
console.log("\n-- Run in the Supabase SQL editor:");
for (const [key, , f] of rows) {
  console.log(`update public.outlets set power_cal = ${f.power}, voltage_cal = ${f.voltage}, pf_cal = ${f.pf}` +
    ` where device_id = '${device.replace(/'/g, "''")}' and outlet = '${key}';`);
}
