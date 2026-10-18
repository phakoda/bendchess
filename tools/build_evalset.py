#!/usr/bin/env python3
"""Build the evaluation-tuning set (data/evalset.jsonl).

1. The self-play positions of data/big/positions.jsonl, with the engine's
   feature vector recomputed by the current binary (the feature set grows
   as terms are added).
2. Positions sampled from the games against Stockfish (results/matches,
   phase-2 records): these contain the strong-opponent pressure (king
   attacks, threats) that self-play at a small node budget rarely shows.
   Labelled by Stockfish at a fixed depth (white POV) and the game result.

Rows: game (string id, for grouped splits), fen, src, sf_cp_white,
result_white, features.
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import random
import subprocess

import chess
import chess.engine
import chess.pgn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SF = os.environ.get("STOCKFISH", "/usr/games/stockfish")


def features(bin_, fens):
    inp = "".join(f"position fen {f}\nfeatures\n" for f in fens) + "quit\n"
    out = subprocess.run([bin_], input=inp, capture_output=True, text=True).stdout.splitlines()
    return [[int(x) for x in l.split()[1:]] for l in out if l.startswith("features")]


def label(chunk):
    fens, depth = chunk
    eng = chess.engine.SimpleEngine.popen_uci(SF)
    eng.configure({"Threads": 1, "Hash": 64})
    out = [eng.analyse(chess.Board(f), chess.engine.Limit(depth=depth))["score"].white().score(mate_score=3000)
           for f in fens]
    eng.quit()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "build", "bendchess"))
    ap.add_argument("--per-game", type=int, default=15)
    ap.add_argument("--depth", type=int, default=12)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--out", default=os.path.join(ROOT, "data", "evalset.jsonl"))
    args = ap.parse_args()
    rows = []
    big = [json.loads(l) for l in open(os.path.join(ROOT, "data", "big", "positions.jsonl"))]
    big = [r for r in big if r.get("sf_cp_white") is not None]
    feats = features(args.bin, [r["fen"] for r in big])
    for r, f in zip(big, feats):
        rows.append({"game": f"self:{r['game']}", "fen": r["fen"], "src": "selfplay",
                     "sf_cp_white": r["sf_cp_white"], "result_white": r["result_white"], "features": f})
    print(f"{len(rows)} self-play positions re-featurised")
    rng = random.Random(5)
    samp = []
    paths = sorted(glob.glob(os.path.join(ROOT, "results", "matches", "*_v2.pgn")) +
                   glob.glob(os.path.join(ROOT, "results", "matches", "sf16_full*.pgn")))
    for path in paths:
        with open(path) as fh:
            while True:
                g = chess.pgn.read_game(fh)
                if g is None:
                    break
                res = {"1-0": 1.0, "0-1": 0.0}.get(g.headers["Result"], 0.5)
                b = g.board()
                cand = []
                for mv in g.mainline_moves():
                    if 8 <= b.fullmove_number <= 80 and not b.is_check():
                        cand.append(b.fen())
                    b.push(mv)
                rng.shuffle(cand)
                gid = f"m:{os.path.basename(path)}:{g.headers['Round']}"
                samp += [(gid, f, res) for f in cand[:args.per_game]]
    fens = [f for _, f, _ in samp]
    k = args.workers
    with cf.ProcessPoolExecutor(k) as ex:
        parts = list(ex.map(label, [(fens[i::k], args.depth) for i in range(k)]))
    sf = [None] * len(fens)
    for i in range(k):
        for j, idx in enumerate(range(i, len(fens), k)):
            sf[idx] = parts[i][j]
    mf = features(args.bin, fens)
    n0 = len(rows)
    for (gid, fen, res), s, f in zip(samp, sf, mf):
        if s is None or abs(s) >= 2500:
            continue
        rows.append({"game": gid, "fen": fen, "src": "matches", "sf_cp_white": s, "result_white": res, "features": f})
    print(f"{len(rows) - n0} match positions labelled")
    with open(args.out, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
