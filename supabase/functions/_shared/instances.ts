// Loads a device's appliance instances with their signature samples and the
// outlet each is running on, in the shape _shared/knn.ts matches against.
// With a model, also each sample's embedding (computed and stored if missing).
import { db } from "./db.ts";
import { embed, type EmbedderModel, type Signal } from "./embedder.ts";
import type { FeatureVector, Instance } from "./knn.ts";

type Row = Record<string, unknown>;
const n = (v: unknown) => (v == null ? null : Number(v));

export function featuresFromRow(row: Row): FeatureVector {
  return {
    power: Number(row.power_w),
    current: Number(row.current_a),
    pf: n(row.power_factor),
    reactive: n(row.reactive_var),
    cv: n(row.power_cv),
    peakRatio: n(row.peak_ratio),
  };
}

export function sampleColumns(f: FeatureVector) {
  const r = (v: number | null | undefined, d: number) => (v == null ? null : Math.round(v * 10 ** d) / 10 ** d);
  return {
    power_w: r(f.power, 2),
    current_a: r(f.current, 3),
    power_factor: r(f.pf, 3),
    reactive_var: r(f.reactive, 2),
    power_cv: r(f.cv, 4),
    peak_ratio: r(f.peakRatio, 3),
  };
}

/** Every instance of [deviceId]. [ignoreOutlet]'s active row is treated as ended. */
export async function loadInstances(
  deviceId: string,
  ignoreOutlet?: string,
  model?: EmbedderModel | null,
): Promise<Instance[]> {
  const [instances, samples, active, embeddings] = await Promise.all([
    db.from("appliance_instances")
      .select("id, name, type_id, max_runtime_mins, last_outlet, appliance_types(name)")
      .eq("device_id", deviceId),
    db.from("signature_samples")
      .select("id, instance_id, mode, power_w, current_a, power_factor, reactive_var, power_cv, peak_ratio, window_signal, appliance_instances!inner(device_id)")
      .eq("appliance_instances.device_id", deviceId),
    db.from("active_sessions").select("outlet, instance_id").eq("device_id", deviceId).not("instance_id", "is", null),
    db.from("signature_embeddings").select("sample_id, embedding")
      .eq("device_id", deviceId).eq("model_version", model?.version ?? ""),
  ]);
  for (const r of [instances, samples, active, embeddings]) if (r.error) throw r.error;
  const stored = new Map<number, number[]>(embeddings.data!.map((e: Row) => [Number(e.sample_id), e.embedding as number[]]));
  const activeOn = new Map<string, string>();
  for (const a of active.data!) if (a.outlet !== ignoreOutlet) activeOn.set(String(a.instance_id), String(a.outlet));
  return instances.data!.map((row: Row) => ({
    id: String(row.id),
    name: String(row.name),
    typeId: String(row.type_id),
    typeName: String((row.appliance_types as Row | null)?.name ?? "Appliance"),
    cutoffS: Number(row.max_runtime_mins) * 60,
    lastOutlet: (row.last_outlet as string | null) ?? null,
    activeOn: activeOn.get(String(row.id)) ?? null,
    samples: samples.data!
      .filter((s: Row) => s.instance_id === row.id)
      .map((s: Row) => ({
        id: Number(s.id),
        mode: Number(s.mode),
        features: featuresFromRow(s),
        signal: (s.window_signal as Signal | null) ?? null,
        embedding: stored.get(Number(s.id)) ?? null,
      })),
  }));
}

/**
 * Embeds every sample that has a signal but no embedding for [model] yet (new
 * samples, or all of them after a retrained model is deployed) and stores the
 * results, so each sample is computed once per model version.
 */
export async function ensureEmbeddings(deviceId: string, instances: Instance[], model: EmbedderModel) {
  const rows = [];
  for (const instance of instances) {
    for (const s of instance.samples) {
      if (s.embedding || !s.signal || s.id == null) continue;
      s.embedding = embed(model, s.signal);
      rows.push({ sample_id: s.id, device_id: deviceId, model_version: model.version, embedding: s.embedding });
    }
  }
  if (!rows.length) return;
  const { error } = await db.from("signature_embeddings")
    .upsert(rows, { onConflict: "sample_id,model_version", ignoreDuplicates: true });
  if (error) throw error;
}
