#!/usr/bin/env python3
"""What does BendChess's evaluation miss? (companion to loss_analysis.py)

Samples positions from the lost games (BendChess to move, moves 10..70),
scores each with the referee (Stockfish, fixed depth) and with BendChess's
own search at a fixed shallow depth, and computes candidate positional
features with python-chess (king safety, threats, space, development,
piece placement, pawn structure details - all from the side to move's
point of view, as "ours minus theirs"). The residual
  gap = referee score - BendChess score
is then related to each feature (correlation and a ridge fit on
standardized features), ranking the knowledge BendChess lacks most.
Algorithmic features only.

Output: results/eval_gap.json, results/eval_gap.md
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import random
import re
import subprocess

import chess
import chess.engine
import chess.pgn
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SF = os.environ.get("STOCKFISH", "/usr/games/stockfish")
MATE = 3000
VAL = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9, chess.KING: 0}


def king_zone(b, c):
    k = b.king(c)
    z = chess.SquareSet(chess.BB_KING_ATTACKS[k]) | chess.SquareSet([k])
    fwd = 8 if c == chess.WHITE else -8
    for s in list(z):
        t = s + fwd
        if 0 <= t < 64:
            z.add(t)
    return z


def side_feats(b, c):
    o = not c
    f = {}
    zone = king_zone(b, c)
    # king safety: enemy attacks on our king zone, attackers, open/semi-open files near our king
    att = 0
    attackers = set()
    for s in zone:
        a = b.attackers(o, s)
        att += len(a)
        attackers |= set(a)
    f["king_zone_attacks"] = att
    f["king_attackers"] = len(attackers)
    kf = chess.square_file(b.king(c))
    openf = semi = 0
    for fl in range(max(0, kf - 1), min(7, kf + 1) + 1):
        own = any(chess.square_file(s) == fl for s in b.pieces(chess.PAWN, c))
        their = any(chess.square_file(s) == fl for s in b.pieces(chess.PAWN, o))
        openf += (not own and not their)
        semi += (not own and their)
    f["king_open_files"] = openf
    f["king_semiopen_files"] = semi
    f["king_shield_pawns"] = sum(1 for s in zone if b.piece_at(s) == chess.Piece(chess.PAWN, c))
    f["king_castled"] = int(chess.square_file(b.king(c)) in (0, 1, 2, 6, 7) and
                            chess.square_rank(b.king(c)) == (0 if c == chess.WHITE else 7))
    # threats: our pieces attacked by lower-valued enemy pieces, hanging pieces
    hanging = threatened = 0
    for t in (chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN):
        for s in b.pieces(t, c):
            a = b.attackers(o, s)
            if not a:
                continue
            if not b.attackers(c, s):
                hanging += VAL[t]
            if any(VAL[b.piece_type_at(x)] < VAL[t] for x in a):
                threatened += VAL[t]
    f["hanging_value"] = hanging
    f["threatened_by_lesser"] = threatened
    # space and center: safe squares we attack in the enemy half / center
    half = [s for s in chess.SQUARES if (chess.square_rank(s) >= 4) == (c == chess.WHITE)]
    f["space"] = sum(1 for s in half if b.is_attacked_by(c, s) and not b.is_attacked_by(o, s))
    center = [chess.D4, chess.E4, chess.D5, chess.E5]
    f["center_control"] = sum(len(b.attackers(c, s)) for s in center)
    f["center_pawns"] = sum(1 for s in center if b.piece_at(s) == chess.Piece(chess.PAWN, c))
    # development and placement
    back = 0 if c == chess.WHITE else 7
    f["undeveloped_minors"] = sum(1 for t in (chess.KNIGHT, chess.BISHOP) for s in b.pieces(t, c)
                                  if chess.square_rank(s) == back)
    outposts = 0
    for s in b.pieces(chess.KNIGHT, c):
        r = chess.square_rank(s)
        adv = r >= 4 if c == chess.WHITE else r <= 3
        if adv and b.attackers(c, s) & b.pieces(chess.PAWN, c):
            fl = chess.square_file(s)
            safe = True
            for p in b.pieces(chess.PAWN, o):
                pf, pr = chess.square_file(p), chess.square_rank(p)
                if abs(pf - fl) == 1 and ((pr > r) if c == chess.WHITE else (pr < r)):
                    safe = False
            outposts += safe
    f["knight_outposts"] = outposts
    # safe mobility (squares not attacked by enemy pawns)
    pawn_att = chess.SquareSet()
    for p in b.pieces(chess.PAWN, o):
        pawn_att |= b.attacks(p)
    mob = 0
    for t in (chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN):
        for s in b.pieces(t, c):
            mob += len([x for x in b.attacks(s) if x not in pawn_att and b.color_at(x) != c])
    f["safe_mobility"] = mob
    # pawn structure details
    pawns = b.pieces(chess.PAWN, c)
    files = [chess.square_file(s) for s in pawns]
    f["pawn_islands"] = len([1 for i in range(8) if i in files and (i - 1) not in files])
    backward = 0
    for s in pawns:
        fl, r = chess.square_file(s), chess.square_rank(s)
        support = [p for p in pawns if abs(chess.square_file(p) - fl) == 1 and
                   ((chess.square_rank(p) <= r) if c == chess.WHITE else (chess.square_rank(p) >= r))]
        stop = s + (8 if c == chess.WHITE else -8)
        if not support and 0 <= stop < 64 and b.is_attacked_by(o, stop):
            backward += 1
    f["backward_pawns"] = backward
    passed_free = 0
    for s in pawns:
        fl, r = chess.square_file(s), chess.square_rank(s)
        blockers = [p for p in b.pieces(chess.PAWN, o) if abs(chess.square_file(p) - fl) <= 1 and
                    ((chess.square_rank(p) > r) if c == chess.WHITE else (chess.square_rank(p) < r))]
        if not blockers:
            stop = s + (8 if c == chess.WHITE else -8)
            if 0 <= stop < 64 and b.piece_at(stop) is None:
                passed_free += (r if c == chess.WHITE else 7 - r)
    f["passed_free_ranks"] = passed_free
    # rooks: connected, on 7th, doubled
    rooks = list(b.pieces(chess.ROOK, c))
    f["rooks_connected"] = int(len(rooks) == 2 and rooks[1] in b.attacks(rooks[0]))
    f["bishop_pair"] = int(len(b.pieces(chess.BISHOP, c)) >= 2)
    f["queen_out_early"] = int(any(chess.square_rank(s) != back for s in b.pieces(chess.QUEEN, c)) and
                               f["undeveloped_minors"] >= 2)
    return f


def features(b):
    me, op = side_feats(b, b.turn), side_feats(b, not b.turn)
    return {k: me[k] - op[k] for k in me}


def sample_positions(paths, name, per_game, seed):
    rng = random.Random(seed)
    out = []
    for path in paths:
        with open(path) as f:
            while True:
                g = chess.pgn.read_game(f)
                if g is None:
                    break
                h = g.headers
                ours = chess.WHITE if name in h["White"] else chess.BLACK if name in h["Black"] else None
                res = h["Result"]
                if ours is None or not ((ours and res == "0-1") or (not ours and res == "1-0")):
                    continue
                b = g.board()
                cand = []
                for mv in g.mainline_moves():
                    if b.turn == ours and 10 <= b.fullmove_number <= 70 and not b.is_check():
                        cand.append(b.fen())
                    b.push(mv)
                rng.shuffle(cand)
                out += [(os.path.basename(path), fen) for fen in cand[:per_game]]
    return out


def bend_eval(bin_, fens, depth):
    p = subprocess.Popen([bin_], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    res = []
    for fen in fens:
        p.stdin.write(f"ucinewgame\nposition fen {fen}\ngo depth {depth}\n")
        p.stdin.flush()
        sc = None
        while True:
            line = p.stdout.readline()
            if line.startswith("bestmove"):
                break
            m = re.search(r"score (cp|mate) (-?\d+)", line)
            if m and line.startswith("info depth"):
                sc = int(m.group(2)) if m.group(1) == "cp" else (MATE if int(m.group(2)) > 0 else -MATE)
        res.append(sc)
    p.stdin.write("quit\n")
    p.stdin.flush()
    return res


def sf_eval(chunk):
    fens, depth = chunk
    eng = chess.engine.SimpleEngine.popen_uci(SF)
    eng.configure({"Threads": 1, "Hash": 64})
    out = [eng.analyse(chess.Board(f), chess.engine.Limit(depth=depth))["score"].relative.score(mate_score=MATE)
           for f in fens]
    eng.quit()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="t_final")
    ap.add_argument("--bin", default=os.path.join(ROOT, "build", "t_final"))
    ap.add_argument("--per-game", type=int, default=14)
    ap.add_argument("--sf-depth", type=int, default=14)
    ap.add_argument("--bend-depth", type=int, default=9)
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()
    paths = sorted(glob.glob(os.path.join(ROOT, "results", "matches", "*_v2.pgn")) +
                   glob.glob(os.path.join(ROOT, "results", "matches", "sf16_full*.pgn")))
    samp = sample_positions(paths, args.name, args.per_game, 3)
    fens = [f for _, f in samp]
    print(f"{len(fens)} positions")
    k = args.workers
    chunks = [fens[i::k] for i in range(k)]
    with cf.ProcessPoolExecutor(k) as ex:
        sf_parts = list(ex.map(sf_eval, [(c, args.sf_depth) for c in chunks]))
        bd_parts = list(ex.map(bend_eval, [args.bin] * k, chunks, [args.bend_depth] * k))
    sf = [None] * len(fens)
    bd = [None] * len(fens)
    for i in range(k):
        for j, idx in enumerate(range(i, len(fens), k)):
            sf[idx] = sf_parts[i][j]
            bd[idx] = bd_parts[i][j]
    rows = []
    for (src, fen), s, e in zip(samp, sf, bd):
        if s is None or e is None or abs(s) > 1500 or abs(e) > 1500:
            continue
        rows.append({"src": src, "fen": fen, "sf": s, "bend": e, "gap": s - e, "f": features(chess.Board(fen))})
    json.dump(rows, open(os.path.join(ROOT, "results", "eval_gap.json"), "w"))
    names = list(rows[0]["f"].keys())
    X = np.array([[r["f"][n] for n in names] for r in rows], float)
    y = np.array([r["gap"] for r in rows], float)
    mu, sd = X.mean(0), X.std(0) + 1e-9
    Z = (X - mu) / sd
    lam = 50.0
    w = np.linalg.solve(Z.T @ Z + lam * np.eye(len(names)), Z.T @ (y - y.mean()))
    raw = w / sd
    corr = [float(np.corrcoef(X[:, i], y)[0, 1]) if sd[i] > 1e-6 else 0.0 for i in range(len(names))]
    pred = Z @ w + y.mean()
    r2 = 1 - np.mean((y - pred) ** 2) / np.var(y)
    order = sorted(range(len(names)), key=lambda i: -abs(w[i]))
    L = ["# What BendChess's evaluation misses (positions from lost games)\n",
         f"{len(rows)} positions (BendChess to move, moves 10-70) from 169 lost games. "
         f"gap = Stockfish depth {args.sf_depth} score - BendChess depth {args.bend_depth} score "
         f"(side to move, cp).\n",
         f"Mean gap {y.mean():+.0f} cp, median {np.median(y):+.0f} cp "
         f"(negative = BendChess more optimistic than the referee). "
         f"Share of positions where BendChess is >= 100 cp more optimistic: {np.mean(y <= -100) * 100:.0f}%.\n",
         f"Ridge fit of the gap on the features below: R^2 {r2:.2f} (in-sample).\n",
         "| feature (ours - theirs) | mean | effect per unit (cp) | effect per SD (cp) | correlation |",
         "|---|---|---|---|---|"]
    for i in order:
        L.append(f"| {names[i]} | {mu[i]:+.2f} | {raw[i]:+.1f} | {w[i]:+.1f} | {corr[i]:+.2f} |")
    L.append("\nReading: a positive effect means the referee values more of this feature for the side to move "
             "than BendChess does (BendChess under-rewards it); negative means BendChess under-penalises it.")
    open(os.path.join(ROOT, "results", "eval_gap.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
