# BendChess architecture

## Language boundary

| Component | Language | Why |
|---|---|---|
| Board, make/unmake, move generation, attacks, FEN, perft | **Bend 2** (`src/board.bend`, `src/movegen.bend`) | core engine |
| Evaluation (PeSTO + feature terms), eval hash, lazy eval | **Bend 2** (`src/eval.bend`, generated `src/tables.bend`, `src/weights.bend`) | core engine |
| Search (PVS, qsearch, TT, pruning, LMR, killers/history) | **Bend 2** (`src/search.bend`) | core engine |
| Root search, move ranking, complexity-aware allocation | **Bend 2** (`src/root.bend`) | core engine / research |
| Complexity estimates, game-state report, ranked table | **Bend 2** (`src/analysis.bend`) | Modules 2-4 |
| UCI loop, iterative deepening, time->node budgets, Syzygy call | **Bend 2** (`src/uci.bend`, `src/main.bend`) | the engine is a native UCI binary |
| Formal laws and proofs | **Bend 2** (`LAWS.bend`, generated `PROOF.bend`) | formal correctness |
| Syzygy table decoding | Python + python-chess (`tools/syzygy_probe.py`), called from Bend via `Process.run` | Bend has no table decoder; root-level probing only |
| Match runner, opening suite, experiment driver | Python (`tools/match.py`, `tools/openings.py`, `tools/experiments.py`) | benchmarking infrastructure |
| Data generation, model fitting (eval weights, cost/length/branching models) | Python + numpy (`tools/datagen.py`, `tools/tune.py`) | training pipeline (Module 6) |
| Terminal play interface | Python (`tools/play.py`) | UI |
| Table / proof generators, Bend source tools | Python (`tools/gen_*.py`, `tools/bendsort.py`, `tools/bendedit.py`) | code generation |

Stockfish is used only as an external opponent and as a labeller of
training positions; no Stockfish code runs inside BendChess.

## Engine memory

One `Array<U32>` of 2^23 words (32 MB) is threaded through every function
(Bend arrays are affine and update in place, compiling to C array code):

| Region (word offset) | Content |
|---|---|
| 0..127 | 0x88 board (piece codes) |
| 1024.. | hash history, 2 words per ply since the root FEN (repetitions) |
| 16384.. | move lists, 256 words per search ply (move + ordering key) |
| 65536.. | triangular PV table; 81920: PV lengths; 82176: killers |
| 98304.. | history heuristic `[side][from][to]` |
| 131072.. | root move table (8 words per root move, see `src/root.bend`) |
| 135168.. | scalars: node budget, stop flag, scratch, UCI string options |
| 1048576.. | eval hash (2^19 entries) |
| 2097152.. | hash set for distinct-position counts (analysis) |
| 4194304.. | transposition table (2^20 entries x 4 words) |

Scalar position state (side, castling, ep, clocks, Zobrist hash, PeSTO
mg/eg/phase, king squares, occupancy bitboards, undo info) is an immutable
`Pos` record: `make` returns a new one (copy-make), so `unmake` only has to
restore board squares. Bend unboxes the record into registers.

## Position representation details

* 0x88 board; off-board test `sq & 0xFFFFFF88 == 0`; reads of off-board
  squares are redirected to slot 8 (always empty).
* Moves: `from | to << 7 | flag << 14` (flags: quiet, double push,
  castle, ep, 4 promotions); ordering keys in bits 17..31.
* Zobrist keys are computed by a bijective 32-bit mixer (two halves give a
  64-bit key) rather than stored tables.
* The en-passant square is recorded only when a pseudo-legal ep capture
  exists, so FIDE-identical positions hash identically (repetitions,
  distinct-position counts).
* Legality: pseudo-legal generation, then a cheap test after `make`: only
  king moves, ep, and moves made while in check need a full attack scan;
  otherwise only a pin ray through the origin square is checked (a 0x88
  delta table tells whether origin and king are aligned).
* Gives-check: direct attack of the moved piece (delta table + one ray
  walk for sliders) plus one discovered-check ray.

## Search

Iterative deepening with aspiration windows (driver in `src/uci.bend`),
root search with per-move statistics (`src/root.bend`), PVS + quiescence
(`src/search.bend`). Draw rules in search: fifty-move (halfmove >= 100),
repetition (any repetition inside the reversible stretch counts as a draw),
dead positions (K v K, K+minor v K). Mate scores are distance-adjusted and
stored ply-relative in the TT.

The search runs on a node budget; the driver converts time to nodes using
the measured speed, decides between iterations whether to continue, and
discards scores from an aborted iteration (the PV and root table are only
updated by completed move searches).

## Complexity-aware search (CAS)

See `docs/RESEARCH.md` for the hypothesis, the policy levels and results.
