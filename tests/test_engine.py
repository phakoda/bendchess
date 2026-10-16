#!/usr/bin/env python3
"""Engine-level tests for BendChess (driven over UCI).

Covers: checkmate / stalemate reporting, draw rules (fifty-move,
repetition, dead positions), incremental-state consistency (hash, PeSTO
sums, occupancy, king squares after move replay == recomputed from FEN),
move replay vs FEN round trip, search determinism and iterative-deepening
sanity, TT persistence safety, tactical puzzles (known solutions plus a
Stockfish-derived "only move" set when tests/data/tactics.epd exists),
complexity counts (distinct positions after 3 and 4 plies from the start:
5,362 and 72,078) and estimator accuracy against exact perft.

usage: tests/test_engine.py [--bin build/bendchess] [--quick]
"""
import argparse
import math
import os
import random
import re
import subprocess
import sys
import time

import chess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Uci:
    def __init__(self, path):
        self.p = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, bufsize=1)

    def cmd(self, s, until=None):
        self.p.stdin.write(s + "\n")
        self.p.stdin.flush()
        if until is None:
            return []
        out = []
        while True:
            ln = self.p.stdout.readline()
            if not ln:
                raise RuntimeError("engine died")
            ln = ln.rstrip("\n")
            out.append(ln)
            if ln.startswith(until):
                return out

    def sync(self):
        return self.cmd("isready", "readyok")[:-1]

    def go(self, pos, limit):
        self.cmd("position " + pos)
        lines = self.cmd("go " + limit, "bestmove")
        best = lines[-1].split()[1]
        infos = [l for l in lines if l.startswith("info depth")]
        score = None
        if infos:
            m = re.search(r"score (cp|mate) (-?\d+)", infos[-1])
            if m:
                score = (m.group(1), int(m.group(2)))
        return best, score, infos

    def d(self, pos):
        self.cmd("position " + pos)
        self.cmd("d")
        lines = self.sync()
        return {l.split()[0]: l for l in lines}

    def close(self):
        try:
            self.cmd("quit")
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()


RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f"  -- {detail}" if detail else ""), flush=True)


def test_mate_stalemate(e):
    best, score, _ = e.go("fen 7k/6Q1/6K1/8/8/8/8/8 b - - 0 1", "depth 3")
    check("checkmated side reports no move and mate 0", best == "0000" and score == ("mate", 0), f"{best} {score}")
    best, score, _ = e.go("fen 7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", "depth 3")
    check("stalemated side reports no move and draw score", best == "0000" and score == ("cp", 0), f"{best} {score}")
    best, score, _ = e.go("fen 6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1", "depth 4")
    check("finds back-rank mate in 1", best == "d1d8" and score == ("mate", 1), f"{best} {score}")
    best, score, _ = e.go("fen r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", "depth 4")
    check("finds scholar's mate", best == "h5f7", best)
    best, score, _ = e.go("fen 2r3k1/p4p2/3Rp2p/1p2P1pK/8/1P4P1/P3Q2P/1q6 b - - 0 1", "depth 7")
    check("finds mate in 3", score == ("mate", 3), f"{best} {score}")


def test_draw_rules(e):
    # KR v K with the halfmove clock at 99: every non-mating move ends in a
    # fifty-move draw, so the engine must not claim a big advantage
    best, score, _ = e.go("fen 8/8/8/4k3/8/8/8/R5K1 w - - 99 120", "depth 6")
    check("fifty-move rule: KRvK at halfmove 99 scores 0", score == ("cp", 0), f"{best} {score}")
    best, score, _ = e.go("fen 8/8/8/4k3/8/8/8/R5K1 w - - 0 120", "depth 6")
    check("same position with a fresh clock is winning", score is not None and score[0] == "cp" and score[1] > 300,
          f"{score}")
    # dead positions
    best, score, _ = e.go("fen 8/8/3k4/8/8/4K3/8/8 w - - 0 1", "depth 5")
    check("K v K is a dead draw", score == ("cp", 0), f"{score}")
    best, score, _ = e.go("fen 8/8/3k4/8/8/4KB2/8/8 w - - 0 1", "depth 5")
    check("K+B v K scores as a draw", score is not None and score[0] == "cp" and abs(score[1]) <= 20, f"{score}")
    # repetition bookkeeping: earlier occurrences of the current position
    for plies, want in ((4, 1), (8, 2)):
        moves = " ".join((["g1f3", "g8f6", "f3g1", "f6g8"] * 2)[:plies])
        lines = analyze_lines(e, "startpos moves " + moves, 1, 1)
        m = re.search(r"earlier occurrences of this position (\d+)", "\n".join(lines))
        check(f"repetition count after {plies} shuffle plies = {want}", m is not None and int(m.group(1)) == want,
              m.group(0) if m else "no report")
    # in-search repetition: with a repetition available in the game
    # history, a side that is otherwise lost scores the draw
    path = os.path.join(ROOT, "tests", "data", "perpetual.epd")
    if os.path.exists(path):
        for ln in open(path):
            if ln.strip() and not ln.startswith("#"):
                fen = ln.strip()
                best, score, _ = e.go("fen " + fen, "depth 10")
                check("perpetual check found (repetition scores ~0): " + fen,
                      score is not None and score[0] == "cp" and abs(score[1]) <= 30, f"{best} {score}")


def test_incremental_state(e, n=40, seed=7):
    rng = random.Random(seed)
    bad = 0
    for _ in range(n):
        b = chess.Board()
        for _ in range(rng.randint(1, 80)):
            mv = list(b.legal_moves)
            if not mv:
                break
            b.push(rng.choice(mv))
        if b.is_game_over():
            continue
        moves = " ".join(m.uci() for m in b.move_stack)
        a = e.d("startpos moves " + moves)
        f = e.d("fen " + b.fen(en_passant="xfen"))
        sa = a.get("state", "").split()
        sf = f.get("state", "").split()
        # compare hash, mg, eg, phase, pieces, kings (all incremental fields)
        if sa[1:] != sf[1:] or a.get("eval") != f.get("eval"):
            bad += 1
            print("   mismatch:", b.fen(), sa, sf)
    check(f"incremental hash/PeSTO/occupancy match recomputation ({n} random games)", bad == 0, f"{bad} mismatches")


def test_replay_fen(e, n=30, seed=11):
    rng = random.Random(seed)
    bad = 0
    for _ in range(n):
        b = chess.Board()
        for _ in range(rng.randint(1, 120)):
            mv = list(b.legal_moves)
            if not mv:
                break
            b.push(rng.choice(mv))
        moves = " ".join(m.uci() for m in b.move_stack)
        out = e.d("startpos moves " + moves).get("fen", "")
        want = b.fen(en_passant="xfen")
        if out[4:] != want:
            bad += 1
            print("   replay mismatch:", out[4:], "want", want)
    check(f"move replay reproduces python-chess FEN ({n} games)", bad == 0, f"{bad} mismatches")


def test_search_consistency(e):
    pos = "fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
    e.cmd("ucinewgame")
    r1 = e.go(pos, "depth 7")
    e.cmd("ucinewgame")
    r2 = e.go(pos, "depth 7")
    check("search is deterministic from a cleared TT", r1[0] == r2[0] and r1[1] == r2[1], f"{r1[:2]} {r2[:2]}")
    depths = [int(l.split()[2]) for l in r1[2]]
    check("iterative deepening reports depths 1..7 in order", depths == list(range(1, 8)), str(depths))
    legal = chess.Board(pos[4:]).legal_moves
    ok = all(chess.Move.from_uci(l.split(" pv ")[1].split()[0]) in legal for l in r1[2] if " pv " in l)
    check("every iteration's PV starts with a legal move", ok)
    # TT reuse: searching again without clearing must still give a legal,
    # equally good move (TT entries from the first search are only hints)
    r3 = e.go(pos, "depth 7")
    check("re-search with a warm TT returns a legal move with a close score",
          chess.Move.from_uci(r3[0]) in legal and r3[1] is not None and abs(r3[1][1] - r1[1][1]) <= 60,
          f"{r1[:2]} {r3[:2]}")


def test_tactics(e, quick):
    known = [
        ("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", "h5f7"),
        ("6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1", "d1d8"),
        ("r2qk2r/pb4pp/1n2Pb2/2B2Q2/p1p5/2P5/2B2PPP/RN2R1K1 w - - 1 1", "f5g6"),
        ("4k3/8/8/8/8/8/4q3/R3K2R w KQ - 0 1", "e1e2"),           # take the checking queen
        ("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3", "0000"),  # fool's mate: mated
        ("k7/8/1K6/8/8/8/8/7R w - - 0 1", "h1h8"),
    ]
    path = os.path.join(ROOT, "tests", "data", "tactics.epd")
    extra = []
    if os.path.exists(path):
        for ln in open(path):
            if ln.strip() and not ln.startswith("#"):
                fen, _, best = ln.strip().rpartition(" bm ")
                extra.append((fen.strip(), best.strip().rstrip(";")))
    if quick:
        extra = extra[:20]
    solved = 0
    for fen, want in known:
        best, _, _ = e.go("fen " + fen, "depth 8")
        solved += best == want
        if best != want:
            print("   missed:", fen, "want", want, "got", best)
    check(f"known tactics solved {solved}/{len(known)}", solved == len(known))
    if extra:
        t0 = time.time()
        ok = 0
        for fen, want in extra:
            best, _, _ = e.go("fen " + fen, "movetime 1000")
            ok += best == want
        rate = ok / len(extra)
        print(f"   Stockfish-derived only-move tactics: {ok}/{len(extra)} at 1 s/position "
              f"({time.time() - t0:.0f} s)")
        check("Stockfish-derived tactics: solve rate >= 50%", rate >= 0.5, f"{rate:.0%}")


def analyze_lines(e, pos, depth, cdepth):
    e.cmd("position " + pos)
    e.cmd(f"analyze depth {depth} cdepth {cdepth}")
    return [l for l in e.sync() if l.startswith("info string")]


def test_complexity(e, quick):
    lines = analyze_lines(e, "startpos", 2, 4)
    txt = "\n".join(lines)
    m3 = re.search(r"d3: A sequences (\d+) \| B distinct positions (\d+)", txt)
    m4 = re.search(r"d4: A sequences (\d+) \| B distinct positions (\d+)", txt)
    check("A/B exact counts from the start: d3 8902 / 5362",
          m3 is not None and m3.groups() == ("8902", "5362"), str(m3.groups() if m3 else None))
    check("A/B exact counts from the start: d4 197281 / 72078",
          m4 is not None and m4.groups() == ("197281", "72078"), str(m4.groups() if m4 else None))
    # estimator accuracy: log10 perft(5) extrapolated from exact d1..d3,
    # vs the exact count (perft(5) from the engine)
    fens = [
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        "8/8/4kpp1/3p1b2/p6P/2B5/6P1/6K1 b - - 0 47",
        "6k1/5p2/6p1/8/7p/8/6PP/6K1 b - - 0 1",
        "2r2rk1/pp1bqpp1/2n1pn1p/3p4/3P4/P1NBPN2/1PQ2PPP/2R2RK1 w - - 0 14",
        "4rrk1/pp1n3p/3q2pQ/2p1pb2/2PP4/2P3N1/P2B2PP/4RRK1 b - - 7 19",
    ]
    if quick:
        fens = fens[:4]
    errs = []
    for fen in fens:
        lines = analyze_lines(e, "fen " + fen, 1, 3)
        txt = "\n".join(lines)
        m = re.search(r"log10 perft\(5\) ~ ([\d.]+) \+/- ([\d.]+)", txt)
        if not m:
            check("estimator prints log10 perft(5)", False, txt[-300:])
            return
        est, band = float(m.group(1)), float(m.group(2))
        out = subprocess.run([e.p.args[0], "perft", "5"] + fen.split(), capture_output=True, text=True).stdout
        exact = int(out.split()[1])
        err = est - math.log10(exact)
        errs.append((err, band))
        print(f"   perft(5) exact 10^{math.log10(exact):.2f}, estimate 10^{est:.1f} +/- {band:.1f}, error {err:+.2f}")
    mae = sum(abs(x) for x, _ in errs) / len(errs)
    inside = sum(1 for x, b in errs if abs(x) <= b + 0.05)
    check(f"A estimator: mean |log10 error| {mae:.2f} <= 0.25 at 2 plies beyond the exact horizon", mae <= 0.25)
    check(f"A estimator: error inside the stated band for {inside}/{len(errs)} positions", inside >= len(errs) * 0.6)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "build", "bendchess"))
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()
    e = Uci(args.bin)
    e.cmd("uci", "uciok")
    try:
        test_mate_stalemate(e)
        test_draw_rules(e)
        test_incremental_state(e)
        test_replay_fen(e)
        test_search_consistency(e)
        test_tactics(e, args.quick)
        test_complexity(e, args.quick)
    finally:
        e.close()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(bad)}/{len(RESULTS)} engine tests passed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
