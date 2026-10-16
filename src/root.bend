# BendChess root search, move ranking and complexity-aware allocation.
#
# The root keeps a table of its legal moves (ROOT region of memory, 8
# words per move):
#   0 move           1 score (last completed search of this move)
#   2 nodes spent on the move in the last iteration
#   3 bound of the score: 3 exact, 1 upper (fail low), 2 lower (fail high)
#   4 replies: the opponent's legal move count after the move
#   5 flags: 1 capture, 2 check, 4 promotion
#   6 score of the previous iteration   7 fluctuation (|delta| averaged)
#
# Two measures per move (Module 4):
#   playing strength: the adversarial search score (exact for the best
#     move, an upper bound for the others under PVS);
#   search priority:  how much more computation on the move is worth,
#     estimated from its gap to the best score, its score fluctuation
#     across iterations (uncertainty) and its observed subtree cost.
#
# Complexity-aware search (CAS, option Complexity) levels:
#   0  baseline: every root move gets the full depth (PVS), no extras.
#   1  + budget adaptation (uci.bend): stop early when the decision is
#      settled, spend more when it is contested, and never start an
#      iteration whose predicted cost exceeds the remaining budget.
#   2  + root allocation: moves with low priority per predicted node get
#      reduced depth; a reduced move that beats alpha is always re-searched
#      at full depth, so no move is chosen on a reduced search.
#   3  + in-tree allocation: positions with very few replies (forced
#      lines: cheap to resolve, often decisive) are extended by one ply.
#
# Complexity is a cost signal only: it changes how deep moves are searched,
# never their scores, and the move played is the best-scored move of the
# deepest search.

import Base
import ./core.bend as C
import ./board.bend as B
import ./movegen.bend as G
import ./search.bend as S

def RN() -> U32:
  U32.add(B.SC(), 30)

def rslot(+i: U32, +k: U32) -> U32:
  U32.add(B.ROOT(), U32.add(U32.shln(i, 3n), k))

def rd(m: Array<U32>, +i: U32, +k: U32) -> Array<U32> & U32:
  m[rslot(i, k)]

def nlegal.go?(m: Array<U32>, +p: B.Pos, +base: U32, +i: U32, +n: U32, +cnt: U32, +chk: Bool, go: Bool) ->
  Array<U32> & U32:
  match go:
    case False{}:
      (m, cnt)
    case True{}:
      nlegal.mv(p, base, i, n, cnt, chk, m[U32.add(base, i)])

def nlegal?(m: Array<U32>, +p: B.Pos, +base: U32, +i: U32, +n: U32, +cnt: U32, +chk: Bool) ->
  Array<U32> & U32:
  nlegal.go(m, p, base, i, n, cnt, chk, U32.is_lt(i, n))

# Setup: legal moves, replies, flags, initial order by a quiescence score
# -----------------------------------------------------------------------

def nlegal.k?(+p: B.Pos, +base: U32, +i: U32, +n: U32, +cnt: U32, +chk: Bool, +mv: U32,
              +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +ill) = r
  nlegal(B.unmake(m, np, mv), p, base, U32.add(i, 1), n, U32.add(cnt, C.b2u(Bool.not(ill))), chk)

def nlegal.mk?(+p: B.Pos, +base: U32, +i: U32, +n: U32, +cnt: U32, +chk: Bool, +mv: U32,
               r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  nlegal.k(p, base, i, n, cnt, chk, mv, np, G.illegal(m, np, mv, chk))

def nlegal.mv?(+p: B.Pos, +base: U32, +i: U32, +n: U32, +cnt: U32, +chk: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +mvk) = r
  +mv = C.mv.bare(mvk)
  nlegal.mk(p, base, i, n, cnt, chk, mv, B.make(m, p, mv))

def nlegal.gen?(+p: B.Pos, +base: U32, +chk: Bool, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  nlegal(m, p, base, 0, n, 0, chk)

def nlegal.chk?(+p: B.Pos, +ply: U32, r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +chk) = r
  +base = S.ply_moves(ply)
  nlegal.gen(p, base, chk, G.gen(m, p, base, 0))

# number of legal moves in p (uses the move list of ply `ply`)
def legal_count?(m: Array<U32>, +p: B.Pos, +ply: U32) -> Array<U32> & U32:
  nlegal.chk(p, ply, G.in_check(m, p))

# root entry i := move mv with its static facts and a quiescence score
def setup.put?(+i: U32, +mv: U32, +np: B.Pos, +gc: Bool, +replies: U32, r: Array<U32> & U32) ->
  Array<U32>:
  (m, +q) = r
  +s = C.s.neg(q)
  +flags = U32.or(U32.or(C.b2u(U32.is_ne(B.P.cap(np), 0)), U32.shln(C.b2u(gc), 1n)),
    U32.shln(C.b2u(C.mv.is_promo(mv)), 2n))
  m[rslot(i, 0)] <- mv
  m[rslot(i, 1)] <- s
  m[rslot(i, 2)] <- 0
  m[rslot(i, 3)] <- 3
  m[rslot(i, 4)] <- replies
  m[rslot(i, 5)] <- flags
  m[rslot(i, 6)] <- s
  m[rslot(i, 7)] <- 0
  m

def setup.rep?(+i: U32, +mv: U32, +np: B.Pos, +gc: Bool, +o: S.Opt, r: Array<U32> & U32) -> Array<U32>:
  (m, +replies) = r
  m = setup.put(i, mv, np, gc, replies,
    S.qsearch(m, np, C.s.neg(C.INF()), C.INF(), 1, gc, o))
  m

def setup.gc?(+i: U32, +mv: U32, +np: B.Pos, +o: S.Opt, r: Array<U32> & Bool) -> Array<U32>:
  (m, +gc) = r
  setup.rep(i, mv, np, gc, o, legal_count(m, np, 1))

def setup.loop.go?(m: Array<U32>, +p: B.Pos, +base: U32, +j: U32, +n: U32, +cnt: U32, +chk: Bool,
                   +o: S.Opt, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, cnt)
    case True{}:
      setup.mv(p, base, j, n, cnt, chk, o, m[U32.add(base, j)])

def setup.loop?(m: Array<U32>, +p: B.Pos, +base: U32, +j: U32, +n: U32, +cnt: U32, +chk: Bool,
                +o: S.Opt) -> Array<U32> & U32:
  setup.loop.go(m, p, base, j, n, cnt, chk, o, U32.is_lt(j, n))

def setup.k?(+p: B.Pos, +base: U32, +j: U32, +n: U32, +cnt: U32, +chk: Bool, +o: S.Opt, +mv: U32,
             +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      setup.loop(B.unmake(m, np, mv), p, base, U32.add(j, 1), n, cnt, chk, o)
    case (m, False{}):
      m = setup.gc(cnt, mv, np, o, G.gchk(m, np, mv))
      setup.loop(B.unmake(m, np, mv), p, base, U32.add(j, 1), n, U32.add(cnt, 1), chk, o)

def setup.mk?(+p: B.Pos, +base: U32, +j: U32, +n: U32, +cnt: U32, +chk: Bool, +o: S.Opt, +mv: U32,
              r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  setup.k(p, base, j, n, cnt, chk, o, mv, np, G.illegal(m, np, mv, chk))

def setup.mv?(+p: B.Pos, +base: U32, +j: U32, +n: U32, +cnt: U32, +chk: Bool, +o: S.Opt,
              r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mvk) = r
  +mv = C.mv.bare(mvk)
  setup.mk(p, base, j, n, cnt, chk, o, mv, B.make(m, p, mv))

def swap8.go?(m: Array<U32>, +a: U32, +b: U32, +k: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      swap8.r(a, b, k, m[rslot(a, k)])

# swap root entries a and b
def swap8?(m: Array<U32>, +a: U32, +b: U32, +k: U32) -> Array<U32>:
  swap8.go(m, a, b, k, U32.is_lt(k, 8))

# Sorting the table (insertion sort on score, best first; stable)
# ----------------------------------------------------------------

def swap8.w?(+a: U32, +b: U32, +k: U32, +va: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +vb) = r
  m[rslot(a, k)] <- vb
  m[rslot(b, k)] <- va
  swap8(m, a, b, U32.add(k, 1))

def swap8.r?(+a: U32, +b: U32, +k: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +va) = r
  swap8.w(a, b, k, va, m[rslot(b, k)])

def sink.go?(m: Array<U32>, +j: U32, +sj: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      sink.b(j, sj, m[rslot(U32.sub(j, 1), 1)])

# move entry j (score sj) up while it beats its predecessor
def sink?(m: Array<U32>, +j: U32, +sj: U32) -> Array<U32>:
  sink.go(m, j, sj, U32.is_gt(j, 0))

def sink.c?(m: Array<U32>, +j: U32, +sj: U32, up: Bool) -> Array<U32>:
  match up:
    case False{}:
      m
    case True{}:
      sink(swap8(m, U32.sub(j, 1), j, 0), U32.sub(j, 1), sj)

def sink.b?(+j: U32, +sj: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +sp) = r
  sink.c(m, j, sj, C.s.gt(sj, sp))

def sort?(m: Array<U32>, +i: U32, +n: U32) -> Array<U32>:
  sort.go(m, i, n, U32.is_lt(i, n))

def sort.k?(+i: U32, +n: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +s) = r
  sort(sink(m, i, s), U32.add(i, 1), n)

def sort.go?(m: Array<U32>, +i: U32, +n: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      sort.k(i, n, m[rslot(i, 1)])

def setup.fin?(r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  m[RN()] <- n
  (sort(m, 1, n), n)

def setup.gen?(+p: B.Pos, +chk: Bool, +o: S.Opt, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  setup.fin(setup.loop(m, p, S.ply_moves(0), 0, n, 0, chk, o))

# build the root table for p; answers the number of legal moves. The
# quiescence searches run on a private node budget. The PV head is cleared
# so that a position without legal moves never reports a stale move.
def setup?(m: Array<U32>, +p: B.Pos, +chk: Bool, +o: S.Opt) -> Array<U32> & U32:
  m[S.BUDGET()] <- 4000000000
  m[S.STOP()] <- 0
  m[B.PVT()] <- 0
  m[B.PVLEN()] <- 0
  setup.gen(p, chk, o, G.gen(m, p, S.ply_moves(0), 0))

# Root iteration
# --------------

# Search priority of entry i (higher = more worth searching): from the gap
# to the best score, the fluctuation (uncertainty) and the subtree cost.
#   gap  = max(0, best - score - 2 * fluct)
#   prio = 1024 * 64 / (64 + gap)   (a soft "chance to become best")
#   voi  = prio * 1024 / (1 + nodes / mean_nodes)   (per predicted node)
def prio(+best: U32, +score: U32, +fluct: U32) -> U32:
  +gap0 = U32.sub(best, U32.add(score, U32.mul(fluct, 2)))
  +gap = C.sel(C.s.lt(gap0, 0), 0, U32.min(gap0, 100000))
  U32.div(65536, U32.add(64, gap))

def mean?(m: Array<U32>, +i: U32, +n: U32, +acc: U32) -> Array<U32> & U32:
  mean.go(m, i, n, acc, U32.is_lt(i, n))

# mean nodes per root move over the last iteration (for voi)
def mean.k?(+i: U32, +n: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  mean(m, U32.add(i, 1), n, U32.add(acc, U32.shrn(v, 4n)))

def mean.go?(m: Array<U32>, +i: U32, +n: U32, +acc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, U32.mul(U32.div(acc, U32.max(n, 1)), 16))
    case True{}:
      mean.k(i, n, acc, m[rslot(i, 2)])

def voi(+pr: U32, +nodes: U32, +mean: U32) -> U32:
  U32.div(U32.mul(pr, 1024), U32.add(1024, U32.div(U32.mul(nodes, 1024), U32.max(mean, 1))))

# CAS root reduction for the i-th move (i >= 1) at depth d, from its voi:
# the lowest-voi moves of a deep search lose one or two plies.
def cas.red(+cas: U32, +i: U32, +d: U32, +v: U32) -> U32:
  +on = U32.is_ge(cas, 2) && U32.is_ge(d, 4) && U32.is_ge(i, 3)
  C.sel(on, C.sel(U32.is_lt(v, 120), C.sel(U32.is_ge(d, 6), 2, 1), C.sel(U32.is_lt(v, 300), 1, 0)), 0)

# exact: search every root move with a full window (exact scores for all
# moves, i.e. MultiPV over the whole move list; used by `analyze`)
type Rt is Data:
  Rt{p: B.Pos, d: U32, beta: U32, n: U32, o: S.Opt, chk: Bool, best: U32, mean: U32, exact: Bool}

def Rt.p(+x: Rt) -> B.Pos:
  match x:
    case Rt{p, _, _, _, _, _, _, _, _}:
      p

def Rt.d(+x: Rt) -> U32:
  match x:
    case Rt{_, d, _, _, _, _, _, _, _}:
      d

def Rt.beta(+x: Rt) -> U32:
  match x:
    case Rt{_, _, beta, _, _, _, _, _, _}:
      beta

def Rt.n(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, n, _, _, _, _, _}:
      n

def Rt.o(+x: Rt) -> S.Opt:
  match x:
    case Rt{_, _, _, _, o, _, _, _, _}:
      o

def Rt.best(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, _, _, _, best, _, _}:
      best

def Rt.mean(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, _, _, _, _, mean, _}:
      mean

def rec.b?(+i: U32, +s: U32, +bound: U32, +spent: U32, +old: U32, r: Array<U32> & U32) ->
  Array<U32>:
  (m, +fl) = r
  +delta = C.s.abs(U32.sub(s, old))
  m[rslot(i, 6)] <- old
  m[rslot(i, 1)] <- s
  m[rslot(i, 3)] <- bound
  m[rslot(i, 2)] <- spent
  m[rslot(i, 7)] <- U32.div(U32.add(U32.mul(fl, 3), U32.min(delta, 2000)), 4)
  m

# record a finished move search: score s with bound, nodes spent
def rec?(+i: U32, +s: U32, +bound: U32, +spent: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +old) = r
  rec.b(i, s, bound, spent, old, m[rslot(i, 7)])

def it.unmk(+np: B.Pos, +mv: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +s) = r
  (B.unmake(m, np, mv), s)

def Rt.exact(+x: Rt) -> Bool:
  match x:
    case Rt{_, _, _, _, _, _, _, _, exact}:
      exact

def it.re1.b?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +np: B.Pos,
              +gc: Bool, +raw: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      it.re2(rt, i, alpha, bestsc, mv, b0, np, gc, (m, raw))
    case True{}:
      it.re2(rt, i, alpha, bestsc, mv, b0, np, gc,
        S.search(m, np, U32.sub(Rt.d(rt), 1), C.s.neg(U32.add(alpha, 1)), C.s.neg(alpha), 1, True{}, gc, Rt.o(rt)))

def it.re1?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +np: B.Pos, +gc: Bool,
            +red: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +raw) = r
  it.re1.b(m, rt, i, alpha, bestsc, mv, b0, np, gc, raw, U32.is_gt(red, 0) && C.s.gt(C.s.neg(raw), alpha))

def it.child?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +np: B.Pos,
              +gc: Bool, +red: U32, first: Bool) -> Array<U32> & U32:
  match first:
    case True{}:
      +wa = C.sel(Rt.exact(rt), C.s.neg(C.INF()), alpha)
      it.after(rt, i, alpha, bestsc, mv, b0, it.unmk(np, mv,
        S.search(m, np, U32.sub(Rt.d(rt), 1), C.s.neg(Rt.beta(rt)), C.s.neg(wa), 1, True{}, gc, Rt.o(rt))))
    case False{}:
      it.re1(rt, i, alpha, bestsc, mv, b0, np, gc, red,
        S.search(m, np, S.sub0(U32.sub(Rt.d(rt), 1), red), C.s.neg(U32.add(alpha, 1)), C.s.neg(alpha), 1,
          True{}, gc, Rt.o(rt)))

def it.gc?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +v: U32, +np: B.Pos,
           r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +gc) = r
  it.child(m, rt, i, alpha, bestsc, mv, b0, np, gc,
    cas.red(S.Opt.cas(Rt.o(rt)), i, Rt.d(rt), v), U32.is_zero(i) || Rt.exact(rt))

def it.mk?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +v: U32, r: Array<U32> & B.Pos) ->
  Array<U32> & U32:
  (m, +np) = r
  m[U32.add(B.PLYAUX(), 4)] <- S.mkey(B.P.mvd(np), C.mv.to(mv))
  it.gc(rt, i, alpha, bestsc, mv, b0, v, np, G.gchk(m, np, mv))

def it.f4?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +v: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +b0) = r
  it.mk(rt, i, alpha, bestsc, mv, b0, v, B.make(m, Rt.p(rt), mv))

# entry i's facts read: score, fluctuation, nodes -> its voi; then make
def it.f3?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +sc: U32, +fl: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +nodes) = r
  +v = voi(prio(Rt.best(rt), sc, fl), nodes, Rt.mean(rt))
  it.f4(rt, i, alpha, bestsc, mv, v, m[S.BUDGET()])

def it.f2?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +sc: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +fl) = r
  it.f3(rt, i, alpha, bestsc, mv, sc, fl, m[rslot(i, 2)])

def it.f1?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sc) = r
  it.f2(rt, i, alpha, bestsc, mv, sc, m[rslot(i, 7)])

def it.f0?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mv) = r
  it.f1(rt, i, alpha, bestsc, mv, m[rslot(i, 1)])

def Rt.chk(+x: Rt) -> Bool:
  match x:
    case Rt{_, _, _, _, _, chk, _, _, _}:
      chk

def it.loop.go?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, C.sel(U32.is_zero(Rt.n(rt)), C.sel(Rt.chk(rt), C.s.neg(C.MATE()), 0), bestsc))
    case True{}:
      it.f0(rt, i, alpha, bestsc, m[rslot(i, 0)])

def it.loop?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32) -> Array<U32> & U32:
  it.loop.go(m, rt, i, alpha, bestsc, U32.is_lt(i, Rt.n(rt)))

def it.next?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, bestsc)
    case False{}:
      it.loop(m, rt, i, alpha, bestsc)

def it.after.d?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +s: U32, r: Array<U32> & U32,
                +b0: U32) -> Array<U32> & U32:
  (m, +b1) = r
  +raise = C.s.gt(s, alpha)
  +bound = C.sel(Rt.exact(rt), 3, C.sel(raise, C.sel(C.s.ge(s, Rt.beta(rt)), 2, 3), 1))
  m = rec(i, s, bound, U32.sub(b0, b1), m[rslot(i, 1)])
  m = S.pv.upd.if(m, 0, mv, raise)
  it.next(m, rt, U32.add(i, 1), C.sel(raise, s, alpha), C.s.max(bestsc, s), C.s.ge(s, Rt.beta(rt)))

def it.after.c?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +s: U32) ->
  Array<U32> & U32:
  it.after.d(rt, i, alpha, bestsc, mv, s, m[S.BUDGET()], b0)

def it.after.b?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +s: U32,
                r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      (m, bestsc)
    case (m, False{}):
      it.after.c(m, rt, i, alpha, bestsc, mv, b0, s)

def it.after?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +raw) = r
  +s = C.s.neg(raw)
  it.after.b(rt, i, alpha, bestsc, mv, b0, s, S.stopped(m))

def it.re2.b?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +np: B.Pos,
              +gc: Bool, +raw: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      it.after(rt, i, alpha, bestsc, mv, b0, (B.unmake(m, np, mv), raw))
    case True{}:
      it.after(rt, i, alpha, bestsc, mv, b0, it.unmk(np, mv,
        S.search(m, np, U32.sub(Rt.d(rt), 1), C.s.neg(Rt.beta(rt)), C.s.neg(alpha), 1, True{}, gc, Rt.o(rt))))

# PVS for root move i: full window for the first, else null window at the
# (possibly CAS-reduced) depth, re-searched at full depth and full window
# when it beats alpha
def it.re2?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, +b0: U32, +np: B.Pos, +gc: Bool,
            r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +raw) = r
  +s = C.s.neg(raw)
  it.re2.b(m, rt, i, alpha, bestsc, mv, b0, np, gc, raw,
    C.s.gt(s, alpha) && C.s.lt(s, Rt.beta(rt)))

def iter.fin?(+n: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +s) = r
  eff.a(s, eff.sum(sort(m, 1, n), 0, n, 0))

def iter.c?(+p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool, +exact: Bool, +n: U32,
            +best: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mn) = r
  iter.fin(n, it.loop(m, Rt{p, d, beta, n, o, chk, best, mn, exact}, 0, alpha, C.s.neg(C.INF())))

def iter.b?(+p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool, +exact: Bool, +n: U32,
            r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +best) = r
  iter.c(p, d, alpha, beta, o, chk, exact, n, best, mean(m, 0, n, 0))

def iter.a?(+p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool, +exact: Bool,
            r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  iter.b(p, d, alpha, beta, o, chk, exact, n, m[rslot(0, 1)])

# one root iteration at depth d >= 1 in (alpha, beta); answers the best
# score (fail-soft). The table must have been set up for p.
def iter.x?(m: Array<U32>, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool,
            +exact: Bool) -> Array<U32> & U32:
  m[B.PVLEN()] <- 0
  iter.a(p, d, alpha, beta, o, chk, exact, m[RN()])

def iter?(m: Array<U32>, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool) ->
  Array<U32> & U32:
  iter.x(m, p, d, alpha, beta, o, chk, False{})

# share (percent) of the last iteration's root nodes spent on the best move
def EFFORT() -> U32:
  U32.add(B.SC(), 52)

def eff.sum?(m: Array<U32>, +i: U32, +n: U32, +acc: U32) -> Array<U32> & U32:
  eff.sum.go(m, i, n, acc, U32.is_lt(i, n))

def eff.sum.k?(+i: U32, +n: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  eff.sum(m, U32.add(i, 1), n, U32.add(acc, U32.shrn(v, 4n)))

def eff.sum.go?(m: Array<U32>, +i: U32, +n: U32, +acc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      eff.sum.k(i, n, acc, m[rslot(i, 2)])

def eff.b?(+s: U32, +tot: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +bn) = r
  m[EFFORT()] <- U32.min(U32.div(U32.mul(U32.min(U32.shrn(bn, 4n), 40000000), 100), U32.max(tot, 1)), 100)
  (m, s)

def eff.a?(+s: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +tot) = r
  eff.b(s, tot, m[rslot(0, 2)])
