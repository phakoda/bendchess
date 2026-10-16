# BendChess entry point: command line tools and the UCI loop.

import Base
import ./core.bend as C
import ./board.bend as B
import ./uci.bend as U

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
  B.perft(m, p, depth, 0)

def perft.top(+depth: U32, fen: String) -> Array<U32> & U32:
  perft.top.b(depth, B.fen.parse(B.mem.new(), fen))

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
  divide.top.c(B.divide(m, p, depth))

def cmd.divide(+depth: U32, fen: String) -> IO(Unit):
  IO.print(divide.top.b(depth, B.fen.parse(B.mem.new(), fen)))

def fen.rt.c(r: Array<U32> & String) -> String:
  (m, s) = r
  s

# fen round trip: parse, print back
def fen.rt.b(r: Array<U32> & B.Pos) -> String:
  (m, +p) = r
  fen.rt.c(B.fen.out(m, p))

def cmd.fen(fen: String) -> IO(Unit):
  IO.print(fen.rt.b(B.fen.parse(B.mem.new(), fen)))

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

def cmd.named(+c: String, rest: List<&2, String>) -> IO(Unit):
  cmd.named.go(String.eq(c, "perft"), String.eq(c, "divide"), String.eq(c, "fen"), rest)

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
