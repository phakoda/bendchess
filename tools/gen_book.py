#!/usr/bin/env python3
"""Generate a large book of distinct, balanced opening positions.

Each opening is a random walk of --plies plies from the start position
where every move is drawn from Stockfish's top-4 moves (depth 8, weighted
toward better moves), kept only if the final position is roughly balanced
(|eval| <= --max-cp at depth 12) and not already in the book.

Why: our engines are deterministic under a node clock, so a match over N
openings has at most 2N distinct games; reusing a 32-line suite for 200
games produced only 64 distinct games and over-confident Elo intervals.
"""
import argparse
import os
import random

import chess
import chess.engine

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=600)
    ap.add_argument("--plies", type=int, default=8)
    ap.add_argument("--max-cp", type=int, default=50)
    ap.add_argument("--seed", type=int, default=31)
    ap.add_argument("--out", default=os.path.join(ROOT, "tools", "book.epd"))
    args = ap.parse_args()
    rng = random.Random(args.seed)
    sf = chess.engine.SimpleEngine.popen_uci(os.environ.get("STOCKFISH", "/usr/games/stockfish"))
    sf.configure({"Threads": 2, "Hash": 64})
    seen, out, tries = set(), [], 0
    while len(out) < args.n and tries < args.n * 5:
        tries += 1
        b = chess.Board()
        ok = True
        for _ in range(args.plies):
            infos = sf.analyse(b, chess.engine.Limit(depth=8), multipv=4)
            moves = [i["pv"][0] for i in infos if i.get("pv")]
            if not moves:
                ok = False
                break
            w = [4, 3, 2, 1][:len(moves)]
            b.push(rng.choices(moves, weights=w)[0])
        if not ok or b.is_game_over():
            continue
        key = b.board_fen() + (" w" if b.turn else " b")
        if key in seen:
            continue
        sc = sf.analyse(b, chess.engine.Limit(depth=12))["score"].white().score(mate_score=10000)
        if abs(sc) > args.max_cp:
            continue
        seen.add(key)
        out.append(b.fen())
    sf.quit()
    with open(args.out, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {len(out)} openings to {args.out} ({tries} walks)")


if __name__ == "__main__":
    main()
