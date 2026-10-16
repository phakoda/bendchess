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
