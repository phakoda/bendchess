# Progress / task tracker

## Done

- [x] Phase 1 - toolchain: Bend 2.0.37 from source (installer host blocked),
      bun + clang 18; feasibility micro-benchmarks (docs/BEND_NOTES.md).
- [x] Phase 2 - board: 0x88 mailbox in a threaded array, copy-make state
      record, make/unmake, pseudo-legal generation with delta-table legality,
      castling, en passant, promotions, FEN in/out, perft, divide.
      Tests: 338/338 perft + FEN checks (CPW positions, edge-case suite,
      random positions vs python-chess).
- [x] Phase 3 - baseline engine: PeSTO eval, PVS + quiescence (check
      evasions), TT, null move, RFP, futility/LMP, LMR, killers, history,
      check extension, mate-distance pruning, aspiration windows, draw rules
      (50-move, repetition, dead positions), native UCI loop in Bend, time ->
      node budget driver, bench command.
- [x] Phase 4 - root table with per-move statistics, search priority /
      value of information, CAS levels 1-3, `analyze` report with complexity
      quantities A-D (exact and estimated, labelled), ranked candidate table.
- [x] Phase 5 - learning pipeline (self-play + Stockfish labels + engine
      features and search statistics; Gauss-Newton fits with game-grouped
      splits); Syzygy root probing and tablebase conversion via
      `Process.run` + python-chess.
- [x] Formal: LAWS.bend / PROOF.bend (13 laws).
- [x] Interfaces: UCI, terminal play (tools/play.py), analysis command.
- [x] Phase 2 (RESULTS.md section 9): faster bitboard evaluation; SEE
      (bitboard, lazy), history malus / countermoves / continuation history,
      aged TT, IIR, improving, qsearch TT, history and SEE pruning,
      singular extensions, correction history; root-split parallel search;
      5x training data, refit weights, learned iteration-cost model;
      TimePolicy 2/3; practical mode (Module 8); speed work; proofs
      re-checked; 30/30 engine tests.

## Commands

```
make && make test
build/bendchess bench 10
python3 tests/test_perft.py --random 200
python3 tests/test_engine.py
python3 tools/experiments.py --list
python3 tools/magnus.py
bend PROOF.bend
```

## Known blockers / limitations

- No external datasets (Lichess, tablebase server, pgnmentor unreachable
  from the sandbox); data is self-generated.
- `stop` cannot interrupt a running search (Bend reads stdin only between
  commands); `go infinite` is capped.
- Parallel search exists (root split, `Threads`) but scales poorly
  without a shared TT (1.18x on 2 threads).

## Next executable task

See "Highest-value next improvements" in docs/RESULTS.md.
