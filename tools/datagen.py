#!/usr/bin/env python3
"""Data generation for the learning pipeline (Module 6).

Stage 1 (games): self-play games of BendChess at a small node budget,
  with random opening plies for diversity -> data/games.pgn
Stage 2 (positions): sample quiet positions from those games and record
  per position: game id (for leakage-free splits), FEN, move number,
  game result, remaining plies, legal move count now and k plies later
  in the actual game, Stockfish evaluation (depth --sf-depth), and the
  engine's own search statistics (nodes needed to finish each depth
  1..--depth, from `go depth`) -> data/positions.jsonl
Stage 3 (features): the engine's feature vector for every position
  (UCI command `features`) -> added to the JSON lines.

A different source (e.g. a Lichess PGN dump) can be fed to stage 2 with
--pgn. Positions from one game never straddle the train/test split
(tools/tune.py splits by game id).
"""
import argparse
import concurrent.futures as cf
import json
import os
import random
import re
import subprocess
import sys

import chess
import chess.engine
import chess.pgn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEND = os.environ.get("BEND", os.path.join(ROOT, "build", "bendchess"))
STOCKFISH = os.environ.get("STOCKFISH", "/usr/games/stockfish")


def selfplay(seed, nodes, maxplies=300):
    rng = random.Random(seed)
    eng = chess.engine.SimpleEngine.popen_uci(BEND)
    b = chess.Board()
    for _ in range(rng.randint(2, 8)):
        mv = list(b.legal_moves)
        if not mv:
            break
        b.push(rng.choice(mv))
    try:
        while not b.is_game_over(claim_draw=True) and b.ply() < maxplies:
            r = eng.play(b, chess.engine.Limit(nodes=nodes))
            b.push(r.move)
    finally:
        eng.quit()
    g = chess.pgn.Game.from_board(b)
    g.headers["Result"] = b.result(claim_draw=True) if b.is_game_over(claim_draw=True) else "1/2-1/2"
    g.headers["Event"] = f"bendchess selfplay seed {seed}"
    return str(g)


class Uci:
    def __init__(self, path):
        self.p = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

    def cmd(self, s, until):
        self.p.stdin.write(s + "\n")
        self.p.stdin.flush()
        out = []
        while True:
            ln = self.p.stdout.readline()
            if not ln:
                raise RuntimeError("engine died")
            out.append(ln.rstrip("\n"))
            if out[-1].startswith(until):
                return out

    def close(self):
        self.p.stdin.write("quit\n")
        self.p.stdin.flush()
        self.p.wait()


def search_stats(u, fen, depth):
    """nodes needed to complete each iteration 1..depth (cumulative)"""
    u.cmd("ucinewgame\nposition fen " + fen + "\nisready", "readyok")
    lines = u.cmd(f"go depth {depth}", "bestmove")
    out = {}
    for ln in lines:
        m = re.match(r"info depth (\d+) .*? nodes (\d+)", ln)
        if m:
            out[int(m.group(1))] = int(m.group(2))
    return [out.get(d) for d in range(1, depth + 1)]


def features(u, fen):
    u.cmd("position fen " + fen + "\nisready", "readyok")
    ln = u.cmd("features", "features")[-1]
    return [int(x) for x in ln.split()[1:]]


def positions_of(game_id, game, per_game, rng):
    res = {"1-0": 1.0, "0-1": 0.0, "1/2-1/2": 0.5}.get(game.headers.get("Result"), None)
    if res is None:
        return []
    boards = []
    b = game.board()
    nodes = list(game.mainline_moves())
    counts = []
    for mv in nodes:
        counts.append(b.legal_moves.count())
        b.push(mv)
    counts.append(b.legal_moves.count())
    total = len(nodes)
    b = game.board()
    cand = []
    for i, mv in enumerate(nodes):
        if i >= 8 and not b.is_check() and not b.is_capture(mv):
            cand.append((i, b.fen()))
        b.push(mv)
    rng.shuffle(cand)
    out = []
    for i, fen in cand[:per_game]:
        out.append({"game": game_id, "fen": fen, "ply": i, "result_white": res, "remaining": total - i,
                    "legal_now": counts[i], "legal_k": [counts[i + k] if i + k < len(counts) else None
                                                        for k in range(1, 9)]})
    return out


def label_chunk(args, rows):
    sf = chess.engine.SimpleEngine.popen_uci(STOCKFISH)
    sf.configure({"Threads": 1, "Hash": 16})
    u = Uci(BEND)
    u.cmd("uci", "uciok")
    out = []
    try:
        for r in rows:
            b = chess.Board(r["fen"])
            info = sf.analyse(b, chess.engine.Limit(depth=args.sf_depth))
            sc = info["score"].white()
            r["sf_cp_white"] = sc.score(mate_score=3000)
            r["features"] = features(u, r["fen"])
            if args.depth:
                r["nodes_by_depth"] = search_stats(u, r["fen"], args.depth)
            out.append(r)
    finally:
        sf.quit()
        u.close()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--games", type=int, default=600)
    ap.add_argument("--nodes", type=int, default=3000)
    ap.add_argument("--per-game", type=int, default=12)
    ap.add_argument("--sf-depth", type=int, default=10)
    ap.add_argument("--depth", type=int, default=7, help="engine search depth for node statistics (0: skip)")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--pgn", default="", help="use these games instead of self-play")
    ap.add_argument("--out", default=os.path.join(ROOT, "data"))
    ap.add_argument("--seed", type=int, default=2024)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    pgn_path = args.pgn or os.path.join(args.out, "games.pgn")
    if not args.pgn:
        with cf.ProcessPoolExecutor(args.workers) as ex:
            games = list(ex.map(selfplay, [args.seed + i for i in range(args.games)], [args.nodes] * args.games))
        with open(pgn_path, "w") as f:
            f.write("\n\n".join(games) + "\n")
        print(f"stage 1: {len(games)} self-play games -> {pgn_path}", flush=True)
    rng = random.Random(args.seed)
    rows = []
    with open(pgn_path) as f:
        gid = 0
        while True:
            g = chess.pgn.read_game(f)
            if g is None:
                break
            rows += positions_of(gid, g, args.per_game, rng)
            gid += 1
    print(f"stage 2: {len(rows)} positions from {gid} games", flush=True)
    chunks = [rows[i::args.workers] for i in range(args.workers)]
    with cf.ProcessPoolExecutor(args.workers) as ex:
        done = [r for part in ex.map(label_chunk, [args] * args.workers, chunks) for r in part]
    path = os.path.join(args.out, "positions.jsonl")
    with open(path, "w") as f:
        for r in sorted(done, key=lambda r: (r["game"], r["ply"])):
            f.write(json.dumps(r) + "\n")
    print(f"stage 3: labelled {len(done)} positions -> {path}")


if __name__ == "__main__":
    sys.exit(main())
