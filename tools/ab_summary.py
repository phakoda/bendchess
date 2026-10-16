#!/usr/bin/env python3
"""Summarise the phase-2 A/B matches (results/ab/*.json) as a markdown
table: results/ab_summary.md. Each row: test, W/D/L for A, Elo with the
95% interval, pair-based interval, distinct games, node ratio, depth."""
import glob
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    rows = []
    for f in sorted(glob.glob(os.path.join(ROOT, "results", "ab", "*.json")), key=os.path.getmtime):
        d = json.load(open(f))
        s = d["summary"]
        tag = os.path.basename(f)[:-5]
        a = s.get("a", "").replace("build/", "")
        b = s.get("b", "").replace("build/", "")
        rows.append(
            f"| {tag} | {a} | {b} | {s['wins']} / {s['draws']} / {s['losses']} | {s['elo']:+.0f} "
            f"[{s['elo_lo']:+.0f}, {s['elo_hi']:+.0f}] | "
            f"[{s.get('elo_lo_pairs', float('nan')):+.0f}, {s.get('elo_hi_pairs', float('nan')):+.0f}] | "
            f"{s['distinct_games']} | {s['a_total_nodes'] / max(s['b_total_nodes'], 1):.2f} | "
            f"{s['a_avg_depth']:.1f} / {s['b_avg_depth']:.1f} |")
    out = ["| test | A | B | W / D / L (A) | Elo (95%) | pair CI | distinct | nodes A/B | depth A/B |",
           "|---|---|---|---|---|---|---|---|---|"] + rows
    path = os.path.join(ROOT, "results", "ab_summary.md")
    open(path, "w").write("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
