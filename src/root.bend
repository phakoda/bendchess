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

def swap8.go?(m: Array<U32>, +a: U32, +b: U32, +k: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      swap8.r(a, b, k, m[rslot(a, k)])

# swap root entries a and b
def swap8?(m: Array<U32>, +a: U32, +b: U32, +k: U32) -> Array<U32>:
  swap8.go(m, a, b, k, U32.is_lt(k, 8))

def sink.c?(m: Array<U32>, +j: U32, +sj: U32, up: Bool) -> Array<U32>:
  match up:
    case False{}:
      m
    case True{}:
      sink(swap8(m, U32.sub(j, 1), j, 0), U32.sub(j, 1), sj)

def sink.b?(+j: U32, +sj: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +sp) = r
  sink.c(m, j, sj, C.s.gt(sj, sp))

def sink.go?(m: Array<U32>, +j: U32, +sj: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      sink.b(j, sj, m[rslot(U32.sub(j, 1), 1)])

# move entry j (score sj) up while it beats its predecessor
def sink?(m: Array<U32>, +j: U32, +sj: U32) -> Array<U32>:
  sink.go(m, j, sj, U32.is_gt(j, 0))

def sort.go?(m: Array<U32>, +i: U32, +n: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      sort.k(i, n, m[rslot(i, 1)])

def sort?(m: Array<U32>, +i: U32, +n: U32) -> Array<U32>:
  sort.go(m, i, n, U32.is_lt(i, n))

def sort.k?(+i: U32, +n: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +s) = r
  sort(sink(m, i, s), U32.add(i, 1), n)

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

def mean.go?(m: Array<U32>, +i: U32, +n: U32, +acc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, U32.mul(U32.div(acc, U32.max(n, 1)), 16))
    case True{}:
      mean.k(i, n, acc, m[rslot(i, 2)])

def mean?(m: Array<U32>, +i: U32, +n: U32, +acc: U32) -> Array<U32> & U32:
  mean.go(m, i, n, acc, U32.is_lt(i, n))

# mean nodes per root move over the last iteration (for voi)
def mean.k?(+i: U32, +n: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  mean(m, U32.add(i, 1), n, U32.add(acc, U32.shrn(v, 4n)))

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
  Rt{p: B.Pos, d: U32, beta: U32, n: U32, o: S.Opt, chk: Bool, best: U32, mean: U32, exact: Bool, nw: U32, k: U32}

def Rt.p(+x: Rt) -> B.Pos:
  match x:
    case Rt{p, _, _, _, _, _, _, _, _, _, _}:
      p

def Rt.d(+x: Rt) -> U32:
  match x:
    case Rt{_, d, _, _, _, _, _, _, _, _, _}:
      d

def Rt.beta(+x: Rt) -> U32:
  match x:
    case Rt{_, _, beta, _, _, _, _, _, _, _, _}:
      beta

def Rt.n(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, n, _, _, _, _, _, _, _}:
      n

def Rt.o(+x: Rt) -> S.Opt:
  match x:
    case Rt{_, _, _, _, o, _, _, _, _, _, _}:
      o

def Rt.best(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, _, _, _, best, _, _, _, _}:
      best

def Rt.mean(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, _, _, _, _, mean, _, _, _}:
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
    case Rt{_, _, _, _, _, _, _, _, exact, _, _}:
      exact

def Rt.nw(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, _, _, _, _, _, _, nw, _}:
      nw

def Rt.k(+x: Rt) -> U32:
  match x:
    case Rt{_, _, _, _, _, _, _, _, _, _, k}:
      k

# Parallel root split (Threads > 1)
# ---------------------------------
# Each worker owns a full engine memory (board, history, its own TT). In an
# iteration the main memory searches the first root move alone (it sets
# alpha); the remaining moves are dealt to the workers by a hash of the
# move (so a move goes to the same worker every iteration and finds its
# subtree in that worker's TT), searched with Bend's fork-join parallel
# calls, and the per-move results, node counts and the best PV are merged
# back into the main memory.

# the worker (0 .. nw-1) that searches root move mv
def mown(+mv: U32, +nw: U32) -> U32:
  U32.and(U32.shrn(U32.mul(mv, 2654435761), 20n), U32.sub(nw, 1))

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

def it.own?(m: Array<U32>, +rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, +mv: U32, mine: Bool) -> Array<U32> & U32:
  match mine:
    case True{}:
      it.f1(rt, i, alpha, bestsc, mv, m[rslot(i, 1)])
    case False{}:
      it.loop(m, rt, U32.add(i, 1), alpha, bestsc)

def it.f0?(+rt: Rt, +i: U32, +alpha: U32, +bestsc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mv) = r
  it.own(m, rt, i, alpha, bestsc, mv,
    U32.is_eq(Rt.nw(rt), 1) || U32.is_zero(i) || U32.is_eq(mown(mv, Rt.nw(rt)), Rt.k(rt)))

def Rt.chk(+x: Rt) -> Bool:
  match x:
    case Rt{_, _, _, _, _, chk, _, _, _, _, _}:
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

def eff.sum.go?(m: Array<U32>, +i: U32, +n: U32, +acc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      eff.sum.k(i, n, acc, m[rslot(i, 2)])

def eff.sum?(m: Array<U32>, +i: U32, +n: U32, +acc: U32) -> Array<U32> & U32:
  eff.sum.go(m, i, n, acc, U32.is_lt(i, n))

def eff.sum.k?(+i: U32, +n: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  eff.sum(m, U32.add(i, 1), n, U32.add(acc, U32.shrn(v, 4n)))

# share (percent) of the last iteration's root nodes spent on the best move
def EFFORT() -> U32:
  U32.add(B.SC(), 52)

def eff.b?(+s: U32, +tot: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +bn) = r
  m[EFFORT()] <- U32.min(U32.div(U32.mul(U32.min(U32.shrn(bn, 4n), 40000000), 100), U32.max(tot, 1)), 100)
  (m, s)

def eff.a?(+s: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +tot) = r
  eff.b(s, tot, m[rslot(0, 2)])

def iter.fin?(+n: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +s) = r
  eff.a(s, eff.sum(sort(m, 1, n), 0, n, 0))

def iter.c?(+p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool, +exact: Bool, +n: U32,
            +best: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mn) = r
  iter.fin(n, it.loop(m, Rt{p, d, beta, n, o, chk, best, mn, exact, 1, 0}, 0, alpha, C.s.neg(C.INF())))

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

type Ws is Type:
  Ws{a: Array<U32>, b: Array<U32>, c: Array<U32>}

def ws.mem(big: Bool) -> Array<U32>:
  match big:
    case True{}:
      [0 : U32^23n]
    case False{}:
      [0 : U32^1n]

# workers for th threads (1, 2 or 4; 3 counts as 2)
def Ws.new(+th: U32) -> Ws:
  Ws{ws.mem(U32.is_ge(th, 2)), ws.mem(U32.is_ge(th, 4)), ws.mem(U32.is_ge(th, 4))}

def nworkers(+th: U32) -> U32:
  C.sel(U32.is_ge(th, 4), 4, C.sel(U32.is_ge(th, 2), 2, 1))

# copy src[i .. end) to dst[i .. end)
def cp.go?(src: Array<U32>, dst: Array<U32>, +i: U32, +end: U32, go: Bool) -> Array<U32> & Array<U32>:
  match go:
    case False{}:
      (src, dst)
    case True{}:
      cp.k(dst, i, end, src[i])

def cp.k?(dst: Array<U32>, +i: U32, +end: U32, r: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (src, +v) = r
  dst[i] <- v
  cp.go(src, dst, U32.add(i, 1), end, U32.is_lt(U32.add(i, 1), end))

def cp?(src: Array<U32>, dst: Array<U32>, +i: U32, +end: U32) -> Array<U32> & Array<U32>:
  cp.go(src, dst, i, end, U32.is_lt(i, end))

# worker memory := the main memory's board, repetition history, root table
# and TT generation; its own budget share
def sync.d?(w: Array<U32>, +share: U32, r: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (m, +age) = r
  w[S.TTAGE()] <- age
  w[S.BUDGET()] <- share
  w[S.STOP()] <- 0
  w[S.SELD()] <- 0
  w[B.PVLEN()] <- 0
  (m, w)

def sync.c?(+share: U32, r: Array<U32> & Array<U32>) -> Array<U32> & Array<U32>:
  (m, w) = r
  sync.d(w, share, m[S.TTAGE()])

def sync.b?(+n: U32, +share: U32, r: Array<U32> & Array<U32>) -> Array<U32> & Array<U32>:
  (m, w) = r
  sync.c(share, cp(m, w, B.ROOT(), rslot(n, 0)))

def sync?(m: Array<U32>, w: Array<U32>, +n: U32, +share: U32, go: Bool) -> Array<U32> & Array<U32>:
  match go:
    case True{}:
      sync.b(n, share, cp(m, w, 0, 9216))
    case False{}:
      (m, w)

def mg.tab?(m: Array<U32>, w: Array<U32>, +k: U32, +nw: U32, +i: U32, +n: U32) -> Array<U32> & Array<U32>:
  mg.tab.go(m, w, k, nw, i, n, U32.is_lt(i, n))

def mg.tab.n?(+k: U32, +nw: U32, +i: U32, +n: U32, r: Array<U32> & Array<U32>) -> Array<U32> & Array<U32>:
  (w, m) = r
  mg.tab(m, w, k, nw, U32.add(i, 1), n)

def mg.tab.c?(m: Array<U32>, w: Array<U32>, +k: U32, +nw: U32, +i: U32, +n: U32, mine: Bool) ->
  Array<U32> & Array<U32>:
  match mine:
    case True{}:
      mg.tab.n(k, nw, i, n, cp(w, m, rslot(i, 0), rslot(i, 8)))
    case False{}:
      mg.tab(m, w, k, nw, U32.add(i, 1), n)

# merge: root-table entries of worker k back into the main memory
def mg.tab.k?(w: Array<U32>, +k: U32, +nw: U32, +i: U32, +n: U32, r: Array<U32> & U32) ->
  Array<U32> & Array<U32>:
  (m, +mv) = r
  mg.tab.c(m, w, k, nw, i, n, U32.is_eq(mown(mv, nw), k))

def mg.tab.go?(m: Array<U32>, w: Array<U32>, +k: U32, +nw: U32, +i: U32, +n: U32, go: Bool) ->
  Array<U32> & Array<U32>:
  match go:
    case False{}:
      (m, w)
    case True{}:
      mg.tab.k(w, k, nw, i, n, m[rslot(i, 0)])

# merge counters: nodes left (summed), stop flag and seldepth (max)
def mg.cnt.f?(w: Array<U32>, +wl: U32, +wst: U32, +wd: U32, +ml: U32, +ms: U32, r: Array<U32> & U32) ->
  Array<U32> & Array<U32>:
  (m, +md) = r
  m[S.BUDGET()] <- U32.add(ml, wl)
  m[S.STOP()] <- U32.or(ms, wst)
  m[S.SELD()] <- U32.max(md, wd)
  (m, w)

def mg.cnt.e?(w: Array<U32>, +wl: U32, +wst: U32, +wd: U32, +ml: U32, r: Array<U32> & U32) ->
  Array<U32> & Array<U32>:
  (m, +ms) = r
  mg.cnt.f(w, wl, wst, wd, ml, ms, m[S.SELD()])

def mg.cnt.d?(w: Array<U32>, +wl: U32, +wst: U32, +wd: U32, r: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (m, +ml) = r
  mg.cnt.e(w, wl, wst, wd, ml, m[S.STOP()])

def mg.cnt.c?(m: Array<U32>, +wl: U32, +wst: U32, r: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (w, +wd) = r
  mg.cnt.d(w, wl, wst, wd, m[S.BUDGET()])

def mg.cnt.b?(m: Array<U32>, +wl: U32, r: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (w, +wst) = r
  mg.cnt.c(m, wl, wst, w[S.SELD()])

def mg.cnt.a?(m: Array<U32>, r: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (w, +wl) = r
  mg.cnt.b(m, wl, w[S.STOP()])

# merge the PV when the worker found the best move so far
def mg.pv.b?(r: Array<U32> & Array<U32>) -> Array<U32> & Array<U32>:
  (w, m) = r
  (m, w)

def mg.pv?(m: Array<U32>, w: Array<U32>, better: Bool) -> Array<U32> & Array<U32>:
  match better:
    case True{}:
      mg.pv.b(cp(w, m, B.PVLEN(), U32.add(B.PVLEN(), 1)))
    case False{}:
      (m, w)

def mg.pv.c?(r: Array<U32> & Array<U32>) -> Array<U32> & Array<U32>:
  (m, w) = r
  mg.pv.b(cp(w, m, B.PVT(), U32.add(B.PVT(), 128)))

def mg.pvb?(m: Array<U32>, w: Array<U32>, better: Bool) -> Array<U32> & Array<U32>:
  match better:
    case True{}:
      mg.pv.c(mg.pv(m, w, True{}))
    case False{}:
      (m, w)

def mg.fin.b?(+sw: U32, +bs: U32, r: Array<U32> & Array<U32>) -> (Array<U32> & U32) & Array<U32>:
  (m, w) = r
  ((m, C.s.max(sw, bs)), w)

# merge worker k (result rw = its memory and fail-soft best) into m;
# bs = the best score so far; answers ((m, new best), worker memory)
def mg.fin?(+sw: U32, +bs: U32, +a1: U32, r: Array<U32> & Array<U32>) -> (Array<U32> & U32) & Array<U32>:
  (m, w) = r
  +better = C.s.gt(sw, bs) && C.s.gt(sw, a1)
  mg.fin.b(sw, bs, mg.pvb(m, w, better))

def mg.c?(+sw: U32, +bs: U32, +a1: U32, r: Array<U32> & Array<U32>) -> (Array<U32> & U32) & Array<U32>:
  (m, w) = r
  mg.fin(sw, bs, a1, mg.cnt.a(m, w[S.BUDGET()]))

def merge?(m: Array<U32>, rw: Array<U32> & U32, +k: U32, +nw: U32, +n: U32, +a1: U32, +bs: U32) ->
  (Array<U32> & U32) & Array<U32>:
  (w, +sw) = rw
  mg.c(sw, bs, a1, mg.tab(m, w, k, nw, 1, n))

def NEGINF() -> U32:
  C.s.neg(C.INF())

def wrt(+p: B.Pos, +d: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool, +best: U32, +mn: U32, +nw: U32,
        +k: U32) -> Rt:
  Rt{p, d, beta, n, o, chk, best, mn, False{}, nw, k}

def par2?(m: Array<U32>, a: Array<U32>, +rt0: Rt, +rt1: Rt, +a1: U32) -> (Array<U32> & U32) & (Array<U32> & U32):
  r0 r1 = it.loop(m, rt0, 1, a1, NEGINF()) it.loop(a, rt1, 1, a1, NEGINF())
  (r0, r1)

def par4?(m: Array<U32>, a: Array<U32>, b: Array<U32>, c: Array<U32>, +rt0: Rt, +rt1: Rt, +rt2: Rt, +rt3: Rt,
          +a1: U32) -> ((Array<U32> & U32) & (Array<U32> & U32)) & ((Array<U32> & U32) & (Array<U32> & U32)):
  x y = par2(m, a, rt0, rt1, a1) par2(b, c, rt2, rt3, a1)
  (x, y)

# answers of a parallel iteration: ((main memory, best score), workers)
def par.end?(+n: U32, b: Array<U32>, c: Array<U32>, r: (Array<U32> & U32) & Array<U32>) ->
  (Array<U32> & U32) & Ws:
  (ms, a) = r
  (iter.fin(n, ms), Ws{a, b, c})

def par.j2.b?(+n: U32, +a1: U32, b: Array<U32>, c: Array<U32>, r1: Array<U32> & U32, r0: Array<U32> & U32) ->
  (Array<U32> & U32) & Ws:
  (m, +sm) = r0
  par.end(n, b, c, merge(m, r1, 1, 2, n, a1, C.s.max(sm, a1)))

def par.j2?(+n: U32, +a1: U32, +s0: U32, b: Array<U32>, c: Array<U32>,
            rr: (Array<U32> & U32) & (Array<U32> & U32)) -> (Array<U32> & U32) & Ws:
  (r0, r1) = rr
  par.j2.b(n, C.s.max(a1, s0), b, c, r1, r0)

def par.j4.e?(+n: U32, a: Array<U32>, b: Array<U32>, r: (Array<U32> & U32) & Array<U32>) ->
  (Array<U32> & U32) & Ws:
  (ms, c) = r
  (iter.fin(n, ms), Ws{a, b, c})

def par.j4.d2?(+n: U32, +a1: U32, a: Array<U32>, b: Array<U32>, r3: Array<U32> & U32, ms: Array<U32> & U32) ->
  (Array<U32> & U32) & Ws:
  (m, +bs) = ms
  par.j4.e(n, a, b, merge(m, r3, 3, 4, n, a1, bs))

def par.j4.d?(+n: U32, +a1: U32, a: Array<U32>, r3: Array<U32> & U32, r: (Array<U32> & U32) & Array<U32>) ->
  (Array<U32> & U32) & Ws:
  (ms, b) = r
  par.j4.d2(n, a1, a, b, r3, ms)

def par.j4.c2?(+n: U32, +a1: U32, a: Array<U32>, r2: Array<U32> & U32, r3: Array<U32> & U32, ms: Array<U32> & U32) ->
  (Array<U32> & U32) & Ws:
  (m, +bs) = ms
  par.j4.d(n, a1, a, r3, merge(m, r2, 2, 4, n, a1, bs))

def par.j4.c?(+n: U32, +a1: U32, r2: Array<U32> & U32, r3: Array<U32> & U32, r: (Array<U32> & U32) & Array<U32>) ->
  (Array<U32> & U32) & Ws:
  (ms, a) = r
  par.j4.c2(n, a1, a, r2, r3, ms)

def par.j4.b?(+n: U32, +a1: U32, r1: Array<U32> & U32, r2: Array<U32> & U32, r3: Array<U32> & U32,
              r0: Array<U32> & U32) -> (Array<U32> & U32) & Ws:
  (m, +sm) = r0
  par.j4.c(n, a1, r2, r3, merge(m, r1, 1, 4, n, a1, C.s.max(sm, a1)))

def par.j4.y?(+n: U32, +a1: U32, r0: Array<U32> & U32, r1: Array<U32> & U32, y: (Array<U32> & U32) & (Array<U32> & U32)) ->
  (Array<U32> & U32) & Ws:
  (r2, r3) = y
  par.j4.b(n, a1, r1, r2, r3, r0)

def par.j4.a?(+n: U32, +a1: U32, x: (Array<U32> & U32) & (Array<U32> & U32), y: (Array<U32> & U32) & (Array<U32> & U32)) ->
  (Array<U32> & U32) & Ws:
  (r0, r1) = x
  par.j4.y(n, a1, r0, r1, y)

def par.j4?(+n: U32, +a1: U32, rr: ((Array<U32> & U32) & (Array<U32> & U32)) & ((Array<U32> & U32) & (Array<U32> & U32))) ->
  (Array<U32> & U32) & Ws:
  (x, y) = rr
  par.j4.a(n, a1, x, y)

def par.run?(m: Array<U32>, a: Array<U32>, b: Array<U32>, c: Array<U32>, +p: B.Pos, +d: U32, +beta: U32, +n: U32,
             +o: S.Opt, +chk: Bool, +best: U32, +mn: U32, +a1: U32, +s0: U32, four: Bool) -> (Array<U32> & U32) & Ws:
  match four:
    case False{}:
      par.j2(n, a1, s0, b, c, par2(m, a, wrt(p, d, beta, n, o, chk, best, mn, 2, 0),
        wrt(p, d, beta, n, o, chk, best, mn, 2, 1), a1))
    case True{}:
      par.j4(n, a1, par4(m, a, b, c, wrt(p, d, beta, n, o, chk, best, mn, 4, 0), wrt(p, d, beta, n, o, chk, best, mn, 4, 1),
        wrt(p, d, beta, n, o, chk, best, mn, 4, 2), wrt(p, d, beta, n, o, chk, best, mn, 4, 3), a1))

def par.s3?(a: Array<U32>, b: Array<U32>, +p: B.Pos, +d: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
            +best: U32, +mn: U32, +a1: U32, +s0: U32, +share: U32, +four: Bool, r: Array<U32> & Array<U32>) ->
  (Array<U32> & U32) & Ws:
  (m, c) = r
  m[S.BUDGET()] <- share
  par.run(m, a, b, c, p, d, beta, n, o, chk, best, mn, a1, s0, four)

def par.s2?(a: Array<U32>, c: Array<U32>, +p: B.Pos, +d: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
            +best: U32, +mn: U32, +a1: U32, +s0: U32, +share: U32, +four: Bool, r: Array<U32> & Array<U32>) ->
  (Array<U32> & U32) & Ws:
  (m, b) = r
  par.s3(a, b, p, d, beta, n, o, chk, best, mn, a1, s0, share, four, sync(m, c, n, share, four))

def par.s1?(b: Array<U32>, c: Array<U32>, +p: B.Pos, +d: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
            +best: U32, +mn: U32, +a1: U32, +s0: U32, +share: U32, +four: Bool, r: Array<U32> & Array<U32>) ->
  (Array<U32> & U32) & Ws:
  (m, a) = r
  par.s2(a, c, p, d, beta, n, o, chk, best, mn, a1, s0, share, four, sync(m, b, n, share, four))

# the first move is searched: s0 its score, the rest is split
def par.h2?(m: Array<U32>, ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
            +best: U32, +mn: U32, +nw: U32, +s0: U32, +left: U32) -> (Array<U32> & U32) & Ws:
  match ws:
    case Ws{a, b, c}:
      +share = U32.div(left, nw)
      +four = U32.is_eq(nw, 4)
      par.s1(b, c, p, d, beta, n, o, chk, best, mn, C.s.max(alpha, s0), s0, share, four, sync(m, a, n, share, True{}))

def par.h?(ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
           +best: U32, +mn: U32, +nw: U32, +s0: U32, r: Array<U32> & U32) -> (Array<U32> & U32) & Ws:
  (m, +left) = r
  par.h2(m, ws, p, d, alpha, beta, n, o, chk, best, mn, nw, s0, left)

def par.g?(m: Array<U32>, ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
           +best: U32, +mn: U32, +nw: U32, +s0: U32, done: Bool) -> (Array<U32> & U32) & Ws:
  match done:
    case True{}:
      (iter.fin(n, (m, s0)), ws)
    case False{}:
      par.h(ws, p, d, alpha, beta, n, o, chk, best, mn, nw, s0, m[S.BUDGET()])

def par.f?(ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
           +best: U32, +mn: U32, +nw: U32, +s0: U32, r: Array<U32> & U32) -> (Array<U32> & U32) & Ws:
  (m, +st) = r
  par.g(m, ws, p, d, alpha, beta, n, o, chk, best, mn, nw, s0, U32.is_ne(st, 0) || C.s.ge(s0, beta))

def par.e?(ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
           +best: U32, +mn: U32, +nw: U32, r: Array<U32> & U32) -> (Array<U32> & U32) & Ws:
  (m, +s0) = r
  par.f(ws, p, d, alpha, beta, n, o, chk, best, mn, nw, s0, m[S.STOP()])

def par.d?(m: Array<U32>, ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +n: U32, +o: S.Opt, +chk: Bool,
           +best: U32, +mn: U32, +nw: U32, go: Bool) -> (Array<U32> & U32) & Ws:
  match go:
    case False{}:
      (iter.fin(n, it.loop(m, wrt(p, d, beta, n, o, chk, best, mn, 1, 0), 0, alpha, NEGINF())), ws)
    case True{}:
      par.e(ws, p, d, alpha, beta, n, o, chk, best, mn, nw,
        it.loop(m, wrt(p, d, beta, 1, o, chk, best, mn, 1, 0), 0, alpha, NEGINF()))

def par.c?(ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool, +n: U32, +best: U32,
           r: Array<U32> & U32) -> (Array<U32> & U32) & Ws:
  (m, +mn) = r
  +nw = nworkers(S.Opt.th(o))
  par.d(m, ws, p, d, alpha, beta, n, o, chk, best, mn, nw, U32.is_gt(nw, 1) && U32.is_gt(n, 2) && U32.is_ge(d, 5))

def par.b?(ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool, +n: U32,
           r: Array<U32> & U32) -> (Array<U32> & U32) & Ws:
  (m, +best) = r
  par.c(ws, p, d, alpha, beta, o, chk, n, best, mean(m, 0, n, 0))

def par.a?(ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool, r: Array<U32> & U32) ->
  (Array<U32> & U32) & Ws:
  (m, +n) = r
  par.b(ws, p, d, alpha, beta, o, chk, n, m[rslot(0, 1)])

# one root iteration, parallel when Threads > 1 (see above)
def iter.par?(m: Array<U32>, ws: Ws, +p: B.Pos, +d: U32, +alpha: U32, +beta: U32, +o: S.Opt, +chk: Bool) ->
  (Array<U32> & U32) & Ws:
  m[B.PVLEN()] <- 0
  par.a(ws, p, d, alpha, beta, o, chk, m[RN()])

# Practical difficulty (Module 8; option Practical = margin P in cp)
# ------------------------------------------------------------------
# After the search, the best move and up to three runners-up (root table
# order) are compared. A runner-up qualifies only if a verification search
# at depth d - 3 proves it scores >= best - P. For each qualifying move the
# opponent's legal replies are scored by quiescence; the difficulty is the
# share of replies that lose >= 100 cp against the opponent's best reply
# (how easy it is to go wrong). The move maximizing
# value + P * difficulty is played. Off (P = 0) by default: it trades
# a bounded amount of objective score for practical chances against
# fallible opponents and is not expected to gain against engines.
def PRV() -> U32:
  U32.add(B.SC(), 2200)

def dif.q?(+np: B.Pos, +base: U32, +i: U32, +n: U32, +k: U32, +mn: U32, +o: S.Opt, +ck: Bool, +rv: U32,
           +np2: B.Pos, r: Array<U32> & Bool) -> Array<U32> & (U32 & U32):
  (m, +c2) = r
  dif.v(np, base, i, n, k, mn, o, ck, rv, np2, S.qsearch(m, np2, NEGINF(), C.INF(), 2, c2, o))

def dif.il?(+np: B.Pos, +base: U32, +i: U32, +n: U32, +k: U32, +mn: U32, +o: S.Opt, +ck: Bool, +rv: U32,
            +np2: B.Pos, r: Array<U32> & Bool) -> Array<U32> & (U32 & U32):
  match r:
    case (m, True{}):
      dif.loop(B.unmake(m, np2, rv), np, base, U32.add(i, 1), n, k, mn, o, ck)
    case (m, False{}):
      dif.q(np, base, i, n, k, mn, o, ck, rv, np2, G.gchk(m, np2, rv))

def dif.mk?(+np: B.Pos, +base: U32, +i: U32, +n: U32, +k: U32, +mn: U32, +o: S.Opt, +ck: Bool, +rv: U32,
            r: Array<U32> & B.Pos) -> Array<U32> & (U32 & U32):
  (m, +np2) = r
  dif.il(np, base, i, n, k, mn, o, ck, rv, np2, G.illegal(m, np2, rv, ck))

def dif.mv?(+np: B.Pos, +base: U32, +i: U32, +n: U32, +k: U32, +mn: U32, +o: S.Opt, +ck: Bool,
            r: Array<U32> & U32) -> Array<U32> & (U32 & U32):
  (m, +rv0) = r
  +rv = C.mv.bare(rv0)
  dif.mk(np, base, i, n, k, mn, o, ck, rv, B.make(m, np, rv))

def dif.go?(m: Array<U32>, +np: B.Pos, +base: U32, +i: U32, +n: U32, +k: U32, +mn: U32, +o: S.Opt,
            +ck: Bool, go: Bool) -> Array<U32> & (U32 & U32):
  match go:
    case False{}:
      (m, (k, mn))
    case True{}:
      dif.mv(np, base, i, n, k, mn, o, ck, m[U32.add(base, i)])

# replies of the opponent at np: (legal count, our best-case minimum) and
# their quiescence values (our point of view) at PRV
def dif.loop?(m: Array<U32>, +np: B.Pos, +base: U32, +i: U32, +n: U32, +k: U32, +mn: U32, +o: S.Opt,
              +ck: Bool) -> Array<U32> & (U32 & U32):
  dif.go(m, np, base, i, n, k, mn, o, ck, U32.is_lt(i, n))

def dif.v?(+np: B.Pos, +base: U32, +i: U32, +n: U32, +k: U32, +mn: U32, +o: S.Opt, +ck: Bool, +rv: U32,
           +np2: B.Pos, r: Array<U32> & U32) -> Array<U32> & (U32 & U32):
  (m, +v) = r
  m[U32.add(PRV(), U32.min(k, 255))] <- v
  dif.loop(B.unmake(m, np2, rv), np, base, U32.add(i, 1), n, U32.add(k, 1), C.s.min(mn, v), o, ck)

def dif.cnt.k?(+j: U32, +k: U32, +thr: U32, +acc: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  dif.cnt(m, U32.add(j, 1), k, thr, U32.add(acc, C.b2u(C.s.ge(v, thr))))

def dif.cnt.go?(m: Array<U32>, +j: U32, +k: U32, +thr: U32, +acc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, U32.div(U32.mul(acc, 100), U32.max(k, 1)))
    case True{}:
      dif.cnt.k(j, k, thr, acc, m[U32.add(PRV(), j)])

def dif.cnt?(m: Array<U32>, +j: U32, +k: U32, +thr: U32, +acc: U32) -> Array<U32> & U32:
  dif.cnt.go(m, j, k, thr, acc, U32.is_lt(j, U32.min(k, 256)))

def dif.res.b?(m: Array<U32>, kn: U32 & U32) -> Array<U32> & U32:
  (+k, +mn) = kn
  dif.cnt(m, 0, k, U32.add(mn, 100), 0)

def dif.res?(r: Array<U32> & (U32 & U32)) -> Array<U32> & U32:
  (m, kn) = r
  dif.res.b(m, kn)

def dif.gen?(+np: B.Pos, +o: S.Opt, +ck: Bool, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  dif.res(dif.loop(m, np, S.ply_moves(1), 0, n, 0, C.INF(), o, ck))

# difficulty (0..100) for the opponent to move at np (ck: in check)
def difficulty?(m: Array<U32>, +np: B.Pos, +o: S.Opt, +ck: Bool) -> Array<U32> & U32:
  dif.gen(np, o, ck, G.gen(m, np, S.ply_moves(1), 0))

def pr.acc?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32, +mv: U32,
            +np: B.Pos, +gc: Bool, +v: U32, +bmv: U32, +bu: U32, ok: Bool) -> Array<U32> & U32:
  match ok:
    case False{}:
      pr.loop(B.unmake(m, np, mv), p, o, vd, score, best, U32.add(i, 1), n, bmv, bu)
    case True{}:
      pr.pick(p, o, vd, score, best, i, n, mv, np, v, bmv, bu, difficulty(m, np, o, gc))

def pr.ok?(+p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32, +mv: U32, +np: B.Pos,
           +gc: Bool, +bmv: U32, +bu: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +raw) = r
  +v = C.s.neg(raw)
  pr.acc(m, p, o, vd, score, best, i, n, mv, np, gc, v, bmv, bu,
    C.s.ge(v, U32.sub(score, S.Opt.pr(o))))

def pr.vb?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32, +mv: U32,
           +np: B.Pos, +gc: Bool, +bmv: U32, +bu: U32, isbest: Bool) -> Array<U32> & U32:
  match isbest:
    case True{}:
      pr.ok(p, o, vd, score, best, i, n, mv, np, gc, bmv, bu, (m, C.s.neg(score)))
    case False{}:
      +thr = U32.sub(score, S.Opt.pr(o))
      pr.ok(p, o, vd, score, best, i, n, mv, np, gc, bmv, bu,
        S.search(m, np, vd, C.s.neg(thr), C.s.neg(U32.sub(thr, 1)), 1, True{}, gc, o))

def pr.gc?(+p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32, +mv: U32, +np: B.Pos,
           +bmv: U32, +bu: U32, r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +gc) = r
  pr.vb(m, p, o, vd, score, best, i, n, mv, np, gc, bmv, bu, U32.is_eq(mv, best))

def pr.mk?(+p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32, +mv: U32, +bmv: U32,
           +bu: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  pr.gc(p, o, vd, score, best, i, n, mv, np, bmv, bu, G.gchk(m, np, mv))

def pr.c?(+p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32, +bmv: U32, +bu: U32,
          r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mv) = r
  pr.mk(p, o, vd, score, best, i, n, mv, bmv, bu, B.make(m, p, mv))

def pr.go?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32,
           +bmv: U32, +bu: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, bmv)
    case True{}:
      pr.c(p, o, vd, score, best, i, n, bmv, bu, m[rslot(i, 0)])

def pr.loop?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32,
             +bmv: U32, +bu: U32) -> Array<U32> & U32:
  pr.go(m, p, o, vd, score, best, i, n, bmv, bu, U32.is_lt(i, U32.min(n, 4)))

def pr.pick?(+p: B.Pos, +o: S.Opt, +vd: U32, +score: U32, +best: U32, +i: U32, +n: U32, +mv: U32, +np: B.Pos,
             +v: U32, +bmv: U32, +bu: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +df) = r
  +u = U32.add(C.s.min(v, score), U32.div(U32.mul(S.Opt.pr(o), df), 100))
  +better = C.s.gt(u, bu)
  pr.loop(B.unmake(m, np, mv), p, o, vd, score, best, U32.add(i, 1), n, C.sel(better, mv, bmv), C.sel(better, u, bu))

def pr.start?(+p: B.Pos, +o: S.Opt, +d: U32, +best: U32, +score: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  m[S.BUDGET()] <- 4000000000
  m[S.STOP()] <- 0
  pr.loop(m, p, o, U32.max(S.sub0(d, 3), 1), score, best, 0, n, best, NEGINF())

def practical.b?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +d: U32, +best: U32, +score: U32, go: Bool) ->
  Array<U32> & U32:
  match go:
    case False{}:
      (m, best)
    case True{}:
      pr.start(p, o, d, best, score, m[RN()])

# the move to play: best, or a practical alternative (see above)
def practical?(m: Array<U32>, +p: B.Pos, +o: S.Opt, +d: U32, +best: U32, +score: U32) -> Array<U32> & U32:
  practical.b(m, p, o, d, best, score,
    U32.is_gt(S.Opt.pr(o), 0) && U32.is_ne(best, 0) && C.s.lt(C.s.abs(score), 300) && U32.is_ge(d, 4))
