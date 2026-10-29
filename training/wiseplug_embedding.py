# %% [markdown]
# # WisePlug appliance signature embedding
#
# Adapted from Matindife, Sun & Wang (2020), *A Machine-Learning Based Nonintrusive
# Smart Home Appliance Status Recognition*, Mathematical Problems in Engineering,
# doi:10.1155/2020/9356165.
#
# | Base study | WisePlug |
# |---|---|
# | P, I_rms, PF at 1 Hz, multivariate time series | same, from one PZEM-004T v3.0 per outlet |
# | Non-intrusive (mains), needs disaggregation | plug-level: one appliance per meter, no disaggregation |
# | MPS-CNN / LSTM / CNN-LSTM classifiers | the same three, compared; MPS-CNN used as an **embedding** model |
# | Closed-set softmax over known appliances | open set: distance to a signature databank, "no pairing = new appliance" |
# | Transfer learning to a small dataset | pretrain on a public 1 Hz plug dataset, fine-tune on WisePlug recordings |
# | 70:30 split; accuracy, precision, recall, F1 | same, plus unknown-appliance detection rate |
#
# The network turns the first **32 seconds** after switch-on into 16 numbers (an
# embedding). It is trained with a **triplet loss**: windows of the same appliance
# are pulled together, windows of different appliances pushed at least a margin
# apart. A new appliance needs no retraining: its embeddings are simply stored in
# the databank (Supabase `signature_embeddings`).
#
# **Outputs** (download at the end):
# * `embedder.json`: weights + thresholds for the Supabase Edge Function
#   (copy to `supabase/functions/_shared/model/embedder.json`, then redeploy)
# * `embedder_float32.tflite`, `embedder_int8.tflite`: TensorFlow Lite models for
#   the on-device option (not used by the current firmware)
# * figures for the thesis: loss curve, distance histogram, confusion matrices
#
# Runtime: Colab free tier, CPU is enough (the model has about 5,000 parameters).

# %%
import json
import os
import time

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import tensorflow as tf
import keras
from keras import layers
from sklearn.metrics import (ConfusionMatrixDisplay, accuracy_score, classification_report,
                             confusion_matrix, precision_recall_fscore_support)
from sklearn.model_selection import train_test_split

SEED = 42
np.random.seed(SEED)
tf.random.set_seed(SEED)
print("TensorFlow", tf.__version__, "| Keras", keras.__version__)

# %% [markdown]
# ## 1. Settings
#
# `DEMO = True` generates **synthetic** appliances so the whole notebook can be
# tested before any recording exists. Never report demo numbers in the thesis.

# %%
DEMO = True
DATA_CSV = "training_readings.csv"      # WisePlug recordings (section 2)
TEST_CSV = None                          # optional: a separate test day, evaluated with frozen thresholds
PUBLIC_CSV = None                        # optional: public dataset already cut into sessions (section 3)
PUBLIC_HAS_PF = True                     # False if the public data has no power factor

WINDOW = 32                              # readings (seconds) from switch-on; must match the firmware
# Fixed scaling, identical in supabase/functions/_shared/embedder.ts. Not fitted
# to the data, so registering new appliances never changes it.
NORM = dict(powerMaxW=3000.0, currentRefA=0.005, currentMaxA=15.0, minPfPowerW=5.0)
EMBED_DIM = 16
MARGIN = 0.3                             # triplet margin, in embedding distance (0..2)
K = 3                                    # k nearest samples, as in the Edge Function
MODEL_VERSION = "mps-cnn-" + time.strftime("%Y%m%d-%H%M")
COMPARE_ARCHITECTURES = True             # also train LSTM and CNN-LSTM for the comparison table

# %% [markdown]
# ## 2. Data
#
# One CSV row per reading (long format), as exported from the Supabase view
# `training_readings` (`select * from training_readings;` in the SQL editor,
# then *Download CSV*):
#
# | column | meaning |
# |---|---|
# | `session_id` | one switch-on (one window) |
# | `appliance` | appliance **model** label, e.g. `Stand fan (Brand A)`; identical units share it |
# | `mode` | operating mode, e.g. fan speed 0/1/2 |
# | `t_s` | seconds since switch-on (0, 1, 2, ...) |
# | `power_w`, `current_a`, `pf` | the PZEM-004T readings |
# | `instance`, `outlet`, `device_id` | optional, for reporting |
#
# A training class is *appliance + mode*: fan speed 1 and speed 3 look different
# and are not forced together.

# %%
REQUIRED = ["session_id", "appliance", "mode", "t_s", "power_w", "current_a", "pf"]


def load_sessions(df):
    missing = [c for c in REQUIRED if c not in df.columns]
    if missing:
        raise ValueError(f"CSV is missing columns {missing}")
    sessions = []
    for sid, g in df.groupby("session_id", sort=False):
        g = g.sort_values("t_s")
        if len(g) < 24:
            continue  # meter dropouts: the Edge Function would not embed it either
        sessions.append(dict(
            session_id=str(sid),
            appliance=str(g["appliance"].iloc[0]),
            mode=int(g["mode"].iloc[0]),
            instance=str(g["instance"].iloc[0]) if "instance" in g else "",
            power=g["power_w"].to_numpy(float),
            current=g["current_a"].to_numpy(float),
            pf=g["pf"].to_numpy(float),
        ))
    return sessions


def synthetic_sessions(rng, per_class=16):
    """Demo appliances, including several at 55-60 W with different PF and start-up."""
    specs = [  # appliance, mode, steady W, PF, start-up shape
        ("Stand fan A", 0, 40, 0.90, "motor"),
        ("Stand fan A", 2, 57, 0.92, "motor"),
        ("LED floodlight", 0, 57, 0.55, "flat"),
        ("Laptop charger", 0, 58, 0.60, "ramp"),
        ("Soldering iron", 0, 56, 1.00, "heater"),
        ("Phone charger", 0, 8, 0.50, "ramp"),
        ("Electric kettle", 0, 1800, 1.00, "flat"),
        ("Desk lamp CFL", 0, 23, 0.58, "warmup"),
    ]
    t = np.arange(WINDOW)
    shapes = {
        "motor": (1 + 0.6 * np.exp(-t / 1.5), -0.12 * np.exp(-t / 1.5)),
        "ramp": (1 - 0.5 * np.exp(-t / 6), 0 * t),
        "heater": (1 + 0.15 * np.exp(-t / 10), 0 * t),
        "flat": (1 + 0 * t, 0 * t),
        "warmup": (0.7 + 0.3 * (1 - np.exp(-t / 8)), 0 * t),
    }
    out = []
    for appliance, mode, watts, pf, shape in specs:
        gain, dpf = shapes[shape]
        for k in range(per_class):
            base = watts * (1 + rng.normal(0, 0.02))  # run-to-run difference
            p = base * gain * (1 + rng.normal(0, 0.005, WINDOW))
            f = np.clip(pf + dpf + rng.normal(0, 0.005, WINDOW), 0.05, 1)
            v = 230 * (1 + rng.normal(0, 0.005))
            out.append(dict(session_id=f"demo-{appliance}-{mode}-{k}", appliance=appliance, mode=mode,
                            instance="", power=p, current=p / (v * f), pf=f))
    return out


rng = np.random.default_rng(SEED)
if DEMO:
    sessions = synthetic_sessions(rng)
    print("DEMO DATA - for testing the pipeline only")
else:
    try:
        from google.colab import files  # upload the CSV if it is not in the runtime yet
        if not os.path.exists(DATA_CSV):
            files.upload()
    except ImportError:
        pass
    sessions = load_sessions(pd.read_csv(DATA_CSV))


def class_of(s):
    return f"{s['appliance']} | mode {s['mode']}"


summary = pd.Series([class_of(s) for s in sessions]).value_counts().rename("sessions")
print(len(sessions), "sessions,", len(summary), "classes")
summary.to_frame()

# %% [markdown]
# ## 3. Preprocessing and augmentation
#
# Each channel is scaled with a fixed formula (same as the Edge Function):
# * P -> ln(1 + P) / ln(1 + 3000): 5 W and 2 kW loads both fit 0..1, and a 5 %
#   change looks the same at any size;
# * I -> ln(1 + I / 5 mA) / ln(1 + 15 A / 5 mA);
# * PF -> PF, or 0 below 5 W where the meter cannot measure it.
#
# **Limits of 1 Hz.** The meter averages each second, so millisecond inrush
# spikes are invisible; only slow start-up behaviour shows (motor spin-up over
# 1-5 s, charger soft-start, lamp warm-up, a heating element's drift). The
# first reading may cover only part of a second.
#
# Augmentation simulates what changes between real runs: mains voltage (+-1 %),
# meter noise, a partial first second, and switch-on detected one reading late.
# Augmentation is applied to training batches only.

# %%
def preprocess(power, current, pf):
    n = len(power)
    idx = np.minimum(np.arange(WINDOW), n - 1)  # a short signal is padded with its last reading
    p = np.asarray(power, float)[idx]
    i = np.asarray(current, float)[idx]
    f = np.asarray(pf, float)[idx]
    x = np.stack([
        np.log1p(p) / np.log1p(NORM["powerMaxW"]),
        np.log1p(i / NORM["currentRefA"]) / np.log1p(NORM["currentMaxA"] / NORM["currentRefA"]),
        np.where(p >= NORM["minPfPowerW"], np.clip(f, 0, 1), 0.0),
    ], axis=-1)
    return x.astype(np.float32)


def window_of(s):
    return preprocess(s["power"], s["current"], s["pf"])


def augment(s, rng):
    p, i, f = (np.asarray(s[c], float).copy() for c in ("power", "current", "pf"))
    if rng.random() < 0.3:  # switch-on detected one reading later
        p, i, f = (np.append(a[1:], a[-1]) for a in (p, i, f))
    g = 1 + rng.normal(0, 0.01)  # mains voltage
    p = p * g * (1 + rng.normal(0, 0.005, len(p)))
    i = i * g * (1 + rng.normal(0, 0.005, len(i)))
    f = f + rng.normal(0, 0.005, len(f))
    first = rng.uniform(0.3, 1.0)  # the first reading may cover part of a second
    p[0] *= first
    i[0] *= first
    return preprocess(np.clip(p, 0, None), np.clip(i, 0, None), np.clip(f, 0, 1))


s0 = sessions[0]
fig, ax = plt.subplots(1, 3, figsize=(12, 2.5))
for c, a in zip(("power", "current", "pf"), ax):
    a.plot(s0[c][:WINDOW])
    a.set_title(f"{class_of(s0)}: {c}")
    a.set_xlabel("s since switch-on")
plt.tight_layout()

# %% [markdown]
# ## 4. 70:30 split by session
#
# Split whole sessions, stratified by class, **before** augmentation: windows of
# the same run never appear in both sets (that would leak and inflate accuracy).

# %%
labels_all = np.array([class_of(s) for s in sessions])
counts = pd.Series(labels_all).value_counts()
splittable = np.array([counts[c] >= 2 for c in labels_all])
if (~splittable).any():
    print("Only one session, kept in training only:", sorted(set(labels_all[~splittable])))
idx = np.arange(len(sessions))
tr_idx, va_idx = train_test_split(idx[splittable], test_size=0.3, stratify=labels_all[splittable],
                                  random_state=SEED)
tr_idx = np.concatenate([tr_idx, idx[~splittable]])
train_s = [sessions[i] for i in tr_idx]
val_s = [sessions[i] for i in va_idx]
CLASSES = sorted(set(labels_all))
print(len(train_s), "training sessions,", len(val_s), "validation sessions")

# %% [markdown]
# ## 5. Models (the base study's three, as embedding networks)
#
# * **MPS-CNN** (recommended): one small 1D-CNN branch per parameter (P, I, PF),
#   ReLU + average pooling, then global average **and** max pooling (the max
#   keeps start-up peaks), concatenated, dense layers, 16-number unit vector.
# * **LSTM**: one forward LSTM over the 3-channel sequence.
# * **CNN-LSTM**: a shared Conv1D feature extractor followed by an LSTM.
#
# The runtime in the Edge Function (`embedder.ts`) implements the MPS-CNN only.

# %%
def head(x):
    x = layers.Dense(32, activation="relu", name="fc1")(x)
    x = layers.Dropout(0.2, name="dropout")(x)
    x = layers.Dense(EMBED_DIM, name="embedding")(x)
    return layers.UnitNormalization(name="unit")(x)


def build_mps_cnn():
    inp = keras.Input((WINDOW, 3), name="signal")
    branches = []
    for c, name in enumerate(["power", "current", "pf"]):
        x = layers.Lambda(lambda t, c=c: t[:, :, c:c + 1], name=f"{name}_in")(inp)
        x = layers.Conv1D(8, 5, padding="same", activation="relu", name=f"{name}_conv1")(x)
        x = layers.AveragePooling1D(2, name=f"{name}_pool1")(x)
        x = layers.Conv1D(16, 3, padding="same", activation="relu", name=f"{name}_conv2")(x)
        x = layers.AveragePooling1D(2, name=f"{name}_pool2")(x)
        branches.append(layers.Concatenate(name=f"{name}_out")(
            [layers.GlobalAveragePooling1D(name=f"{name}_gap")(x),
             layers.GlobalMaxPooling1D(name=f"{name}_gmp")(x)]))
    return keras.Model(inp, head(layers.Concatenate(name="merge")(branches)), name="mps_cnn")


def build_lstm():
    inp = keras.Input((WINDOW, 3), name="signal")
    return keras.Model(inp, head(layers.LSTM(32, name="lstm")(inp)), name="lstm")


def build_cnn_lstm():
    inp = keras.Input((WINDOW, 3), name="signal")
    x = layers.Conv1D(16, 5, padding="same", activation="relu", name="conv")(inp)
    x = layers.AveragePooling1D(2, name="pool")(x)
    return keras.Model(inp, head(layers.LSTM(32, name="lstm")(x)), name="cnn_lstm")


BUILDERS = {"MPS-CNN": build_mps_cnn, "LSTM": build_lstm, "CNN-LSTM": build_cnn_lstm}
for name, build in BUILDERS.items():
    print(f"{name}: {build().count_params():,} parameters")
build_mps_cnn().summary()

# %% [markdown]
# ## 6. Triplet loss (metric learning)
#
# Each batch holds P classes x K windows. For every window (the *anchor*) the
# loss takes its farthest same-class window and its nearest other-class window
# ("batch-hard", Hermans et al. 2017) and asks
# `d(anchor, positive) + margin <= d(anchor, negative)`.

# %%
def batch_hard_triplet_loss(labels, emb, margin=MARGIN):
    d2 = tf.reduce_sum(tf.square(emb[:, None, :] - emb[None, :, :]), axis=-1)
    d = tf.sqrt(tf.maximum(d2, 1e-12))
    same = tf.equal(labels[:, None], labels[None, :])
    eye = tf.eye(tf.shape(labels)[0], dtype=tf.bool)
    hardest_pos = tf.reduce_max(tf.where(tf.logical_and(same, tf.logical_not(eye)), d, 0.0), axis=1)
    hardest_neg = tf.reduce_min(tf.where(same, 4.0, d), axis=1)  # unit vectors: d <= 2
    return tf.reduce_mean(tf.nn.relu(hardest_pos - hardest_neg + margin))


def by_class(sess):
    groups = {}
    for s in sess:
        groups.setdefault(class_of(s), []).append(s)
    return list(groups.values())


def pk_batch(groups, rng, p=8, k=4):
    chosen = rng.choice(len(groups), size=min(p, len(groups)), replace=False)
    xs, ys = [], []
    for c in chosen:
        for j in rng.choice(len(groups[c]), size=k, replace=True):
            xs.append(augment(groups[c][j], rng))
            ys.append(c)
    return tf.constant(np.stack(xs)), tf.constant(np.array(ys, np.int32))


def train(model, sess, epochs, lr, steps=40, label=""):
    groups = by_class(sess)
    if len(groups) < 2:
        raise ValueError("Need at least 2 classes to train")
    opt = keras.optimizers.Adam(lr)
    opt.build(model.trainable_variables)

    @tf.function
    def step(x, y):
        with tf.GradientTape() as tape:
            loss = batch_hard_triplet_loss(y, model(x, training=True))
        grads = tape.gradient(loss, model.trainable_variables)
        opt.apply_gradients(zip(grads, model.trainable_variables))
        return loss

    rng = np.random.default_rng(SEED)
    history = []
    for e in range(epochs):
        history.append(float(np.mean([step(*pk_batch(groups, rng)).numpy() for _ in range(steps)])))
        if e % 10 == 0 or e == epochs - 1:
            print(f"{label} epoch {e:3d}  loss {history[-1]:.4f}")
    return history


def set_trainable(model, convs):
    for layer in model.layers:
        if "_conv" in layer.name:
            layer.trainable = convs

# %% [markdown]
# ## 7. Transfer learning: pretrain on public data, fine-tune on WisePlug
#
# Recommended public data (low frequency, plug level):
# * **iAWE** (Batra et al. 2013): 1 Hz plug meters with V, I, P, apparent power
#   and phase, so PF = P / S. Load it with NILMTK and export per appliance.
# * **ACS-F2** (Ridi et al. 2014): 225 appliances, 15 categories, but one reading
#   per **10 s**: useful for steady levels, not for start-up shape.
# * **ECO**, **UK-DALE** plugs: power only. Then set `PUBLIC_HAS_PF = False`:
#   the PF branch is re-initialised before fine-tuning (the separate branches of
#   the MPS-CNN make this possible) and learns from WisePlug data alone.
#
# `sessions_from_recording` cuts a long recording into switch-on windows. Use
# it once per appliance, then concatenate and save as `PUBLIC_CSV` (same long
# format as section 2).

# %%
def sessions_from_recording(df, appliance, mode=0, prefix="pub", on_w=3.5, off_w=2.0, quiet_s=10, max_gap_s=5):
    """df: columns timestamp, power_w, and current_a / pf / apparent_va / phase_deg when available."""
    d = df.copy()
    d["timestamp"] = pd.to_datetime(d["timestamp"])
    cols = [c for c in ["power_w", "current_a", "pf", "apparent_va", "phase_deg"] if c in d]
    d = d.set_index("timestamp").sort_index()[cols].resample("1s").mean().interpolate(limit=max_gap_s)
    if "pf" not in d:
        if "apparent_va" in d:
            d["pf"] = (d["power_w"] / d["apparent_va"].replace(0, np.nan)).clip(0, 1)
        elif "phase_deg" in d:
            d["pf"] = np.cos(np.radians(d["phase_deg"])).abs()
        else:
            d["pf"] = 0.0
    if "current_a" not in d:  # estimate from a 230 V mains
        d["current_a"] = d["power_w"] / (230 * d["pf"].where(d["pf"] > 0.05, 1.0))
    d = d.fillna(0.0)
    p = d["power_w"].to_numpy()
    quiet = pd.Series((p < off_w).astype(float)).rolling(quiet_s).min().shift(1).to_numpy() == 1.0
    out = []
    for k, s in enumerate(np.where((p >= on_w) & quiet)[0]):
        if s + WINDOW > len(d):
            break
        seg = d.iloc[s:s + WINDOW]
        out.append(dict(session_id=f"{prefix}-{appliance}-{k}", appliance=appliance, mode=mode, instance="",
                        power=seg["power_w"].to_numpy(float), current=seg["current_a"].to_numpy(float),
                        pf=seg["pf"].to_numpy(float)))
    return out


model = build_mps_cnn()
pretrain_history = []
if PUBLIC_CSV:
    public = load_sessions(pd.read_csv(PUBLIC_CSV))
    print(len(public), "public sessions")
    pretrain_history = train(model, public, epochs=60, lr=1e-3, label="pretrain")
    if not PUBLIC_HAS_PF:  # the PF branch learned nothing useful: start it fresh
        init = keras.initializers.GlorotUniform(seed=SEED)
        for name in ("pf_conv1", "pf_conv2"):
            layer = model.get_layer(name)
            kernel, bias = layer.get_weights()
            layer.set_weights([np.array(init(kernel.shape)), np.zeros_like(bias)])
    # Fine-tune: first only the dense layers (keep the pretrained filters), then all, slowly.
    set_trainable(model, False)
    history = train(model, train_s, epochs=20, lr=1e-3, label="fine-tune (dense)")
    set_trainable(model, True)
    history += train(model, train_s, epochs=60, lr=1e-4, label="fine-tune (all)")
else:
    history = train(model, train_s, epochs=80, lr=1e-3, label="train")

plt.figure(figsize=(6, 3))
if pretrain_history:
    plt.plot(pretrain_history, label="pretrain (public)")
plt.plot(range(len(pretrain_history), len(pretrain_history) + len(history)), history, label="WisePlug")
plt.xlabel("epoch")
plt.ylabel("triplet loss")
plt.legend()
plt.tight_layout()
plt.savefig("loss.png", dpi=150)

# %% [markdown]
# ## 8. Databank, k-NN matching and thresholds T1 / T2
#
# The training sessions form the databank. A validation window is compared with
# each class: mean distance to its k = 3 nearest stored embeddings (as the Edge
# Function does per appliance instance and mode).
#
# **Setting the thresholds from validation data:**
# * *genuine* distance: a window to its own class;
# * *impostor* distance: a window to the nearest **other** class (this is how
#   close a different, possibly unregistered, appliance gets).
# * **T1 = 1st percentile of impostor distances**: at most ~1 % of other
#   appliances fall inside T1, which bounds confident mislabels (a mislabel
#   would apply the wrong appliance's cutoff);
# * **T2 = 95th percentile of genuine distances** (at least T1 + 0.05): 95 % of
#   runs of a registered appliance are at least offered as a candidate;
# * tie margin = 0.25 x T1: two candidates closer than that are "nearly tied".

# %%
def embed_all(m, sess):
    return m.predict(np.stack([window_of(s) for s in sess]), verbose=0)


def class_distances(q, bank_e, bank_y):
    out = {}
    for c in np.unique(bank_y):
        d = np.sort(np.linalg.norm(bank_e[bank_y == c] - q, axis=1))[:K]
        out[c] = float(d.mean())
    return out


def decide(dists, t1, t2, tie):
    """Mirror of decide() in supabase/functions/_shared/knn.ts (without outlet context)."""
    ranked = sorted(dists.items(), key=lambda kv: kv[1])
    if not ranked or ranked[0][1] > t2:
        return "UNKNOWN", None
    c, d = ranked[0]
    if d > t1:
        return "AMBIGUOUS", c
    if len(ranked) > 1 and ranked[1][1] <= t1 and ranked[1][1] - d < tie:
        return "AMBIGUOUS", c
    return "CONFIDENT", c


def thresholds_from(m, bank, queries):
    bank_e, bank_y = embed_all(m, bank), np.array([class_of(s) for s in bank])
    genuine, impostor = [], []
    for s, q in zip(queries, embed_all(m, queries)):
        d = class_distances(q, bank_e, bank_y)
        own = class_of(s)
        if own in d:
            genuine.append(d[own])
        others = [v for c, v in d.items() if c != own]
        if others:
            impostor.append(min(others))
    t1 = float(np.percentile(impostor, 1))
    t2 = max(float(np.percentile(genuine, 95)), t1 + 0.05)
    return dict(t1=round(t1, 4), t2=round(t2, 4), tieMargin=round(0.25 * t1, 4)), genuine, impostor


TH, genuine, impostor = thresholds_from(model, train_s, val_s)
print("Thresholds:", TH)
plt.figure(figsize=(7, 3))
plt.hist(genuine, bins=30, alpha=0.6, label="genuine (own appliance)")
plt.hist(impostor, bins=30, alpha=0.6, label="impostor (nearest other)")
for v, n in ((TH["t1"], "T1"), (TH["t2"], "T2")):
    plt.axvline(v, color="k", ls="--")
    plt.text(v, plt.ylim()[1] * 0.9, n)
plt.xlabel("embedding distance")
plt.legend()
plt.tight_layout()
plt.savefig("distances.png", dpi=150)

# %% [markdown]
# ## 9. Evaluation (thesis metrics)
#
# 1. **Closed set** (nearest class, no thresholds): accuracy, precision, recall,
#    F1 per class, confusion matrix, as in the base study.
# 2. **Open set** (with T1/T2): a run is correct only if CONFIDENT and right;
#    AMBIGUOUS/UNKNOWN count as "asked the user".
# 3. **Unknown-appliance detection**, leave-one-appliance-out: remove every
#    mode of one appliance from the databank, then run its windows; they should
#    end UNKNOWN (or at least not CONFIDENT).
#
# The thresholds were chosen on this validation set, so its open-set numbers are
# slightly optimistic: for the final thesis numbers record a separate test day
# (`TEST_CSV`) and evaluate it with these frozen thresholds.

# %%
def evaluate(m, bank, queries, th, title):
    bank_e, bank_y = embed_all(m, bank), np.array([class_of(s) for s in bank])
    y_true = [class_of(s) for s in queries]
    closed, opened, outcomes = [], [], []
    for q in embed_all(m, queries):
        d = class_distances(q, bank_e, bank_y)
        closed.append(min(d, key=d.get))
        outcome, c = decide(d, th["t1"], th["t2"], th["tieMargin"])
        outcomes.append(outcome)
        opened.append(c if outcome == "CONFIDENT" else "ASKED USER")
    print(f"=== {title}: closed set ===  accuracy {accuracy_score(y_true, closed):.3f}")
    print(classification_report(y_true, closed, zero_division=0))
    print(f"=== {title}: open set ===")
    print(pd.Series(outcomes).value_counts().to_string())
    wrong_confident = sum(o == "CONFIDENT" and p != t for o, p, t in zip(outcomes, opened, y_true))
    print(f"correct CONFIDENT {np.mean([p == t for p, t in zip(opened, y_true)]):.3f}, "
          f"wrong CONFIDENT {wrong_confident} of {len(y_true)}")
    labels = sorted(set(y_true)) + ["ASKED USER"]
    fig, ax = plt.subplots(1, 2, figsize=(14, 6))
    ConfusionMatrixDisplay(confusion_matrix(y_true, closed, labels=labels[:-1]), display_labels=labels[:-1]).plot(
        ax=ax[0], xticks_rotation=90, colorbar=False)
    ax[0].set_title(f"{title}: closed set")
    ConfusionMatrixDisplay(confusion_matrix(y_true, opened, labels=labels), display_labels=labels).plot(
        ax=ax[1], xticks_rotation=90, colorbar=False)
    ax[1].set_title(f"{title}: open set (T1/T2)")
    plt.tight_layout()
    plt.savefig(f"confusion_{title.lower().replace(' ', '_')}.png", dpi=150)
    p, r, f, _ = precision_recall_fscore_support(y_true, closed, average="macro", zero_division=0)
    return dict(accuracy=accuracy_score(y_true, closed), macro_precision=p, macro_recall=r, macro_f1=f,
                confident_correct=float(np.mean([p_ == t for p_, t in zip(opened, y_true)])),
                wrong_confident=wrong_confident)


def unknown_detection(m, bank, queries, th):
    rows = []
    for appliance in sorted({s["appliance"] for s in queries}):
        b = [s for s in bank if s["appliance"] != appliance]
        q = [s for s in queries if s["appliance"] == appliance]
        if not b or not q:
            continue
        bank_e, bank_y = embed_all(m, b), np.array([class_of(s) for s in b])
        out = [decide(class_distances(e, bank_e, bank_y), th["t1"], th["t2"], th["tieMargin"])[0]
               for e in embed_all(m, q)]
        rows.append(dict(appliance=appliance, runs=len(out),
                         unknown=np.mean([o == "UNKNOWN" for o in out]),
                         ambiguous=np.mean([o == "AMBIGUOUS" for o in out]),
                         wrongly_confident=np.mean([o == "CONFIDENT" for o in out])))
    df = pd.DataFrame(rows)
    print("Unknown-appliance detection rate (UNKNOWN):", round(float((df.unknown * df.runs).sum() / df.runs.sum()), 3))
    print("Not auto-labelled (UNKNOWN or AMBIGUOUS):",
          round(float(((df.unknown + df.ambiguous) * df.runs).sum() / df.runs.sum()), 3))
    return df


results = {"MPS-CNN": evaluate(model, train_s, val_s, TH, "Validation")}
unknown_detection(model, train_s, val_s, TH)

# %% [markdown]
# ### Baseline: hand-crafted features + k-NN
#
# The method the system falls back to without a model (mean P, I, PF, the
# variation and the start-up peak over the same window, z-scored). If the CNN
# does not beat it on *your* data, say so in the thesis: at 1 Hz most of the
# information is in the steady levels.

# %%
def handcrafted(s):
    p, i, f = (np.asarray(s[c][:WINDOW], float) for c in ("power", "current", "pf"))
    steady = slice(5, None)
    mean_p = p[steady].mean()
    return np.array([mean_p, i[steady].mean(), f[steady].mean(),
                     p[steady].std() / max(mean_p, 1e-6), p[:5].max() / max(mean_p, 1e-6)])


Xtr = np.stack([handcrafted(s) for s in train_s])
mu, sd = Xtr.mean(0), Xtr.std(0) + 1e-9
ytr = np.array([class_of(s) for s in train_s])
pred = [min(class_distances((handcrafted(s) - mu) / sd, (Xtr - mu) / sd, ytr).items(), key=lambda kv: kv[1])[0]
        for s in val_s]
yva = [class_of(s) for s in val_s]
p, r, f, _ = precision_recall_fscore_support(yva, pred, average="macro", zero_division=0)
results["Features k-NN (baseline)"] = dict(accuracy=accuracy_score(yva, pred), macro_precision=p,
                                           macro_recall=r, macro_f1=f)
print("Baseline accuracy", round(accuracy_score(yva, pred), 3), "macro F1", round(f, 3))

# %% [markdown]
# ### Architecture comparison (same data, loss and training budget, no pretraining)

# %%
if COMPARE_ARCHITECTURES:
    for name in ("LSTM", "CNN-LSTM"):
        tf.random.set_seed(SEED)
        m = BUILDERS[name]()
        train(m, train_s, epochs=80, lr=1e-3, label=name)
        th, _, _ = thresholds_from(m, train_s, val_s)
        results[name] = evaluate(m, train_s, val_s, th, name)
    for name, build in BUILDERS.items():
        if name in results:
            m = model if name == "MPS-CNN" else build()
            x = np.stack([window_of(s) for s in val_s[:1]])
            m.predict(x, verbose=0)
            t0 = time.perf_counter()
            for _ in range(50):
                m(x, training=False)
            results[name]["parameters"] = build().count_params()
            results[name]["ms_per_window"] = (time.perf_counter() - t0) / 50 * 1000
results_table = pd.DataFrame(results).T
results_table.round(3)

# %%
if TEST_CSV:
    test_s = load_sessions(pd.read_csv(TEST_CSV))
    evaluate(model, train_s + val_s, test_s, TH, "Test")
    unknown_detection(model, train_s + val_s, test_s, TH)

# %% [markdown]
# ## 10. Export
#
# * `embedder.json` for the Edge Function, with **parity vectors**: inputs and
#   the Keras outputs. `supabase/tests/embedder.test.ts` checks the TypeScript
#   implementation reproduces them, and the NumPy check below does the same here.
# * TensorFlow Lite (float32 and int8) of the network up to the 16-number
#   output (normalise to unit length in C), for the on-device option.

# %%
def conv_json(name):
    k, b = model.get_layer(name).get_weights()
    return {"kernel": np.round(k, 7).tolist(), "bias": np.round(b, 7).tolist()}


parity_sessions = val_s[:3] if len(val_s) >= 3 else sessions[:3]
export = {
    "version": MODEL_VERSION,
    "architecture": "mps-cnn-v1",
    "windowLength": WINDOW,
    "norm": NORM,
    "thresholds": TH,
    "branches": {c: {"conv1": conv_json(f"{c}_conv1"), "conv2": conv_json(f"{c}_conv2")}
                 for c in ("power", "current", "pf")},
    "fc1": conv_json("fc1"),
    "embedding": conv_json("embedding"),
    "parity": {
        "inputs": [{c: np.round(s[c][:WINDOW], 4).tolist() for c in ("power", "current", "pf")}
                   for s in parity_sessions],
    },
    "training": {"demo": DEMO, "sessions": len(sessions), "classes": CLASSES, "embedDim": EMBED_DIM,
                 "margin": MARGIN, "pretrained": bool(PUBLIC_CSV),
                 "validation": {k: float(v) for k, v in results["MPS-CNN"].items()}},
}
export["parity"]["outputs"] = np.round(model.predict(np.stack(
    [preprocess(**{c: np.array(v) for c, v in x.items()}) for x in export["parity"]["inputs"]]), verbose=0), 6).tolist()


def numpy_embed(e, signal):
    """Independent re-implementation of embedder.ts, from the JSON only."""
    x = preprocess(signal["power"], signal["current"], signal["pf"])

    def conv(h, w):
        k, b = np.array(w["kernel"]), np.array(w["bias"])
        pad = (k.shape[0] - 1) // 2
        hp = np.pad(h, ((pad, pad), (0, 0)))
        return np.maximum(0, np.stack([np.einsum("ki,kio->o", hp[t:t + k.shape[0]], k) + b
                                       for t in range(h.shape[0])]))

    def pool(h):
        return h[: h.shape[0] // 2 * 2].reshape(-1, 2, h.shape[1]).mean(1)

    merged = []
    for ci, c in enumerate(("power", "current", "pf")):
        h = pool(conv(pool(conv(x[:, ci:ci + 1], e["branches"][c]["conv1"])), e["branches"][c]["conv2"]))
        merged += [h.mean(0), h.max(0)]
    v = np.concatenate(merged)
    v = np.maximum(0, v @ np.array(e["fc1"]["kernel"]) + e["fc1"]["bias"])
    v = v @ np.array(e["embedding"]["kernel"]) + e["embedding"]["bias"]
    return v / np.linalg.norm(v)


err = max(np.abs(numpy_embed(export, x) - np.array(y)).max()
          for x, y in zip(export["parity"]["inputs"], export["parity"]["outputs"]))
print("max |NumPy - Keras| =", err)
assert err < 1e-4, "the exported JSON does not reproduce Keras: do not deploy it"
with open("embedder.json", "w") as fh:
    json.dump(export, fh)
print("embedder.json", round(os.path.getsize("embedder.json") / 1024, 1), "KB")

# %%
raw = keras.Model(model.input, model.get_layer("embedding").output)


@tf.function(input_signature=[tf.TensorSpec([1, WINDOW, 3], tf.float32)])
def serve(x):
    return raw(x, training=False)


def tflite(int8):
    conv = tf.lite.TFLiteConverter.from_concrete_functions([serve.get_concrete_function()], raw)
    if int8:
        reps = np.stack([window_of(s) for s in train_s])

        def representative():
            for x in reps[:200]:
                yield [x[None].astype(np.float32)]

        conv.optimizations = [tf.lite.Optimize.DEFAULT]
        conv.representative_dataset = representative
        conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        conv.inference_input_type = tf.int8
        conv.inference_output_type = tf.int8
    return conv.convert()


for name, int8 in (("embedder_float32.tflite", False), ("embedder_int8.tflite", True)):
    try:
        data = tflite(int8)
        with open(name, "wb") as fh:
            fh.write(data)
        print(name, round(len(data) / 1024, 1), "KB")
    except Exception as exc:  # the Edge Function option does not need TFLite
        print(name, "not converted:", exc)

# %%
try:
    from google.colab import files
    for name in ["embedder.json", "embedder_float32.tflite", "embedder_int8.tflite", "loss.png",
                 "distances.png", "confusion_validation.png"]:
        if os.path.exists(name):
            files.download(name)
except ImportError:
    print("Files are in", os.getcwd())
