#!/usr/bin/env python3
"""Play against BendChess in the terminal.

    python3 tools/play.py [--black] [--movetime MS] [--depth D] [--fen FEN]
                          [--complexity N] [--show-analysis]

Enter moves in SAN (Nf3, exd5, O-O, e8=Q) or UCI (g1f3). Commands:
  undo         take back your last move (and the engine's reply)
  hint         ask the engine for a move suggestion
  analyze [D]  run the engine's full analysis report on the current position
  fen          print the current FEN
  flip         flip the board display
  quit         leave

The engine is the Bend binary build/bendchess speaking UCI; python-chess is
used here only for the board display and for parsing your input.
"""
import argparse
import os
import subprocess
import sys

import chess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "build", "bendchess")

GLYPH = {"P": "P", "N": "N", "B": "B", "R": "R", "Q": "Q", "K": "K",
         "p": "p", "n": "n", "b": "b", "r": "r", "q": "q", "k": "k"}


class Engine:
    def __init__(self, path, options):
        self.p = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, bufsize=1)
        self.send("uci")
        self.wait("uciok")
        for k, v in options.items():
            self.send(f"setoption name {k} value {v}")
        self.send("isready")
        self.wait("readyok")

    def send(self, s):
        self.p.stdin.write(s + "\n")
        self.p.stdin.flush()

    def wait(self, token, echo=None):
        lines = []
        while True:
            ln = self.p.stdout.readline()
            if not ln:
                raise RuntimeError("engine exited")
            ln = ln.rstrip("\n")
            lines.append(ln)
            if echo:
                echo(ln)
            if ln.startswith(token):
                return lines

    def go(self, board, limit, echo=None):
        moves = " ".join(m.uci() for m in board.move_stack)
        root = board.root()
        pos = "startpos" if root.fen() == chess.STARTING_FEN else "fen " + root.fen()
        self.send(f"position {pos}" + (f" moves {moves}" if moves else ""))
        self.send(f"go {limit}")
        lines = self.wait("bestmove", echo)
        info = [l for l in lines if l.startswith("info depth")]
        return lines[-1].split()[1], (info[-1] if info else "")

    def analyze(self, board, depth):
        moves = " ".join(m.uci() for m in board.move_stack)
        root = board.root()
        pos = "startpos" if root.fen() == chess.STARTING_FEN else "fen " + root.fen()
        self.send(f"position {pos}" + (f" moves {moves}" if moves else ""))
        self.send(f"analyze depth {depth} cdepth 3")
        self.send("isready")
        for ln in self.wait("readyok"):
            if ln.startswith("info string"):
                print(ln[len("info string "):])

    def quit(self):
        try:
            self.send("quit")
            self.p.wait(timeout=2)
        except Exception:
            self.p.kill()


def show(board, flip):
    ranks = range(8) if flip else range(7, -1, -1)
    files = range(7, -1, -1) if flip else range(8)
    print()
    for r in ranks:
        row = f" {r + 1} "
        for f in files:
            pc = board.piece_at(chess.square(f, r))
            row += (" " + GLYPH[pc.symbol()] if pc else " .")
        print(row)
    print("    " + " ".join("abcdefgh"[f] for f in files))
    print()


def parse(board, text):
    for fn in (board.parse_san, chess.Move.from_uci):
        try:
            mv = fn(text)
            if mv in board.legal_moves:
                return mv
        except Exception:
            pass
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--black", action="store_true", help="play the black pieces")
    ap.add_argument("--movetime", type=int, default=2000)
    ap.add_argument("--depth", type=int, default=0)
    ap.add_argument("--fen", default=chess.STARTING_FEN)
    ap.add_argument("--complexity", type=int, default=0, help="engine Complexity option (0..3)")
    ap.add_argument("--show-analysis", action="store_true", help="print the engine's search lines")
    ap.add_argument("--bin", default=BIN)
    args = ap.parse_args()
    eng = Engine(args.bin, {"Complexity": args.complexity})
    board = chess.Board(args.fen)
    human = chess.BLACK if args.black else chess.WHITE
    flip = args.black
    limit = f"depth {args.depth}" if args.depth else f"movetime {args.movetime}"
    echo = (lambda l: print("  " + l) if l.startswith("info depth") else None) if args.show_analysis else None
    print("BendChess -- type 'help' for commands")
    try:
        while not board.is_game_over(claim_draw=True):
            show(board, flip)
            if board.turn != human:
                mv, info = eng.go(board, limit, echo)
                move = chess.Move.from_uci(mv)
                print(f"BendChess plays {board.san(move)}   ({info.split(' pv ')[0][5:] if info else ''})")
                board.push(move)
                continue
            text = input(f"{'White' if human else 'Black'} to move> ").strip()
            if not text:
                continue
            cmd = text.split()
            if cmd[0] == "quit":
                break
            if cmd[0] == "help":
                print(__doc__)
                continue
            if cmd[0] == "fen":
                print(board.fen())
                continue
            if cmd[0] == "flip":
                flip = not flip
                continue
            if cmd[0] == "undo":
                for _ in range(2):
                    if board.move_stack:
                        board.pop()
                continue
            if cmd[0] == "hint":
                mv, info = eng.go(board, limit)
                print("hint:", board.san(chess.Move.from_uci(mv)), "|", info)
                continue
            if cmd[0] == "analyze":
                eng.analyze(board, int(cmd[1]) if len(cmd) > 1 else 6)
                continue
            mv = parse(board, text)
            if mv is None:
                print("illegal or unreadable move")
                continue
            board.push(mv)
        show(board, flip)
        print("Game over:", board.result(claim_draw=True), board.outcome(claim_draw=True).termination.name)
    except (EOFError, KeyboardInterrupt):
        print()
    finally:
        eng.quit()


if __name__ == "__main__":
    main()
