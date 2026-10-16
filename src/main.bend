# BendChess entry point: command line tools and the UCI loop.

import Base
import ./core.bend as C
import ./board.bend as B
import ./movegen.bend as G
import ./uci.bend as U
import ./search.bend as S

# List<&1, String> (as IO.args answers) -> List<&2, String>
def strs(xs: List<&1, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{h, t}:
      Con{h, strs(t)}

def fen.or_start(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      B.START_FEN()
    case Con{h, t}:
      String.join(Con{h, t}, " ")

# Perft / divide
# --------------

def perft.top.b(+depth: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +p) = r
  G.perft(m, p, depth, 0)

def perft.top(+depth: U32, fen: String) -> Array<U32> & U32:
  perft.top.b(depth, G.fen.parse(B.mem.new(), fen))

def perft.show(+t0: Nat, +t1: Nat, r: Array<U32> & U32) -> IO(Unit):
  (m, +n) = r
  +ms = Nat.sub(t1, t0)
  IO.print("perft " ++ U32.show(n) ++ " nodes " ++ Nat.show(ms) ++ " ms " ++
    Nat.show(Nat.div(Nat.mul(U32.to_nat(n), 1000n), Nat.max(ms, 1n))) ++ " nps")

def cmd.perft(+depth: U32, fen: String) -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    r : Array<U32> & U32 = perft.top(depth, fen)
    t1 : Nat <- IO.now()
    perft.show(t0, t1, r)

def divide.top.c(r: Array<U32> & String) -> String:
  (m, s) = r
  s

def divide.top.b(+depth: U32, r: Array<U32> & B.Pos) -> String:
  (m, +p) = r
  divide.top.c(G.divide(m, p, depth))

def cmd.divide(+depth: U32, fen: String) -> IO(Unit):
  IO.print(divide.top.b(depth, G.fen.parse(B.mem.new(), fen)))

def fen.rt.c(r: Array<U32> & String) -> String:
  (m, s) = r
  s

# fen round trip: parse, print back
def fen.rt.b(r: Array<U32> & B.Pos) -> String:
  (m, +p) = r
  fen.rt.c(G.fen.out(m, p))

def cmd.fen(fen: String) -> IO(Unit):
  IO.print(fen.rt.b(G.fen.parse(B.mem.new(), fen)))

def cmd.depth.go(perft: Bool, +d: U32, fen: String) -> IO(Unit):
  match perft:
    case True{}:
      cmd.perft(d, fen)
    case False{}:
      cmd.divide(d, fen)

def cmd.depth(perft: Bool, rest: List<&2, String>) -> IO(Unit):
  match rest:
    case Nil{}:
      IO.print("missing depth")
    case Con{d, fenp}:
      cmd.depth.go(perft, B.str.u32(d, 1), fen.or_start(fenp))

def cmd.named.go(perft: Bool, divide: Bool, fen: Bool, rest: List<&2, String>) -> IO(Unit):
  match perft divide fen:
    case True{} _ _:
      cmd.depth(True{}, rest)
    case False{} True{} _:
      cmd.depth(False{}, rest)
    case False{} False{} True{}:
      cmd.fen(fen.or_start(rest))
    case False{} False{} False{}:
      U.uci.main()

# Bench: fixed-depth searches of a fixed position set; prints the total
# node count (a determinism signature) and the speed.

def bench.fens() -> List<&2, String>:
  ["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
   "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
   "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
   "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
   "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
   "r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 3 9",
   "2r2rk1/pp1bqpp1/2n1pn1p/3p4/3P4/P1NBPN2/1PQ2PPP/2R2RK1 w - - 0 14",
   "r2q1rk1/1p1nbppp/p2pbn2/4p3/4P3/1NN1BP2/PPPQ2PP/2KR1B1R w - - 4 11",
   "8/8/4kpp1/3p1b2/p6P/2B5/6P1/6K1 b - - 0 47",
   "6k1/5p2/6p1/8/7p/8/6PP/6K1 b - - 0 1",
   "r1b1k2r/ppppnppp/2n2q2/2b5/3NP3/2P1B3/PP3PPP/RN1QKB1R w KQkq - 0 1",
   "4rrk1/pp1n3p/3q2pQ/2p1pb2/2PP4/2P3N1/P2B2PP/4RRK1 b - - 7 19"]

def bench.one.d?(+d: U32, +tot: U32, rest: List<&2, String>, +t0: Nat, m: Array<U32>) -> IO(Unit):
  bench.one.e(d, tot, rest, t0, m[B.SC()])

def bench.one.c?(+d: U32, +tot: U32, rest: List<&2, String>, +t0: Nat, r: Array<U32> & (U32 & U32)) -> IO(Unit):
  (m, bs) = r
  bench.one.d(d, tot, rest, t0, m)

def bench.one.b?(+d: U32, +tot: U32, rest: List<&2, String>, +t0: Nat, r: Array<U32> & B.Pos) -> IO(Unit):
  (m, +p) = r
  IO.bind(Array<U32> & (U32 & U32), Unit,
    U.think(S.clear(m), p, S.Opt.default(), U.Lim{d, 4000000000, 4000000000, 4000000000}, False{}),
    x => bench.one.c(d, tot, rest, t0, x))

def bench.fin(+tot: U32, +t0: Nat, t1: Nat) -> IO(Unit):
  +ms = Nat.max(Nat.sub(t1, t0), 1n)
  IO.print("bench nodes " ++ U32.show(tot) ++ " time " ++ Nat.show(ms) ++ " ms nps " ++
    Nat.show(Nat.div(Nat.mul(U32.to_nat(tot), 1000n), ms)))

def bench.go?(m: Array<U32>, +d: U32, +tot: U32, fens: List<&2, String>, +t0: Nat) -> IO(Unit):
  match fens:
    case Nil{}:
      IO.bind(Nat, Unit, IO.now(), t1 => bench.fin(tot, t0, t1))
    case Con{f, rest}:
      bench.one.b(d, tot, rest, t0, G.fen.parse(m, f))

def bench.one.e?(+d: U32, +tot: U32, rest: List<&2, String>, +t0: Nat, r: Array<U32> & U32) -> IO(Unit):
  (m, +left) = r
  bench.go(m, d, U32.add(tot, U32.sub(4000000000, left)), rest, t0)

def cmd.bench(+d: U32) -> IO(Unit):
  IO.bind(Nat, Unit, IO.now(), t0 => bench.go(B.mem.new(), d, 0, bench.fens(), t0))

def cmd.named.b(bench: Bool, +c: String, rest: List<&2, String>) -> IO(Unit):
  match bench:
    case True{}:
      cmd.bench(B.str.u32(B.str.nth(rest, 0n, "11"), 11))
    case False{}:
      cmd.named.go(String.eq(c, "perft"), String.eq(c, "divide"), String.eq(c, "fen"), rest)

def cmd.named(+c: String, rest: List<&2, String>) -> IO(Unit):
  cmd.named.b(String.eq(c, "bench"), c, rest)

# Dispatch
# --------

def cmd.go(args: List<&2, String>) -> IO(Unit):
  match args:
    case Con{c, rest}:
      cmd.named(c, rest)
    case Nil{}:
      U.uci.main()

def main.args(args: List<&2, String>) -> IO(Unit):
  match args:
    case Nil{}:
      cmd.go(Nil{})
    case Con{prog, rest}:
      cmd.go(rest)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.args(strs(args))
