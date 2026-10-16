#!/usr/bin/env python3
"""BendChess vs a "Magnus Carlsen bot".

No real Magnus Carlsen bot is available offline (the commercial bots are
online services and his game collection could not be downloaded here), so
the opponent is a STRENGTH PROXY: Stockfish 16 with UCI_LimitStrength and
UCI_Elo = 2850, roughly Carlsen's classical rating. Caveats: Stockfish's
UCI_Elo is calibrated against engine rating lists (CCRL-style, at about
60 s + 0.6 s per game), not FIDE; it does not imitate Carlsen's style or
openings; a limited Stockfish plays differently from a human of the same
rating.

The match uses the balanced opening suite (each opening with both
colours) at the calibration time control by default.

usage: tools/magnus.py [--games 100] [--tc 60+0.6] [--elo 2850] [--concurrency 4]
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--games", type=int, default=100)
    ap.add_argument("--tc", default="60+0.6")
    ap.add_argument("--elo", type=int, default=2850)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--engine", default="bend")
    ap.add_argument("--tag", default="", help="record name (default magnus_proxy_<elo>)")
    args = ap.parse_args()
    cmd = [sys.executable, os.path.join(ROOT, "tools", "match.py"), args.engine, f"sf:elo={args.elo}",
           "--games", str(args.games), "--tc", args.tc, "--concurrency", str(args.concurrency),
           "--out", os.path.join(ROOT, "results", "matches"), "--tag", args.tag or f"magnus_proxy_{args.elo}",
           "--event", f"BendChess vs Stockfish 16 UCI_Elo {args.elo} (Magnus-strength proxy)"]
    subprocess.run(cmd, check=True)


if __name__ == "__main__":
    main()
