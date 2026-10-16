#!/usr/bin/env python3
"""Engine-vs-engine match runner (python-chess UCI driver).

Engines are given as specs:
  bend[:Option=value,...]        the BendChess binary (build/bendchess)
  sf[:elo=N|skill=N|...]         Stockfish (UCI_LimitStrength with UCI_Elo=N)
  path/to/engine[:Opt=v,...]     any UCI engine

Each opening of tools/openings.py is played twice (colours reversed).
Limits: --nodes N (per move), --movetime MS, or --tc BASE+INC (seconds),
optionally different per side with --nodes2/--movetime2 (applied to B).

Prints W/D/L from engine A's point of view, the score, and an Elo estimate
with a 95% interval (normal approximation over game results; small samples
are labelled preliminary). Writes a PGN and a JSON summary to --out.
"""
import argparse
import concurrent.futures as cf
import datetime as dt
import json
import math
import os
import random
import sys
import threading
import time

import chess
import chess.engine
import chess.pgn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import openings  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEND = os.environ.get("BEND", os.path.join(ROOT, "build", "bendchess"))
STOCKFISH = os.environ.get("STOCKFISH", "/usr/games/stockfish")


def parse_spec(spec):
    name, _, opts = spec.partition(":")
    options = {}
    for kv in filter(None, opts.split(",")):
        k, _, v = kv.partition("=")
        options[k] = v
    if name == "bend":
        return {"cmd": [BEND], "options": options, "label": spec}
    if name == "sf":
        o = {"Threads": "1", "Hash": "16"}
        if "elo" in options:
            o["UCI_LimitStrength"] = "true"
            o["UCI_Elo"] = options.pop("elo")
        if "skill" in options:
            o["Skill Level"] = options.pop("skill")
        o.update(options)
        return {"cmd": [STOCKFISH], "options": o, "label": spec}
    return {"cmd": [name], "options": options, "label": spec}


def open_engine(spec):
    eng = chess.engine.SimpleEngine.popen_uci(spec["cmd"], timeout=30)
    opts = {}
    for k, v in spec["options"].items():
        if k not in eng.options:
            continue
        o = eng.options[k]
        if o.type == "check":
            opts[k] = v.lower() in ("1", "true", "yes", "on")
        elif o.type == "spin":
            opts[k] = int(v)
        else:
            opts[k] = v
    if opts:
        eng.configure(opts)
    return eng


def limit_for(args, side_b, clocks, turn):
    nodes = args.nodes2 if (side_b and args.nodes2) else args.nodes
    mt = args.movetime2 if (side_b and args.movetime2) else args.movetime
    if nodes:
        return chess.engine.Limit(nodes=nodes)
    if mt:
        return chess.engine.Limit(time=mt / 1000.0)
    base, inc = clocks["inc"], clocks["inc"]
    return chess.engine.Limit(white_clock=clocks[chess.WHITE], black_clock=clocks[chess.BLACK],
                              white_inc=clocks["inc"], black_inc=clocks["inc"])


def play_game(args, spec_a, spec_b, fen, opening, a_white, game_no):
    ea = open_engine(spec_a)
    eb = open_engine(spec_b)
    board = chess.Board(fen)
    white, black = (ea, eb) if a_white else (eb, ea)
    labels = (spec_a["label"], spec_b["label"]) if a_white else (spec_b["label"], spec_a["label"])
    for e in (ea, eb):
        try:
            e.ping()
        except Exception:
            pass
    clocks = {"inc": 0.0}
    if args.tc:
        base, _, inc = args.tc.partition("+")
        clocks = {chess.WHITE: float(base), chess.BLACK: float(base), "inc": float(inc or 0)}
    stats = {"a_depth": [], "a_nodes": [], "a_time": [], "b_depth": [], "b_nodes": [], "b_time": []}
    result, reason = "*", ""
    game_moves = []
    try:
        while True:
            if board.is_game_over(claim_draw=True):
                outcome = board.outcome(claim_draw=True)
                result = outcome.result()
                reason = outcome.termination.name.lower()
                break
            if board.ply() >= args.maxplies + len(openings_plies(opening)):
                result, reason = "1/2-1/2", "max_plies"
                break
            eng = white if board.turn == chess.WHITE else black
            is_a = (eng is ea)
            lim = limit_for(args, not is_a, clocks, board.turn)
            t0 = time.time()
            res = eng.play(board, lim, info=chess.engine.INFO_BASIC | chess.engine.INFO_SCORE)
            el = time.time() - t0
            if args.nodeclock:
                # node clock: charge nodes / K virtual milliseconds
                el = res.info.get("nodes", 0) / args.nodeclock / 1000.0
            if args.tc:
                clocks[board.turn] -= el
                if clocks[board.turn] < -args.margin:
                    result = "0-1" if board.turn == chess.WHITE else "1-0"
                    reason = "time_forfeit"
                    break
                clocks[board.turn] += clocks["inc"]
            if res.move is None or res.move not in board.legal_moves:
                result = "0-1" if board.turn == chess.WHITE else "1-0"
                reason = f"illegal_move:{res.move}"
                break
            side = "a" if is_a else "b"
            stats[side + "_depth"].append(res.info.get("depth", 0))
            stats[side + "_nodes"].append(res.info.get("nodes", 0))
            stats[side + "_time"].append(el)
            game_moves.append(res.move)
            board.push(res.move)
    finally:
        for e in (ea, eb):
            try:
                e.quit()
            except Exception:
                pass
    pts_a = {"1-0": 1.0, "0-1": 0.0, "1/2-1/2": 0.5}.get(result, 0.5)
    if not a_white:
        pts_a = 1.0 - pts_a
    game = chess.pgn.Game()
    game.setup(chess.Board(fen))
    node = game
    for mv in game_moves:
        node = node.add_variation(mv)
    game.headers.update({"Event": args.event, "Round": str(game_no), "White": labels[0],
                         "Black": labels[1], "Result": result, "Termination": reason,
                         "Opening": opening, "Date": dt.date.today().isoformat()})
    return {"game": game_no, "a_white": a_white, "result": result, "reason": reason,
            "points_a": pts_a, "plies": len(game_moves), "opening": opening,
            "pgn": str(game), **stats}


def openings_plies(line):
    return line.split()


def pair_interval(results):
    """95% Elo interval from the variance of per-opening pair scores"""
    pairs = {}
    for r in results:
        pairs.setdefault(r["opening"], []).append(r["points_a"])
    ps = [sum(v) / len(v) for v in pairs.values()]
    n = len(ps)
    if n < 2:
        return None
    s = sum(ps) / n
    se = math.sqrt(sum((p - s) ** 2 for p in ps) / (n - 1) / n)

    def elo(x):
        x = min(max(x, 1e-6), 1 - 1e-6)
        return -400 * math.log10(1 / x - 1)
    return {"pairs": n, "elo_lo_pairs": elo(s - 1.96 * se), "elo_hi_pairs": elo(s + 1.96 * se)}


def elo_summary(points):
    n = len(points)
    if n == 0:
        return {}
    w = sum(1 for p in points if p == 1.0)
    d = sum(1 for p in points if p == 0.5)
    l = n - w - d
    s = (w + 0.5 * d) / n
    var = sum((p - s) ** 2 for p in points) / n
    se = math.sqrt(var / n) if n > 1 else 0.5

    def elo(x):
        x = min(max(x, 1e-6), 1 - 1e-6)
        return -400 * math.log10(1 / x - 1)
    return {"games": n, "wins": w, "draws": d, "losses": l, "score": s, "elo": elo(s),
            "elo_lo": elo(s - 1.96 * se), "elo_hi": elo(s + 1.96 * se),
            "preliminary": n < 200}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--games", type=int, default=64)
    ap.add_argument("--nodes", type=int, default=0)
    ap.add_argument("--nodes2", type=int, default=0)
    ap.add_argument("--movetime", type=int, default=0)
    ap.add_argument("--movetime2", type=int, default=0)
    ap.add_argument("--tc", default="")
    ap.add_argument("--margin", type=float, default=0.5, help="clock overrun tolerance (s)")
    ap.add_argument("--nodeclock", type=int, default=0,
                    help="charge clocks by nodes/K virtual ms (engines must run with NodesTime=K)")
    ap.add_argument("--concurrency", type=int, default=2)
    ap.add_argument("--maxplies", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="results")
    ap.add_argument("--event", default="BendChess match")
    ap.add_argument("--tag", default="")
    ap.add_argument("--book", default=os.path.join(ROOT, "tools", "book.epd"),
                    help="EPD/FEN file of openings ('' = the 32-line suite)")
    args = ap.parse_args()
    if not (args.nodes or args.movetime or args.tc):
        args.movetime = 100
    spec_a, spec_b = parse_spec(args.a), parse_spec(args.b)
    if args.book and os.path.exists(args.book):
        suite = [(f"book#{i}", ln.strip()) for i, ln in enumerate(open(args.book)) if ln.strip()]
    else:
        suite = openings.suite()
    rng = random.Random(args.seed)
    rng.shuffle(suite)
    if args.games > 2 * len(suite):
        print(f"warning: {args.games} games but only {len(suite)} openings: games will repeat", flush=True)
    jobs = []
    for g in range(args.games):
        line, fen = suite[(g // 2) % len(suite)]
        jobs.append((fen, line, g % 2 == 0, g + 1))
    os.makedirs(args.out, exist_ok=True)
    tag = args.tag or dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    results = []
    lock = threading.Lock()
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futs = [ex.submit(play_game, args, spec_a, spec_b, fen, line, aw, g) for fen, line, aw, g in jobs]
        for fut in cf.as_completed(futs):
            r = fut.result()
            with lock:
                results.append(r)
                s = elo_summary([x["points_a"] for x in results])
                print(f"game {r['game']:3d} {'A=white' if r['a_white'] else 'A=black'} {r['result']:7s} "
                      f"{r['reason']:22s} plies={r['plies']:3d} | A: +{s['wins']} ={s['draws']} -{s['losses']} "
                      f"score {s['score']:.3f}", flush=True)
    results.sort(key=lambda r: r["game"])
    summ = elo_summary([r["points_a"] for r in results])
    summ.update(pair_interval(results) or {})
    summ["distinct_games"] = len({r["pgn"].split("\n\n", 1)[-1] for r in results})
    bdepth = [d for r in results for d in r["b_depth"]]
    bnodes = [n for r in results for n in r["b_nodes"]]
    btms = [t for r in results for t in r["b_time"]]
    depth = [d for r in results for d in r["a_depth"]]
    nodes = [n for r in results for n in r["a_nodes"]]
    tms = [t for r in results for t in r["a_time"]]
    summ.update({"a": args.a, "b": args.b, "limits": {"nodes": args.nodes, "nodes2": args.nodes2,
                 "movetime": args.movetime, "movetime2": args.movetime2, "tc": args.tc},
                 "a_avg_depth": sum(depth) / max(len(depth), 1),
                 "a_avg_nodes": sum(nodes) / max(len(nodes), 1),
                 "a_avg_time": sum(tms) / max(len(tms), 1),
                 "b_avg_depth": sum(bdepth) / max(len(bdepth), 1),
                 "b_avg_nodes": sum(bnodes) / max(len(bnodes), 1),
                 "b_avg_time": sum(btms) / max(len(btms), 1),
                 "a_total_nodes": sum(nodes), "b_total_nodes": sum(bnodes),
                 "wall_seconds": time.time() - t0,
                 "terminations": {}})
    for r in results:
        summ["terminations"][r["reason"]] = summ["terminations"].get(r["reason"], 0) + 1
    with open(os.path.join(args.out, f"{tag}.pgn"), "w") as f:
        f.write("\n\n".join(r["pgn"] for r in results) + "\n")
    with open(os.path.join(args.out, f"{tag}.json"), "w") as f:
        json.dump({"summary": summ, "games": [{k: v for k, v in r.items() if k != "pgn"} for r in results]},
                  f, indent=1)
    print(json.dumps(summ, indent=1))


if __name__ == "__main__":
    main()
