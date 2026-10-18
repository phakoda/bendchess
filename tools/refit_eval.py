#!/usr/bin/env python3
"""Fit the evaluation weights on data/evalset.jsonl (see build_evalset.py)
with tools/tune.py's Gauss-Newton fit, game-grouped train/test split.

Match positions (games against Stockfish) can be up-weighted by
duplication in training (--match-weight). Test losses are reported for
the whole test split and per source. tools/weights.json is rewritten only
with --write and only when the fitted weights beat the current ones on
the test split.
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tune  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.path.join(ROOT, "data", "evalset.jsonl"))
    ap.add_argument("--weights", default=os.path.join(ROOT, "tools", "weights.json"))
    ap.add_argument("--lam", type=float, default=0.7, help="weight of the SF target vs the game result")
    ap.add_argument("--match-weight", type=int, default=3)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    rows = [json.loads(l) for l in open(args.data)]
    wj = json.load(open(args.weights))
    feats = wj["features"]
    nf = len(feats)
    rows = [r for r in rows if len(r["features"]) == nf + 3]
    tr, te = tune.split(rows, 0.8, seed=7)
    tr2 = tr + [r for r in tr if r["src"] == "matches"] * (args.match_weight - 1)
    w0 = np.array([f[1] for f in feats] + [f[2] for f in feats], dtype=float)
    lam_r, scores = tune.choose_lam(tr2, nf, w0, args.lam)
    btr, xtr = tune.eval_design(tr2, nf)
    w = tune.fit_eval(btr, xtr, tune.eval_target(tr2, args.lam), w0, lam_r)
    print(f"{len(rows)} positions ({sum(r['src'] == 'matches' for r in rows)} from matches); "
          f"train {len(tr)} / test {len(te)}; ridge {lam_r}")
    res = {}
    for name, sub in (("all", te), ("selfplay", [r for r in te if r["src"] == "selfplay"]),
                      ("matches", [r for r in te if r["src"] == "matches"])):
        if not sub:
            continue
        b, x = tune.eval_design(sub, nf)
        t = tune.eval_target(sub, args.lam)
        z = np.zeros_like(w0)
        res[name] = (tune.loss(z, b, x, t), tune.loss(w0, b, x, t), tune.loss(w, b, x, t))
        print(f"  test {name:9s} n={len(sub):5d}  PeSTO only {res[name][0]:.5f}  current {res[name][1]:.5f}  "
              f"fitted {res[name][2]:.5f}")
    for i, f in enumerate(feats):
        print(f"   {f[0]:20s} mg {f[1]:6.0f} -> {w[i]:6.0f}   eg {f[2]:6.0f} -> {w[nf + i]:6.0f}")
    if args.write and res["all"][2] < res["all"][1]:
        for i, f in enumerate(feats):
            f[1], f[2] = int(round(w[i])), int(round(w[nf + i]))
        wj["fit"] = {"data": os.path.basename(args.data), "positions": len(rows), "ridge": lam_r,
                     "test_mse": {k: v[2] for k, v in res.items()},
                     "test_mse_before": {k: v[1] for k, v in res.items()}}
        json.dump(wj, open(args.weights, "w"), indent=1)
        print("wrote", args.weights)


if __name__ == "__main__":
    main()
