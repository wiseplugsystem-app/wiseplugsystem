// Per-outlet sensor calibration, so a run measured on Outlet A and one
// measured on Outlet B are in the same units: two PZEM-004T modules can read
// the same load a little differently. The factors are in the outlets table
// (power_cal, voltage_cal, pf_cal; 1.0 = as measured), found with
// tool/calibrate.ts (docs/appliance-identification.md, "Calibrating the outlets").
//
// recognize-appliance applies them to the plug's summary before anything is
// stored or matched. Scaling every reading by a factor scales its average by
// the same factor, and leaves ratios (start-up peak, power variation) and
// times unchanged, so this equals calibrating each reading on the plug.
import type { Features } from "./matching.ts";

export interface Calibration {
  power: number;
  voltage: number;
  pf: number;
}

export const NO_CALIBRATION: Calibration = { power: 1, voltage: 1, pf: 1 };

/** The outlets row's factors (numerics may arrive as strings). */
export function calibrationFromRow(r: Record<string, unknown> | null | undefined): Calibration {
  const f = (v: unknown) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Number(v) : 1);
  return r ? { power: f(r.power_cal), voltage: f(r.voltage_cal), pf: f(r.pf_cal) } : NO_CALIBRATION;
}

const round = (v: number, d: number) => Math.round(v * 10 ** d) / 10 ** d;
const scale = (v: number | null | undefined, k: number, d: number) => (v == null ? v : round(v * k, d));

/** The summary as if measured by the reference meter. */
export function calibrate(x: Features, c: Calibration): Features {
  const pf = scale(x.avg_pf, c.pf, 3);
  return {
    ...x,
    avg_power_w: scale(x.avg_power_w, c.power, 2),
    standby_power_w: scale(x.standby_power_w, c.power, 2),
    avg_voltage_v: scale(x.avg_voltage_v, c.voltage, 1),
    avg_pf: pf == null ? pf : Math.min(pf, 1),
  };
}

/** One steady reading of the calibration load. */
export interface CalibrationReading {
  power: number;
  voltage: number;
  pf: number;
}

/**
 * The factors that make [measured] (an outlet's reading of the load) equal
 * [reference] (the same load on the reference outlet or meter).
 */
export function factorsFrom(reference: CalibrationReading, measured: CalibrationReading): Calibration {
  const k = (ref: number, x: number, name: string) => {
    if (!(ref > 0) || !(x > 0)) throw new Error(`${name} must be above 0 in both readings`);
    return round(ref / x, 4);
  };
  return {
    power: k(reference.power, measured.power, "power"),
    voltage: k(reference.voltage, measured.voltage, "voltage"),
    pf: k(reference.pf, measured.pf, "pf"),
  };
}
