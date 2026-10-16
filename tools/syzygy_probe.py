#!/usr/bin/env python3
"""Syzygy probe helper for the Bend engine (called through Process.run).

usage: syzygy_probe.py TABLE_DIR FEN

Prints one line:
  root <move> wdl <W> dtz <D> pieces <n>   the position itself is in the
      tables: <move> is a tablebase-optimal move (best WDL, then the DTZ
      that preserves it fastest; mate preferred), W in -2..2 from the side
      to move (2 win, 1 cursed win, 0 draw, -1 blessed loss, -2 loss)
  convert <move> wdl <W> dtz <D> ...    not in the tables, but some legal
      move (a capture or promotion) reaches a tablebase position; listed:
      the best such move with the resulting WDL for the side to move
  none                                  nothing applicable / tables missing

WDL respects the fifty-move rule (cursed wins / blessed losses are
reported separately). Only the move choice is decided here; the engine
compares a "convert" win with its own search result.
"""
import sys

import chess
import chess.syzygy


def main():
    if len(sys.argv) < 3:
        print("none")
        return
    path, fen = sys.argv[1], " ".join(sys.argv[2:])
    try:
        b = chess.Board(fen)
        tb = chess.syzygy.open_tablebase(path)
    except Exception:
        print("none")
        return
    with tb:
        n = chess.popcount(b.occupied)
        if n <= 7:
            try:
                tb.probe_wdl(b)
                best = None
                for mv in list(b.legal_moves):
                    c = b.copy(stack=False)
                    c.push(mv)
                    if c.is_checkmate():
                        key = (3, 0)
                        wdl, dtz = 2, 1
                    else:
                        wdl = -tb.probe_wdl(c)
                        dtz = abs(tb.probe_dtz(c)) if wdl != 0 else 0
                        # among wins, the shortest distance to a zeroing move
                        key = (wdl, -dtz if wdl > 0 else dtz)
                    if best is None or key > best[0]:
                        best = (key, mv, wdl, dtz)
                if best:
                    print(f"root {best[1].uci()} wdl {best[2]} dtz {best[3]} pieces {n}")
                    return
            except (KeyError, chess.syzygy.MissingTableError):
                pass
        best = None
        for mv in list(b.legal_moves):
            if not (b.is_capture(mv) or mv.promotion):
                continue
            c = b.copy(stack=False)
            c.push(mv)
            try:
                wdl = 2 if c.is_checkmate() else -tb.probe_wdl(c)
                if best is None or wdl > best[0]:
                    best = (wdl, mv, wdl)
            except (KeyError, chess.syzygy.MissingTableError):
                pass
        if best:
            print(f"convert {best[1].uci()} wdl {best[2]} dtz 0 pieces {n}")
        else:
            print("none")


if __name__ == "__main__":
    main()
