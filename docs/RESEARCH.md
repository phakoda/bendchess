# Research: complexity-aware search allocation

## Hypothesis

Conventional alpha-beta engines spend effort on a candidate move according
to its ordering and the pruning/reduction rules, largely independent of how
*expensive* its subtree is or how likely more search is to change the
decision. The hypothesis tested here: an engine that estimates, per
candidate and per decision,

1. the growth of the subtree after the move (branching, forcing replies),
2. the nodes needed to resolve its evaluation (observed and predicted),
3. how uncertain the move's value still is (score fluctuation across
   iterations, gap to the best move),
4. whether further search is likely to change the ranking,

and reallocates search effort with those estimates, plays stronger than
the same engine at the same node or time budget.

Complexity is used **only as a cost signal**. Scores always come from
adversarial search; a cheaper move is never preferred because it is
cheaper. The move played is the best-scored move of the deepest completed
search, and any move reduced by the policy that beats the current best is
re-searched at full depth before it can be chosen.

## Measures per candidate move (Module 4)

* **Playing strength**: the search score (exact for the best move, an upper
  bound for others under PVS; exact for all moves in `analyze`).
* **Search priority**: `prio = 65536 / (64 + gap)`, with
  `gap = max(0, best - score - 2 * fluctuation)` (a soft "chance to become
  best" that grows with uncertainty), and
  `voi = prio / (1 + nodes / mean_nodes)` (priority per predicted node,
  using the move's subtree cost in the previous iteration).

## Policy levels (UCI option `Complexity`)

| Level | Adds | Mechanism |
|---|---|---|
| 0 | - | conventional baseline: PVS at the root, every root move at full depth; time manager stops after the soft limit |
| 1 | budget adaptation | soft limit x0.6 when the best move has been stable for >= 3 iterations without a score drop, x0.8 at 2, x1.5 after a change or a score drop > 25 cp; never start an iteration whose predicted cost (last cost x observed growth, clamped 1.5..6) overruns the hard limit |
| 2 | root allocation | from depth 4, root moves ranked 4th or worse with low value of information (voi < 300: 1 ply less; voi < 120 and depth >= 6: 2 plies less), verified at full depth if they beat alpha |
| 3 | in-tree allocation | nodes with <= 3 pseudo-legal moves (forced lines) are extended one ply; late quiet moves in nodes with > 40 moves get one extra ply of reduction |

## Budget-adaptation policy versions (UCI option `TimePolicy`, phase 2)

Level 1 above is `TimePolicy 1`. Two extensions use more of the root
table:

* `TimePolicy 2`: soft-limit factor = stability (x1.4 after a best-move
  change, x0.65 after 3+ stable iterations) x graded score drop
  (1 + min(drop, 80) / 100) x node effort (share of the last iteration's
  root nodes spent on the best move: >= 90% -> x0.7, < 50% -> x1.3, from
  depth 6), clamped to [0.45, 2.5].
* `TimePolicy 3` (default): v2 plus a learned iteration-cost model
  (`tools/costmodel.py`): log2 growth = 1.9065 - 0.4292 log2 g1
  - 0.2034 log2 g2 - 0.0206 d - 0.357 changed - 0.0398 log2(|dscore| + 1)
  (+0.5 bit margin), used for the hard-limit check and to decline an
  iteration predicted to end beyond the scaled soft limit (half of it
  done by then). Test MAE 0.72 bits vs 1.12 for the level-1 rule.

Result at equal node budgets: v3 vs v1 +18 [-8, +45] (3% fewer nodes).
See RESULTS.md section 9.

## Complexity quantities (Module 3)

Kept separate and labelled in every report:

* **A** legal move sequences to depth d (perft): exact up to the chosen
  horizon; extrapolated beyond it from the last two same-side branching
  ratios, with a band from their drift.
* **B** distinct reachable positions at depth d: exact (hash set over the
  perft tree; positions identified FIDE-style: placement, side to move,
  castling rights, en passant only when a capture is pseudo-legal). From the
  start: 20, 400, 5,362, 72,078 for d = 1..4 (match the published values).
* **C** complete-game continuations: a Shannon-style order-of-magnitude
  heuristic (expected remaining plies x mean log branching), reported with
  a wide band and explicitly NOT a count.
* **D** search nodes to resolve: measured per iteration, effective
  branching factor, predicted next-iteration cost and the prediction error.

## Experimental protocol

* Paired openings (32 master lines, each played with both colours).
* Equal **node** budgets: both engines on a node clock (`NodesTime`), each
  engine's own time manager spends a per-game node budget; deterministic and
  independent of CPU load. Equal **wall-clock** budgets: a real time control
  with no more concurrent games than cores.
* Elo with a 95% interval from the per-game score variance; samples under
  200 games are labelled preliminary.

Results: [RESULTS.md](RESULTS.md).
