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
import ./movegen.bend as G
import ./eval.bend as E
import ./search.bend as S
import ./weights.bend as W
import ./root.bend as R
import ./analysis.bend as A

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

def go.parse?(toks: List<&2, String>, g: Gp) -> Gp:
  match toks:
    case Nil{}:
      g
    case Con{+k, Nil{}}:
      gp.set(g, k, 0)
    case Con{+k, Con{+v, rest}}:
      go.parse.b(k, v, rest, gp.set(g, k, B.str.u32(v, 0)), str.eq(k, "infinite"))

def go.parse.b?(k: String, +v: String, rest: List<&2, String>, g: Gp, single: Bool) -> Gp:
  match single:
    case True{}:
      go.parse(Con{v, rest}, g)
    case False{}:
      go.parse(rest, g)

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

def score.loss.go(+n: U32, zero: Bool) -> String:
  match zero:
    case True{}:
      "mate 0"
    case False{}:
      "mate -" ++ U32.show(n)

def score.loss(+n: U32) -> String:
  score.loss.go(n, U32.is_zero(n))

def score.str.go(+s: U32, win: Bool, loss: Bool) -> String:
  match win loss:
    case True{} _:
      "mate " ++ U32.show(U32.div(U32.add(U32.sub(C.MATE(), s), 1), 2))
    case False{} True{}:
      score.loss(U32.div(U32.add(s, C.MATE()), 2))
    case False{} False{}:
      "cp " ++ C.s.show(s)

# Score / PV text
# ---------------

def score.str(+s: U32) -> String:
  score.str.go(s, C.s.ge(s, C.MATE_BOUND()), C.s.le(s, C.s.neg(C.MATE_BOUND())))

def pv.str?(m: Array<U32>, +k: U32, +len: U32, acc: String) -> Array<U32> & String:
  pv.str.go(m, k, len, acc, U32.is_lt(k, len))

def pv.str.b?(+k: U32, +len: U32, acc: String, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +mv) = r
  pv.str(m, U32.add(k, 1), len, acc ++ " " ++ B.mv.uci(mv))

def pv.str.go?(m: Array<U32>, +k: U32, +len: U32, acc: String, go: Bool) -> Array<U32> & String:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      pv.str.b(k, len, acc, m[U32.add(B.PVT(), k)])

def asp.res?(+p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +a: U32, +b: U32, +delta: U32,
             r: (Array<U32> & U32) & R.Ws) -> (Array<U32> & U32) & R.Ws:
  (ms, ws) = r
  asp.res.m(p, d, chk, o, a, b, delta, ws, ms)

# Aspiration windows
# ------------------
# search the root in (prev - delta, prev + delta); on a fail, widen that
# side (delta * 4) until the score is inside or the window is infinite.

def asp.go?(m: Array<U32>, ws: R.Ws, +p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +a: U32, +b: U32,
            +delta: U32) -> (Array<U32> & U32) & R.Ws:
  asp.res(p, d, chk, o, a, b, delta, R.iter.par(m, ws, p, d, a, b, o, chk))

def asp.again?(m: Array<U32>, ws: R.Ws, +p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +s: U32, done: Bool,
               +a: U32, +b: U32, +delta: U32) -> (Array<U32> & U32) & R.Ws:
  match done:
    case True{}:
      ((m, s), ws)
    case False{}:
      asp.go(m, ws, p, d, chk, o, a, b, delta)

def asp.res.b?(+p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +a: U32, +b: U32, +delta: U32, +s: U32, ws: R.Ws,
               r: Array<U32> & Bool) -> (Array<U32> & U32) & R.Ws:
  (m, stop) = r
  +inf = C.INF()
  +low = C.s.le(s, a) && C.s.gt(a, C.s.neg(inf))
  +high = C.s.ge(s, b) && C.s.lt(b, inf)
  +d2 = U32.mul(delta, 4)
  +wide = U32.is_gt(d2, 1000)
  asp.again(m, ws, p, d, chk, o, s, stop || Bool.not(low || high),
    C.sel(low, C.sel(wide, C.s.neg(inf), C.s.max(U32.sub(s, d2), C.s.neg(inf))), a),
    C.sel(high, C.sel(wide, inf, C.s.min(U32.add(s, d2), inf)), b), d2)

def asp.res.m?(+p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +a: U32, +b: U32, +delta: U32, ws: R.Ws,
               r: Array<U32> & U32) -> (Array<U32> & U32) & R.Ws:
  (m, +s) = r
  asp.res.b(p, d, chk, o, a, b, delta, s, ws, S.stopped(m))

def aspire(m: Array<U32>, ws: R.Ws, +p: B.Pos, +d: U32, +chk: Bool, +o: S.Opt, +prev: U32) ->
  (Array<U32> & U32) & R.Ws:
  +narrow = U32.is_ge(d, 4) && C.s.lt(C.s.abs(prev), 2000)
  asp.go(m, ws, p, d, chk, o, C.sel(narrow, U32.sub(prev, 30), C.s.neg(C.INF())),
    C.sel(narrow, U32.add(prev, 30), C.INF()), 30)

# Iterative deepening
# -------------------

# results of one iteration, read from memory
type It is Data:
  It{left: U32, stop: Bool, best: U32, pvlen: U32, seld: U32, eff: U32}

def it.f(+left: U32, +stop: U32, +best: U32, +pvlen: U32, +seld: U32, r: Array<U32> & U32) -> Array<U32> & It:
  (m, +eff) = r
  (m, It{left, U32.is_ne(stop, 0), best, pvlen, seld, eff})

def it.e(+left: U32, +stop: U32, +best: U32, +pvlen: U32, r: Array<U32> & U32) -> Array<U32> & It:
  (m, +seld) = r
  it.f(left, stop, best, pvlen, seld, m[R.EFFORT()])

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
  m[S.SELD()] <- 0
  m

# the driver's state between iterations: sp = nodes spent by the last
# iteration, stab = iterations the best move has stayed the same
type Dr is Data:
  Dr{p: B.Pos, o: S.Opt, lim: Lim, t0: Nat, chk: Bool, used: U32, best: U32, score: U32, npms: U32,
     verbose: Bool, sp: U32, stab: U32}

def Dr.fin(m: Array<U32>, dr: Dr) -> IO(Array<U32> & (U32 & U32)):
  match dr:
    case Dr{p, o, lim, t0, chk, used, best, score, npms, verbose, sp, stab}:
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

# elapsed "milliseconds": wall time, or used / NodesTime on the node clock
def elapsed(+now: Nat, +t0: Nat, +used: U32, +nt: U32) -> U32:
  C.sel(U32.is_zero(nt), nat.u32(Nat.sub(now, t0)), U32.div(used, U32.max(nt, 1)))

# nodes affordable in `ms` milliseconds at `rate` nodes/ms (no overflow)
def afford(+ms: U32, +rate: U32) -> U32:
  U32.mul(U32.min(ms, U32.div(BIG(), U32.max(rate, 1))), rate)

def more.pick(baseline: Bool, a: Bool, b: Bool) -> Bool:
  match baseline:
    case True{}:
      a
    case False{}:
      b

# Whether to start iteration d + 1.
# Baseline: while time < soft limit (and depth/node caps allow).
# Complexity-aware (cas >= 1): the soft limit scales with how settled the
#   decision is, and an iteration whose predicted cost (last cost x
#   observed growth factor) would overrun the hard limit is not started.
#   TimePolicy 1: best move stable for several iterations and no score
#     drop: x0.6; just changed or score dropped > 25 cp: x1.5.
#   TimePolicy 2: stability x graded score drop x node effort, where node
#     effort is the share of the last iteration's root nodes spent on the
#     best move (>= 90%: the alternatives were refuted cheaply, x0.7;
#     < 50%: they were hard to refute, x1.3; from depth 6 on).
def tp.factor(+tp: U32, +eff: U32, +d: U32, +s: U32, +score0: U32, +changed: Bool, +stab: U32) -> U32:
  +drop = U32.is_gt(d, 1) && C.s.gt(U32.sub(score0, s), 25)
  +f1 = C.sel(changed || drop, 150, C.sel(U32.is_ge(stab, 3), 60, C.sel(U32.is_eq(stab, 2), 80, 100)))
  +fs = C.sel(changed, 140, C.sel(U32.is_ge(stab, 3), 65, C.sel(U32.is_eq(stab, 2), 85, 100)))
  +dr = U32.sub(score0, s)
  +fd = U32.add(100, C.sel(U32.is_gt(d, 1) && C.s.gt(dr, 0), U32.min(dr, 80), 0))
  +fe = C.sel(U32.is_lt(d, 6), 100, C.sel(U32.is_ge(eff, 90), 70, C.sel(U32.is_ge(eff, 50), 100, 130)))
  +f2 = U32.min(U32.max(U32.div(U32.mul(U32.div(U32.mul(fs, fd), 100), fe), 100), 45), 250)
  C.sel(U32.is_ge(tp, 2), f2, f1)

def id.more(+cas: U32, +ss: U32, +tp: U32, +eff: U32, +d: U32, +s: U32, +score0: U32, +changed: Bool, +stab: U32,
            +spent: U32, +sp: U32, +ms: U32, +rate: U32, +lim: Lim, +stop: Bool, +used: U32) -> Bool:
  +base = Bool.not(stop) && U32.is_lt(d, Lim.maxd(lim)) && U32.is_lt(used, Lim.nodes(lim)) &&
    C.s.lt(C.s.abs(s), U32.sub(C.MATE(), U32.add(d, 2)))
  +f = tp.factor(tp, eff, d, s, score0, changed, stab)
  +soft = Lim.soft(lim)
  +soft0 = C.sel(U32.is_gt(soft, 20000000), soft, U32.div(U32.mul(soft, ss), 100))
  +soft2 = U32.min(C.sel(U32.is_gt(soft, 20000000), soft, U32.div(U32.mul(soft, f), 100)),
    U32.max(U32.div(U32.mul(Lim.hard(lim), 8), 10), soft))
  +growth = U32.min(U32.max(U32.div(U32.mul(spent, 10), U32.max(sp, 1)), 15), 60)
  +pred_ms = U32.div(U32.div(U32.mul(U32.min(spent, 400000000), growth), 10), U32.max(rate, 1))
  +fits = U32.is_lt(d, 4) || U32.is_ge(Lim.hard(lim), BIG()) || U32.is_le(U32.add(ms, pred_ms), Lim.hard(lim))
  more.pick(U32.is_zero(cas), base && U32.is_lt(ms, soft0), base && U32.is_lt(ms, soft2) && fits)

def id.done.c?(+d: U32, +budget: U32, +s: U32, dr: Dr, ws: R.Ws, +now: Nat, r: Array<U32> & U32) ->
  IO(Array<U32> & (U32 & U32)):
  (m, +len) = r
  id.after(d, budget, s, dr, ws, now, pv.str(m, 0, len, ""))

def id.done.b?(+d: U32, +budget: U32, +s: U32, dr: Dr, ws: R.Ws, m: Array<U32>, now: Nat) ->
  IO(Array<U32> & (U32 & U32)):
  id.done.c(d, budget, s, dr, ws, now, mem.read(m, B.PVLEN()))

def id.done.m?(+d: U32, +budget: U32, dr: Dr, ws: R.Ws, r: Array<U32> & U32) -> IO(Array<U32> & (U32 & U32)):
  (m, +s) = r
  IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), id.done.b(d, budget, s, dr, ws, m))

def id.done?(+d: U32, +budget: U32, dr: Dr, r: (Array<U32> & U32) & R.Ws) -> IO(Array<U32> & (U32 & U32)):
  (ms, ws) = r
  id.done.m(d, budget, dr, ws, ms)

# run iteration d with a budget derived from the time left
def id.iter.t?(m: Array<U32>, ws: R.Ws, +d: U32, dr: Dr, now: Nat) -> IO(Array<U32> & (U32 & U32)):
  match dr:
    case Dr{+p, +o, +lim, +t0, +chk, +used, +best, +score, +npms, +verbose, +sp, +stab}:
      +nt = S.Opt.nt(o)
      +ms = elapsed(now, t0, used, nt)
      +left_t = S.sub0(Lim.hard(lim), ms)
      +by_time = C.sel(U32.is_ge(Lim.hard(lim), BIG()), BIG(), afford(left_t, C.sel(U32.is_zero(nt), npms, nt)))
      +by_nodes = S.sub0(Lim.nodes(lim), used)
      +budget = U32.max(U32.min(by_time, by_nodes), C.sel(U32.is_eq(d, 1), 2000, 1))
      id.done(d, budget, Dr{p, o, lim, t0, chk, used, best, score, npms, verbose, sp, stab},
        aspire(budget.set(m, budget), ws, p, d, chk, o, score))

def id.next?(m: Array<U32>, ws: R.Ws, +d: U32, dr: Dr, more: Bool) -> IO(Array<U32> & (U32 & U32)):
  match more:
    case False{}:
      Dr.fin(m, dr)
    case True{}:
      # through IO.bind (a closure call), not a direct call: a direct call
      # here makes Bend 2.0.37 emit a fused C function before its
      # declaration (see docs/BEND_NOTES.md)
      IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), id.iter.t(m, ws, U32.add(d, 1), dr))

def id.after.b?(+d: U32, +budget: U32, +s: U32, +p: B.Pos, +o: S.Opt, +lim: Lim, +t0: Nat,
                +chk: Bool, +used0: U32, +best0: U32, +score0: U32, +npms0: U32, +verbose: Bool,
                +sp: U32, +stab: U32, +now: Nat, pv: String, ws: R.Ws, r: Array<U32> & It) -> IO(Array<U32> & (U32 & U32)):
  (m, it) = r
  match it:
    case It{+left, +stop, +best, +pvlen, +seld, +eff}:
      +spent = U32.sub(budget, left)
      +used = U32.add(used0, spent)
      +nt = S.Opt.nt(o)
      +ms = elapsed(now, t0, used, nt)
      +wall = nat.u32(Nat.sub(now, t0))
      +npms = U32.max(U32.div(used, U32.max(wall, 1)), 50)
      +best2 = C.sel(U32.is_zero(best), best0, best)
      +score2 = C.sel(stop, score0, s)
      +changed = U32.is_gt(d, 1) && U32.is_ne(best2, best0)
      +stab2 = C.sel(changed, 0, U32.add(stab, 1))
      +more = id.more(S.Opt.cas(o), S.Opt.ss(o), S.Opt.tp(o), eff, d, s, score0, changed, stab2, spent, sp, ms,
        C.sel(U32.is_zero(nt), npms, nt), lim, stop, used)
      do IO<Array<U32> & (U32 & U32)>:
        say(verbose && (Bool.not(stop) || U32.is_eq(d, 1)), id.info(d, s, used, ms, seld, pv))
        say(verbose && Bool.not(more), "info nodes " ++ U32.show(used) ++ " time " ++ U32.show(ms))
        id.next(m, ws, d, Dr{p, o, lim, t0, chk, used, best2, score2, npms, verbose, spent, stab2}, more)

# after iteration d: report, then decide whether to go deeper
def id.after?(+d: U32, +budget: U32, +s: U32, dr: Dr, ws: R.Ws, +now: Nat, r: Array<U32> & String) ->
  IO(Array<U32> & (U32 & U32)):
  match dr:
    case Dr{+p, +o, +lim, +t0, +chk, +used0, +best0, +score0, +npms0, +verbose, +sp, +stab}:
      (m, pv) = r
      id.after.b(d, budget, s, p, o, lim, t0, chk, used0, best0, score0, npms0, verbose, sp, stab, now, pv, ws,
        it.read(m))

def id.iter?(m: Array<U32>, ws: R.Ws, +d: U32, dr: Dr) -> IO(Array<U32> & (U32 & U32)):
  IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), id.iter.t(m, ws, d, dr))

def think.root(+p: B.Pos, +o: S.Opt, +lim: Lim, +t0: Nat, +verbose: Bool, +chk: Bool, r: Array<U32> & U32) ->
  IO(Array<U32> & (U32 & U32)):
  (m, +n) = r
  id.iter(m, R.Ws.new(S.Opt.th(o)), 1, Dr{p, o, lim, t0, chk, 0, 0, 0, 500, verbose, 0, 0})

def think.go(+p: B.Pos, +o: S.Opt, +lim: Lim, +t0: Nat, +verbose: Bool, r: Array<U32> & Bool) ->
  IO(Array<U32> & (U32 & U32)):
  (m, +chk) = r
  think.root(p, o, lim, t0, verbose, chk, R.setup(m, p, chk, o))

def think.t(m: Array<U32>, +p: B.Pos, +o: S.Opt, +lim: Lim, +verbose: Bool, t0: Nat) ->
  IO(Array<U32> & (U32 & U32)):
  think.go(p, o, lim, t0, verbose, G.in_check(S.prep(m), p))

# search p within lim; answers memory, best move and score
def think(m: Array<U32>, +p: B.Pos, +o: S.Opt, +lim: Lim, +verbose: Bool) ->
  IO(Array<U32> & (U32 & U32)):
  IO.bind(Nat, Array<U32> & (U32 & U32), IO.now(), think.t(m, p, o, lim, verbose))

# Position command
# ----------------

def moves.apply.b?(rest: List<&2, String>, r: Array<U32> & B.Pos) -> Array<U32> & B.Pos:
  (m, +p) = r
  moves.apply(m, p, rest)

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
      moves.apply.a(p, rest, G.find_move(m, p, s, 0))

def until.moves.c(h: String, r: List<&2, String> & List<&2, String>) -> List<&2, String> & List<&2, String>:
  (a, b) = r
  (Con{h, a}, b)

# split tokens at "moves": (before, after)
def until.moves?(toks: List<&2, String>) -> List<&2, String> & List<&2, String>:
  match toks:
    case Nil{}:
      (Nil{}, Nil{})
    case Con{+h, t}:
      until.moves.b(h, t, str.eq(h, "moves"))

def until.moves.b?(h: String, t: List<&2, String>, stop: Bool) -> List<&2, String> & List<&2, String>:
  match stop:
    case True{}:
      (Nil{}, t)
    case False{}:
      until.moves.c(h, until.moves(t))

def pos.fen.b(mvs: List<&2, String>, r: Array<U32> & B.Pos) -> Array<U32> & B.Pos:
  (m, +p) = r
  moves.apply(m, p, mvs)

def pos.fen.go(m: Array<U32>, sp: List<&2, String> & List<&2, String>) -> Array<U32> & B.Pos:
  (fenp, mvs) = sp
  pos.fen.b(mvs, G.fen.parse(m, String.join(fenp, " ")))

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
      G.fen.parse(m, B.START_FEN())
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

def line.at?(+c: Char, rest: String, nl: Bool) -> Maybe<&1, String & String>:
  match nl:
    case True{}:
      Some{(SNil{}, rest)}
    case False{}:
      line.cons(c, line.split(rest))

# the first line of s (without its newline) and the rest, if s has a newline
def line.split?(s: String) -> Maybe<&1, String & String>:
  match s:
    case SNil{}:
      None{}
    case SCon{+c, rest}:
      line.at(c, rest, U32.is_eq(Char.to_u32(c), 10))

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
    IO.print("option name Complexity type spin default 1 min 0 max 3")
    IO.print("option name EvalMode type spin default 1 min 0 max 2")
    IO.print("option name NodesTime type spin default 0 min 0 max 100000")
    IO.print("option name SyzygyPath type string default <empty>")
    IO.print("option name SoftScale type spin default 100 min 10 max 1000")
    IO.print("option name TimePolicy type spin default 1 min 1 max 2")
    IO.print("option name Threads type spin default 1 min 1 max 4")
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
    case S.Opt{null, lmr, prune, cas, evm, nt, ss, tp, th}:
      S.Opt{opt.pick(str.eq(name, "NullMove"), opt.bool(v), null),
        opt.pick(str.eq(name, "LMR"), opt.bool(v), lmr),
        opt.pick(str.eq(name, "Pruning"), opt.bool(v), prune),
        C.sel(str.eq(name, "Complexity"), B.str.u32(v, 0), cas),
        C.sel(str.eq(name, "EvalMode"), B.str.u32(v, 0), evm),
        C.sel(str.eq(name, "NodesTime"), B.str.u32(v, 0), nt),
        C.sel(str.eq(name, "SoftScale"), B.str.u32(v, 100), ss),
        C.sel(str.eq(name, "TimePolicy"), B.str.u32(v, 1), tp),
        C.sel(str.eq(name, "Threads"), B.str.u32(v, 1), th)}

# setoption name <N> value <V>
def opt.set(o: S.Opt, toks: List<&2, String>) -> S.Opt:
  match toks:
    case Con{_, Con{+name, Con{_, Con{+v, _}}}}:
      opt.set.b(o, name, v)
    case _:
      o

# command name -> code
def cmd.code(+c: String) -> U32:
  C.sel(str.eq(c, "uci"), 1, C.sel(str.eq(c, "isready"), 2, C.sel(str.eq(c, "position"), 3,
  C.sel(str.eq(c, "go"), 4, C.sel(str.eq(c, "quit"), 5, C.sel(str.eq(c, "setoption"), 6,
  C.sel(str.eq(c, "ucinewgame"), 7, C.sel(str.eq(c, "d"), 8, C.sel(str.eq(c, "features"), 9,
  C.sel(str.eq(c, "eval"), 8, C.sel(str.eq(c, "analyze"), 10, C.sel(str.eq(c, "see"), 11, 0))))))))))))

# Strings kept in engine memory (UCI string options): length, then chars
def TBPATH() -> U32:
  U32.add(B.SC(), 256)

def mstr.get.go?(m: Array<U32>, +base: U32, +k: U32, acc: String) -> Array<U32> & String:
  mstr.get.b(m, base, k, acc, U32.is_zero(k))

def mstr.get.c?(+base: U32, +k: U32, acc: String, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +c) = r
  mstr.get.go(m, base, U32.sub(k, 1), SCon{Chr{c}, acc})

def mstr.get.b?(m: Array<U32>, +base: U32, +k: U32, acc: String, done: Bool) -> Array<U32> & String:
  match done:
    case True{}:
      (m, acc)
    case False{}:
      mstr.get.c(base, k, acc, m[U32.add(base, k)])

def mstr.get.a?(+base: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +len) = r
  mstr.get.go(m, base, U32.min(len, 1000), SNil{})

def mstr.get(m: Array<U32>, +base: U32) -> Array<U32> & String:
  mstr.get.a(base, m[base])

def HELPER() -> U32:
  U32.add(B.SC(), 1280)

def uci.go.tb8?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>,
                +mvs: String, +w: String, +d: String, root: Bool, conv: Bool) -> IO(Unit):
  match root conv:
    case True{} _:
      +dz = B.str.u32(d, 0)
      +sc = C.sel(str.eq(w, "2"), U32.sub(20000, dz), C.sel(str.eq(w, "-2"), U32.sub(0, U32.sub(20000, dz)), 0))
      do IO<Unit>:
        IO.print("info string syzygy: tablebase position, WDL " ++ w ++ " (side to move), DTZ " ++ d)
        IO.print("info depth 1 score cp " ++ C.s.show(sc) ++ " nodes 0 pv " ++ mvs)
        IO.print("bestmove " ++ mvs)
        uci.loop(m, p, o, buf, f)
    case False{} True{}:
      uci.go.search(m, p, o, f, buf, toks, mvs)
    case False{} False{}:
      uci.go.search(m, p, o, f, buf, toks, "")

def uci.go.tb7?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>,
                +kind: String, +mvs: String, +w: String, +d: String) -> IO(Unit):
  uci.go.tb8(m, p, o, f, buf, toks, mvs, w, d, str.eq(kind, "root"), str.eq(kind, "convert") && str.eq(w, "2"))

def uci.go.tb6?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>,
                ws: List<&2, String>) -> IO(Unit):
  match ws:
    case Con{kind, Con{mvs, Con{_, Con{w, Con{_, Con{d, _}}}}}}:
      uci.go.tb7(m, p, o, f, buf, toks, kind, mvs, w, d)
    case _:
      uci.go.search(m, p, o, f, buf, toks, "")

def uci.go.tb5?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>,
                res: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(Unit):
  match res:
    case Fail{_}:
      uci.go.search(m, p, o, f, buf, toks, "")
    case Done{(_, (out, _))}:
      uci.go.tb6(m, p, o, f, buf, toks, words(out))

def uci.go.tb4?(+p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>, path: String, fen: String,
                r: Array<U32> & String) -> IO(Unit):
  (m, helper) = r
  IO.bind(Result<&1, &1, U32 & String, U32 & (String & String)>, Unit,
    Process.run("python3", [helper, path, fen], "", 65536, 10000),
    res => uci.go.tb5(m, p, o, f, buf, toks, res))

def uci.go.tb3?(+p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>, path: String,
                r: Array<U32> & String) -> IO(Unit):
  (m, fen) = r
  uci.go.tb4(p, o, f, buf, toks, path, fen, mstr.get(m, HELPER()))

def uci.go.tb2?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>, path: String,
                skip: Bool) -> IO(Unit):
  match skip:
    case True{}:
      uci.go.search(m, p, o, f, buf, toks, "")
    case False{}:
      uci.go.tb3(p, o, f, buf, toks, path, G.fen.out(m, p))

def uci.go.tb?(+p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>, r: Array<U32> & String) -> IO(Unit):
  (m, +path) = r
  uci.go.tb2(m, p, o, f, buf, toks, path, String.is_empty(path) || U32.is_gt(B.npieces(p), 8))

def uci.go?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>) -> IO(Unit):
  uci.go.tb(p, o, f, buf, toks, mstr.get(m, TBPATH()))

def uci.pos?(+o: S.Opt, f: File, buf: String, r: Array<U32> & B.Pos) -> IO(Unit):
  (m, +p) = r
  uci.loop(m, p, o, buf, f)

# white-relative feature values 1..NFEAT, then PeSTO mg, eg and phase
def feats.k?(+p: B.Pos, +k: U32, acc: String, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +v) = r
  feats(m, p, U32.add(k, 1), acc ++ " " ++ C.s.show(v))

def feats.go?(m: Array<U32>, +p: B.Pos, +k: U32, acc: String, go: Bool) -> Array<U32> & String:
  match go:
    case True{}:
      feats.k(p, k, acc, E.eval.white(m, p, k))
    case False{}:
      (m, acc ++ " " ++ C.s.show(B.P.mg(p)) ++ " " ++ C.s.show(B.P.eg(p)) ++ " " ++ U32.show(B.P.ph(p)))

def feats?(m: Array<U32>, +p: B.Pos, +k: U32, acc: String) -> Array<U32> & String:
  feats.go(m, p, k, acc, U32.is_le(k, W.NFEAT()))

def uci.feat?(+p: B.Pos, +o: S.Opt, f: File, buf: String, r: Array<U32> & String) -> IO(Unit):
  (m, s) = r
  do IO<Unit>:
    IO.print("features" ++ s)
    uci.loop(m, p, o, buf, f)

# Analysis command
# ----------------
# analyze [depth D] [cdepth K]: a game-state report, exact complexity
# counts up to K plies with estimates beyond, then an exact-scores search
# (every root move with a full window) printing the ranked candidate table
# and node statistics after every iteration.

def an.cnt.slot(+d: U32) -> U32:
  U32.add(A.SCR(), U32.add(20, d))

def an.uni.slot(+d: U32) -> U32:
  U32.add(A.SCR(), U32.add(40, d))

# exact A and B counts for depth 1..cd (stored in scratch slots)
def an.cx.u?(+p: B.Pos, +d: U32, +cd: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +u) = r
  m[an.uni.slot(d)] <- u
  an.cx(m, p, U32.add(d, 1), cd)

def an.cx.n?(+p: B.Pos, +d: U32, +cd: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +n) = r
  m[an.cnt.slot(d)] <- n
  an.cx.u(p, d, cd, A.distinct(m, p, d))

def an.cx.go?(m: Array<U32>, +p: B.Pos, +d: U32, +cd: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      an.cx.n(p, d, cd, G.perft(m, p, d, 0))

def an.cx?(m: Array<U32>, +p: B.Pos, +d: U32, +cd: U32) -> Array<U32>:
  an.cx.go(m, p, d, cd, U32.is_le(d, cd))

def an.lines.u?(+d: U32, +cd: U32, acc: String, +n: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +u) = r
  +tr = C.sel(U32.is_gt(n, 0), U32.div(U32.mul(S.sub0(n, u), 1000), U32.max(n, 1)), 0)
  an.lines(m, U32.add(d, 1), cd, acc ++ A.say("  d" ++ U32.show(d) ++ ": A sequences " ++ U32.show(n) ++
    " | B distinct positions " ++ U32.show(u) ++ " | transpositions " ++ U32.show(U32.div(tr, 10)) ++ "." ++
    U32.show(U32.mod(tr, 10)) ++ "%"))

def an.lines.n?(+d: U32, +cd: U32, acc: String, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +n) = r
  an.lines.u(d, cd, acc, n, m[an.uni.slot(d)])

def an.lines.go?(m: Array<U32>, +d: U32, +cd: U32, acc: String, go: Bool) -> Array<U32> & String:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      an.lines.n(d, cd, acc, m[an.cnt.slot(d)])

def an.lines?(m: Array<U32>, +d: U32, +cd: U32, acc: String) -> Array<U32> & String:
  an.lines.go(m, d, cd, acc, U32.is_le(d, cd))

# estimates beyond the exact horizon from the last ratios
def an.est.c(+cd: U32, +nk: U32, +n1: U32, +n2: U32, +plies: U32, +mat: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +n3) = r
  +lnk = A.log10u(nk)
  +la = (A.log10u(nk) - A.log10u(n1) : F32)
  +lb = (A.log10u(n1) - A.log10u(n2) : F32)
  +drift = F32.abs(((A.log10u(nk) - A.log10u(n1)) - (A.log10u(n2) - A.log10u(n3)) : F32))
  +d2 = U32.add(cd, 2)
  +e2 = A.est.a(lnk, la, lb, cd, d2)
  +e10 = A.est.a(lnk, la, lb, cd, 10)
  +u2 = (drift + 0.1 : F32)
  +u10 = (drift * U32.to_f32(S.sub0(10, cd)) / 2.0 + 0.2 : F32)
  +lbar = (((la + lb) / 2.0 + 1.0) / 2.0 : F32)
  # remaining plies: linear model fitted by tools/tune.py on self-play
  # data (63.5 + 32.8 * phase/24 - 0.224 * ply; test MAE ~33 plies)
  +rem = U32.max(S.sub0(U32.add(63, U32.div(U32.mul(33, mat), 24)), U32.div(U32.mul(22, plies), 100)), 8)
  +lc = (U32.to_f32(rem) * lbar : F32)
  +remlo = U32.max(S.sub0(rem, 33), 4)
  +remhi = U32.add(rem, 33)
  +lclo = (U32.to_f32(remlo) * lbar : F32)
  +lchi = (U32.to_f32(remhi) * lbar : F32)
  (m, A.say("  A estimate (branching extrapolated from exact d" ++ U32.show(S.sub0(cd, 1)) ++ "-" ++ U32.show(cd) ++
    "): log10 perft(" ++ U32.show(d2) ++ ") ~ " ++ A.f1(e2) ++ " +/- " ++ A.f1(u2) ++ ", log10 perft(10) ~ " ++
    A.f1(e10) ++ " +/- " ++ A.f1(u10)) ++
    A.say("  C heuristic (NOT a count): expected remaining plies ~" ++ U32.show(rem) ++ " (" ++
    U32.show(remlo) ++ "-" ++ U32.show(remhi) ++ ", fitted model), mean log10 branching ~" ++ A.f1(lbar) ++
    " => log10 complete-game continuations ~" ++ A.f1(lc) ++ " (" ++ A.f1(lclo) ++ "-" ++ A.f1(lchi) ++ ")"))

def an.est.b(+cd: U32, +nk: U32, +n1: U32, +plies: U32, +mat: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +n2) = r
  an.est.c(cd, nk, n1, n2, plies, mat, m[an.cnt.slot(U32.sub(cd, 3))])

def an.est.a(+cd: U32, +nk: U32, +plies: U32, +mat: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +n1) = r
  an.est.b(cd, nk, n1, plies, mat, m[an.cnt.slot(U32.sub(cd, 2))])

def an.est.a0(+cd: U32, +plies: U32, +mat: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +nk) = r
  an.est.a(cd, nk, plies, mat, m[an.cnt.slot(U32.sub(cd, 1))])

def an.est(m: Array<U32>, +cd: U32, +plies: U32, +mat: U32) -> Array<U32> & String:
  an.est.a0(cd, plies, mat, m[an.cnt.slot(cd)])

# search phase: exact-score iterations 1..depth
def an.it.out?(+p: B.Pos, +o: S.Opt, +depth: U32, +chk: Bool, +d: U32, +n1: U32, +n0: U32, +s: U32,
               +nodes: U32, r: Array<U32> & String) -> IO(Array<U32>):
  (m, tab) = r
  +ebf = C.sel(U32.is_gt(n1, 0), U32.div(U32.mul(nodes, 10), U32.max(n1, 1)), 0)
  +pred = U32.mul(U32.div(nodes, 10), C.sel(U32.is_gt(ebf, 0), ebf, 30))
  +err = C.sel(U32.is_gt(n0, 0), U32.div(U32.mul(nodes, 100), U32.max(n0, 1)), 0)
  do IO<Array<U32>>:
    IO.print("info string depth " ++ U32.show(d) ++ ": best score " ++ C.s.show(s) ++ " | D nodes " ++
      U32.show(nodes) ++ " | EBF " ++ U32.show(U32.div(ebf, 10)) ++ "." ++ U32.show(U32.mod(ebf, 10)) ++
      " | predicted nodes for depth " ++ U32.show(U32.add(d, 1)) ++ ": " ++ U32.show(pred) ++
      " | last prediction: actual/predicted = " ++ U32.show(err) ++ "%")
    IO.write(tab)
    an.it(m, p, o, depth, chk, U32.add(d, 1), nodes, pred)

def an.it.res?(+p: B.Pos, +o: S.Opt, +depth: U32, +chk: Bool, +d: U32, +n1: U32, +n0: U32, +s: U32,
               r: Array<U32> & U32) -> IO(Array<U32>):
  (m, +left) = r
  +nodes = U32.sub(BIG(), left)
  an.it.out(p, o, depth, chk, d, n1, n0, s, nodes, A.table(m, C.sel(U32.is_eq(d, depth), 300, 6)))

def an.it.s?(+p: B.Pos, +o: S.Opt, +depth: U32, +chk: Bool, +d: U32, +n1: U32, +n0: U32, r: Array<U32> & U32) ->
  IO(Array<U32>):
  (m, +s) = r
  an.it.res(p, o, depth, chk, d, n1, n0, s, m[S.BUDGET()])

def an.it.go?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +depth: U32, +chk: Bool, +d: U32, +n1: U32, +n0: U32,
              go: Bool) -> IO(Array<U32>):
  match go:
    case False{}:
      IO.pure(Array<U32>, m)
    case True{}:
      an.it.s(p, o, depth, chk, d, n1, n0,
        R.iter.x(budget.set(m, BIG()), p, d, C.s.neg(C.INF()), C.INF(), o, chk, True{}))

def an.it?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +depth: U32, +chk: Bool, +d: U32, +n1: U32, +n0: U32) ->
  IO(Array<U32>):
  an.it.go(m, p, o, depth, chk, d, n1, n0, U32.is_le(d, depth))

def an.search.b?(+p: B.Pos, +o: S.Opt, +depth: U32, +chk: Bool, r: Array<U32> & U32) -> IO(Array<U32>):
  (m, +n) = r
  an.it(m, p, o, depth, chk, 1, 0, 0)

def an.cx.out.b?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, +chk: Bool, lines: String,
                 r: Array<U32> & String) -> IO(Array<U32>):
  (m, est) = r
  do IO<Array<U32>>:
    IO.write(lines)
    IO.write(est)
    IO.print("info string search (exact score for every root move, depth 1.." ++ U32.show(depth) ++ "):")
    an.search.b(p, o, depth, chk, R.setup(m, p, chk, o))

def an.cx.out?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, +chk: Bool, +plies: U32, +mat0: U32,
               r: Array<U32> & String) -> IO(Array<U32>):
  (m, lines) = r
  an.cx.out.b(p, o, depth, cd, chk, lines, an.est(m, cd, plies, U32.min(B.P.ph(p), 24)))

# the report
def an.r7?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, fen: String, +chk: Bool, wmat: String, bmat: String,
           cen: A.Cen, +nrep: U32, r: Array<U32> & U32) -> IO(Array<U32>):
  match cen:
    case A.Cen{+n, +caps, +chks, +proms}:
      (m, +ev) = r
      +half = B.P.half(p)
      +ph = B.P.ph(p)
      do IO<Array<U32>>:
        IO.print("info string === BendChess analysis ===")
        IO.print("info string position: " ++ fen)
        IO.print("info string game: side to move " ++ A.side.name(B.P.side(p)) ++ ", plies played since the FEN " ++
          U32.show(B.P.hidx(p)) ++ ", halfmove clock " ++ U32.show(half) ++ " (claimable 50-move draw at 100, automatic 75-move draw at 150)")
        IO.print("info string history: earlier occurrences of this position " ++ U32.show(nrep) ++
          " (threefold claim at 2), castling " ++ B.fen.castle.str(B.P.castle(p)) ++ ", en passant " ++
          B.fen.ep.str(B.P.ep(p)) ++ ", in check " ++ A.yesno(chk))
        IO.print("info string material: white " ++ wmat ++ "; black " ++ bmat ++ "; phase " ++ U32.show(U32.min(ph, 24)) ++
          "/24 (" ++ A.phase.name(ph) ++ ")")
        IO.print("info string moves: " ++ U32.show(n) ++ " legal (captures " ++ U32.show(caps) ++ ", checks " ++
          U32.show(chks) ++ ", promotions " ++ U32.show(proms) ++ ")")
        IO.print("info string eval: static " ++ C.s.show(ev) ++ " cp for the side to move (PeSTO part " ++
          C.s.show(E.pesto(p)) ++ ")")
        IO.print("info string complexity (exact up to d" ++ U32.show(cd) ++ "):")
        an.cx.out(p, o, depth, cd, chk, U32.add(B.P.hidx(p), 0), 0,
          an.lines(an.cx(m, p, 1, cd), 1, cd, ""))

def an.r6?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, fen: String, +chk: Bool, wmat: String, bmat: String,
           cen: A.Cen, r: Array<U32> & U32) -> IO(Array<U32>):
  (m, +nrep) = r
  an.r7(p, o, depth, cd, fen, chk, wmat, bmat, cen, nrep, E.eval(m, p, 0))

def an.r5?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, fen: String, +chk: Bool, wmat: String, bmat: String,
           r: Array<U32> & A.Cen) -> IO(Array<U32>):
  (m, cen) = r
  an.r6(p, o, depth, cd, fen, chk, wmat, bmat, cen,
    A.reps(m, B.P.hlo(p), B.P.hhi(p), B.P.hidx(p), 4, U32.min(B.P.half(p), B.P.hidx(p)), 0))

def an.r4?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, fen: String, +chk: Bool, wmat: String,
           r: Array<U32> & String) -> IO(Array<U32>):
  (m, bmat) = r
  an.r5(p, o, depth, cd, fen, chk, wmat, bmat, A.census(m, p, chk))

def an.r3?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, fen: String, +chk: Bool, r: Array<U32> & String) ->
  IO(Array<U32>):
  (m, wmat) = r
  an.r4(p, o, depth, cd, fen, chk, wmat, A.side.mat(m, 1))

def an.r2?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, fen: String, r: Array<U32> & Bool) -> IO(Array<U32>):
  (m, +chk) = r
  an.r3(p, o, depth, cd, fen, chk, A.side.mat(m, 0))

def an.r1?(+p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32, r: Array<U32> & String) -> IO(Array<U32>):
  (m, fen) = r
  an.r2(p, o, depth, cd, fen, G.in_check(A.counts(m, p), p))

def analyze(m: Array<U32>, +p: B.Pos, +o: S.Opt, +depth: U32, +cd: U32) -> IO(Array<U32>):
  an.r1(p, o, depth, U32.max(U32.min(cd, 6), 3), G.fen.out(S.prep(m), p))

def an.arg.b?(rest: List<&2, String>, +key: String, +d: U32, hit: Bool) -> U32:
  match hit:
    case True{}:
      B.str.u32(B.str.nth(rest, 0n, ""), d)
    case False{}:
      an.arg(rest, key, d)

# "analyze [depth D] [cdepth K]" tokens
def an.arg?(toks: List<&2, String>, +key: String, +d: U32) -> U32:
  match toks:
    case Nil{}:
      d
    case Con{+k, rest}:
      an.arg.b(rest, key, d, str.eq(k, key))

def uci.an?(+p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>, m: Array<U32>) -> IO(Unit):
  +ts = toks
  IO.bind(Array<U32>, Unit, analyze(m, p, o, an.arg(ts, "depth", 7), an.arg(ts, "cdepth", 3)),
    m2 => uci.loop(m2, p, o, buf, f))

def uci.d.b?(+p: B.Pos, +o: S.Opt, f: File, buf: String, fen: String, r: Array<U32> & U32) -> IO(Unit):
  (m, +ev) = r
  do IO<Unit>:
    IO.print("fen " ++ fen)
    IO.print("eval " ++ C.s.show(ev) ++ " (static, side to move, cp; PeSTO part " ++ C.s.show(E.pesto(p)) ++ ")")
    IO.print("state hash " ++ U32.show(B.P.hhi(p)) ++ ":" ++ U32.show(B.P.hlo(p)) ++ " mg " ++ C.s.show(B.P.mg(p)) ++
      " eg " ++ C.s.show(B.P.eg(p)) ++ " phase " ++ U32.show(B.P.ph(p)) ++ " pieces " ++ U32.show(B.npieces(p)) ++ " pawns " ++ U32.show(B.pawnsig(p)) ++
      " kings " ++ U32.show(B.P.wk(p)) ++ "," ++ U32.show(B.P.bk(p)))
    uci.loop(m, p, o, buf, f)

def uci.d?(+p: B.Pos, +o: S.Opt, f: File, buf: String, r: Array<U32> & String) -> IO(Unit):
  (m, fen) = r
  uci.d.b(p, o, f, buf, fen, E.eval(m, p, 0))

def mstr.put?(m: Array<U32>, +base: U32, s: String, +i: U32) -> Array<U32>:
  match s:
    case SNil{}:
      m[base] <- i
      m
    case SCon{c, rest}:
      m[U32.add(base, U32.add(1, U32.and(i, 1023)))] <- Char.to_u32(c)
      mstr.put(m, base, rest, U32.min(U32.add(i, 1), 1000))

def opt.mem.b(m: Array<U32>, vs: List<&2, String>, tb: Bool) -> Array<U32>:
  match tb:
    case True{}:
      mstr.put(m, TBPATH(), String.join(vs, " "), 0)
    case False{}:
      m

# setoption name SyzygyPath value <dir...>: kept in memory
def opt.mem(m: Array<U32>, toks: List<&2, String>) -> Array<U32>:
  match toks:
    case Con{_, Con{+name, Con{_, vs}}}:
      opt.mem.b(m, vs, str.eq(name, "SyzygyPath"))
    case _:
      m

def uci.setopt?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, +rest: List<&2, String>) -> IO(Unit):
  uci.loop(opt.mem(m, rest), p, opt.set(o, rest), buf, f)

def uci.see.b?(+p: B.Pos, +o: S.Opt, f: File, buf: String, +mv: U32, r: Array<U32> & U32) -> IO(Unit):
  (m, +v) = r
  do IO<Unit>:
    IO.print("see " ++ B.mv.uci(mv) ++ " " ++ C.s.show(v))
    uci.loop(m, p, o, buf, f)

def uci.see?(+p: B.Pos, +o: S.Opt, f: File, buf: String, r: Array<U32> & U32) -> IO(Unit):
  (m, +mv) = r
  uci.see.b(p, o, f, buf, mv, G.see(m, mv, B.P.side(p)))

def uci.cmd.b?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, rest: List<&2, String>,
               code: Nat) -> IO(Unit):
  match code:
    case 1n:
      IO.bind(Unit, Unit, uci.id(), u => uci.loop(m, p, o, buf, f))
    case 2n:
      IO.bind(Unit, Unit, IO.print("readyok"), u => uci.loop(m, p, o, buf, f))
    case 3n:
      uci.pos(o, f, buf, pos.cmd(m, rest))
    case 4n:
      uci.go(m, p, o, f, buf, rest)
    case 5n:
      File.close(f)
    case 6n:
      uci.setopt(m, p, o, f, buf, rest)
    case 7n:
      uci.loop(S.clear(m), p, o, buf, f)
    case 8n:
      uci.d(p, o, f, buf, G.fen.out(m, p))
    case 9n:
      uci.feat(p, o, f, buf, feats(m, p, 1, ""))
    case 10n:
      uci.an(p, o, f, buf, rest, m)
    case 11n:
      uci.see(p, o, f, buf, G.find_move(m, p, B.str.nth(rest, 0n, ""), 0))
    case _:
      uci.loop(m, p, o, buf, f)

# dispatch one command line
def uci.cmd?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>) -> IO(Unit):
  match toks:
    case Nil{}:
      uci.loop(m, p, o, buf, f)
    case Con{+c, rest}:
      uci.cmd.b(m, p, o, f, buf, rest, U32.to_nat(cmd.code(c)))

def uci.cmd.line?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, rest: String,
                  toks: List<&2, String>) -> IO(Unit):
  uci.cmd(m, p, o, f, rest, toks)

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

def go.out.c?(+o: S.Opt, f: File, buf: String, +conv: String, m: Array<U32>, +p: B.Pos, +best: U32, use: Bool) -> IO(Unit):
  match use:
    case True{}:
      do IO<Unit>:
        IO.print("info string syzygy: " ++ conv ++ " converts to a tablebase win (proven); search preferred " ++ B.mv.uci(best))
        IO.print("bestmove " ++ conv)
        uci.loop(m, p, o, buf, f)
    case False{}:
      do IO<Unit>:
        IO.print("bestmove " ++ B.mv.uci(best))
        uci.loop(m, p, o, buf, f)

# go: tablebase probe first (when SyzygyPath is set), then search
def go.out.b?(+o: S.Opt, f: File, buf: String, +conv: String, m: Array<U32>, +p: B.Pos, bs: U32 & U32) -> IO(Unit):
  (+best, +score) = bs
  go.out.c(o, f, buf, conv, m, p, best, Bool.not(String.is_empty(conv)) && C.s.lt(score, C.MATE_BOUND()))

def go.out?(+o: S.Opt, f: File, buf: String, +conv: String, r: Array<U32> & (U32 & U32), +p: B.Pos) -> IO(Unit):
  (m, bs) = r
  go.out.b(o, f, buf, conv, m, p, bs)

def uci.go.search?(m: Array<U32>, +p: B.Pos, +o: S.Opt, f: File, buf: String, toks: List<&2, String>, +conv: String) ->
  IO(Unit):
  IO.bind(Array<U32> & (U32 & U32), Unit,
    think(m, p, o, go.limits(go.parse(toks, Gp.empty()), B.P.side(p)), True{}),
    r => go.out(o, f, buf, conv, r, p))

def path.drop.b?(rest: String, slash: Bool) -> String:
  match slash:
    case True{}:
      rest
    case False{}:
      path.drop(rest)

def path.drop?(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, rest}:
      path.drop.b(rest, U32.is_eq(Char.to_u32(c), 47))

# the directory part of a path ("" when there is none)
def path.parent(s: String) -> String:
  String.reverse(path.drop(String.reverse(s)))

def helper.of.c(d: String, none: Bool) -> String:
  match none:
    case True{}:
      "tools/syzygy_probe.py"
    case False{}:
      d ++ "/tools/syzygy_probe.py"

def helper.of.b(+d: String) -> String:
  helper.of.c(d, String.is_empty(d))

# tools/syzygy_probe.py next to the binary's build/ directory
def helper.of(prog: String) -> String:
  helper.of.b(path.parent(path.parent(prog)))

def uci.start(prog: String, r: Array<U32> & B.Pos) -> IO(Unit):
  (m, +p) = r
  m = mstr.put(m, HELPER(), helper.of(prog), 0)
  m = mstr.put(m, TBPATH(), "", 0)
  IO.bind(File, Unit, IO.try(File, File.open("/dev/stdin", "r")),
    f => uci.loop(m, p, S.Opt.default(), "", f))

def uci.main.b(args: List<&1, String>) -> IO(Unit):
  match args:
    case Con{prog, _}:
      uci.start(prog, G.fen.parse(B.mem.new(), B.START_FEN()))
    case Nil{}:
      uci.start("", G.fen.parse(B.mem.new(), B.START_FEN()))

def uci.main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), uci.main.b)
