// The deployed embedding model. Replace model/embedder.json with the file the
// Colab notebook exports and redeploy; while it is the placeholder, `model`
// is null and identification uses the feature k-NN (_shared/knn.ts).
import raw from "./model/embedder.json" with { type: "json" };
import { parseModel } from "./embedder.ts";

export const model = parseModel(raw);
