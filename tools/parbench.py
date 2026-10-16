#!/usr/bin/env python3
"""Parallel root-split search benchmark: time to depth with Threads 1/2/4.

Runs `go depth D` from a fresh state (ucinewgame) on a set of positions and
reports, per thread count, the total wall time, the speedup over one
thread (ratio of total times and geometric mean of per-position ratios),
the node overhead and how often the chosen move matches the 1-thread
search. Needs an otherwise idle machine.
"""
import argparse
import math
import os
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEND = os.environ.get("BEND", os.path.join(ROOT, "build", "bendchess"))


def run(fen, depth, threads):
    p = subprocess.Popen([BEND], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    p.stdin.write(f"setoption name Threads value {threads}\nucinewgame\nposition fen {fen}\nisready\n")
    p.stdin.flush()
    while p.stdout.readline().strip() != "readyok":
        pass
    t0 = time.time()
    p.stdin.write(f"go depth {depth}\n")
    p.stdin.flush()
    nodes, best = 0, ""
    while True:
        line = p.stdout.readline()
        if not line:
            break
        t = line.split()
        if t and t[0] == "bestmove":
            best = t[1]
            break
        if "nodes" in t and t[:2] == ["info", "depth"]:
            nodes = int(t[t.index("nodes") + 1])
    dt = time.time() - t0
    p.stdin.write("quit\n")
    p.stdin.flush()
    p.wait()
    return dt, nodes, best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=24)
    ap.add_argument("--depth", type=int, default=13)
    ap.add_argument("--threads", default="1,2,4")
    args = ap.parse_args()
    fens = [l.strip() for l in open(os.path.join(ROOT, "tools", "book.epd")) if l.strip()][: args.n]
    ths = [int(x) for x in args.threads.split(",")]
    res = {t: [run(f, args.depth, t) for f in fens] for t in ths}
    base = res[ths[0]]
    print(f"{len(fens)} positions, go depth {args.depth}")
    for t in ths:
        r = res[t]
        tot = sum(x[0] for x in r)
        geo = math.exp(sum(math.log(b[0] / max(x[0], 1e-3)) for b, x in zip(base, r)) / len(r))
        nodes = sum(x[1] for x in r) / max(sum(b[1] for b in base), 1)
        same = sum(x[2] == b[2] for b, x in zip(base, r))
        print(f"Threads {t}: total {tot:.1f} s, speedup {sum(b[0] for b in base) / tot:.2f}x "
              f"(geo-mean {geo:.2f}x), nodes {nodes:.2f}x, same move {same}/{len(r)}")


if __name__ == "__main__":
    main()
