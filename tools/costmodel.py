#!/usr/bin/env python3
"""Learned iteration-cost model for the budget policy (Module 6 -> Module 4).

The time manager must decide, after iteration d, whether iteration d + 1
can finish in the remaining time. The engine's default prediction is the
observed growth factor of the last iteration (cost_d / cost_{d-1}, clamped
to [1.5, 6]). This tool measures whether a learned predictor does better:

  1. collect: run `go depth D` on many positions (book openings plus
     positions from data/*/positions.jsonl) and record, per iteration, the
     iteration cost (node difference), score, best move and the number of
     legal root moves. Node counts under `go depth` are deterministic, so
     the data does not depend on machine load.
  2. fit: least squares for log2(cost_{d+1} / cost_d) on features known
     when the decision is taken (last two growth factors, depth, best-move
     change, score change, root move count), split by position (train /
     test), and compare the mean absolute error (in bits) with the
     engine's current rule.

Output: results/costmodel.json (coefficients and test errors).
"""
import argparse
import json
import math
import os
import random
import subprocess

import chess
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEND = os.environ.get("BEND", os.path.join(ROOT, "build", "bendchess"))


def positions(n, seed):
    fens = [l.strip() for l in open(os.path.join(ROOT, "tools", "book.epd")) if l.strip()]
    for d in ("data/big", "data"):
        p = os.path.join(ROOT, d, "positions.jsonl")
        if os.path.exists(p):
            fens += [json.loads(l)["fen"] for l in open(p)]
    rng = random.Random(seed)
    rng.shuffle(fens)
    out = []
    for f in fens:
        b = chess.Board(f)
        if b.is_game_over() or b.legal_moves.count() < 2:
            continue
        out.append(f)
        if len(out) >= n:
            break
    return out


def collect(fens, depth, out):
    rows = []
    p = subprocess.Popen([BEND], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    for k, f in enumerate(fens):
        p.stdin.write(f"ucinewgame\nposition fen {f}\ngo depth {depth}\n")
        p.stdin.flush()
        its = []
        while True:
            line = p.stdout.readline()
            if not line:
                break
            t = line.split()
            if line.startswith("bestmove"):
                break
            if t[:2] == ["info", "depth"] and "pv" in t and "nodes" in t:
                d = int(t[2])
                nodes = int(t[t.index("nodes") + 1])
                sc = t[t.index("score") + 1:t.index("score") + 3]
                cp = int(sc[1]) if sc[0] == "cp" else (30000 if int(sc[1]) > 0 else -30000)
                best = t[t.index("pv") + 1] if len(t) > t.index("pv") + 1 else ""
                its.append((d, nodes, cp, best))
        nroot = chess.Board(f).legal_moves.count()
        rows.append({"fen": f, "nroot": nroot, "its": its})
        if (k + 1) % 50 == 0:
            print(f"  {k + 1}/{len(fens)} positions", flush=True)
    p.stdin.write("quit\n")
    p.stdin.flush()
    json.dump(rows, open(out, "w"))
    return rows


def samples(rows, dmin=4):
    X, y, base, grp = [], [], [], []
    for g, r in enumerate(rows):
        its = r["its"]
        cost = {}
        prev = 0
        for d, n, cp, best in its:
            cost[d] = max(n - prev, 1)
            prev = n
        byd = {d: (cp, best) for d, n, cp, best in its}
        for d in sorted(cost):
            if d < dmin or (d + 1) not in cost or (d - 1) not in cost or (d - 2) not in cost:
                continue
            g1 = cost[d] / cost[d - 1]
            g2 = cost[d - 1] / cost[d - 2]
            changed = 1.0 if byd[d][1] != byd[d - 1][1] else 0.0
            ds = abs(byd[d][0] - byd[d - 1][0])
            X.append([1.0, math.log2(g1), math.log2(g2), d, changed, math.log2(min(ds, 300) + 1),
                      math.log2(r["nroot"])])
            y.append(math.log2(cost[d + 1] / cost[d]))
            base.append(math.log2(min(max(g1, 1.5), 6.0)))
            grp.append(g)
    return np.array(X), np.array(y), np.array(base), np.array(grp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=800)
    ap.add_argument("--depth", type=int, default=12)
    ap.add_argument("--seed", type=int, default=5)
    ap.add_argument("--raw", default=os.path.join(ROOT, "results", "costmodel_raw.json"))
    ap.add_argument("--reuse", action="store_true", help="fit on an existing --raw file")
    args = ap.parse_args()
    if args.reuse and os.path.exists(args.raw):
        rows = json.load(open(args.raw))
    else:
        rows = collect(positions(args.n, args.seed), args.depth, args.raw)
    X, y, base, grp = samples(rows)
    test = grp % 4 == 0
    lam = 1e-3
    A = X[~test]
    w = np.linalg.solve(A.T @ A + lam * np.eye(A.shape[1]), A.T @ y[~test])
    pred = X @ w
    const = np.full_like(y, np.mean(y[~test]))
    res = {
        "features": ["1", "log2 g1", "log2 g2", "depth", "best changed", "log2(|dscore|+1)", "log2 root moves"],
        "coef": [round(float(c), 4) for c in w],
        "n_train": int((~test).sum()), "n_test": int(test.sum()),
        "mae_bits_test": {
            "engine rule (last growth clamped 1.5..6)": round(float(np.mean(np.abs(base[test] - y[test]))), 3),
            "constant (mean growth)": round(float(np.mean(np.abs(const[test] - y[test]))), 3),
            "learned linear model": round(float(np.mean(np.abs(pred[test] - y[test]))), 3),
        },
        "underestimate_rate_test": {
            "engine rule": round(float(np.mean(base[test] < y[test])), 3),
            "learned": round(float(np.mean(pred[test] < y[test])), 3),
        },
    }
    print(json.dumps(res, indent=1))
    json.dump(res, open(os.path.join(ROOT, "results", "costmodel.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
