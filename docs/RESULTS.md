# Results

All numbers below were measured in this repository on a 4-core cloud VM
(no GPU). Raw match records: `results/matches/*.json|pgn` (game-by-game,
with PGN), `results/summary.json`; earlier runs in `results/preliminary/`
and `results/superseded/`. Elo intervals are 95% intervals; "pair-CI"
treats the two games of an opening (colours reversed) as one sample.

## 1. Correctness

| Check | Result |
|---|---|
| Perft, standard positions (CPW start d1-6, Kiwipete d1-5, positions 3-6) | all exact (e.g. start d6 = 119,060,324; Kiwipete d5 = 193,690,690) |
| Perft edge-case suite (illegal ep, castling through check, promotions, stalemate/checkmate) | 16/16 exact |
| Random positions vs python-chess (perft 3) + FEN round trips | 432/432 checks pass (`tests/test_perft.py --random 200`) |
| Engine tests (`tests/test_engine.py`) | **23/23 pass**: mate/stalemate reporting, 50-move rule, dead positions, repetition bookkeeping, incremental hash/PeSTO/occupancy == recomputed (40 random games), move replay == python-chess FEN, deterministic search, ID sanity, warm-TT safety, known tactics, complexity counts and estimator accuracy - see section 6 |
| Distinct positions from the start (complexity quantity B) | d3 = 5,362, d4 = 72,078 (match published values) |
| Formal proofs (`bend PROOF.bend`) | **ALL PROOFS CHECK** (13 laws, 8 min 24 s; `results/proof_check.txt`) |

Proven laws (LAWS.bend): square coordinates round trip and on-board; 0x88
detection of every king step and knight jump from every square equals the
coordinate bounds test; the engine's direction table equals the geometric
steps; colour involution; piece encoding; move encoding round trip (all
64 x 64 x 8 cases); promotion metadata; castling-rights table matches a
specification; branch-free selection correct for all 32-bit inputs;
make-move flips the side, counts one ply, records the undo information and
never adds castling rights, for every position and move (the last via a
proven bit-vector lemma); null-move state. Not proven: move generation,
legality, search, evaluation (tested instead).

## 2. Speed and resources

| Measure | Value |
|---|---|
| Perft (legal leaves, full make/unmake + legality) | ~4.2-5.1 M nodes/s |
| Search, `bench 11` (12 positions) | 5.79 M nodes, ~584 k nodes/s (PeSTO eval, with other matches running) |
| Search, full feature eval | ~350 k nodes/s; light eval ~400 k nodes/s; PeSTO only ~750 k nodes/s (single position, depth 10) |
| Peak memory | ~36 MB (32 MB engine memory array incl. 16 MB TT) |
| Threads | 1 (no parallel search; see limitations) |

## 3. The research question: complexity-aware search allocation

Equal node budgets via the node clock (each side's own time manager spends
2 M nodes per game + 20 k per move), 400 games per row, 200 balanced
openings x 2 colours, **all 400 games distinct**:

| A vs B | W / D / L (A) | Elo for A | 95% CI | nodes used A/B |
|---|---|---|---|---|
| CAS-1 (budget adaptation) vs baseline | 152 / 139 / 109 | **+37** | [+10, +65] | 0.96 |
| CAS-2 (+ root allocation) vs baseline | 156 / 147 / 97 | **+52** | [+25, +79] | 0.96 |
| CAS-3 (+ in-tree allocation) vs baseline | 160 / 137 / 103 | **+50** | [+22, +78] | 0.96 |
| CAS-3 vs CAS-1 | 130 / 151 / 119 | +10 | [-17, +37] | 1.00 |
| control: baseline with soft limit x1.3 vs baseline | 99 / 142 / 159 | **-53** | [-80, -25] | 1.01 |
| CAS-1 vs control (soft x1.3) | 189 / 127 / 84 | +93 | [+65, +123] | 0.95 |

Equal wall-clock budgets (10 s + 0.1 s per game, 4 games in parallel on 4
cores, 400 distinct games each):

| A vs B | W / D / L (A) | Elo for A | 95% CI | avg time/move A vs B |
|---|---|---|---|---|
| CAS-1 vs baseline | 155 / 153 / 92 | **+55** | [+29, +82] | 0.95x nodes |
| CAS-3 vs baseline | 151 / 154 / 95 | **+49** | [+22, +76] | 0.218 s vs 0.230 s |

Findings:

* **Positive result.** Allocating the budget by how settled the decision is
  (stable best move and no score drop: stop early; changed best move or
  score drop: spend more) and by predicted iteration cost (never start an
  iteration predicted not to finish) gains about +40-55 Elo at equal node
  and at equal wall-clock budgets, **while using ~4% fewer nodes**.
* The control shows this is not "spending more": statically scaling the
  baseline's per-move budget by 1.3 loses 53 Elo (it front-loads the bank),
  and CAS-1 beats that control by 93 Elo.
* **Neutral result.** The finer-grained allocation (level 2: reduced depth
  for root moves with low value of information; level 3: forced-line
  extensions and extra reductions in very wide nodes) adds no measurable
  strength beyond level 1 (+10 [-17, +37]). The engine therefore defaults
  to `Complexity=1`.
* A methodological error was caught and corrected: an earlier round reused
  a 32-opening suite for 200 games, so engines that are deterministic under
  the node clock played only 64 distinct games and the intervals were too
  narrow (one of those runs even showed CAS-2 at -14). Those runs are kept
  in `results/superseded/` and were re-run with a 600-opening book.

## 4. Ablations (fixed 30,000 nodes per move, 400 distinct games)

| Component on vs off | W / D / L | Elo | 95% CI |
|---|---|---|---|
| Late-move reductions | 173 / 121 / 106 | +59 | [+30, +88] |
| Reverse futility + futility + late-move pruning | 198 / 122 / 80 | +106 | [+77, +136] |
| Null-move pruning | 137 / 127 / 136 | +1 | [-27, +29] (no measurable gain at this shallow budget) |

## 5. Evaluation and learning

| Experiment | Result |
|---|---|
| Full feature eval vs PeSTO only, equal nodes (20k/move, 96 games, preliminary*) | +73 [+17, +135]: the extra knowledge is real |
| same at equal time (8 s + 0.08 s, 96 games, preliminary*) | -93 [-157, -34] and, with eval hash + lazy eval, -73 [-141, -11]: the 2x slowdown costs more than it gains |
| Light eval (no mobility / king-zone walks) vs PeSTO, equal time (preliminary*) | -89 [-155, -28] |
| Weight fitting (Texel-style, Gauss-Newton with ridge toward hand weights, game-grouped split; 7,164 Stockfish-labelled positions from 600 self-play games) | test MSE in win-probability space: PeSTO only 0.02721, hand weights 0.02524, fitted 0.02556: **no improvement over hand weights; not adopted** |
| Search-cost model (log2 nodes to finish depth 7) | features-only MAE 0.74 bits (R^2 0.33); naive EBF extrapolation 0.79; hybrid 0.73 (small gain) |
| Remaining-game-length model | MAE 32.7 plies vs 37.4 for a constant (R^2 0.16); used in complexity quantity C |
| Branching k plies ahead | R^2 0.33 / 0.52 / 0.49 / 0.40 for k = 1 / 2 / 4 / 8 |

\* 96 games on the 32-line suite: fewer distinct games than played; treat
the intervals as optimistic. Consequence: the default evaluation is
PeSTO-only (`EvalMode=1`); the feature evaluation stays available.

## 6. Complexity estimator accuracy

Quantity A, log10 perft(5) extrapolated from exact counts at depths 1-3,
on 8 varied positions: mean |error| **0.02** (largest 0.05), all inside the
stated band. Quantity D (next-iteration node prediction) is printed with
its actual/predicted ratio by `analyze`; quantity C is a heuristic and is
labelled as such.

Tactical accuracy: 6/6 known positions (mates, tactics, mate/stalemate
detection) and **53/60 (88%)** of Stockfish-derived "only-move" positions
(one move >= 250 cp better than all others at depth 16) at 1 s/position.

## 7. Strength against external opponents

Preliminary calibration (16 games each, 10 s + 0.1 s, early engine
version): +13 =1 -2 vs Stockfish 16 at UCI_Elo 2000; +8 =3 -5 vs UCI_Elo
2400.

## 8. Match vs a "Magnus Carlsen bot" (strength proxy)

No real Magnus bot is reachable offline (commercial bots are online
services; his game collections could not be downloaded here). The opponent
is a **strength proxy**: Stockfish 16 with `UCI_LimitStrength` and
`UCI_Elo 2850` (about Carlsen's classical rating), at Stockfish's
calibration time control of 60 s + 0.6 s per game, 4 games in parallel,
100 games, 50 balanced openings x 2 colours (all 100 games distinct).

| BendChess (default: Complexity=1, PeSTO eval) vs SF16 @ UCI_Elo 2850 | Result |
|---|---|
| Wins / draws / losses | **10 / 41 / 49** |
| Score | 30.5% |
| Elo difference | **-143** [-200, -93] (pairs: [-208, -86]) |
| Terminations | 59 checkmates, 25 threefold, 9 fifty-move, 3 stalemate, 2 insufficient material, 2 max length; no time forfeits |
| Average per move | BendChess depth 14.3, 825 k nodes, 1.22 s; Stockfish depth 30.9 (limited strength), 1.32 s |

So BendChess **won 10 of 100 games** against this proxy and lost the match
clearly: on Stockfish's UCI_Elo scale it sits roughly 140 points below
2850 (very roughly ~2700 on that engine-calibrated scale, which is NOT a
FIDE rating). Caveats: a strength-limited Stockfish is not Carlsen (it
neither plays his openings nor errs like a human), and UCI_Elo is
calibrated against engine rating lists, not FIDE.

### 8.1 Phase 2 re-measurement (final defaults: EvalMode 0, TimePolicy 3)

Same openings and setup (1 thread each, 4 games in parallel on 4 cores):

| Opponent | TC | Games | W / D / L | Score | Elo diff (95%) | Wall time |
|---|---|---|---|---|---|---|
| SF16 UCI_Elo 2850 (Magnus proxy) | 60 + 0.6 | 100 | **17 / 52 / 31** | 43.0% | **-49** [-97, -2] | 85 min |
| SF16 UCI_Elo 3190 (top of SF's calibrated range) | 60 + 0.6 | 100 | 1 / 33 / 66 | 17.5% | -269 [-336, -216] | 75 min |
| SF16 full strength | 60 + 0.6 | 40 | 0 / 5 / 35 | 6.3% | about -470 (lower bound, too few points) | 28 min |
| SF16 full strength at 10:1 time odds (0.12 s vs 1.2 s per move) | fixed time | 40 | 0 / 3 / 37 | 3.8% | about -560 (lower bound) | 9 min |

Against the proxy the phase-2 engine improved from 10 / 41 / 49
(-143) to 17 / 52 / 31 (-49), i.e. about +95 Elo. On Stockfish's UCI_Elo
scale the two anchors give ~2800 [2750, 2850] (from 2850) and ~2920
[2855, 2975] (from 3190); the intervals do not overlap, so the
strength-limited levels are not mutually consistent against this engine
(the limited Stockfish weakens itself with random errors, which is not
the same as a lower-rated engine). A fair summary is "roughly 2800-2900
on Stockfish's engine-calibrated UCI_Elo scale" - not a FIDE rating.
Full-strength Stockfish wins almost every game, even with 10x less time.

## 9. Phase 2: the five listed improvements and further fundamentals

Every change below was A/B-tested (400 games, 200 book openings x 2
colours, all games distinct; 5 s + 0.05 s per game at wall clock with 4
games on 4 cores, or a node clock where stated). Full table:
`results/ab_summary.md`; game records: `results/ab/*.pgn`. "Same tree"
means the change was verified to leave node counts at fixed depth
unchanged (pure speedups), and value-identical changes were checked
against the previous implementation (feature vectors on 1,500 random
positions, SEE on 6,000 captures, perft).

### 9.1 What was built

| # | Improvement | Implementation |
|---|---|---|
| 1 | Faster feature evaluation | pawn bitboards + pawn-structure Zobrist key kept incrementally in the position; passed/isolated/doubled pawns, shield and rook files by bit arithmetic (fills, spans, file masks); knight mobility from attack tables + popcount; bishop/rook/queen mobility from ray tables (first blocker = lowest/highest set bit); the per-piece pass skips pawns. Identical features. |
| 2 | SEE, TT replacement, history | SEE on occupancy bitboards (x-rays by clearing bits, no board edits), lazy SEE in the move picker, SEE pruning in quiescence and at depth <= 3; aged TT replacement; signed history with gravity and malus; countermoves; continuation history; history-adjusted LMR and history pruning |
| 3 | Parallel search | root split with Bend fork-join calls, worker memories with their own TT, moves dealt by hash (`Threads` 2/4) |
| 4 | More data, learned cost model | 35,830 Stockfish-labelled positions from 3,000 self-play games (5x phase 1); refit evaluation weights; a learned iteration-cost model (`tools/costmodel.py`) used by `TimePolicy 3` |
| 5 | Budget policy v2, longer TC | `TimePolicy 2`: best-move node effort (share of root nodes) + graded score drops; `TimePolicy 3`: + learned cost model; CAS retested at a 3x larger budget |
| + | Further fundamentals | quiescence TT probe; IIR; improving heuristic; singular extensions with multi-cut; pawn-structure correction history; Zobrist and LMR from lookup tables; loop-free legality / gives-check fast paths (ray tables); make-move with the capture/castling updates behind one branch; options and node record packed into fewer words; practical-difficulty mode (Module 8) |

### 9.2 Measured effects

| Test | Result (Elo, 95%) | Notes |
|---|---|---|
| SEE (eager, in ordering + qsearch) vs phase-1 engine, equal time | **-30** [-59, -3] | SEE in ordering cost 32% of the node rate; made lazy afterwards (-24% instructions per node) |
| history malus + countermoves + continuation history + history LMR | **+49** [+21, +78] | |
| TT replacement + IIR + improving | +11 [-19, +41] | |
| lazy-SEE build vs phase-1 engine, equal time | +10 [-18, +37] | node rate 0.65x |
| **all phase-2 search changes vs phase-1 engine, equal nodes** (30k/move) | **+114** [+85, +145] | the search is much more efficient per node |
| all phase-2 changes vs phase-1 engine, equal time (PeSTO eval) | +9 [-18, +36] | node rate 0.63x: per-node cost eats most of the gain at this very short TC (about 0.1 s / 44k nodes per move) |
| full eval vs PeSTO, equal time, before the bitboard speedups | **-34** [-64, -5] | phase 1: -73 to -93 |
| full eval with refit weights vs PeSTO, equal time, after the speedups | +20 [-9, +50] | now the default (`EvalMode=0`) |
| refit vs hand weights, equal nodes | +3 [-26, +32] | held-out MSE 0.02565 vs 0.02639 (PeSTO only 0.02777): better fit, no measurable Elo |
| `TimePolicy 3` vs 1, equal node budgets | +18 [-8, +45] | uses 3% fewer nodes; now the default |
| practical mode (`Practical`) | not measured for Elo | off by default; tested for legality / not changing decisive choices |

Learned cost model (6,146 iterations from 800 positions, depth 12,
position-grouped split): predicting log2 of the next iteration's cost, the
engine's phase-1 rule ("same growth as the last iteration") has test MAE
**1.12 bits** - worse than a constant (0.81); the learned linear model
gets **0.72 bits**. Growth mean-reverts (coefficient -0.43 on the last
growth) and is smaller after a best-move change.

Parallel search, time to depth 13 on 16 positions, idle 4-core machine:
**1.18x** with 2 threads, **1.11x** with 4 (nodes 0.99x / 1.12x). The
first root move (a large share of each iteration) is searched alone, the
static fork-join scheduler cannot rebalance uneven move subtrees, and
workers do not share a TT. A speculative variant that starts all root
moves at once against the aspiration alpha was slower (0.86x, 2.2x the
nodes) and was not kept. `Threads` stays 1 by default (the benchmark
matches run one game per core anyway).

Speed (instructions per node from callgrind on a fixed-depth search,
same position; deterministic, unlike nps on a shared machine): the
phase-1 engine needs 13.4k. Eager SEE raised that to 22.6k; lazy SEE,
table Zobrist keys, bitboard SEE, loop-free legality, packed records and
the branching make-move brought it back to 20.3k (PeSTO eval) despite
the added features (continuation history, correction history,
quiescence TT, singular extensions). The full evaluation fell from 1.6x
to 1.3x the cost of PeSTO-only. Profiling shows ~15% of all instructions
are Bend's spills of live variables between continuation segments (the
node record carries the 23-word position record); shrinking the position
record further would require re-proving the make-move laws over packed
bit fields and was not done.

### 9.3 Correctness after phase 2

Perft suite and random-position perft vs python-chess: all exact. Engine
tests: **30/30** (adds Threads 2/4, TimePolicy 2/3, Practical). Tactics:
53/60 Stockfish-derived only-move positions (unchanged). Formal proofs:
**ALL PROOFS CHECK** after the position-record changes
(`results/proof_check2.txt`, 9 min 25 s).

## 10. Known limitations

* Strength: about 2800-2900 on Stockfish's UCI_Elo scale (section 8.1);
  full-strength Stockfish 16 scores 35.5/40 at equal time and 38.5/40
  while using 10x less time.
* Node rate: the phase-2 search is +114 Elo better at equal nodes but
  costs ~1.5x the instructions per node of the phase-1 engine, so at a
  very short time control (5 s + 0.05 s) the net gain is small
  (+9 [-18, +36]). The remaining overhead is structural (Bend's
  continuation segments copy the live node state; see 9.2).
* Parallel search scales poorly (1.18x on 2 threads): no shared TT (Bend
  arrays are affine), static fork-join with no work stealing, first root
  move searched alone. Off by default.
* `stop` cannot interrupt a running search (the Bend IO loop reads stdin
  only between commands); time control is enforced through node budgets
  from the measured speed. `go infinite` is capped.
* Several adopted defaults rest on positive but not significant results:
  full eval at equal time +20 [-9, +50], TimePolicy 3 +18 [-8, +45].
  The refit evaluation weights fit held-out data better but show no Elo
  difference from the hand weights.
* Data is self-play labelled by Stockfish; external corpora (Lichess,
  engine-analysis sets) were not reachable from the sandbox.
* Syzygy: root-only probing via a Python helper (no in-search WDL probes);
  only the 3-4-piece tables shipped with python-chess were available here.
* Repetition: any repetition inside the reversible stretch is scored as a
  draw in search (standard simplification); the TT is not keyed by the
  halfmove clock (graph-history interaction).
* Proofs cover the stated laws only; movegen/search/eval are tested, not
  proven. `--verdict` (Lean kernel re-check) was not run (no Lean offline).
* Practical mode (Module 8) is implemented but its effect against
  fallible (human-like) opponents was not measured; no such opponent was
  available offline.

## 11. Highest-value next improvements

1. Node rate: a packed position record (side/castling/ep/clocks and king
   squares in a few words) with the make-move laws re-proved over bit
   fields; staged move generation (try the TT move before generating).
2. Shared-memory parallel search once Bend offers safe shared arrays
   (lazy SMP with a shared TT), or splitting along the PV, not only at
   the root.
3. In-search tablebase WDL probes through a native decoder.
4. An external game corpus for tuning, and tuning the search parameters
   (margins, reduction tables) with the A/B harness at longer TCs.
5. Measure the practical mode against human-like opponents (e.g. Maia
   networks) once available.
