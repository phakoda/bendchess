# Bend 2 notes: what we verified, what we had to work around

Toolchain: Bend **2.0.37** (`bendlang/bend` at commit `d2aeefc`), run from a
checkout with bun 1.4, compiling to C with clang 18 (`bend file.bend -o bin`).
The official installer host was unreachable from our sandbox, so
`tools/setup_bend.sh` clones the repository and creates a `bend` wrapper.

Everything below was measured or observed in this project, not assumed.

## Performance facts

| Pattern | Result |
|---|---|
| Array read/write loop threaded through recursion (`a[i]`, `a[i] <- v`) | Same speed and same result as the equivalent C loop (100M iterations: 0.08 s vs 0.09 s) |
| 64-case `Nat` match returning constants | Same speed as a C lookup table (clang turns the if-chain into a table) |
| `do`-notation state monad over the array | ~200x slower and overflowed the stack: closures are not fused. Not used in hot code. |
| `+x = e` lets | Bound once to a C local, not re-evaluated per use |
| Data records (`Pos`, 15 fields) passed by value | Fully unboxed into registers by the compiler; no heap traffic |
| `-march=native` | No gain over the default `-O3` |

So the engine is written like C over one threaded `Array<U32>` "memory",
with immutable `Data` records for scalar state (copy-make).

## Language constraints that shaped the code

* **`match` only scrutinizes parameters** (or fields bound by a pattern),
  never computed values, and a parameter cannot be matched after a `let`.
  Every branch on a computed condition is a call to a helper def that takes
  the `Bool` as a parameter. Every array read (`m[i]` answers the pair
  `(array, value)`) is handed to the next def, which destructures it: the
  code is in an explicit continuation-passing "staged" style.
* **Scrutinees must follow parameter order** (`match a b` with `a` declared
  before `b`).
* **Termination is mandatory and mutual recursion is forbidden** for safe
  defs. All search/movegen loops count on `U32` and are marked `@unsafe`
  (`def f?(...)`), which also permits the mutual recursion of
  search <-> move loop. Safe defs must be declared after the defs they call;
  `tools/bendsort.py` stably topologically sorts a file to satisfy this.
* **Affine variables**: everything used twice needs `+` (and must be `Data`).
* **No signed integers**: scores are two's-complement values in `U32` with
  explicit signed comparisons (`C.s.lt` etc.).
* **No `U32` patterns** (`case 0:`); dispatch goes through `U32.to_nat` and
  `Nat` literal patterns (compiled to a flat if-chain / table).
* **Operators need a type annotation**: `(a + b : U32)`; we mostly call
  `U32.add` etc. directly.
* **A law proof may not depend on any `@unsafe` def anywhere in the imported
  files** — even unused ones. Hence `src/board.bend` (state, make/unmake;
  fully checked) is separate from `src/movegen.bend` (loops, `@unsafe`).

## I/O

* `File.open("/dev/stdin")` + `File.read` works for a line-based UCI loop.
* `IO.print` output is flushed when the event loop waits (e.g. on the next
  stdin read), so `bestmove` reaches the GUI promptly. Info lines printed
  during a long synchronous search are only flushed at the next wait.
* The pure search cannot read the clock; the driver converts time budgets
  into node budgets between iterations. A running search cannot be
  interrupted by `stop` (stdin is only read between commands).

## Compiler bug found (worked around)

A cycle of IO-returning functions where one call in the cycle is direct made
Bend 2.0.37 emit a fused C function ("spin") that is called before it is
declared (no prototype): clang fails with "call to undeclared function
spin_N". Workaround in `src/uci.bend` (`id.next`): route that edge through
`IO.bind` with a partial application (a closure call), which is not fused.
Upstream fix would be to emit prototypes for all spin functions before
their definitions (`bend2/comp.ts`, where `FL.spins` are written).

## Proofs

* The checker evaluates `U32` operations on literals, so finite-domain laws
  are proven by exhaustive case analysis closed by `{==}` (e.g. the move
  encoding round trip over all 64 x 64 x 8 cases: about 8 minutes).
* General bit-vector facts are provable by induction over `Word(n)`: we
  proved `(a & b) & ~a == 0` and the identities behind branch-free
  selection for all 32-bit values, and used them to prove that make-move
  never adds castling rights for any position and move.
* `%e : P` rewrites the right-hand side of `e : {a == b}` into the left:
  the goal must equal `P` with `_ := b` and becomes `P` with `_ := a`.
* `--verdict` (re-check with the Lean-proven kernel) needs Lean 4.34; it was
  not available offline here, so our proofs are checked by bend2's checker
  only.
