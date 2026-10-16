# BendChess

An original chess engine written in **Bend 2**, built to test one research
question: *can an engine play stronger at a fixed compute budget by
predicting how much search each candidate move will need, and allocating
search effort accordingly?*

Board representation, move generation, evaluation, alpha-beta search, the
complexity estimators, the complexity-aware search policy and the UCI
protocol loop are all Bend 2 code (`src/*.bend`), compiled to a native
binary. Python is used for tooling around the engine (match runner,
training pipeline, tablebase decoding, terminal UI). See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the exact boundary.

**Status and results:** see [docs/RESULTS.md](docs/RESULTS.md) (measured
numbers, including negative results) and [docs/PROGRESS.md](docs/PROGRESS.md).

## Build

Requirements: git, [bun](https://bun.sh) >= 1.2, clang >= 14, Python 3 with
`python-chess` (tests and tools) and `numpy` (training). Stockfish is only
needed for benchmark matches and data labelling.

```sh
make setup      # clone Bend 2 (pinned: 2.0.37) into third_party/, create tools/bin/bend
make            # build/bendchess (native binary via Bend -> C -> clang)
make test       # perft suite + engine tests
make proofs     # check LAWS.bend with PROOF.bend (about 9 minutes)
```

If `bend` is already on your PATH, `make` uses it.

## Run

```sh
build/bendchess                   # UCI engine (stdin/stdout): point a GUI at this
build/bendchess perft 5           # perft from the start (or: perft D <FEN>)
build/bendchess divide 3 <FEN>    # per-move perft
build/bendchess bench 10          # fixed-depth bench (node-count signature + speed)
python3 tools/play.py             # play against it in the terminal
python3 tools/play.py --black --movetime 3000 --show-analysis
```

UCI options: `NullMove`, `LMR`, `Pruning` (speculative pruning switches),
`Complexity` 0-3 (the complexity-aware search policy, 0 = conventional
baseline), `TimePolicy` 1-3 (budget adaptation v1 [default]; v2 adds
best-move node effort; v3 adds the learned iteration-cost model),
`Threads` 1/2/4 (root-split parallel search), `Practical` 0-200 (margin in
cp for the practical-difficulty move choice, Module 8; 0 = off),
`EvalMode` (0 full feature eval, 1 PeSTO only [default], 2 light),
`NodesTime` (node clock for equal-node experiments), `SoftScale`,
`SyzygyPath`.

Extra UCI commands: `d` (position, eval, incremental state), `features`
(evaluation feature vector), and

```
position fen <FEN>
analyze depth 8 cdepth 4
```

which prints the game-state report (move counts, material, clocks,
repetitions, rights), the complexity quantities (A legal sequences, B
distinct positions, C game-continuation heuristic, D search effort; each
labelled as exact or estimated) and the ranked candidate-move table after
every iteration (exact score for every move, nodes, opponent replies,
forcing flags, score fluctuation, search priority).

Tablebases: `tools/fetch_syzygy.sh` downloads the 3-4-piece Syzygy tables
shipped with python-chess into `third_party/syzygy`; then
`setoption name SyzygyPath value <dir>`.

## Experiments

```sh
python3 tools/match.py bend sf:elo=2000 --games 100 --tc 10+0.1
python3 tools/experiments.py --list
python3 tools/experiments.py cas1_nodes cas2_nodes --games 200
python3 tools/magnus.py --games 100           # vs a Magnus-strength proxy
python3 tools/datagen.py && python3 tools/tune.py   # learning pipeline
```

## Repository map

| Path | Content |
|---|---|
| `src/core.bend` | squares, pieces, moves, signed scores, hashing (safe, proven) |
| `src/board.bend` | memory layout, position record, make/unmake (safe, proven) |
| `src/movegen.bend` | move generation, attacks, legality, FEN, perft |
| `src/eval.bend` | evaluation (PeSTO + features), eval hash, lazy eval |
| `src/search.bend` | PVS, quiescence, TT, pruning, ordering, draw rules |
| `src/root.bend` | root search, move ranking, complexity-aware allocation |
| `src/analysis.bend` | analysis report and complexity estimators |
| `src/uci.bend`, `src/main.bend` | UCI loop, time management, CLI |
| `LAWS.bend`, `PROOF.bend` | formal laws and their proofs |
| `tests/` | perft / rules / search / estimator tests |
| `tools/` | match runner, experiments, training, play UI, generators |
| `docs/` | architecture, research write-up, results, Bend notes |

## Honest limits

Not unbeatable, not "solved", not formally verified as a whole: the proofs
cover the specific laws in `LAWS.bend` (encodings, 0x88 geometry,
castling-rights table, selection, and the make-move state transition).
Movegen, search and evaluation are validated by tests. See
[docs/RESULTS.md](docs/RESULTS.md) for strength numbers and limitations.
