# BendChess search: negamax alpha-beta with principal variation search,
# quiescence search, transposition table, null-move pruning, reverse
# futility, futility / late-move pruning, late-move reductions, killer and
# history heuristics, check extension and mate-distance pruning.
#
# Every function threads the memory m (board + tables, see board.bend).
# The node budget lives in m[BUDGET]: each node decrements it; at zero the
# search sets STOP and every node returns at once. Scores computed after a
# stop are junk: they are never stored in the TT, never written to the PV,
# and the root driver ignores them.
#
# Safe vs speculative pruning: alpha-beta, PVS, mate-distance pruning and
# TT cutoffs at sufficient depth are exact (they never change the minimax
# value of the searched tree). Null move, reverse futility, futility,
# late-move pruning and LMR are speculative (they can miss moves); each is
# switchable through Opt so its effect can be measured.

import Base
import ./core.bend as C
import ./board.bend as B
import ./movegen.bend as G
import ./eval.bend as E

# Scalar slots
# ------------

def BUDGET() -> U32:
  B.SC()

def STOP() -> U32:
  U32.add(B.SC(), 1)

def SELD() -> U32:
  U32.add(B.SC(), 3)

# Options
# -------
# null: null-move pruning; lmr: late-move reductions; prune: reverse
# futility, futility and late-move pruning; cas: the experimental
# complexity-aware reductions (see search.cas below).
# nt: NodesTime, nodes per virtual millisecond (0: real clock)
# ss: SoftScale, percent applied to the baseline's soft time limit
type Opt is Data:
  Opt{null: Bool, lmr: Bool, prune: Bool, cas: U32, evm: U32, nt: U32, ss: U32}

def Opt.null(+o: Opt) -> Bool:
  match o:
    case Opt{null, _, _, _, _, _, _}:
      null

def Opt.lmr(+o: Opt) -> Bool:
  match o:
    case Opt{_, lmr, _, _, _, _, _}:
      lmr

def Opt.prune(+o: Opt) -> Bool:
  match o:
    case Opt{_, _, prune, _, _, _, _}:
      prune

def Opt.cas(+o: Opt) -> U32:
  match o:
    case Opt{_, _, _, cas, _, _, _}:
      cas

def Opt.evm(+o: Opt) -> U32:
  match o:
    case Opt{_, _, _, _, evm, _, _}:
      evm

def Opt.nt(+o: Opt) -> U32:
  match o:
    case Opt{_, _, _, _, _, nt, _}:
      nt

def Opt.default() -> Opt:
  Opt{True{}, True{}, True{}, 1, 1, 0, 100}

# Small helpers
# -------------

# saturating a - b
def sub0(+a: U32, +b: U32) -> U32:
  C.sel(U32.is_gt(a, b), U32.sub(a, b), 0)

def ply_moves(+ply: U32) -> U32:
  U32.add(B.MOVES(), U32.shln(ply, 8n))

# centipawn value of a piece type, for delta pruning
def pval(t: Nat) -> U32:
  match t:
    case 1n:
      100
    case 2n:
      320
    case 3n:
      330
    case 4n:
      500
    case 5n:
      900
    case _:
      0

# node accounting: answers True when the budget is exhausted
def tick.c(m: Array<U32>, +b: U32, out: Bool) -> Array<U32> & Bool:
  match out:
    case True{}:
      m[STOP()] <- 1
      (m, True{})
    case False{}:
      m[BUDGET()] <- U32.sub(b, 1)
      (m, False{})

def tick.b(r: Array<U32> & U32) -> Array<U32> & Bool:
  (m, +b) = r
  tick.c(m, b, U32.is_zero(b))

def tick(m: Array<U32>) -> Array<U32> & Bool:
  tick.b(m[BUDGET()])

def stopped.b(r: Array<U32> & U32) -> Array<U32> & Bool:
  (m, +s) = r
  (m, U32.is_ne(s, 0))

def stopped(m: Array<U32>) -> Array<U32> & Bool:
  stopped.b(m[STOP()])

def rep.slot(+hidx: U32, +k: U32) -> U32:
  U32.add(B.HISTH(), U32.shln(U32.and(U32.sub(hidx, k), 4095), 1n))

def rep.go?(m: Array<U32>, +hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, go: Bool) ->
  Array<U32> & Bool:
  match go:
    case False{}:
      (m, False{})
    case True{}:
      rep.a(hlo, hhi, hidx, k, lim, m[rep.slot(hidx, k)])

def rep?(m: Array<U32>, +hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32) ->
  Array<U32> & Bool:
  rep.go(m, hlo, hhi, hidx, k, lim, U32.is_le(k, lim))

# Draw detection
# --------------
# Fifty-move rule (halfmove clock >= 100) and repetition: the current hash
# equal to one 4, 6, ... plies back within the reversible stretch. A single
# repetition counts as a draw inside the search (standard practice: if the
# position can repeat once it can repeat again).

def rep.d?(m: Array<U32>, +hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, eq: Bool) ->
  Array<U32> & Bool:
  match eq:
    case True{}:
      (m, True{})
    case False{}:
      rep(m, hlo, hhi, hidx, U32.add(k, 2), lim)

def rep.c?(+hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, r: Array<U32> & U32) ->
  Array<U32> & Bool:
  (m, +hi) = r
  rep.d(m, hlo, hhi, hidx, k, lim, U32.is_eq(hi, hhi))

def rep.b?(m: Array<U32>, +hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, eq: Bool) ->
  Array<U32> & Bool:
  match eq:
    case True{}:
      rep.c(hlo, hhi, hidx, k, lim, m[U32.add(rep.slot(hidx, k), 1)])
    case False{}:
      rep(m, hlo, hhi, hidx, U32.add(k, 2), lim)

def rep.a?(+hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, r: Array<U32> & U32) ->
  Array<U32> & Bool:
  (m, +lo) = r
  rep.b(m, hlo, hhi, hidx, k, lim, U32.is_eq(lo, hlo))

def draw.rep(fifty: Bool, m: Array<U32>, +p: B.Pos) -> Array<U32> & Bool:
  match fifty:
    case True{}:
      (m, True{})
    case False{}:
      rep(m, B.P.hlo(p), B.P.hhi(p), B.P.hidx(p), 4, U32.min(B.P.half(p), B.P.hidx(p)))

def draw.go(m: Array<U32>, +p: B.Pos, check: Bool) -> Array<U32> & Bool:
  match check:
    case False{}:
      (m, False{})
    case True{}:
      draw.rep(U32.is_ge(B.P.half(p), 100) || B.dead(p), m, p)

# is position p (at search ply `ply`) a draw by rule? Never at the root.
def draw(m: Array<U32>, +p: B.Pos, +ply: U32) -> Array<U32> & Bool:
  draw.go(m, p, U32.is_gt(ply, 0))

# Transposition table
# -------------------
# Entry (4 words) at TT + (hlo & mask) * 4: lock (hhi), data
# (move | bound << 17 | depth << 19), score (mate scores ply-adjusted),
# unused. Bounds: 1 upper, 2 lower, 3 exact.

def tt.idx(+hlo: U32) -> U32:
  U32.add(B.TT(), U32.shln(U32.and(hlo, B.TT_MASK()), 2n))

def tt.to(+s: U32, +ply: U32) -> U32:
  C.sel(C.s.ge(s, C.MATE_BOUND()), U32.add(s, ply),
    C.sel(C.s.le(s, C.s.neg(C.MATE_BOUND())), U32.sub(s, ply), s))

def tt.from(+s: U32, +ply: U32) -> U32:
  C.sel(C.s.ge(s, C.MATE_BOUND()), U32.sub(s, ply),
    C.sel(C.s.le(s, C.s.neg(C.MATE_BOUND())), U32.add(s, ply), s))

def tt.store.c(m: Array<U32>, +p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32,
               +mv: U32, ok: Bool) -> Array<U32>:
  match ok:
    case False{}:
      m
    case True{}:
      +i = tt.idx(B.P.hlo(p))
      m[i] <- B.P.hhi(p)
      m[U32.add(i, 1)] <- U32.or(U32.or(C.mv.bare(mv), U32.shln(bound, 17n)), U32.shln(U32.min(depth, 255), 19n))
      m[U32.add(i, 2)] <- tt.to(score, ply)
      m

def tt.store.b(+p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32, +mv: U32,
               r: Array<U32> & U32) -> Array<U32>:
  (m, +st) = r
  tt.store.c(m, p, ply, depth, bound, score, mv, U32.is_zero(st))

def tt.store(m: Array<U32>, +p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32,
             +mv: U32) -> Array<U32>:
  tt.store.b(p, ply, depth, bound, score, mv, m[STOP()])

# Move ordering
# -------------
# The key goes in bits 17..31 of each move-list word, so picking the
# largest word picks the best-ordered move.
#   TT move 32767; queen promotion 30000+; captures 20000 + 100*victim
#   - attacker (MVV-LVA); killers 19000/18990; under-promotions 50;
#   quiet moves: history score, capped at 18000.

def okey(+mv: U32, +vic: U32, +att: U32, +h: U32, +ttm: U32, +k1: U32, +k2: U32) -> U32:
  +b = C.mv.bare(mv)
  +fl = C.mv.flag(mv)
  +isep = U32.is_eq(fl, 3)
  +vt = C.sel(isep, 1, C.pc.type(vic))
  +cap = U32.is_ne(vic, 0) || isep
  C.sel(U32.is_eq(b, ttm), 32767,
    C.sel(U32.is_eq(fl, 7), U32.add(30000, U32.mul(vt, 100)),
      C.sel(cap, U32.sub(U32.add(20000, U32.mul(vt, 100)), C.pc.type(att)),
        C.sel(U32.is_ge(fl, 4), 50,
          C.sel(U32.is_eq(b, k1), 19000,
            C.sel(U32.is_eq(b, k2), 18990, U32.min(h, 18000)))))))

def hist.idx(+side: U32, +mv: U32) -> U32:
  U32.add(B.HISTORY(), U32.or(U32.shln(side, 14n), U32.and(mv, 16383)))

def ord.go?(m: Array<U32>, +side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32,
            +k2: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      ord.m(side, base, i, n, ttm, k1, k2, m[U32.add(base, i)])

# give every move at m[base..base+n) its ordering key
def ord?(m: Array<U32>, +side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32) ->
  Array<U32>:
  ord.go(m, side, base, i, n, ttm, k1, k2, U32.is_lt(i, n))

def ord.w?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +mv: U32,
           +vic: U32, +att: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +h) = r
  m[U32.add(base, i)] <- U32.or(C.mv.bare(mv), U32.shln(okey(mv, vic, att, h, ttm, k1, k2), 17n))
  ord(m, side, base, U32.add(i, 1), n, ttm, k1, k2)

def ord.a?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +mv: U32,
           +vic: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +att) = r
  ord.w(side, base, i, n, ttm, k1, k2, mv, vic, att, m[hist.idx(side, mv)])

def ord.v?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +mv: U32,
           r: Array<U32> & U32) -> Array<U32>:
  (m, +vic) = r
  ord.a(side, base, i, n, ttm, k1, k2, mv, vic, m[C.mv.from(mv)])

def ord.m?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32,
           r: Array<U32> & U32) -> Array<U32>:
  (m, +mv) = r
  ord.v(side, base, i, n, ttm, k1, k2, mv, m[C.mv.to(mv)])

# selection: swap the largest word of m[base+i .. base+n) into slot i
def pick.fin(+base: U32, +i: U32, +bi: U32, +bv: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +vi) = r
  m[U32.add(base, bi)] <- vi
  m[U32.add(base, i)] <- bv
  (m, bv)

def pick.v?(+base: U32, +i: U32, +j: U32, +n: U32, +bi: U32, +bv: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +v) = r
  +better = U32.is_gt(v, bv)
  pick.go(m, base, i, U32.add(j, 1), n, C.sel(better, j, bi), C.sel(better, v, bv),
    U32.is_lt(U32.add(j, 1), n))

def pick.go?(m: Array<U32>, +base: U32, +i: U32, +j: U32, +n: U32, +bi: U32, +bv: U32, go: Bool) ->
  Array<U32> & U32:
  match go:
    case True{}:
      pick.v(base, i, j, n, bi, bv, m[U32.add(base, j)])
    case False{}:
      pick.fin(base, i, bi, bv, m[U32.add(base, i)])

def pick.a(+base: U32, +i: U32, +n: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  pick.go(m, base, i, U32.add(i, 1), n, i, v, U32.is_lt(U32.add(i, 1), n))

def pick(m: Array<U32>, +base: U32, +i: U32, +n: U32) -> Array<U32> & U32:
  pick.a(base, i, n, m[U32.add(base, i)])

def pv.copy.go?(m: Array<U32>, +dst: U32, +src: U32, +k: U32, +len: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      pv.copy.b(dst, src, k, len, m[U32.add(src, k)])

def pv.copy?(m: Array<U32>, +dst: U32, +src: U32, +k: U32, +len: U32) -> Array<U32>:
  pv.copy.go(m, dst, src, k, len, U32.is_lt(k, len))

# Principal variation
# -------------------

def pv.copy.b?(+dst: U32, +src: U32, +k: U32, +len: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +v) = r
  m[U32.add(dst, k)] <- v
  pv.copy(m, dst, src, U32.add(k, 1), len)

def pv.row(+ply: U32) -> U32:
  U32.add(B.PVT(), U32.shln(ply, 7n))

def pv.upd.b(+ply: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +len) = r
  +l2 = U32.min(len, 120)
  m[U32.add(B.PVLEN(), ply)] <- U32.add(l2, 1)
  pv.copy(m, U32.add(pv.row(ply), 1), pv.row(U32.add(ply, 1)), 0, l2)

# PV at ply := mv followed by the PV at ply + 1
def pv.upd(m: Array<U32>, +ply: U32, +mv: U32) -> Array<U32>:
  m[pv.row(ply)] <- C.mv.bare(mv)
  pv.upd.b(ply, m[U32.add(B.PVLEN(), U32.add(ply, 1))])

# Killers and history
# -------------------

def killer.c(m: Array<U32>, +i: U32, +mv: U32, +k1: U32, same: Bool) -> Array<U32>:
  match same:
    case True{}:
      m
    case False{}:
      m[U32.add(i, 1)] <- k1
      m[i] <- mv
      m

def killer.b(+ply: U32, +mv: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +k1) = r
  killer.c(m, U32.add(B.KILLERS(), U32.shln(ply, 1n)), mv, k1, U32.is_eq(k1, mv))

def hist.b(+i: U32, +bonus: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +h) = r
  m[i] <- U32.min(U32.add(h, bonus), 30000)
  m

# a quiet move caused a beta cutoff: remember it
def good_quiet(m: Array<U32>, +side: U32, +ply: U32, +depth: U32, +mv: U32) -> Array<U32>:
  +b = C.mv.bare(mv)
  +i = hist.idx(side, b)
  m = hist.b(i, U32.mul(depth, depth), m[i])
  killer.b(ply, b, m[U32.add(B.KILLERS(), U32.shln(ply, 1n))])

# LMR
# ---

# reduction for the i-th legal move at depth d: 0.75 + ln d * ln i / 2.25
def lmr.r(+d: U32, +i: U32) -> U32:
  F32.to_u32((0.75 + F32.log(U32.to_f32(d)) * F32.log(U32.to_f32(i)) / 2.25 : F32))

# Node context and loop state
# ---------------------------

type Nd is Data:
  Nd{p: B.Pos, depth: U32, beta: U32, ply: U32, pv: Bool, chk: Bool, ev: U32, base: U32,
     n: U32, oalpha: U32, o: Opt}

type Lp is Data:
  Lp{alpha: U32, best: U32, bmv: U32, i: U32, legal: U32, quiets: U32}

def Nd.p(+x: Nd) -> B.Pos:
  match x:
    case Nd{p, _, _, _, _, _, _, _, _, _, _}:
      p

def Nd.depth(+x: Nd) -> U32:
  match x:
    case Nd{_, depth, _, _, _, _, _, _, _, _, _}:
      depth

def Nd.beta(+x: Nd) -> U32:
  match x:
    case Nd{_, _, beta, _, _, _, _, _, _, _, _}:
      beta

def Nd.ply(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, ply, _, _, _, _, _, _, _}:
      ply

def Nd.pv(+x: Nd) -> Bool:
  match x:
    case Nd{_, _, _, _, pv, _, _, _, _, _, _}:
      pv

def Nd.chk(+x: Nd) -> Bool:
  match x:
    case Nd{_, _, _, _, _, chk, _, _, _, _, _}:
      chk

def Nd.ev(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, ev, _, _, _, _}:
      ev

def Nd.base(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, _, base, _, _, _}:
      base

def Nd.n(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, _, _, n, _, _}:
      n

def Nd.oalpha(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, _, _, _, oalpha, _}:
      oalpha

def Nd.o(+x: Nd) -> Opt:
  match x:
    case Nd{_, _, _, _, _, _, _, _, _, _, o}:
      o

def Lp.alpha(+x: Lp) -> U32:
  match x:
    case Lp{alpha, _, _, _, _, _}:
      alpha

def Lp.best(+x: Lp) -> U32:
  match x:
    case Lp{_, best, _, _, _, _}:
      best

def Lp.bmv(+x: Lp) -> U32:
  match x:
    case Lp{_, _, bmv, _, _, _}:
      bmv

def Lp.i(+x: Lp) -> U32:
  match x:
    case Lp{_, _, _, i, _, _}:
      i

def Lp.legal(+x: Lp) -> U32:
  match x:
    case Lp{_, _, _, _, legal, _}:
      legal

def Lp.quiets(+x: Lp) -> U32:
  match x:
    case Lp{_, _, _, _, _, quiets}:
      quiets

# next move index, nothing else changed (illegal move)
def Lp.skip(+x: Lp) -> Lp:
  match x:
    case Lp{alpha, best, bmv, i, legal, quiets}:
      Lp{alpha, best, bmv, U32.add(i, 1), legal, quiets}

# a legal move that was pruned without search
def Lp.pruned(+x: Lp) -> Lp:
  match x:
    case Lp{alpha, best, bmv, i, legal, quiets}:
      Lp{alpha, best, bmv, U32.add(i, 1), U32.add(legal, 1), U32.add(quiets, 1)}

# Quiescence search
# -----------------
# Stand pat on the static eval, then captures and queen promotions in
# MVV-LVA order with delta pruning. In check there is no stand pat: all
# evasions are searched, and no legal move means mate.

def qs.done(m: Array<U32>, +nd: Nd, +lp: Lp) -> Array<U32> & U32:
  (m, C.sel(Nd.chk(nd) && U32.is_zero(Lp.legal(lp)),
    U32.add(C.s.neg(C.MATE()), Nd.ply(nd)), Lp.best(lp)))

def pv.upd.if(m: Array<U32>, +ply: U32, +mv: U32, go: Bool) -> Array<U32>:
  match go:
    case True{}:
      pv.upd(m, ply, mv)
    case False{}:
      m

# unmake, then: has the search been stopped?
def unmake.mem(m: Array<U32>, +np: B.Pos, +mv: U32) -> Array<U32> & Bool:
  stopped(B.unmake(m, np, mv))

def qs.stand?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
              +o: Opt, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, ev)
    case False{}:
      +stand = Bool.not(chk)
      +base = ply_moves(ply)
      qs.gen(p, C.sel(stand, C.s.max(alpha, ev), alpha), beta, ply, chk, ev,
        C.sel(stand, ev, U32.add(C.s.neg(C.MATE()), ply)), base, o,
        G.gen(m, p, base, C.sel(chk, 0, 1)))

def qs.ev?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt,
           r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +ev) = r
  qs.stand(m, p, alpha, beta, ply, chk, ev, o, Bool.not(chk) && C.s.ge(ev, beta))

def qs.deep?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt,
             deep: Bool) -> Array<U32> & U32:
  match deep:
    case True{}:
      E.eval(m, p, Opt.evm(o))
    case False{}:
      qs.ev(p, alpha, beta, ply, chk, o, E.eval.lazy(m, p, Opt.evm(o), alpha, beta))

def qs.a?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt,
          r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      (m, 0)
    case (m, False{}):
      qs.deep(m, p, alpha, beta, ply, chk, o, U32.is_ge(ply, B.MAX_PLY()))

def qsearch?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt) ->
  Array<U32> & U32:
  m[U32.add(B.PVLEN(), ply)] <- 0
  qs.a(p, alpha, beta, ply, chk, o, tick(m))

def qs.cut?(m: Array<U32>, +nd: Nd, +lp: Lp, +best: U32, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, best)
    case False{}:
      qs.loop(m, nd, lp)

def qs.upd?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +s: U32) -> Array<U32> & U32:
  match lp:
    case Lp{alpha, best, bmv, i, legal, quiets}:
      +better = C.s.gt(s, best)
      +raise = C.s.gt(s, alpha)
      +best2 = C.sel(better, s, best)
      qs.cut(pv.upd.if(m, Nd.ply(nd), mv, raise), nd,
        Lp{C.sel(raise, s, alpha), best2, C.sel(better, mv, bmv), U32.add(i, 1), U32.add(legal, 1), quiets},
        best2, C.s.ge(s, Nd.beta(nd)))

def qs.after.b?(r: Array<U32> & Bool, +nd: Nd, +lp: Lp, +mv: U32, +s: U32) -> Array<U32> & U32:
  match r:
    case (m, False{}):
      qs.upd(m, nd, lp, mv, s)
    case (m, True{}):
      (m, 0)

def qs.after?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +raw) = r
  qs.after.b(unmake.mem(m, np, mv), nd, lp, mv, C.s.neg(raw))

def qs.child?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, gc):
      qs.after(nd, lp, mv, np,
        qsearch(m, np, C.s.neg(Nd.beta(nd)), C.s.neg(Lp.alpha(lp)), U32.add(Nd.ply(nd), 1), gc, Nd.o(nd)))

def qs.delta?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, futile: Bool) -> Array<U32> & U32:
  match futile:
    case True{}:
      qs.loop(B.unmake(m, np, mv), nd, Lp.pruned(lp))
    case False{}:
      qs.child(nd, lp, mv, np, G.gchk(m, np, mv))

def qs.legal?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      qs.loop(B.unmake(m, np, mv), nd, Lp.skip(lp))
    case (m, False{}):
      +gain = U32.add(pval(U32.to_nat(C.pc.type(B.P.cap(np)))), 200)
      qs.delta(m, nd, lp, mv, np, Bool.not(Nd.chk(nd)) && Bool.not(C.mv.is_promo(mv)) &&
        C.s.le(U32.add(Nd.ev(nd), gain), Lp.alpha(lp)))

def qs.made?(+nd: Nd, +lp: Lp, +mv: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  qs.legal(nd, lp, mv, np, G.illegal(m, np, mv, Nd.chk(nd)))

def qs.picked?(+nd: Nd, +lp: Lp, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mvk) = r
  +mv = C.mv.bare(mvk)
  qs.made(nd, lp, mv, B.make(m, Nd.p(nd), mv))

def qs.loop.go?(m: Array<U32>, +nd: Nd, +lp: Lp, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      qs.done(m, nd, lp)
    case True{}:
      qs.picked(nd, lp, pick(m, Nd.base(nd), Lp.i(lp), Nd.n(nd)))

def qs.loop?(m: Array<U32>, +nd: Nd, +lp: Lp) -> Array<U32> & U32:
  qs.loop.go(m, nd, lp, U32.is_lt(Lp.i(lp), Nd.n(nd)))

def qs.gen?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32, +best: U32,
            +base: U32, +o: Opt, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  m = ord(m, B.P.side(p), base, 0, n, 0, 0, 0)
  qs.loop(m, Nd{p, 0, beta, ply, False{}, chk, ev, base, n, alpha, o}, Lp{alpha, best, 0, 0, 0, 0})

# Main search
# -----------

def sr.done?(m: Array<U32>, +nd: Nd, +lp: Lp) -> Array<U32> & U32:
  +nolegal = U32.is_zero(Lp.legal(lp))
  +score = C.sel(nolegal, C.sel(Nd.chk(nd), U32.add(C.s.neg(C.MATE()), Nd.ply(nd)), 0), Lp.best(lp))
  +bound = C.sel(C.s.gt(Lp.best(lp), Nd.oalpha(nd)) || nolegal, 3, 1)
  (tt.store(m, Nd.p(nd), Nd.ply(nd), Nd.depth(nd), bound, score, Lp.bmv(lp)), score)

def good_quiet.if(m: Array<U32>, +side: U32, +ply: U32, +depth: U32, +mv: U32, go: Bool) -> Array<U32>:
  match go:
    case True{}:
      good_quiet(m, side, ply, depth, mv)
    case False{}:
      m

def sr.k2?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, +k1: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +k2) = r
  m = ord(m, B.P.side(p), base, 0, n, ttm, k1, k2)
  sr.loop(m, Nd{p, depth, beta, ply, pv, chk, ev, base, n, alpha, o},
    Lp{alpha, U32.add(C.s.neg(C.INF()), 0), 0, 0, 0, 0})

def sr.k1?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +k1) = r
  sr.k2(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, base, n, k1,
    m[U32.add(U32.add(B.KILLERS(), U32.shln(ply, 1n)), 1)])

# CAS level 3 (in-tree allocation): a node with at most 3 pseudo-legal
# moves is a forced line (cheap to resolve, often decisive): +1 ply
def sr.gen?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
            +pv: Bool, +ttm: U32, +o: Opt, +base: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  +ext = C.b2u(U32.is_ge(Opt.cas(o), 3) && U32.is_le(n, 3) && U32.is_lt(ply, 40))
  sr.k1(p, U32.add(depth, ext), alpha, beta, ply, chk, ev, pv, ttm, o, base, n,
    m[U32.add(B.KILLERS(), U32.shln(ply, 1n))])

def sr.moves?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool,
              +ev: U32, +pv: Bool, +ttm: U32, +o: Opt) -> Array<U32> & U32:
  +base = ply_moves(ply)
  sr.gen(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, base, G.gen(m, p, base, 0))

# null move: the side to move passes; if a reduced search still fails
# high, so would a real move (except in zugzwang)
def sr.nm.c?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool,
             +ev: U32, +pv: Bool, +ttm: U32, +o: Opt, +s: U32, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, C.sel(C.s.ge(s, C.MATE_BOUND()), beta, s))
    case False{}:
      sr.moves(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o)

def sr.nm.b?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
             +pv: Bool, +ttm: U32, +o: Opt, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +raw) = r
  +s = C.s.neg(raw)
  sr.nm.c(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, s, C.s.ge(s, beta))

def sr.nm.a?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
             +pv: Bool, +ttm: U32, +o: Opt, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  +red = U32.add(3, U32.div(depth, 6))
  sr.nm.b(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o,
    search(m, np, sub0(depth, U32.add(red, 1)), C.s.neg(beta), C.s.neg(U32.sub(beta, 1)),
      U32.add(ply, 1), False{}, False{}, o))

def sr.nm?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool,
           +ev: U32, +pv: Bool, +ttm: U32, +o: Opt, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      sr.moves(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o)
    case True{}:
      sr.nm.a(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, B.null.make(m, p))

def sr.rfp?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
            +nullok: Bool, +chk: Bool, +ev: U32, +pv: Bool, +ttm: U32, +o: Opt, cut: Bool) ->
  Array<U32> & U32:
  match cut:
    case True{}:
      (m, ev)
    case False{}:
      sr.nm(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o,
        Opt.null(o) && nullok && Bool.not(pv) && Bool.not(chk) && U32.is_ge(depth, 3) &&
        C.s.ge(ev, beta) && U32.is_ge(B.P.ph(p), 3))

def sr.ev?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
           +ttm: U32, +o: Opt, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +ev) = r
  +pv = U32.is_gt(U32.sub(beta, alpha), 1)
  +bmate = C.s.lt(C.s.abs(beta), C.MATE_BOUND())
  sr.rfp(m, p, depth, alpha, beta, ply, nullok, chk, ev, pv, ttm, o,
    Opt.prune(o) && Bool.not(pv) && Bool.not(chk) && U32.is_gt(ply, 0) && U32.is_le(depth, 7) &&
    bmate && C.s.ge(U32.sub(ev, U32.mul(75, depth)), beta))

def sr.noprobe?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
                +nullok: Bool, +chk: Bool, +ttm: U32, +o: Opt) -> Array<U32> & U32:
  sr.ev(p, depth, alpha, beta, ply, nullok, chk, ttm, o, E.eval(m, p, Opt.evm(o)))

def sr.tt.e?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
             +nullok: Bool, +chk: Bool, +ttm: U32, +o: Opt, +sc: U32, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, sc)
    case False{}:
      sr.noprobe(m, p, depth, alpha, beta, ply, nullok, chk, ttm, o)

def sr.tt.d?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
             +o: Opt, +data: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sc0) = r
  +ttm = U32.and(data, 131071)
  +bnd = U32.and(U32.shrn(data, 17n), 3)
  +ttd = U32.shrn(data, 19n)
  +sc = tt.from(sc0, ply)
  +pv = U32.is_gt(U32.sub(beta, alpha), 1)
  +cut = Bool.not(pv) && U32.is_gt(ply, 0) && U32.is_ge(ttd, depth) &&
    (U32.is_eq(bnd, 3) || (U32.is_eq(bnd, 2) && C.s.ge(sc, beta)) || (U32.is_eq(bnd, 1) && C.s.le(sc, alpha)))
  sr.tt.e(m, p, depth, alpha, beta, ply, nullok, chk, ttm, o, sc, cut)

def sr.tt.c?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
             +o: Opt, +i: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +data) = r
  sr.tt.d(p, depth, alpha, beta, ply, nullok, chk, o, data, m[U32.add(i, 2)])

def sr.tt.b?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
             +nullok: Bool, +chk: Bool, +o: Opt, +i: U32, hit: Bool) -> Array<U32> & U32:
  match hit:
    case False{}:
      sr.noprobe(m, p, depth, alpha, beta, ply, nullok, chk, 0, o)
    case True{}:
      sr.tt.c(p, depth, alpha, beta, ply, nullok, chk, o, i, m[U32.add(i, 1)])

def sr.tt?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
           +o: Opt, +i: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +lock) = r
  sr.tt.b(m, p, depth, alpha, beta, ply, nullok, chk, o, i, U32.is_eq(lock, B.P.hhi(p)))

def sr.mdp?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
            +nullok: Bool, +chk: Bool, +o: Opt, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, alpha)
    case False{}:
      +i = tt.idx(B.P.hlo(p))
      sr.tt(p, depth, alpha, beta, ply, nullok, chk, o, i, m[i])

def sr.depth?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
              +nullok: Bool, +chk: Bool, +o: Opt, leaf: Bool) -> Array<U32> & U32:
  match leaf:
    case True{}:
      qsearch(m, p, alpha, beta, ply, chk, o)
    case False{}:
      +a2 = C.s.max(alpha, U32.add(C.s.neg(C.MATE()), ply))
      +b2 = C.s.min(beta, U32.sub(C.MATE(), U32.add(ply, 1)))
      sr.mdp(m, p, depth, a2, b2, ply, nullok, chk, o, C.s.ge(a2, b2))

def sr.draw?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
             +o: Opt, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      (m, 0)
    case (m, False{}):
      +d = U32.add(depth, C.b2u(chk))
      sr.depth(m, p, d, alpha, beta, ply, nullok, chk, o,
        U32.is_zero(d) || U32.is_ge(ply, B.MAX_PLY()))

def sr.a?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
          +o: Opt, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      (m, 0)
    case (m, False{}):
      sr.draw(p, depth, alpha, beta, ply, nullok, chk, o, draw(m, p, ply))

# negamax value of p searched to `depth` plies within (alpha, beta);
# chk: is the side to move in check (computed by the caller)
def search?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
            +nullok: Bool, +chk: Bool, +o: Opt) -> Array<U32> & U32:
  m[U32.add(B.PVLEN(), ply)] <- 0
  sr.a(p, depth, alpha, beta, ply, nullok, chk, o, tick(m))

def sr.re2.b?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, +gc: Bool,
              +raw: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      sr.after(nd, lp, mv, np, quiet, (m, raw))
    case True{}:
      sr.after(nd, lp, mv, np, quiet,
        search(m, np, sub0(Nd.depth(nd), 1), C.s.neg(Nd.beta(nd)), C.s.neg(Lp.alpha(lp)),
          U32.add(Nd.ply(nd), 1), True{}, gc, Nd.o(nd)))

# research at full depth / full window when a reduced or null-window
# search beat alpha
def sr.re2?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, +gc: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +raw) = r
  +s = C.s.neg(raw)
  sr.re2.b(m, nd, lp, mv, np, quiet, gc, raw,
    Nd.pv(nd) && C.s.gt(s, Lp.alpha(lp)) && C.s.lt(s, Nd.beta(nd)))

def sr.re1.b?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, +gc: Bool,
              +raw: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      sr.re2(nd, lp, mv, np, quiet, gc, (m, raw))
    case True{}:
      +a = Lp.alpha(lp)
      sr.re2(nd, lp, mv, np, quiet, gc,
        search(m, np, sub0(Nd.depth(nd), 1), C.s.neg(U32.add(a, 1)), C.s.neg(a),
          U32.add(Nd.ply(nd), 1), True{}, gc, Nd.o(nd)))

def sr.re1?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, +gc: Bool, +red: U32,
            r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +raw) = r
  sr.re1.b(m, nd, lp, mv, np, quiet, gc, raw,
    U32.is_gt(red, 0) && C.s.gt(C.s.neg(raw), Lp.alpha(lp)))

def sr.child?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, +gc: Bool,
              +red: U32, first: Bool) -> Array<U32> & U32:
  match first:
    case True{}:
      sr.after(nd, lp, mv, np, quiet,
        search(m, np, sub0(Nd.depth(nd), 1), C.s.neg(Nd.beta(nd)), C.s.neg(Lp.alpha(lp)),
          U32.add(Nd.ply(nd), 1), True{}, gc, Nd.o(nd)))
    case False{}:
      +a = Lp.alpha(lp)
      sr.re1(nd, lp, mv, np, quiet, gc, red,
        search(m, np, sub0(sub0(Nd.depth(nd), 1), red), C.s.neg(U32.add(a, 1)), C.s.neg(a),
          U32.add(Nd.ply(nd), 1), True{}, gc, Nd.o(nd)))

# reduction for a late quiet move (0 when LMR does not apply); CAS level 3
# reduces one more ply in very wide nodes (> 40 moves), where each quiet
# move's subtree is expensive and individually unlikely to matter
def sr.red(+nd: Nd, +lp: Lp, +quiet: Bool, +gc: Bool) -> U32:
  +d = Nd.depth(nd)
  +k = U32.add(Lp.legal(lp), 1)
  +ok = Opt.lmr(Nd.o(nd)) && quiet && Bool.not(gc) && Bool.not(Nd.chk(nd)) &&
    U32.is_ge(d, 3) && U32.is_gt(k, 3)
  +wide = C.b2u(U32.is_ge(Opt.cas(Nd.o(nd)), 3) && U32.is_gt(Nd.n(nd), 40) && U32.is_gt(k, 8))
  +r0 = U32.add(sub0(lmr.r(d, k), C.b2u(Nd.pv(nd))), wide)
  C.sel(ok, U32.min(r0, sub0(d, 2)), 0)

def sr.prune?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, +gc: Bool,
              prune: Bool) -> Array<U32> & U32:
  match prune:
    case True{}:
      sr.loop(B.unmake(m, np, mv), nd, Lp.pruned(lp))
    case False{}:
      sr.child(m, nd, lp, mv, np, quiet, gc, sr.red(nd, lp, quiet, gc), U32.is_zero(Lp.legal(lp)))

# late-move pruning threshold: quiet moves tried before the rest are skipped
def lmp.max(+d: U32) -> U32:
  U32.add(3, U32.mul(d, d))

def sr.gc?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +gc) = r
  +quiet = U32.is_zero(B.P.cap(np)) && Bool.not(C.mv.is_promo(mv))
  +d = Nd.depth(nd)
  +ok = Opt.prune(Nd.o(nd)) && Bool.not(Nd.pv(nd)) && Bool.not(Nd.chk(nd)) && Bool.not(gc) && quiet &&
    U32.is_gt(Lp.legal(lp), 0) && U32.is_le(d, 3) &&
    C.s.gt(Lp.best(lp), C.s.neg(C.MATE_BOUND()))
  +futile = C.s.le(U32.add(Nd.ev(nd), U32.add(100, U32.mul(d, 120))), Lp.alpha(lp))
  +late = U32.is_ge(Lp.quiets(lp), lmp.max(d))
  sr.prune(m, nd, lp, mv, np, quiet, gc, ok && (futile || late))

def sr.legal?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      sr.loop(B.unmake(m, np, mv), nd, Lp.skip(lp))
    case (m, False{}):
      sr.gc(nd, lp, mv, np, G.gchk(m, np, mv))

def sr.made?(+nd: Nd, +lp: Lp, +mv: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  sr.legal(nd, lp, mv, np, G.illegal(m, np, mv, Nd.chk(nd)))

def sr.picked?(+nd: Nd, +lp: Lp, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mvk) = r
  +mv = C.mv.bare(mvk)
  sr.made(nd, lp, mv, B.make(m, Nd.p(nd), mv))

def sr.loop.go?(m: Array<U32>, +nd: Nd, +lp: Lp, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      sr.done(m, nd, lp)
    case True{}:
      sr.picked(nd, lp, pick(m, Nd.base(nd), Lp.i(lp), Nd.n(nd)))

def sr.loop?(m: Array<U32>, +nd: Nd, +lp: Lp) -> Array<U32> & U32:
  sr.loop.go(m, nd, lp, U32.is_lt(Lp.i(lp), Nd.n(nd)))

def sr.cut?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +s: U32, +quiet: Bool, cut: Bool) ->
  Array<U32> & U32:
  match cut:
    case False{}:
      sr.loop(m, nd, lp)
    case True{}:
      m = good_quiet.if(m, B.P.side(Nd.p(nd)), Nd.ply(nd), Nd.depth(nd), mv, quiet)
      (tt.store(m, Nd.p(nd), Nd.ply(nd), Nd.depth(nd), 2, s, mv), s)

def sr.upd?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +s: U32, +quiet: Bool) -> Array<U32> & U32:
  match lp:
    case Lp{alpha, best, bmv, i, legal, quiets}:
      +better = C.s.gt(s, best)
      +raise = C.s.gt(s, alpha)
      sr.cut(pv.upd.if(m, Nd.ply(nd), mv, raise), nd,
        Lp{C.sel(raise, s, alpha), C.sel(better, s, best), C.sel(better, mv, bmv), U32.add(i, 1),
          U32.add(legal, 1), U32.add(quiets, C.b2u(quiet))},
        mv, s, quiet, C.s.ge(s, Nd.beta(nd)))

def sr.after.b?(r: Array<U32> & Bool, +nd: Nd, +lp: Lp, +mv: U32, +s: U32, +quiet: Bool) ->
  Array<U32> & U32:
  match r:
    case (m, False{}):
      sr.upd(m, nd, lp, mv, s, quiet)
    case (m, True{}):
      (m, 0)

def sr.after?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +raw) = r
  sr.after.b(unmake.mem(m, np, mv), nd, lp, mv, C.s.neg(raw), quiet)

def fill.go?(m: Array<U32>, +i: U32, +end: U32, +v: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      m[i] <- v
      fill(m, U32.add(i, 1), end, v)

# Table maintenance
# -----------------

def fill?(m: Array<U32>, +i: U32, +end: U32, +v: U32) -> Array<U32>:
  fill.go(m, i, end, v, U32.is_lt(i, end))

def halve.b?(+i: U32, +end: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +v) = r
  m[i] <- U32.shrn(v, 1n)
  halve(m, U32.add(i, 1), end)

def halve.go?(m: Array<U32>, +i: U32, +end: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      halve.b(i, end, m[i])

def halve?(m: Array<U32>, +i: U32, +end: U32) -> Array<U32>:
  halve.go(m, i, end, U32.is_lt(i, end))

# before a search: age the history table, clear killers
def prep(m: Array<U32>) -> Array<U32>:
  m = halve(m, B.HISTORY(), U32.add(B.HISTORY(), 32768))
  fill(m, B.KILLERS(), U32.add(B.KILLERS(), 256), 0)

# new game: clear TT, history, killers
def clear(m: Array<U32>) -> Array<U32>:
  m = fill(m, B.TT(), U32.add(B.TT(), 4194304), 0)
  m = fill(m, B.HISTORY(), U32.add(B.HISTORY(), 32768), 0)
  fill(m, B.KILLERS(), U32.add(B.KILLERS(), 256), 0)

def Opt.ss(+o: Opt) -> U32:
  match o:
    case Opt{_, _, _, _, _, _, ss}:
      ss
