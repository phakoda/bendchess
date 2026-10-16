#!/usr/bin/env python3
"""Run the controlled experiments and append results to results/summary.json.

Each experiment is an engine-vs-engine match (tools/match.py) with paired
openings. Budgets are equal for both sides:
  * node clock: both engines run with NodesTime=K, so a "time control" of
    B ms is a budget of B*K nodes per game, spent by each engine's own
    time manager (deterministic; independent of CPU load);
  * wall clock: a real time control (sensitive to CPU contention, so run
    with concurrency <= cores).

usage: tools/experiments.py NAME [NAME...] [--games N] [--concurrency C]
       tools/experiments.py --list
"""
import argparse
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NT = 100        # NodesTime: nodes per virtual millisecond
NODE_TC = "20+0.2"  # virtual seconds: 2M nodes per game + 20k per move
WALL_TC = "10+0.1"

EXPERIMENTS = {
    # complexity-aware search vs baseline
    "cas1_nodes": ("bend:Complexity=1,NodesTime=%d" % NT, "bend:Complexity=0,NodesTime=%d" % NT, ["--tc", NODE_TC, "--nodeclock", str(NT)]),
    "cas2_nodes": ("bend:Complexity=2,NodesTime=%d" % NT, "bend:Complexity=1,NodesTime=%d" % NT, ["--tc", NODE_TC, "--nodeclock", str(NT)]),
    "cas3_nodes": ("bend:Complexity=3,NodesTime=%d" % NT, "bend:Complexity=2,NodesTime=%d" % NT, ["--tc", NODE_TC, "--nodeclock", str(NT)]),
    "cas2_vs0_nodes": ("bend:Complexity=2,NodesTime=%d" % NT, "bend:Complexity=0,NodesTime=%d" % NT, ["--tc", NODE_TC, "--nodeclock", str(NT)]),
    "cas3_vs0_nodes": ("bend:Complexity=3,NodesTime=%d" % NT, "bend:Complexity=0,NodesTime=%d" % NT, ["--tc", NODE_TC, "--nodeclock", str(NT)]),
    # controls: does spending more of the bank (static soft-limit scale) explain CAS-1?
    "soft130_vs0_nodes": ("bend:SoftScale=130,NodesTime=%d" % NT, "bend:Complexity=0,NodesTime=%d" % NT, ["--tc", NODE_TC, "--nodeclock", str(NT)]),
    "cas1_vs_soft130_nodes": ("bend:Complexity=1,NodesTime=%d" % NT, "bend:SoftScale=130,NodesTime=%d" % NT, ["--tc", NODE_TC, "--nodeclock", str(NT)]),
    "cas1_wall": ("bend:Complexity=1", "bend:Complexity=0", ["--tc", WALL_TC]),
    "cas2_wall": ("bend:Complexity=2", "bend:Complexity=0", ["--tc", WALL_TC]),
    # ablations (fixed nodes per move): speculative pruning components
    "abl_null": ("bend", "bend:NullMove=false", ["--nodes", "30000"]),
    "abl_lmr": ("bend", "bend:LMR=false", ["--nodes", "30000"]),
    "abl_prune": ("bend", "bend:Pruning=false", ["--nodes", "30000"]),
    # evaluation variants
    "eval_full_vs_pesto_nodes": ("bend:EvalMode=0", "bend:EvalMode=1", ["--nodes", "20000"]),
    "eval_full_vs_pesto_wall": ("bend:EvalMode=0", "bend:EvalMode=1", ["--tc", WALL_TC]),
    "eval_light_vs_pesto_wall": ("bend:EvalMode=2", "bend:EvalMode=1", ["--tc", WALL_TC]),
}


def run(name, games, conc):
    a, b, lim = EXPERIMENTS[name]
    tag = f"{name}"
    cmd = [sys.executable, os.path.join(ROOT, "tools", "match.py"), a, b, "--games", str(games),
           "--concurrency", str(conc), "--out", os.path.join(ROOT, "results", "matches"), "--tag", tag,
           "--event", name] + lim
    t0 = time.time()
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    res = json.load(open(os.path.join(ROOT, "results", "matches", tag + ".json")))["summary"]
    res["experiment"] = name
    res["minutes"] = (time.time() - t0) / 60
    path = os.path.join(ROOT, "results", "summary.json")
    allr = json.load(open(path)) if os.path.exists(path) else {}
    allr[name] = res
    json.dump(allr, open(path, "w"), indent=1)
    print(f"{name}: A={a} B={b} {' '.join(lim)} -> +{res['wins']} ={res['draws']} -{res['losses']} "
          f"score {res['score']:.3f} Elo {res['elo']:+.0f} [{res['elo_lo']:+.0f}, {res['elo_hi']:+.0f}] "
          f"({res['minutes']:.0f} min)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--games", type=int, default=200)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        for k, (a, b, lim) in EXPERIMENTS.items():
            print(f"{k:28s} {a}  vs  {b}  {' '.join(lim)}")
        return
    for n in args.names:
        run(n, args.games, args.concurrency)


if __name__ == "__main__":
    main()
