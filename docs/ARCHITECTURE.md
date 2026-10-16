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
| 82688.. | per-ply auxiliary words: previous-move key (continuation history), static eval, improving flag, singular-extension slot |
| 98304.. | history heuristic `[side][from][to]` (signed, gravity-bounded) |
| 131072.. | root move table (8 words per root move, see `src/root.bend`) |
| 135168.. | scalars: node budget, stop flag, seldepth, TT generation, node effort, SEE gain list, practical-mode scratch, UCI string options |
| 262144.. | correction history (2 x 16384, by side and pawn-structure key) |
| 1048576.. | eval hash (2^19 entries) |
| 2097152.. | hash set for distinct-position counts (analysis) |
| 3145728.. | searched-quiet lists (history malus), countermoves, continuation history (769 x 768) |
| 4194304.. | transposition table (2^20 entries x 4 words; replacement by depth and generation) |

With `Threads` > 1 every parallel worker owns another such memory
(allocated per `go`, freed afterwards; see "Parallel search").

Scalar position state (side, castling, ep, clocks, Zobrist hash, PeSTO
mg/eg/phase, king squares, undo info, and an `Occ` record with colour
occupancy, pawn bitboards and a pawn-structure Zobrist key) is an
immutable `Pos` record: `make` returns a new one (copy-make), so `unmake`
only has to restore board squares. Bend unboxes the record into
registers. 64-bit bitboards are pairs of U32 halves (Bend has no U64).

## Position representation details

* 0x88 board; off-board test `sq & 0xFFFFFF88 == 0`; reads of off-board
  squares are redirected to slot 8 (always empty).
* Moves: `from | to << 7 | flag << 14` (flags: quiet, double push,
  castle, ep, 4 promotions); ordering keys in bits 17..31.
* Zobrist keys come from generated lookup tables (`tools/gen_tables.py`),
  whose values are those of a bijective 32-bit mixer (two halves give a
  64-bit key). Large `Nat` matches compile to C arrays.
* Generated tables also hold knight / king attack sets, slider rays per
  direction (first blocker = lowest or highest set bit of ray & occupancy)
  and a log table for late-move reductions.
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

Main-search techniques (phase 2 additions marked +): PVS with aspiration
windows; transposition table (+ aged replacement); null move; reverse
futility; futility and late-move pruning (+ improving-aware); + history
pruning of bad quiets and + SEE pruning of losing captures at depth <= 3;
late-move reductions (log table, + history-key adjusted); killers;
+ countermoves; history (+ signed with gravity, + malus for searched
quiets that did not cut); + continuation history (previous move ->
current move); + internal iterative reduction; check extension;
+ singular extensions with multi-cut; mate-distance pruning;
+ correction history (static eval corrected by a running average of
search-minus-eval per pawn structure). Captures: MVV-LVA, + lazy SEE
(computed when the picker reaches a capture made by a more valuable
piece; losers are re-keyed below quiets). Quiescence: + TT probe,
delta pruning (+ before SEE / make), + SEE pruning, check evasions.

SEE runs on the occupancy bitboards: the attackers already used are
cleared from a local occupancy, so x-rays appear without touching the
board; superset masks skip the scan when no attacker can exist.

## Evaluation

`EvalMode=1` (default): PeSTO tapered tables (incremental) + tempo,
corrected by the correction history. `EvalMode=0`: plus 18 linear
features (passed pawns by rank, isolated, doubled, bishop pair, rook on
open / semi-open file and 7th rank, mobility per piece type, king attack
units, pawn shield). Pawn terms are pure bit arithmetic on the pawn
bitboards (fills, spans, file masks); knights use attack tables +
popcount; bishops / rooks / queens walk rays. The feature vector is
dumped by the `features` command for the learning pipeline.

## Parallel search (`Threads`)

Root split with Bend fork-join parallel calls (`a b = f(x) g(y)`): in each
iteration the main memory searches the first root move alone (it sets
alpha), then the remaining moves are dealt to 2 or 4 workers by a hash of
the move (a move goes to the same worker every iteration, so its subtree
is in that worker's TT) and searched in parallel; per-move results, node
counts and the best PV are merged back. Workers do not share a TT (Bend
arrays are affine; there is no shared mutable memory between parallel
calls).

## Time management

The driver converts time to node budgets. `TimePolicy` 1 (default) is the
CAS level-1 budget adaptation; 2 adds the best move's share of root nodes
(node effort) and graded score drops; 3 adds a learned iteration-cost
model (`tools/costmodel.py`) for the overrun check and declines iterations
predicted to end far past the soft limit.

## Practical mode (`Practical`, Module 8)

Off by default. With margin P > 0, the best move and up to three
runners-up are compared after the search: a runner-up qualifies if a
verification search proves it within P cp of the best; each qualifying
move gets a difficulty score (share of the opponent's replies that lose
>= 100 cp against the opponent's best reply, by quiescence), and the move
maximising value + P x difficulty is played.

## Complexity-aware search (CAS)

See `docs/RESEARCH.md` for the hypothesis, the policy levels and results.
