#!/usr/bin/env python3
"""Analyse lost games: where and why did BendChess go wrong?

For every game BendChess lost (PGN records in results/matches), every
position is scored by full-strength Stockfish (the referee; nothing of it
goes into the engine). Then:

1. Decisive error: BendChess's move with the largest eval drop (from its
   point of view) among moves that started from a playable position
   (>= -100 cp) and ended clearly worse (<= -150 cp). Games with no such
   move are "gradual" (slow decline) and their largest drop is reported.
2. Classification of the decisive position: move number, phase (non-pawn
   material), material balance, queens on/off, our move type and the
   referee's best move type (capture / check / quiet / pawn push / king
   move), whether the referee's refutation is tactical (its PV starts with
   a capture or check, or the drop exceeds 300 cp).
3. Diagnosis by re-searching the position with BendChess:
     - at the game's thinking time (1x),
     - at 10x the time,
     - at 10x with pruning and LMR switched off.
   An alternative move is "safe" when the referee rates it within 50 cp of
   its best move. If 10x avoids the error -> "depth/time"; if only the
   no-pruning search does -> "pruning"; if neither -> "knowledge" (the
   evaluation or search does not see the problem at that depth). Also
   records BendChess's own score at the position against the referee's
   (over-optimism).

Output: results/loss_analysis.json and results/loss_analysis.md.
"""
import argparse
import collections
import concurrent.futures as cf
import glob
import json
import os
import statistics

import chess
import chess.engine
import chess.pgn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SF = os.environ.get("STOCKFISH", "/usr/games/stockfish")
MATE = 3000


def cp(score):
    return score.white().score(mate_score=MATE)


def lost_games(paths, name):
    out = []
    for path in paths:
        with open(path) as f:
            while True:
                g = chess.pgn.read_game(f)
                if g is None:
                    break
                h = g.headers
                ours = chess.WHITE if name in h["White"] else chess.BLACK if name in h["Black"] else None
                if ours is None:
                    continue
                res = h["Result"]
                if (ours == chess.WHITE and res == "0-1") or (ours == chess.BLACK and res == "1-0"):
                    out.append((os.path.basename(path), h, g, ours))
    return out


def referee_game(args):
    """Score every position of a game (white POV) and the referee's best move."""
    fen, moves, depth = args
    eng = chess.engine.SimpleEngine.popen_uci(SF)
    eng.configure({"Threads": 1, "Hash": 64})
    b = chess.Board(fen)
    rows = []
    for i in range(len(moves) + 1):
        info = eng.analyse(b, chess.engine.Limit(depth=depth))
        pv = info.get("pv", [])
        rows.append({"cp": cp(info["score"]), "best": pv[0].uci() if pv else None,
                     "pv2": pv[1].uci() if len(pv) > 1 else None})
        if i < len(moves):
            b.push(chess.Move.from_uci(moves[i]))
    eng.quit()
    return rows


def move_kind(b, mv):
    if mv is None:
        return "none"
    if b.is_castling(mv):
        return "castle"
    if b.gives_check(mv):
        return "check"
    if b.is_capture(mv):
        return "capture"
    p = b.piece_type_at(mv.from_square)
    if p == chess.PAWN:
        return "pawn push"
    if p == chess.KING:
        return "king move"
    return "quiet piece move"


def phase(b):
    w = {chess.KNIGHT: 1, chess.BISHOP: 1, chess.ROOK: 2, chess.QUEEN: 4}
    s = sum(len(b.pieces(t, c)) * v for t, v in w.items() for c in (chess.WHITE, chess.BLACK))
    return "opening/middlegame" if s >= 16 else "late middlegame" if s >= 8 else "endgame"


def material(b, side):
    v = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9}
    return sum(len(b.pieces(t, side)) * x for t, x in v.items()) - \
        sum(len(b.pieces(t, not side)) * x for t, x in v.items())


def bend_search(bin_, fen, ms, opts):
    eng = chess.engine.SimpleEngine.popen_uci(bin_)
    eng.configure(opts)
    r = eng.play(chess.Board(fen), chess.engine.Limit(time=ms / 1000.0), info=chess.engine.INFO_ALL)
    eng.quit()
    sc = r.info.get("score")
    return r.move.uci(), (sc.relative.score(mate_score=MATE) if sc else None), r.info.get("depth")


def referee_move_value(fen, mv, depth):
    """Referee score (side-to-move POV) after playing mv, negated back."""
    eng = chess.engine.SimpleEngine.popen_uci(SF)
    eng.configure({"Threads": 1, "Hash": 64})
    b = chess.Board(fen)
    side = b.turn
    b.push(chess.Move.from_uci(mv))
    info = eng.analyse(b, chess.engine.Limit(depth=depth))
    eng.quit()
    v = cp(info["score"])
    return v if side == chess.WHITE else -v


def diagnose(job):
    fen, bin_, ms, depth, best_val, played = job
    out = {}
    for tag, t, opts in (("1x", ms, {}), ("10x", ms * 10, {}),
                         ("10x_noprune", ms * 10, {"Pruning": False, "LMR": False})):
        mv, sc, d = bend_search(bin_, fen, t, opts)
        val = referee_move_value(fen, mv, depth) if mv != played else None
        out[tag] = {"move": mv, "score": sc, "depth": d,
                    "safe": mv != played and val is not None and val >= best_val - 50,
                    "same_as_game": mv == played, "ref_value": val}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pgn", nargs="*", default=sorted(glob.glob(os.path.join(ROOT, "results", "matches", "*_v2.pgn")) +
                                                      glob.glob(os.path.join(ROOT, "results", "matches", "sf16_full*.pgn"))))
    ap.add_argument("--name", default="t_final")
    ap.add_argument("--bin", default=os.path.join(ROOT, "build", "t_final"))
    ap.add_argument("--depth", type=int, default=14, help="referee depth")
    ap.add_argument("--ms", type=int, default=1200, help="BendChess thinking time per move in the games")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    games = lost_games(args.pgn, args.name)
    print(f"{len(games)} lost games")
    jobs = []
    for src, h, g, ours in games:
        jobs.append((h.get("FEN", chess.STARTING_FEN), [m.uci() for m in g.mainline_moves()], args.depth))
    with cf.ProcessPoolExecutor(args.workers) as ex:
        refs = list(ex.map(referee_game, jobs))
    print("referee scoring done")

    cases = []
    for (src, h, g, ours), (fen, moves, _), ref in zip(games, jobs, refs):
        b = chess.Board(fen)
        sgn = 1 if ours == chess.WHITE else -1
        drops = []
        for i, mv in enumerate(moves):
            if b.turn == ours:
                before = sgn * ref[i]["cp"]
                after = sgn * ref[i + 1]["cp"]
                drops.append({"ply": i, "fen": b.fen(), "played": mv, "before": before, "after": after,
                              "drop": before - after, "best": ref[i]["best"],
                              "kind": move_kind(b, chess.Move.from_uci(mv)),
                              "best_kind": move_kind(b, chess.Move.from_uci(ref[i]["best"])) if ref[i]["best"] else "none",
                              "phase": phase(b), "material": material(b, ours),
                              "queens": bool(b.pieces(chess.QUEEN, chess.WHITE) or b.pieces(chess.QUEEN, chess.BLACK)),
                              "in_check": b.is_check(), "fullmove": b.fullmove_number})
            b.push(chess.Move.from_uci(mv))
        crit = [d for d in drops if d["before"] >= -100 and d["after"] <= -150]
        dec = max(crit, key=lambda d: d["drop"]) if crit else (max(drops, key=lambda d: d["drop"]) if drops else None)
        if dec is None:
            continue
        dec["gradual"] = not crit
        dec["source"] = src
        dec["opening"] = h.get("Opening")
        dec["blunders"] = sum(1 for d in drops if d["drop"] >= 100)
        dec["mistakes"] = sum(1 for d in drops if 50 <= d["drop"] < 100)
        dec["ref_best_value"] = dec["before"]
        bb = chess.Board(dec["fen"])
        reply = None
        dec["tactical"] = dec["drop"] > 300 or dec["best_kind"] in ("capture", "check")
        cases.append(dec)
    print(f"{len(cases)} decisive positions; diagnosing with BendChess")

    djobs = [(c["fen"], args.bin, args.ms, args.depth, c["ref_best_value"], c["played"]) for c in cases]
    with cf.ProcessPoolExecutor(args.workers) as ex:
        diags = list(ex.map(diagnose, djobs))
    for c, d in zip(cases, diags):
        c["diag"] = d
        if d["10x"]["safe"]:
            c["cause"] = "depth/time"
        elif d["10x_noprune"]["safe"]:
            c["cause"] = "pruning"
        else:
            c["cause"] = "knowledge"
        c["our_score"] = d["1x"]["score"]

    json.dump(cases, open(os.path.join(ROOT, "results", "loss_analysis.json"), "w"), indent=1)
    report(cases, args)


def table(title, counter, n):
    lines = [f"\n**{title}**\n", "| | games | share |", "|---|---|---|"]
    for k, v in counter.most_common():
        lines.append(f"| {k} | {v} | {100 * v / n:.0f}% |")
    return lines


def report(cases, args):
    n = len(cases)
    sharp = [c for c in cases if not c["gradual"]]
    L = [f"# Loss analysis ({n} lost games)\n",
         f"Referee: Stockfish 16 depth {args.depth}. Decisive error = largest drop from >= -100 to <= -150 cp "
         f"(BendChess's view). {len(sharp)} games had one; {n - len(sharp)} declined gradually.\n"]
    L += table("Opponent / source", collections.Counter(c["source"] for c in cases), n)
    L += table("Cause (re-search diagnosis, sharp errors)", collections.Counter(c["cause"] for c in sharp), len(sharp))
    L += table("Phase of the decisive error", collections.Counter(c["phase"] for c in sharp), len(sharp))
    L += table("Our move type", collections.Counter(c["kind"] for c in sharp), len(sharp))
    L += table("Referee's better move type", collections.Counter(c["best_kind"] for c in sharp), len(sharp))
    L += table("Tactical refutation (capture/check best move or drop > 300)",
               collections.Counter("tactical" if c["tactical"] else "positional" for c in sharp), len(sharp))
    L += table("Queens on the board", collections.Counter("queens on" if c["queens"] else "queens off" for c in sharp), len(sharp))
    mv = [c["fullmove"] for c in sharp]
    if mv:
        L.append(f"\nMove number of the decisive error: median {statistics.median(mv)}, "
                 f"quartiles {statistics.quantiles(mv, n=4)}")
    opt = [c["our_score"] - c["after"] for c in sharp if c["our_score"] is not None]
    if opt:
        L.append(f"BendChess's own score minus the referee's score after its move: median {statistics.median(opt):+.0f} cp "
                 f"(positive = over-optimistic).")
    dd = [c["drop"] for c in sharp]
    if dd:
        L.append(f"Size of the decisive drop: median {statistics.median(dd):.0f} cp.")
    L.append(f"Blunders (>= 100 cp) per lost game: mean {statistics.mean(c['blunders'] for c in cases):.1f}; "
             f"mistakes (50-99 cp): {statistics.mean(c['mistakes'] for c in cases):.1f}.")
    L.append("\n## Sharp errors\n")
    L.append("| source | move | phase | played | better | drop | cause | 10x move | no-prune move |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for c in sorted(sharp, key=lambda c: -c["drop"]):
        d = c["diag"]
        L.append(f"| {c['source'].replace('.pgn', '')} | {c['fullmove']} | {c['phase']} | {c['played']} ({c['kind']}) | "
                 f"{c['best']} ({c['best_kind']}) | {c['drop']} | {c['cause']} | {d['10x']['move']} | {d['10x_noprune']['move']} |")
    open(os.path.join(ROOT, "results", "loss_analysis.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L[:60]))


if __name__ == "__main__":
    main()
