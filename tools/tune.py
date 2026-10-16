#!/usr/bin/env python3
"""Learning pipeline, part 2: fit lightweight, explainable models on the
data from tools/datagen.py, with a train/test split BY GAME (no position
of a test game is ever seen in training).

1. Evaluation weights (Texel-style): the engine's evaluation is
   PeSTO + sum_i w_i f_i (tapered); fit the 2 x NFEAT weights so that the
   win probability 1 / (1 + 10^(-E/400)) matches a blend of the Stockfish
   evaluation's win probability and the game result. Reports test loss for
   the current weights and the fitted ones; writes tools/weights.json only
   with --write and only if the test loss improves.
2. Search-cost model (complexity quantity D): predict log2 of the nodes
   needed to finish depth 7 from cheap position features, compared with
   the naive extrapolation from the depth-5 cost.
3. Remaining-game-length model (input to complexity quantity C).
4. Branching-growth model: log legal moves k plies later from features now
   (input to the quantity-A extrapolation).
All model coefficients and test metrics go to data/models.json.
"""
import argparse
import json
import math
import os

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(path):
    rows = [json.loads(l) for l in open(path)]
    return [r for r in rows if r.get("features") and r.get("sf_cp_white") is not None]


def split(rows, frac=0.8, seed=7):
    games = sorted({r["game"] for r in rows})
    rng = np.random.default_rng(seed)
    rng.shuffle(games)
    train_g = set(games[: int(len(games) * frac)])
    tr = [r for r in rows if r["game"] in train_g]
    te = [r for r in rows if r["game"] not in train_g]
    return tr, te


def sig(x):
    return 1.0 / (1.0 + np.power(10.0, -x / 400.0))


def eval_design(rows, nfeat):
    f = np.array([r["features"][:nfeat] for r in rows], dtype=float)
    mg = np.array([r["features"][nfeat] for r in rows], dtype=float)
    eg = np.array([r["features"][nfeat + 1] for r in rows], dtype=float)
    ph = np.minimum(np.array([r["features"][nfeat + 2] for r in rows], dtype=float), 24) / 24.0
    base = mg * ph + eg * (1 - ph)
    x = np.concatenate([f * ph[:, None], f * (1 - ph)[:, None]], axis=1)
    return base, x


def eval_target(rows, lam):
    sf = np.clip(np.array([r["sf_cp_white"] for r in rows], dtype=float), -2000, 2000)
    res = np.array([r["result_white"] for r in rows], dtype=float)
    return lam * sig(sf) + (1 - lam) * res


def loss(w, base, x, t):
    return float(np.mean((sig(base + x @ w) - t) ** 2))


def fit_eval(base, x, t, w0, lam=0.0, iters=30):
    """Gauss-Newton on the squared win-probability error with a ridge
    penalty lam * |w - w0|^2 (shrinkage toward the hand weights)."""
    w = w0.copy()
    k = math.log(10) / 400.0
    n = len(t)
    obj = lambda v: loss(v, base, x, t) + lam * float(np.sum((v - w0) ** 2)) / 1e6
    best = (obj(w), w.copy())
    for _ in range(iters):
        p = sig(base + x @ w)
        jac = (p * (1 - p) * k)[:, None] * x
        g = jac.T @ (p - t) / n + lam * (w - w0) / 1e6
        h = jac.T @ jac / n + (lam / 1e6 + 1e-12) * np.eye(len(w))
        w = w - np.linalg.solve(h, g)
        cur = obj(w)
        if cur < best[0]:
            best = (cur, w.copy())
    return best[1]


def choose_lam(rows, nfeat, w0, lam_target):
    """pick the ridge strength by game-grouped validation inside training"""
    a, b = split(rows, 0.75, seed=11)
    ba, xa = eval_design(a, nfeat)
    bb, xb = eval_design(b, nfeat)
    ta, tb = eval_target(a, lam_target), eval_target(b, lam_target)
    scores = []
    for lam in (0.0, 1.0, 3.0, 10.0, 30.0, 100.0, 300.0, 1000.0):
        w = fit_eval(ba, xa, ta, w0, lam)
        scores.append((loss(w, bb, xb, tb), lam))
    return min(scores)[1], scores


def linfit(x, y):
    xa = np.concatenate([np.ones((len(x), 1)), x], axis=1)
    coef, *_ = np.linalg.lstsq(xa, y, rcond=None)
    return coef


def linpred(coef, x):
    return coef[0] + x @ coef[1:]


def r2(y, yh):
    return float(1 - np.sum((y - yh) ** 2) / np.sum((y - np.mean(y)) ** 2))


def cheap_features(rows, nfeat):
    """features available at the root without search"""
    out = []
    for r in rows:
        f = r["features"]
        ph = min(f[nfeat + 2], 24)
        mat = abs(r["sf_cp_white"]) if False else 0
        out.append([math.log(max(r["legal_now"], 1)), ph / 24.0, r["ply"] / 100.0,
                    abs(f[nfeat] + 0) / 1000.0, sum(abs(v) for v in f[12:16]) / 50.0, abs(f[16]) / 50.0])
    return np.array(out, dtype=float)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.path.join(ROOT, "data", "positions.jsonl"))
    ap.add_argument("--weights", default=os.path.join(ROOT, "tools", "weights.json"))
    ap.add_argument("--lam", type=float, default=0.7, help="weight of the SF target vs the game result")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    rows = load(args.data)
    wj = json.load(open(args.weights))
    feats = wj["features"]
    nfeat = len(feats)
    tr, te = split(rows)
    print(f"{len(rows)} positions; train {len(tr)} / test {len(te)} (split by game, "
          f"{len({r['game'] for r in tr})} / {len({r['game'] for r in te})} games)")
    report = {"n_train": len(tr), "n_test": len(te)}

    # 1. evaluation weights
    btr, xtr = eval_design(tr, nfeat)
    bte, xte = eval_design(te, nfeat)
    ttr, tte = eval_target(tr, args.lam), eval_target(te, args.lam)
    w0 = np.array([f[1] for f in feats] + [f[2] for f in feats], dtype=float)
    zero = np.zeros_like(w0)
    l_pesto = loss(zero, bte, xte, tte)
    l_hand = loss(w0, bte, xte, tte)
    lam, grid = choose_lam(tr, nfeat, w0, args.lam)
    print("[eval] ridge strength by validation:", ", ".join(f"{l:g}:{v:.5f}" for v, l in grid), "-> chose", lam)
    w = fit_eval(btr, xtr, ttr, w0, lam)
    l_fit_tr, l_fit_te = loss(w, btr, xtr, ttr), loss(w, bte, xte, tte)
    l_hand_tr = loss(w0, btr, xtr, ttr)
    print(f"[eval] train MSE hand weights {l_hand_tr:.5f}")
    print(f"[eval] test MSE (win-prob space): PeSTO only {l_pesto:.5f} | hand weights {l_hand:.5f} | "
          f"fitted {l_fit_te:.5f} (train {l_fit_tr:.5f})")
    fitted = [[feats[i][0], round(float(w[i])), round(float(w[nfeat + i]))] for i in range(nfeat)]
    for (name, a, b), old in zip(fitted, feats):
        print(f"   {name:15s} mg {old[1]:5d} -> {a:5d}   eg {old[2]:5d} -> {b:5d}")
    report["eval"] = {"test_mse_pesto": l_pesto, "test_mse_hand": l_hand, "test_mse_fitted": l_fit_te,
                      "train_mse_fitted": l_fit_tr, "fitted": fitted, "lambda": args.lam}
    wr = np.array([f[1] for f in fitted] + [f[2] for f in fitted], dtype=float)
    l_round = loss(wr, bte, xte, tte)
    if args.write and l_round < l_hand:
        wj["features"] = fitted
        wj["_comment"] = ("Evaluation weights fitted by tools/tune.py (Texel-style, SF/result blend "
                          f"lambda={args.lam}); test MSE {l_round:.5f} vs hand {l_hand:.5f}.")
        json.dump(wj, open(args.weights, "w"), indent=1)
        print("   wrote", args.weights)

    # 2. search-cost model
    cost = [r for r in rows if r.get("nodes_by_depth") and all(r["nodes_by_depth"][d] for d in (2, 4, 6))]
    if cost:
        ctr, cte = split(cost)
        xc_tr, xc_te = cheap_features(ctr, nfeat), cheap_features(cte, nfeat)
        y_tr = np.log2([r["nodes_by_depth"][6] for r in ctr])
        y_te = np.log2([r["nodes_by_depth"][6] for r in cte])
        coef = linfit(xc_tr, y_tr)
        pred = linpred(coef, xc_te)
        # naive: N(7) = N(5)^2 / N(3) (constant effective branching)
        naive = np.array([2 * math.log2(r["nodes_by_depth"][4]) - math.log2(r["nodes_by_depth"][2]) for r in cte])
        # hybrid: naive extrapolation corrected by the features
        res_tr = y_tr - np.array([2 * math.log2(r["nodes_by_depth"][4]) - math.log2(r["nodes_by_depth"][2]) for r in ctr])
        coef_h = linfit(xc_tr, res_tr)
        hyb = naive + linpred(coef_h, xc_te)
        mae = lambda a, b: float(np.mean(np.abs(a - b)))
        print(f"[cost] predict log2 nodes(depth 7): features-only MAE {mae(pred, y_te):.2f} bits (R2 {r2(y_te, pred):.2f}) | "
              f"naive EBF extrapolation from depths 3,5 MAE {mae(naive, y_te):.2f} | hybrid MAE {mae(hyb, y_te):.2f}")
        report["cost"] = {"features_mae_bits": mae(pred, y_te), "features_r2": r2(y_te, pred),
                          "naive_mae_bits": mae(naive, y_te), "hybrid_mae_bits": mae(hyb, y_te),
                          "coef_features": coef.tolist(), "coef_hybrid": coef_h.tolist(),
                          "features": ["log legal", "phase/24", "ply/100", "|pesto mg|/1000", "mobility/50",
                                       "king attack/50"]}

    # 3. remaining game length
    xl = lambda rs: np.array([[min(r["features"][nfeat + 2], 24) / 24.0, r["ply"] / 100.0,
                               math.log(max(r["legal_now"], 1))] for r in rs])
    yl_tr = np.array([r["remaining"] for r in tr], dtype=float)
    yl_te = np.array([r["remaining"] for r in te], dtype=float)
    cl = linfit(xl(tr), yl_tr)
    pl = linpred(cl, xl(te))
    print(f"[length] remaining plies: MAE {np.mean(np.abs(pl - yl_te)):.1f} vs constant-mean MAE "
          f"{np.mean(np.abs(np.mean(yl_tr) - yl_te)):.1f} (R2 {r2(yl_te, pl):.2f})")
    report["length"] = {"coef": cl.tolist(), "features": ["phase/24", "ply/100", "log legal"],
                        "mae": float(np.mean(np.abs(pl - yl_te))),
                        "mae_const": float(np.mean(np.abs(np.mean(yl_tr) - yl_te))), "r2": r2(yl_te, pl)}

    # 4. branching k plies ahead
    report["branching"] = {}
    for k in (1, 2, 4, 8):
        sel_tr = [r for r in tr if r["legal_k"][k - 1]]
        sel_te = [r for r in te if r["legal_k"][k - 1]]
        xb = lambda rs: np.array([[math.log(max(r["legal_now"], 1)), min(r["features"][nfeat + 2], 24) / 24.0]
                                  for r in rs])
        yb_tr = np.log([r["legal_k"][k - 1] for r in sel_tr])
        yb_te = np.log([r["legal_k"][k - 1] for r in sel_te])
        cb = linfit(xb(sel_tr), yb_tr)
        pb = linpred(cb, xb(sel_te))
        print(f"[branching] log legal moves {k} plies ahead: R2 {r2(yb_te, pb):.2f}, MAE {np.mean(np.abs(pb - yb_te)):.2f} (nats)")
        report["branching"][str(k)] = {"coef": cb.tolist(), "r2": r2(yb_te, pb)}
    out = os.path.join(ROOT, "data", "models.json")
    json.dump(report, open(out, "w"), indent=1)
    print("wrote", out)


if __name__ == "__main__":
    main()
