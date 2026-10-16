#!/usr/bin/env python3
"""Build tests/data/tactics.epd: "only-move" positions where Stockfish
(MultiPV 2) finds one move at least --gap centipawns better than every
alternative, sampled from games (default data/games.pgn). Each line is
`FEN bm <uci>;`. Used by tests/test_engine.py to measure tactical
accuracy on positions the engine was never tuned on.
"""
import argparse
import os
import random

import chess
import chess.engine
import chess.pgn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pgn", default=os.path.join(ROOT, "data", "games.pgn"))
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--gap", type=int, default=250)
    ap.add_argument("--depth", type=int, default=16)
    ap.add_argument("--seed", type=int, default=99)
    ap.add_argument("--out", default=os.path.join(ROOT, "tests", "data", "tactics.epd"))
    args = ap.parse_args()
    rng = random.Random(args.seed)
    cands = []
    with open(args.pgn) as f:
        while True:
            g = chess.pgn.read_game(f)
            if g is None:
                break
            b = g.board()
            for i, mv in enumerate(g.mainline_moves()):
                if i >= 10 and rng.random() < 0.08:
                    cands.append(b.fen())
                b.push(mv)
    rng.shuffle(cands)
    sf = chess.engine.SimpleEngine.popen_uci(os.environ.get("STOCKFISH", "/usr/games/stockfish"))
    sf.configure({"Threads": 2, "Hash": 64})
    out = []
    for fen in cands:
        if len(out) >= args.n:
            break
        b = chess.Board(fen)
        if b.legal_moves.count() < 2:
            continue
        infos = sf.analyse(b, chess.engine.Limit(depth=args.depth), multipv=2)
        if len(infos) < 2:
            continue
        s1 = infos[0]["score"].relative.score(mate_score=10000)
        s2 = infos[1]["score"].relative.score(mate_score=10000)
        if s1 - s2 >= args.gap and abs(s2) < 2000:
            out.append(f"{fen} bm {infos[0]['pv'][0].uci()};")
    sf.quit()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(f"# {len(out)} only-move positions (Stockfish 16 MultiPV 2, depth {args.depth}, gap >= {args.gap} cp)\n")
        f.write("\n".join(out) + "\n")
    print(f"wrote {len(out)} positions to {args.out}")


if __name__ == "__main__":
    main()
