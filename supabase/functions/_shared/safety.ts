// Server-side reading of a safety event reported by the plug. The ESP32 has
// already acted (warned, locked the outlet); this decides how serious it is,
// what to log and what the push notification says. Pure logic, tested in node.

export const LEARNING_SESSIONS = 7; // firmware LEARNING_SESSIONS

export const ALERT_TYPES = [
  "RUNTIME_WARNING", // ran past its limit; 60 s countdown before lockout
  "SENSOR_UNAVAILABLE", // meter stopped answering while running
  "LOCKED_OUT", // a warning went unanswered, outlet switched off
  "OVERCURRENT", // above the outlet's hardware rating
  "POWER_ANOMALY", // far above its learned signature
] as const;
export type AlertType = (typeof ALERT_TYPES)[number];

export interface AlertInput {
  type: AlertType;
  outlet: "outlet_1" | "outlet_2";
  applianceName: string;
  runtimeS: number;
  limitS: number;
  baselineS: number;
  learned: boolean;
  sessionCount: number;
  powerW: number;
  currentA: number;
}

export interface Evaluation {
  severity: "info" | "warning" | "critical";
  title: string;
  message: string;
  /** Runtime as a multiple of the learned typical use (null while learning). */
  baselineRatio: number | null;
}

const minutes = (s: number) => `${Math.max(1, Math.round(s / 60))} min`;
const outletName = (o: string) => (o === "outlet_1" ? "Outlet 1" : "Outlet 2");

export function evaluate(a: AlertInput): Evaluation {
  const where = `${a.applianceName} on ${outletName(a.outlet)}`;
  const ratio = a.learned && a.baselineS > 0 ? a.runtimeS / a.baselineS : null;
  switch (a.type) {
    case "OVERCURRENT":
      return {
        severity: "critical",
        title: "WisePlug: overcurrent, outlet locked",
        message: `${where} drew ${a.currentA.toFixed(2)} A, above the outlet's rating. ` +
          "Unplug it and inspect it before resetting.",
        baselineRatio: ratio,
      };
    case "POWER_ANOMALY":
      return {
        severity: "critical",
        title: "WisePlug: abnormal power, outlet locked",
        message: `${where} drew ${Math.round(a.powerW)} W, far more than its learned signature. ` +
          "Inspect it before resetting.",
        baselineRatio: ratio,
      };
    case "LOCKED_OUT":
      return {
        severity: "critical",
        title: "WisePlug: outlet locked out",
        message: `${where} ran ${minutes(a.runtimeS)} and the warning went unanswered, ` +
          "so the outlet was switched off.",
        baselineRatio: ratio,
      };
    case "SENSOR_UNAVAILABLE":
      return {
        severity: "warning",
        title: "WisePlug: power meter not responding",
        message: `${where} is running but its meter stopped reporting. ` +
          "Open WisePlug within 60 s or the outlet locks.",
        baselineRatio: ratio,
      };
    case "RUNTIME_WARNING": {
      // Adaptive baseline: after 7 uses the limit is learned from the typical
      // use; before that only the backstop (safety ceiling) applies.
      const basis = a.learned
        ? `its typical use is ${minutes(a.baselineS)} (learned from ${LEARNING_SESSIONS} uses)`
        : `it is still learning (${Math.min(a.sessionCount, LEARNING_SESSIONS)} of ` +
          `${LEARNING_SESSIONS} uses), so the ${minutes(a.limitS)} safety ceiling applies`;
      return {
        severity: ratio != null && ratio >= 2 ? "critical" : "warning",
        title: "WisePlug: safety limit reached",
        message: `${where} has run ${minutes(a.runtimeS)}; ${basis}. ` +
          "Open WisePlug within 60 s to extend, or the outlet locks.",
        baselineRatio: ratio,
      };
    }
  }
}
