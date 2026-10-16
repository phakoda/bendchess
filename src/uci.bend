# BendChess UCI front end and iterative-deepening driver (Bend IO).
#
# The search itself is pure and cannot read the clock, so time control is
# done here: before each iteration the driver converts the remaining time
# into a node budget using the measured speed (nodes per ms), and between
# iterations it decides whether another one fits. A running search cannot
# be interrupted by a "stop" command (stdin is read only between
# searches); `go infinite` is therefore capped (see go.limits).

import Base
import ./core.bend as C
import ./board.bend as B
import ./eval.bend as E
import ./search.bend as S

# Small IO helpers
# ----------------

def nat.u32(n: Nat) -> U32:
  U32.from_nat(n)

def str.eq(a: String, b: String) -> Bool:
  String.eq(a, b)

def mem.read(m: Array<U32>, +i: U32) -> Array<U32> & U32:
  m[i]

# Search limits
# -------------
# maxd: depth cap; nodes: node cap; soft/hard: ms from the start of the
# search (soft: no new iteration after soft; hard: abort).
type Lim is Data:
  Lim{maxd: U32, nodes: U32, soft: U32, hard: U32}

# go parameters: wtime btime winc binc movestogo movetime depth nodes infinite
type Gp is Data:
  Gp{wt: U32, bt: U32, wi: U32, bi: U32, mtg: U32, mt: U32, depth: U32, nodes: U32, inf: Bool}

def Gp.empty() -> Gp:
  Gp{0, 0, 0, 0, 0, 0, 0, 0, False{}}

def gp.set(g: Gp, key: String, +v: U32) -> Gp:
  match g:
    case Gp{wt, bt, wi, bi, mtg, mt, depth, nodes, inf}:
      +k = key
      Gp{C.sel(str.eq(k, "wtime"), v, wt), C.sel(str.eq(k, "btime"), v, bt),
        C.sel(str.eq(k, "winc"), v, wi), C.sel(str.eq(k, "binc"), v, bi),
        C.sel(str.eq(k, "movestogo"), v, mtg), C.sel(str.eq(k, "movetime"), v, mt),
        C.sel(str.eq(k, "depth"), v, depth), C.sel(str.eq(k, "nodes"), v, nodes),
        inf || str.eq(k, "infinite")}

def go.parse.b?(k: String, +v: String, rest: List<&2, String>, g: Gp, single: Bool) -> Gp:
  match single:
    case True{}:
      go.parse(Con{v, rest}, g)
    case False{}:
      go.parse(rest, g)

def go.parse?(toks: List<&2, String>, g: Gp) -> Gp:
  match toks:
    case Nil{}:
      g
    case Con{+k, Nil{}}:
      gp.set(g, k, 0)
    case Con{+k, Con{+v, rest}}:
      go.parse.b(k, v, rest, gp.set(g, k, B.str.u32(v, 0)), str.eq(k, "infinite"))

def BIG() -> U32:
  4000000000

# turn go parameters into limits for side `side`
def go.limits(+g: Gp, +side: U32) -> Lim:
  match g:
    case Gp{wt, bt, wi, bi, mtg, mt, depth, nodes, inf}:
      +mine = C.sel(U32.is_zero(side), wt, bt)
      +inc = C.sel(U32.is_zero(side), wi, bi)
      +timed = U32.is_gt(mine, 0)
      +moves = C.sel(U32.is_gt(mtg, 0), U32.add(mtg, 1), 28)
      +alloc = U32.add(U32.div(mine, moves), U32.div(U32.mul(inc, 3), 4))
      +cap = S.sub0(U32.div(mine, 3), 30)
      +hardt = U32.max(U32.min(U32.mul(alloc, 3), cap), 5)
      +softt = U32.max(U32.min(alloc, cap), 5)
      +hasmt = U32.is_gt(mt, 0)
      +mtl = U32.max(S.sub0(mt, 30), 5)
      Lim{C.sel(U32.is_gt(depth, 0), U32.min(depth, 100), 100),
        C.sel(U32.is_gt(nodes, 0), nodes, BIG()),
        C.sel(hasmt, mtl, C.sel(timed, softt, C.sel(inf || U32.is_gt(depth, 0) || U32.is_gt(nodes, 0), BIG(), 2000))),
        C.sel(hasmt, mtl, C.sel(timed, hardt, C.sel(inf || U32.is_gt(depth, 0) || U32.is_gt(nodes, 0), BIG(), 2000)))}

def Lim.maxd(+l: Lim) -> U32:
  match l:
    case Lim{maxd, _, _, _}:
      maxd

def Lim.nodes(+l: Lim) -> U32:
  match l:
    case Lim{_, nodes, _, _}:
      nodes

def Lim.soft(+l: Lim) -> U32:
  match l:
    case Lim{_, _, soft, _}:
      soft

def Lim.hard(+l: Lim) -> U32:
  match l:
    case Lim{_, _, _, hard}:
      hard

def score.str.go(+s: U32, win: Bool, loss: Bool) -> String:
  match win loss:
    case True{} _:
      "mate " ++ U32.show(U32.div(U32.add(U32.sub(C.MATE(), s), 1), 2))
    case False{} True{}:
      "mate -" ++ U32.show(U32.div(U32.add(s, C.MATE()), 2))
    case False{} False{}:
      "cp " ++ C.s.show(s)

# Score / PV text
# ---------------

def score.str(+s: U32) -> String:
  score.str.go(s, C.s.ge(s, C.MATE_BOUND()), C.s.le(s, C.s.neg(C.MATE_BOUND())))

def pv.str.go?(m: Array<U32>, +k: U32, +len: U32, acc: String, go: Bool) -> Array<U32> & String:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      pv.str.b(k, len, acc, m[U32.add(B.PVT(), k)])

def pv.str?(m: Array<U32>, +k: U32, +len: U32, acc: String) -> Array<U32> & String:
  pv.str.go(m, k, len, acc, U32.is_lt(k, len))

def pv.str.b?(+k: U32, +len: U32, acc: String, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +mv) = r
  pv.str(m, U32.add(k, 1), len, acc ++ " " ++ B.mv.uci(mv))

def asp.again?(m: Array<U32>, +p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +s: U32, done: Bool,
               +a: U32, +b: U32, +delta: U32) -> Array<U32> & U32:
  match done:
    case True{}:
      (m, s)
    case False{}:
      asp.go(m, p, d, chk, o, a, b, delta)

def asp.res.b?(+p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +a: U32, +b: U32, +delta: U32, +s: U32,
               r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, stop) = r
  +inf = C.INF()
  +low = C.s.le(s, a) && C.s.gt(a, C.s.neg(inf))
  +high = C.s.ge(s, b) && C.s.lt(b, inf)
  +d2 = U32.mul(delta, 4)
  +wide = U32.is_gt(d2, 1000)
  asp.again(m, p, d, chk, o, s, stop || Bool.not(low || high),
    C.sel(low, C.sel(wide, C.s.neg(inf), C.s.max(U32.sub(s, d2), C.s.neg(inf))), a),
    C.sel(high, C.sel(wide, inf, C.s.min(U32.add(s, d2), inf)), b), d2)

def asp.res?(+p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +a: U32, +b: U32, +delta: U32,
             r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +s) = r
  asp.res.b(p, d, chk, o, a, b, delta, s, S.stopped(m))

# Aspiration windows
# ------------------
# search the root in (prev - delta, prev + delta); on a fail, widen that
# side (delta * 4) until the score is inside or the window is infinite.

def asp.go?(m: Array<U32>, +p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +a: U32, +b: U32,
            +delta: U32) -> Array<U32> & U32:
  asp.res(p, d, chk, o, a, b, delta, S.search(m, p, d, a, b, 0, False{}, chk, o))

def aspire(m: Array<U32>, +p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +prev: U32) -> Array<U32> & U32:
  +narrow = U32.is_ge(d, 4) && C.s.lt(C.s.abs(prev), 2000)
  asp.go(m, p, d, chk, o, C.sel(narrow, U32.sub(prev, 30), C.s.neg(C.INF())),
    C.sel(narrow, U32.add(prev, 30), C.INF()), 30)

# Iterative deepening
# -------------------

# results of one iteration, read from memory
type It is Data:
  It{left: U32, stop: Bool, best: U32, pvlen: U32, seld: U32}

def it.e(+left: U32, +stop: U32, +best: U32, +pvlen: U32, r: Array<U32> & U32) -> Array<U32> & It:
  (m, +seld) = r
  (m, It{left, U32.is_ne(stop, 0), best, pvlen, seld})

def it.d(+left: U32, +stop: U32, +best: U32, r: Array<U32> & U32) -> Array<U32> & It:
  (m, +pvlen) = r
  it.e(left, stop, best, pvlen, m[S.SELD()])

def it.c(+left: U32, +stop: U32, r: Array<U32> & U32) -> Array<U32> & It:
  (m, +best) = r
  it.d(left, stop, best, m[B.PVLEN()])

def it.b(+left: U32, r: Array<U32> & U32) -> Array<U32> & It:
  (m, +stop) = r
  it.c(left, stop, m[B.PVT()])

def it.b.a(r: Array<U32> & U32) -> Array<U32> & It:
  (m, +left) = r
  it.b(left, m[S.STOP()])

def it.read(m: Array<U32>) -> Array<U32> & It:
  it.b.a(m[S.BUDGET()])

# set the node budget of the next iteration and clear the stop flag
def budget.set(m: Array<U32>, +n: U32) -> Array<U32>:
  m[S.BUDGET()] <- n
  m[S.STOP()] <- 0
  m

# the driver's state between iterations
type Dr is Data:
  Dr{p: B.Pos, o: S.Opt, lim: Lim, t0: Nat, chk: Bool, used: U32, best: U32, score: U32, npms: U32,
     verbose: Bool}

def Dr.fin(m: Array<U32>, dr: Dr) -> IO(Array<U32> & (U32 & U32)):
  match dr:
    case Dr{p, o, lim, t0, chk, used, best, score, npms, verbose}:
      IO.pure(Array<U32> & (U32 & U32), (m, (best, score)))

def id.info(+d: U32, +s: U32, +used: U32, +ms: U32, +seld: U32, pv: String) -> String:
  "info depth " ++ U32.show(d) ++ " seldepth " ++ U32.show(seld) ++ " score " ++ score.str(s) ++
    " nodes " ++ U32.show(used) ++ " nps " ++
    U32.show(U32.div(U32.mul(U32.min(used, 4000000), 1000), U32.max(ms, 1))) ++
    " time " ++ U32.show(ms) ++ " pv" ++ pv

def say(verbose: Bool, s: String) -> IO(Unit):
  match verbose:
    case True{}:
      IO.print(s)
    case False{}:
      IO.pure(Unit, Unit{})

def id.done.c?(+d: U32, +budget: U32, +s: U32, dr: Dr, +now: Nat, r: Array<U32> & U32) ->
  IO(Array<U32> & (U32 & U32)):
  (m, +len) = r
  id.after(d, budget, s, dr, now, pv.str(m, 0, len, ""))

def id.done.b?(+d: U32, +budget: U32, +s: U32, dr: Dr, m: Array<U32>, now: Nat) ->
  IO(Array<U32> & (U32 & U32)):
  id.done.c(d, budget, s, dr, now, mem.read(m, B.PVLEN()))

def id.done?(+d: U32, +budget: U32, dr: Dr, r: Array<U32> & U32) -> IO(Array<U32> & (U32 & U32)):
  (m, +s) = r
  IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), id.done.b(d, budget, s, dr, m))

# run iteration d with a budget derived from the time left
def id.iter.t?(m: Array<U32>, +d: U32, dr: Dr, now: Nat) -> IO(Array<U32> & (U32 & U32)):
  match dr:
    case Dr{+p, +o, +lim, +t0, +chk, +used, +best, +score, +npms, +verbose}:
      +ms = nat.u32(Nat.sub(now, t0))
      +left_t = S.sub0(Lim.hard(lim), ms)
      +by_time = C.sel(U32.is_ge(Lim.hard(lim), BIG()), BIG(), U32.mul(U32.min(left_t, 100000), npms))
      +by_nodes = S.sub0(Lim.nodes(lim), used)
      +budget = U32.max(U32.min(by_time, by_nodes), C.sel(U32.is_eq(d, 1), 2000, 1))
      id.done(d, budget, Dr{p, o, lim, t0, chk, used, best, score, npms, verbose},
        aspire(budget.set(m, budget), p, d, chk, o, score))

def id.iter?(m: Array<U32>, +d: U32, dr: Dr) -> IO(Array<U32> & (U32 & U32)):
  IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), id.iter.t(m, d, dr))

def id.next?(m: Array<U32>, +d: U32, dr: Dr, more: Bool) -> IO(Array<U32> & (U32 & U32)):
  match more:
    case False{}:
      Dr.fin(m, dr)
    case True{}:
      # through IO.bind (a closure call), not a direct call: a direct call
      # here makes Bend 2.0.37 emit a fused C function before its
      # declaration (see docs/BEND_NOTES.md)
      IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), id.iter.t(m, U32.add(d, 1), dr))

def id.after.b?(+d: U32, +budget: U32, +s: U32, +p: B.Pos, +o: S.Opt, +lim: Lim, +t0: Nat,
                +chk: Bool, +used0: U32, +best0: U32, +score0: U32, +npms0: U32, +verbose: Bool,
                +now: Nat, pv: String, r: Array<U32> & It) -> IO(Array<U32> & (U32 & U32)):
  (m, it) = r
  match it:
    case It{+left, +stop, +best, +pvlen, +seld}:
      +spent = U32.sub(budget, left)
      +used = U32.add(used0, spent)
      +ms = nat.u32(Nat.sub(now, t0))
      +npms = U32.max(U32.div(used, U32.max(ms, 1)), 50)
      +best2 = C.sel(U32.is_zero(best), best0, best)
      +score2 = C.sel(stop, score0, s)
      +more = Bool.not(stop) && U32.is_lt(d, Lim.maxd(lim)) && U32.is_lt(ms, Lim.soft(lim)) &&
        U32.is_lt(used, Lim.nodes(lim)) && C.s.lt(C.s.abs(s), U32.sub(C.MATE(), U32.add(d, 2)))
      do IO<Array<U32> & (U32 & U32)>:
        say(verbose && (Bool.not(stop) || U32.is_eq(d, 1)), id.info(d, s, used, ms, seld, pv))
        id.next(m, d, Dr{p, o, lim, t0, chk, used, best2, score2, npms, verbose}, more)

# after iteration d: report, then decide whether to go deeper
def id.after?(+d: U32, +budget: U32, +s: U32, dr: Dr, +now: Nat, r: Array<U32> & String) ->
  IO(Array<U32> & (U32 & U32)):
  match dr:
    case Dr{+p, +o, +lim, +t0, +chk, +used0, +best0, +score0, +npms0, +verbose}:
      (m, pv) = r
      id.after.b(d, budget, s, p, o, lim, t0, chk, used0, best0, score0, npms0, verbose, now, pv, it.read(m))

def think.go(+p: B.Pos, +o: S.Opt, +lim: Lim, +t0: Nat, +verbose: Bool, r: Array<U32> & Bool) ->
  IO(Array<U32> & (U32 & U32)):
  (m, +chk) = r
  id.iter(m, 1, Dr{p, o, lim, t0, chk, 0, 0, 0, 500, verbose})

def think.t(m: Array<U32>, +p: B.Pos, +o: S.Opt, +lim: Lim, +verbose: Bool, t0: Nat) ->
  IO(Array<U32> & (U32 & U32)):
  think.go(p, o, lim, t0, verbose, B.in_check(S.prep(m), p))

# search p within lim; answers memory, best move and score
def think(m: Array<U32>, +p: B.Pos, +o: S.Opt, +lim: Lim, +verbose: Bool) ->
  IO(Array<U32> & (U32 & U32)):
  IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), think.t(m, p, o, lim, verbose))

def moves.apply.c?(m: Array<U32>, +p: B.Pos, +mv: U32, rest: List<&2, String>, bad: Bool) ->
  Array<U32> & B.Pos:
  match bad:
    case True{}:
      (m, p)
    case False{}:
      moves.apply.b(rest, B.make(m, p, mv))

def moves.apply.a?(+p: B.Pos, rest: List<&2, String>, r: Array<U32> & U32) -> Array<U32> & B.Pos:
  (m, +mv) = r
  moves.apply.c(m, p, mv, rest, U32.is_zero(mv))

# play UCI moves from p (stops at the first illegal one)
def moves.apply?(m: Array<U32>, +p: B.Pos, toks: List<&2, String>) -> Array<U32> & B.Pos:
  match toks:
    case Nil{}:
      (m, p)
    case Con{s, rest}:
      moves.apply.a(p, rest, B.find_move(m, p, s, 0))

# Position command
# ----------------

def moves.apply.b?(rest: List<&2, String>, r: Array<U32> & B.Pos) -> Array<U32> & B.Pos:
  (m, +p) = r
  moves.apply(m, p, rest)

def until.moves.c(h: String, r: List<&2, String> & List<&2, String>) -> List<&2, String> & List<&2, String>:
  (a, b) = r
  (Con{h, a}, b)

def until.moves.b?(h: String, t: List<&2, String>, stop: Bool) -> List<&2, String> & List<&2, String>:
  match stop:
    case True{}:
      (Nil{}, t)
    case False{}:
      until.moves.c(h, until.moves(t))

# split tokens at "moves": (before, after)
def until.moves?(toks: List<&2, String>) -> List<&2, String> & List<&2, String>:
  match toks:
    case Nil{}:
      (Nil{}, Nil{})
    case Con{+h, t}:
      until.moves.b(h, t, str.eq(h, "moves"))

def pos.fen.b(mvs: List<&2, String>, r: Array<U32> & B.Pos) -> Array<U32> & B.Pos:
  (m, +p) = r
  moves.apply(m, p, mvs)

def pos.fen.go(m: Array<U32>, sp: List<&2, String> & List<&2, String>) -> Array<U32> & B.Pos:
  (fenp, mvs) = sp
  pos.fen.b(mvs, B.fen.parse(m, String.join(fenp, " ")))

def until.moves.snd(r: List<&2, String> & List<&2, String>) -> List<&2, String>:
  (a, b) = r
  b

def until.moves.after(toks: List<&2, String>) -> List<&2, String>:
  until.moves.snd(until.moves(toks))

def pos.cmd.b(m: Array<U32>, rest: List<&2, String>, fen: Bool) -> Array<U32> & B.Pos:
  match fen:
    case True{}:
      pos.fen.go(m, until.moves(rest))
    case False{}:
      pos.fen.go(m, (B.START_FEN() <> Nil{}, until.moves.after(rest)))

# "position startpos|fen <fen> [moves ...]" (tokens after "position")
def pos.cmd(m: Array<U32>, toks: List<&2, String>) -> Array<U32> & B.Pos:
  match toks:
    case Nil{}:
      B.fen.parse(m, B.START_FEN())
    case Con{+kind, rest}:
      pos.cmd.b(m, rest, str.eq(kind, "fen"))

# UCI loop
# --------

def line.cons(+c: Char, r: Maybe<&1, String & String>) -> Maybe<&1, String & String>:
  match r:
    case None{}:
      None{}
    case Some{(l, rest)}:
      Some{(SCon{c, l}, rest)}

# the first line of s (without its newline) and the rest, if s has a newline
def line.split?(s: String) -> Maybe<&1, String & String>:
  match s:
    case SNil{}:
      None{}
    case SCon{+c, rest}:
      line.at(c, rest, U32.is_eq(Char.to_u32(c), 10))

def line.at?(+c: Char, rest: String, nl: Bool) -> Maybe<&1, String & String>:
  match nl:
    case True{}:
      Some{(SNil{}, rest)}
    case False{}:
      line.cons(c, line.split(rest))

def line.clean.c(+c: Char, rest: String, cr: Bool, tab: Bool) -> String:
  match cr tab:
    case True{} _:
      rest
    case False{} True{}:
      SCon{' ', rest}
    case False{} False{}:
      SCon{c, rest}

# drop carriage returns and turn tabs into spaces
def line.clean(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, rest}:
      line.clean.c(c, line.clean(rest), U32.is_eq(Char.to_u32(c), 13), U32.is_eq(Char.to_u32(c), 9))

def words.keep.b(h: String, t: List<&2, String>, empty: Bool) -> List<&2, String>:
  match empty:
    case True{}:
      t
    case False{}:
      Con{h, t}

def words.keep(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+h, t}:
      words.keep.b(h, words.keep(t), String.is_empty(h))

# words of a line, empty ones dropped
def words(s: String) -> List<&2, String>:
  words.keep(String.split(line.clean(s), ' '))

def uci.id() -> IO(Unit):
  do IO<Unit>:
    IO.print("id name BendChess 0.1")
    IO.print("id author BendChess authors")
    IO.print("option name NullMove type check default true")
    IO.print("option name LMR type check default true")
    IO.print("option name Pruning type check default true")
    IO.print("option name Complexity type spin default 0 min 0 max 3")
    IO.print("uciok")

def opt.bool(v: String) -> Bool:
  str.eq(v, "true")

def opt.pick(c: Bool, a: Bool, b: Bool) -> Bool:
  match c:
    case True{}:
      a
    case False{}:
      b

def opt.set.b(o: S.Opt, +name: String, +v: String) -> S.Opt:
  match o:
    case S.Opt{null, lmr, prune, cas}:
      S.Opt{opt.pick(str.eq(name, "NullMove"), opt.bool(v), null),
        opt.pick(str.eq(name, "LMR"), opt.bool(v), lmr),
        opt.pick(str.eq(name, "Pruning"), opt.bool(v), prune),
        C.sel(str.eq(name, "Complexity"), B.str.u32(v, 0), cas)}

# setoption name <N> value <V>
def opt.set(o: S.Opt, toks: List<&2, String>) -> S.Opt:
  match toks:
    case Con{_, Con{+name, Con{_, Con{+v, _}}}}:
      opt.set.b(o, name, v)
    case _:
      o

def uci.read.b?(m: Array<U32>, +p: B.Pos, +o: S.Opt, buf: String, f: File, eof: Bool) -> IO(Unit):
  match eof:
    case True{}:
      File.close(f)
    case False{}:
      uci.loop(m, p, o, buf, f)

def uci.read?(m: Array<U32>, +p: B.Pos, +o: S.Opt, buf: String,
              r: File & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (f, res) = r
  match res:
    case Fail{_}:
      File.close(f)
    case Done{+s}:
      uci.read.b(m, p, o, buf ++ s, f, String.is_empty(s))

def uci.go?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>) -> IO(Unit):
  IO.bind(Array<U32> & (U32 & U32), Unit,
    think(m, p, o, go.limits(go.parse(toks, Gp.empty()), B.P.side(p)), True{}),
    r => go.out(o, f, buf, r, p))

def uci.pos?(+o: S.Opt, f: File, buf: String, r: Array<U32> & B.Pos) -> IO(Unit):
  (m, +p) = r
  uci.loop(m, p, o, buf, f)

def uci.d?(+p: B.Pos, +o: S.Opt, f: File, buf: String, r: Array<U32> & String) -> IO(Unit):
  (m, fen) = r
  do IO<Unit>:
    IO.print("fen " ++ fen)
    IO.print("eval " ++ C.s.show(E.pesto(p)) ++ " (side to move, cp)")
    uci.loop(m, p, o, buf, f)

def uci.cmd.b?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, rest: List<&2, String>,
               uci: Bool, ready: Bool, pos: Bool, go: Bool, quit: Bool, setopt: Bool, newg: Bool,
               d: Bool) -> IO(Unit):
  match uci ready pos go quit setopt newg d:
    case True{} _ _ _ _ _ _ _:
      IO.bind(Unit, Unit, uci.id(), u => uci.loop(m, p, o, buf, f))
    case False{} True{} _ _ _ _ _ _:
      IO.bind(Unit, Unit, IO.print("readyok"), u => uci.loop(m, p, o, buf, f))
    case False{} False{} True{} _ _ _ _ _:
      uci.pos(o, f, buf, pos.cmd(m, rest))
    case False{} False{} False{} True{} _ _ _ _:
      uci.go(m, p, o, f, buf, rest)
    case False{} False{} False{} False{} True{} _ _ _:
      File.close(f)
    case False{} False{} False{} False{} False{} True{} _ _:
      uci.loop(m, p, opt.set(o, rest), buf, f)
    case False{} False{} False{} False{} False{} False{} True{} _:
      uci.loop(S.clear(m), p, o, buf, f)
    case False{} False{} False{} False{} False{} False{} False{} True{}:
      uci.d(p, o, f, buf, B.fen.out(m, p))
    case False{} False{} False{} False{} False{} False{} False{} False{}:
      uci.loop(m, p, o, buf, f)

# dispatch one command line
def uci.cmd?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>) -> IO(Unit):
  match toks:
    case Nil{}:
      uci.loop(m, p, o, buf, f)
    case Con{+c, rest}:
      uci.cmd.b(m, p, o, f, buf, rest, str.eq(c, "uci"), str.eq(c, "isready"), str.eq(c, "position"),
        str.eq(c, "go"), str.eq(c, "quit"), str.eq(c, "setoption"), str.eq(c, "ucinewgame"),
        str.eq(c, "d"))

def uci.cmd.line?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, rest: String,
                  toks: List<&2, String>) -> IO(Unit):
  uci.cmd(m, p, o, f, rest, toks)

def uci.next?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String,
              r: Maybe<&1, String & String>) -> IO(Unit):
  match r:
    case None{}:
      IO.bind(File & Result<&1, &1, U32 & String, String>, Unit, File.read(f, 65536),
        x => uci.read(m, p, o, buf, x))
    case Some{(line, rest)}:
      uci.cmd.line(m, p, o, f, rest, words(line))

# handle complete lines in buf, reading stdin when none is left
def uci.loop?(m: Array<U32>, +p: B.Pos, +o: S.Opt, buf: String, f: File) -> IO(Unit):
  +b = buf
  uci.next(m, p, o, f, b, line.split(b))

def go.out.b?(+o: S.Opt, f: File, buf: String, m: Array<U32>, +p: B.Pos, bs: U32 & U32) -> IO(Unit):
  (+best, +score) = bs
  do IO<Unit>:
    IO.print("bestmove " ++ B.mv.uci(best))
    uci.loop(m, p, o, buf, f)

def go.out?(+o: S.Opt, f: File, buf: String, r: Array<U32> & (U32 & U32), +p: B.Pos) -> IO(Unit):
  (m, bs) = r
  go.out.b(o, f, buf, m, p, bs)

def uci.start(r: Array<U32> & B.Pos) -> IO(Unit):
  (m, +p) = r
  IO.bind(File, Unit, IO.try(File, File.open("/dev/stdin", "r")),
    f => uci.loop(m, p, S.Opt.default(), "", f))

def uci.main() -> IO(Unit):
  uci.start(B.fen.parse(B.mem.new(), B.START_FEN()))
