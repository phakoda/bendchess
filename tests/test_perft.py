#!/usr/bin/env python3
"""Perft and FEN round-trip tests for the Bend engine.

1. Standard positions with published perft counts (Chess Programming Wiki
   "Perft Results" plus well-known edge-case positions).
2. Random positions reached by random legal play, compared against
   python-chess (an independent move generator) at depth 3, so the engine
   is not just tuned to a fixed list of known answers.
3. FEN round trips on all of the above.

usage: tests/test_perft.py [--quick] [--random N] [--bin build/bendchess]
"""
import argparse
import random
import subprocess
import sys
import time

import chess

KNOWN = [
    # (fen, {depth: nodes})
    ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
     {1: 20, 2: 400, 3: 8902, 4: 197281, 5: 4865609}),
    ("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
     {1: 48, 2: 2039, 3: 97862, 4: 4085603}),
    ("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
     {1: 14, 2: 191, 3: 2812, 4: 43238, 5: 674624}),
    ("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
     {1: 6, 2: 264, 3: 9467, 4: 422333}),
    ("r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
     {1: 6, 2: 264, 3: 9467, 4: 422333}),
    ("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
     {1: 44, 2: 1486, 3: 62379, 4: 2103487}),
    ("r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
     {1: 46, 2: 2079, 3: 89890, 4: 3894594}),
    # edge cases (Martin Sedlak's / talkchess perft suite)
    ("3k4/3p4/8/K1P4r/8/8/8/8 b - - 0 1", {6: 1134888}),          # avoid illegal ep
    ("8/8/4k3/8/2p5/8/B2P2K1/8 w - - 0 1", {6: 1015133}),         # avoid illegal ep 2
    ("8/8/1k6/2b5/2pP4/8/5K2/8 b - d3 0 1", {6: 1440467}),        # ep capture checks
    ("5k2/8/8/8/8/8/8/4K2R w K - 0 1", {6: 661072}),             # short castle gives check
    ("3k4/8/8/8/8/8/8/R3K3 w Q - 0 1", {6: 803711}),             # long castle gives check
    ("r3k2r/1b4bq/8/8/8/8/7B/R3K2R w KQkq - 0 1", {4: 1274206}),  # castling rights
    ("r3k2r/8/3Q4/8/8/5q2/8/R3K2R b KQkq - 0 1", {4: 1720476}),   # castling prevented
    ("2K2r2/4P3/8/8/8/8/8/3k4 w - - 0 1", {6: 3821001}),          # promote out of check
    ("8/8/1P2K3/8/2n5/1q6/8/5k2 b - - 0 1", {5: 1004658}),        # discovered check
    ("4k3/1P6/8/8/8/8/K7/8 w - - 0 1", {6: 217342}),              # promote to give check
    ("8/P1k5/K7/8/8/8/8/8 w - - 0 1", {6: 92683}),                # under-promote check
    ("K1k5/8/P7/8/8/8/8/8 w - - 0 1", {6: 2217}),                 # self stalemate
    ("8/k1P5/8/1K6/8/8/8/8 w - - 0 1", {7: 567584}),              # stalemate/checkmate
    ("8/8/2k5/5q2/5n2/8/5K2/8 b - - 0 1", {4: 23527}),            # double check
]


def run(binary, args):
    out = subprocess.run([binary] + args, capture_output=True, text=True, timeout=600)
    return out.stdout.strip()


def engine_perft(binary, fen, depth):
    out = run(binary, ["perft", str(depth)] + fen.split())
    # "perft N nodes T ms R nps"
    parts = out.split()
    if len(parts) < 2 or parts[0] != "perft":
        raise RuntimeError(f"bad output: {out!r}")
    return int(parts[1])


def ref_perft(board, depth):
    if depth == 0:
        return 1
    if depth == 1:
        return board.legal_moves.count()
    n = 0
    for mv in board.legal_moves:
        board.push(mv)
        n += ref_perft(board, depth - 1)
        board.pop()
    return n


def norm_fen(board):
    """FEN as our engine prints it: the ep square only when a pseudo-legal
    en passant capture exists (python-chess's en_passant="xfen")."""
    return board.fen(en_passant="xfen")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendchess")
    ap.add_argument("--quick", action="store_true", help="cap depth so each test is fast")
    ap.add_argument("--random", type=int, default=60)
    ap.add_argument("--seed", type=int, default=12345)
    args = ap.parse_args()

    fails = 0
    total = 0
    t0 = time.time()
    for fen, table in KNOWN:
        for d, want in sorted(table.items()):
            if args.quick and want > 2_500_000:
                continue
            total += 1
            got = engine_perft(args.bin, fen, d)
            ok = got == want
            fails += not ok
            print(f"{'PASS' if ok else 'FAIL'} perft({d}) = {got} (want {want})  {fen}")

    rng = random.Random(args.seed)
    for i in range(args.random):
        b = chess.Board()
        for _ in range(rng.randint(4, 120)):
            moves = list(b.legal_moves)
            if not moves or b.is_game_over():
                break
            # bias toward captures/promotions/castling to reach tricky states
            special = [m for m in moves if b.is_capture(m) or m.promotion or b.is_castling(m)]
            b.push(rng.choice(special if special and rng.random() < 0.4 else moves))
        if b.is_game_over():
            continue
        fen = norm_fen(b)
        d = 3
        want = ref_perft(b, d)
        got = engine_perft(args.bin, fen, d)
        total += 1
        ok = got == want
        fails += not ok
        if not ok:
            print(f"FAIL random perft({d}) = {got} (want {want})  {fen}")
        # FEN round trip
        rt = run(args.bin, ["fen"] + fen.split())
        total += 1
        if rt != fen:
            fails += 1
            print(f"FAIL fen round trip: {fen!r} -> {rt!r}")
    print(f"\n{total - fails}/{total} passed in {time.time() - t0:.1f}s")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
