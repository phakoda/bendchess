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
import ./tables.bend as T
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
# tp: TimePolicy, 1 = budget adaptation v1, 2 = v2 (adds best-move node
#     effort and graded score drops; see uci.bend id.more)
# th: Threads, root-split parallel search workers (1, 2 or 4)
# pr: Practical, margin in cp for the practical-difficulty choice (0 = off)
# Packed into two words (it travels in every search frame):
# a = null | lmr << 1 | prune << 2 | cas << 3 (3 bits) | evm << 6 (3 bits)
#     | tp << 9 (3 bits) | th << 12 (4 bits) | pr << 16 (8 bits)
# b = nt (16 bits) | ss << 16 (16 bits)
type Opt is Data:
  Opt{a: U32, b: U32}

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

def rep.go?(m: Array<U32>, +hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, go: Bool) ->
  Array<U32> & Bool:
  match go:
    case False{}:
      (m, False{})
    case True{}:
      rep.a(hlo, hhi, hidx, k, lim, m[rep.slot(hidx, k)])

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

# TT generation (search counter, 5 bits) and improving flags per ply
def TTAGE() -> U32:
  U32.add(B.SC(), 5)

def tt.store.g(m: Array<U32>, +p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32, +bm: U32,
               +age: U32, repl: Bool) -> Array<U32>:
  match repl:
    case False{}:
      m
    case True{}:
      +i = tt.idx(B.P.hlo(p))
      m[i] <- B.P.hhi(p)
      m[U32.add(i, 1)] <- U32.or(U32.or(U32.or(bm, U32.shln(bound, 17n)), U32.shln(U32.min(depth, 255), 19n)),
        U32.shln(age, 27n))
      m[U32.add(i, 2)] <- tt.to(score, ply)
      m

def tt.store.f(+p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32, +mv: U32, +age: U32,
               +lock: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +old) = r
  +same = U32.is_eq(lock, B.P.hhi(p))
  +odepth = U32.and(U32.shrn(old, 19n), 255)
  +oage = U32.shrn(old, 27n)
  +repl = same || U32.is_ne(oage, age) || U32.is_eq(bound, 3) || U32.is_ge(U32.add(depth, 2), odepth)
  +bm = C.sel(same && U32.is_zero(C.mv.bare(mv)), U32.and(old, 131071), C.mv.bare(mv))
  tt.store.g(m, p, ply, depth, bound, score, bm, age, repl)

def tt.store.e(+p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32, +mv: U32, +age: U32,
               r: Array<U32> & U32) -> Array<U32>:
  (m, +lock) = r
  tt.store.f(p, ply, depth, bound, score, mv, age, lock, m[U32.add(tt.idx(B.P.hlo(p)), 1)])

def tt.store.d(+p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32, +mv: U32,
               r: Array<U32> & U32) -> Array<U32>:
  (m, +age) = r
  tt.store.e(p, ply, depth, bound, score, mv, U32.and(age, 31), m[tt.idx(B.P.hlo(p))])

def tt.store.c(m: Array<U32>, +p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32,
               +mv: U32, ok: Bool) -> Array<U32>:
  match ok:
    case False{}:
      m
    case True{}:
      tt.store.d(p, ply, depth, bound, score, mv, m[TTAGE()])

def tt.store.b(+p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32, +mv: U32,
               r: Array<U32> & U32) -> Array<U32>:
  (m, +st) = r
  tt.store.c(m, p, ply, depth, bound, score, mv, U32.is_zero(st))

# Transposition-table store with a replacement rule: an entry is replaced
# when it belongs to the same position, comes from an older search, is
# exact, or the new search is not much shallower than the old one. A store
# without a best move keeps the old move of the same position.
#   data = move | bound << 17 | depth << 19 | age << 27
def tt.store(m: Array<U32>, +p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32,
             +mv: U32) -> Array<U32>:
  tt.store.b(p, ply, depth, bound, score, mv, m[STOP()])

# history + continuation history -> ordering key in 0..18000 (9000 neutral)
def qkey(+h: U32, +c: U32) -> U32:
  +sum = U32.add(U32.add(h, c), 32768)
  U32.min(U32.div(U32.mul(U32.and(sum, 131071), 18000), 65536), 18000)

def okey(+mv: U32, +vic: U32, +att: U32, +h: U32, +c: U32, +ttm: U32, +k1: U32, +k2: U32, +cm: U32, +bad: Bool) -> U32:
  +b = C.mv.bare(mv)
  +fl = C.mv.flag(mv)
  +isep = U32.is_eq(fl, 3)
  +vt = C.sel(isep, 1, C.pc.type(vic))
  +cap = U32.is_ne(vic, 0) || isep
  C.sel(U32.is_eq(b, ttm), 32767,
    C.sel(U32.is_eq(fl, 7), U32.add(30000, U32.mul(vt, 100)),
      C.sel(cap && bad, U32.add(20, vt),
        C.sel(cap, U32.sub(U32.add(20000, U32.mul(vt, 100)), C.pc.type(att)),
          C.sel(U32.is_ge(fl, 4), 50,
            C.sel(U32.is_eq(b, k1), 19000,
              C.sel(U32.is_eq(b, k2), 18990,
                C.sel(U32.is_eq(b, cm), 18980, qkey(h, c)))))))))

def hist.idx(+side: U32, +mv: U32) -> U32:
  U32.add(B.HISTORY(), U32.or(U32.shln(side, 14n), U32.and(mv, 16383)))

def mkey(+pc: U32, +to: U32) -> U32:
  U32.add(U32.shln(U32.add(U32.mul(C.pc.color(pc), 6), U32.sub(C.pc.type(pc), 1)), 6n), C.sq.to64(to))

def CHIST() -> U32:
  3162112

def ch.idx(+pk: U32, +ck: U32) -> U32:
  U32.add(CHIST(), U32.add(U32.mul(U32.min(pk, 768), 768), U32.min(ck, 767)))

def ord.m?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +pk: U32, +cm: U32,
           r: Array<U32> & U32) -> Array<U32>:
  (m, +mv) = r
  ord.v(side, base, i, n, ttm, k1, k2, pk, cm, mv, m[C.mv.to(mv)])

def ord.go?(m: Array<U32>, +side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32,
            +k2: U32, +pk: U32, +cm: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      ord.m(side, base, i, n, ttm, k1, k2, pk, cm, m[U32.add(base, i)])

def ord?(m: Array<U32>, +side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +pk: U32,
         +cm: U32) -> Array<U32>:
  ord.go(m, side, base, i, n, ttm, k1, k2, pk, cm, U32.is_lt(i, n))

def ord.w?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +pk: U32, +cm: U32,
           +mv: U32, +vic: U32, +att: U32, +bad: Bool, +h: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +c) = r
  m[U32.add(base, i)] <- U32.or(C.mv.bare(mv), U32.shln(okey(mv, vic, att, h, c, ttm, k1, k2, cm, bad), 17n))
  ord(m, side, base, U32.add(i, 1), n, ttm, k1, k2, pk, cm)

def ord.h?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +pk: U32, +cm: U32,
           +mv: U32, +vic: U32, +att: U32, +bad: Bool, r: Array<U32> & U32) -> Array<U32>:
  (m, +h) = r
  ord.w(side, base, i, n, ttm, k1, k2, pk, cm, mv, vic, att, bad, h, m[ch.idx(pk, mkey(att, C.mv.to(mv)))])

def ord.a?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +pk: U32, +cm: U32,
           +mv: U32, +vic: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +att) = r
  ord.h(side, base, i, n, ttm, k1, k2, pk, cm, mv, vic, att, False{}, m[hist.idx(side, mv)])

def ord.v?(+side: U32, +base: U32, +i: U32, +n: U32, +ttm: U32, +k1: U32, +k2: U32, +pk: U32, +cm: U32,
           +mv: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +vic) = r
  ord.a(side, base, i, n, ttm, k1, k2, pk, cm, mv, vic, m[C.mv.from(mv)])

# selection: swap the largest word of m[base+i .. base+n) into slot i
def pick.fin(+base: U32, +i: U32, +bi: U32, +bv: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +vi) = r
  m[U32.add(base, bi)] <- vi
  m[U32.add(base, i)] <- bv
  (m, bv)

def pick.go?(m: Array<U32>, +base: U32, +i: U32, +j: U32, +n: U32, +bi: U32, +bv: U32, go: Bool) ->
  Array<U32> & U32:
  match go:
    case True{}:
      pick.v(base, i, j, n, bi, bv, m[U32.add(base, j)])
    case False{}:
      pick.fin(base, i, bi, bv, m[U32.add(base, i)])

def pick.v?(+base: U32, +i: U32, +j: U32, +n: U32, +bi: U32, +bv: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +v) = r
  +better = U32.is_gt(v, bv)
  pick.go(m, base, i, U32.add(j, 1), n, C.sel(better, j, bi), C.sel(better, v, bv),
    U32.is_lt(U32.add(j, 1), n))

def pick.a(+base: U32, +i: U32, +n: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  pick.go(m, base, i, U32.add(i, 1), n, i, v, U32.is_lt(U32.add(i, 1), n))

def pick(m: Array<U32>, +base: U32, +i: U32, +n: U32) -> Array<U32> & U32:
  pick.a(base, i, n, m[U32.add(base, i)])

def pv.copy?(m: Array<U32>, +dst: U32, +src: U32, +k: U32, +len: U32) -> Array<U32>:
  pv.copy.go(m, dst, src, k, len, U32.is_lt(k, len))

# Principal variation
# -------------------

def pv.copy.b?(+dst: U32, +src: U32, +k: U32, +len: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +v) = r
  m[U32.add(dst, k)] <- v
  pv.copy(m, dst, src, U32.add(k, 1), len)

def pv.copy.go?(m: Array<U32>, +dst: U32, +src: U32, +k: U32, +len: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      pv.copy.b(dst, src, k, len, m[U32.add(src, k)])

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

# Quiet-move statistics
# ---------------------
# history[side][from][to], continuation history [previous move key][move
# key] (key = piece (12) x target square (64); 768 = no previous move) and
# countermove[previous move key]; signed values in +-16384, updated with
# the gravity rule h += b - h*|b|/16384 (bonus for the move that caused a
# beta cutoff, malus for the quiet moves searched before it).

def QUIETS() -> U32:
  3145728

def CMOVE() -> U32:
  3153920

def grav(+h: U32, +b: U32) -> U32:
  +r = U32.add(h, U32.sub(b, C.s.div(U32.mul(h, C.s.abs(b)), 16384)))
  C.s.max(C.s.min(r, 16384), C.s.neg(16384))

def grav.b(+i: U32, +b: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +h) = r
  m[i] <- grav(h, b)
  m

def grav.at(m: Array<U32>, +i: U32, +b: U32) -> Array<U32>:
  grav.b(i, b, m[i])

def hbonus(+d: U32) -> U32:
  U32.min(U32.mul(U32.mul(d, d), 32), 1600)

def malus?(m: Array<U32>, +side: U32, +pk: U32, +qb: U32, +j: U32, +nq: U32, +b: U32) -> Array<U32>:
  malus.go(m, side, pk, qb, j, nq, b, U32.is_lt(j, nq))

# the malus pass over the quiet moves searched before the cutoff move
def malus.k?(+side: U32, +pk: U32, +qb: U32, +j: U32, +nq: U32, +b: U32, +mv: U32, r: Array<U32> & U32) ->
  Array<U32>:
  (m, +pc) = r
  m = grav.at(m, hist.idx(side, mv), C.s.neg(b))
  m = grav.at(m, ch.idx(pk, mkey(pc, C.mv.to(mv))), C.s.neg(b))
  malus(m, side, pk, qb, U32.add(j, 1), nq, b)

def malus.mv?(+side: U32, +pk: U32, +qb: U32, +j: U32, +nq: U32, +b: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +mv) = r
  malus.k(side, pk, qb, j, nq, b, mv, m[C.mv.from(mv)])

def malus.go?(m: Array<U32>, +side: U32, +pk: U32, +qb: U32, +j: U32, +nq: U32, +b: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      malus.mv(side, pk, qb, j, nq, b, m[U32.add(qb, j)])

def good_quiet.b(+side: U32, +ply: U32, +depth: U32, +mv: U32, +pk: U32, +nq: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +pc) = r
  +b = hbonus(depth)
  m = grav.at(m, hist.idx(side, mv), b)
  m = grav.at(m, ch.idx(pk, mkey(pc, C.mv.to(mv))), b)
  m[U32.add(CMOVE(), U32.min(pk, 768))] <- mv
  m = malus(m, side, pk, U32.add(QUIETS(), U32.shln(ply, 6n)), 0, U32.min(nq, 64), b)
  killer.b(ply, mv, m[U32.add(B.KILLERS(), U32.shln(ply, 1n))])

# a quiet move caused a beta cutoff: reward it, punish the quiets before it
def good_quiet(m: Array<U32>, +side: U32, +ply: U32, +depth: U32, +mv: U32, +pk: U32, +nq: U32) -> Array<U32>:
  +b = C.mv.bare(mv)
  good_quiet.b(side, ply, depth, b, pk, nq, m[C.mv.from(b)])

# LMR
# ---

# reduction for the i-th legal move at depth d: 0.75 + ln d * ln i / 2.25
def lmr.r(+d: U32, +i: U32) -> U32:
  +ld = T.lmr_ln(U32.to_nat(U32.min(d, 63)))
  +li = T.lmr_ln(U32.to_nat(U32.min(i, 63)))
  U32.shrn(U32.add(49152, U32.mul(ld, li)), 16n)

# Node context and loop state
# ---------------------------

# sx: singular-extension state of the node: a move with bit 31 set is
#     excluded (the node is a singularity verification search); a plain
#     move is extended by one ply; 0 none
type Nd is Data:
  Nd{p: B.Pos, depth: U32, beta: U32, ply: U32, fl: U32, ev: U32, n: U32, oalpha: U32, o: Opt, pk: U32, cm: U32,
     sx: U32}

type Lp is Data:
  Lp{alpha: U32, best: U32, bmv: U32, i: U32, legal: U32, quiets: U32, nq: U32}

def Lp.alpha(+x: Lp) -> U32:
  match x:
    case Lp{alpha, _, _, _, _, _, _}:
      alpha

def Lp.best(+x: Lp) -> U32:
  match x:
    case Lp{_, best, _, _, _, _, _}:
      best

def Lp.bmv(+x: Lp) -> U32:
  match x:
    case Lp{_, _, bmv, _, _, _, _}:
      bmv

def Lp.i(+x: Lp) -> U32:
  match x:
    case Lp{_, _, _, i, _, _, _}:
      i

def Lp.legal(+x: Lp) -> U32:
  match x:
    case Lp{_, _, _, _, legal, _, _}:
      legal

def Lp.quiets(+x: Lp) -> U32:
  match x:
    case Lp{_, _, _, _, _, quiets, _}:
      quiets

def Lp.skip(+x: Lp) -> Lp:
  match x:
    case Lp{alpha, best, bmv, i, legal, quiets, nq}:
      Lp{alpha, best, bmv, U32.add(i, 1), legal, quiets, nq}

def Lp.pruned(+x: Lp) -> Lp:
  match x:
    case Lp{alpha, best, bmv, i, legal, quiets, nq}:
      Lp{alpha, best, bmv, U32.add(i, 1), U32.add(legal, 1), U32.add(quiets, 1), nq}

def Nd.ply(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, ply, _, _, _, _, _, _, _, _}:
      ply

def Nd.fl(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, fl, _, _, _, _, _, _, _}:
      fl

def Nd.chk(+x: Nd) -> Bool:
  U32.is_ne(U32.and(Nd.fl(x), 2), 0)

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

def PK_NONE() -> U32:
  768

def Opt.a(+o: Opt) -> U32:
  match o:
    case Opt{a, _}:
      a

def opt.bits(+o: Opt, +sh: Nat, +mask: U32) -> U32:
  U32.and(U32.shrn(Opt.a(o), sh), mask)

def Opt.evm(+o: Opt) -> U32:
  opt.bits(o, 6n, 7)

# Correction history
# ------------------
# The static evaluation is corrected by a running average of (search
# result - static eval) over positions with the same pawn structure and
# side to move: 2 x 16384 entries in units of cp/16, learned during search
# from nodes whose result bound says the eval was too low / too high.
def CORR() -> U32:
  262144

def corr.idx(+p: B.Pos) -> U32:
  U32.add(CORR(), U32.add(U32.shln(B.P.side(p), 14n), U32.and(B.pawnkey(p), 16383)))

def ev.corr.b(+ev: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +c) = r
  (m, U32.add(ev, C.s.div(c, 16)))

def ev.corr(+p: B.Pos, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +ev) = r
  ev.corr.b(ev, m[corr.idx(p)])

def Nd.n(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, n, _, _, _, _, _}:
      n

def qs.tt.d?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt, +data: U32,
             r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sc0) = r
  +bnd = U32.and(U32.shrn(data, 17n), 3)
  +sc = tt.from(sc0, ply)
  +cut = U32.is_eq(U32.sub(beta, alpha), 1) &&
    (U32.is_eq(bnd, 3) || (U32.is_eq(bnd, 2) && C.s.ge(sc, beta)) || (U32.is_eq(bnd, 1) && C.s.le(sc, alpha)))
  qs.tt.e(m, p, alpha, beta, ply, chk, o, U32.and(data, 131071), sc, cut)

def qs.tt.c?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt, +i: U32,
             r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +data) = r
  qs.tt.d(p, alpha, beta, ply, chk, o, data, m[U32.add(i, 2)])

def qs.tt.b?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt, +i: U32,
             hit: Bool) -> Array<U32> & U32:
  match hit:
    case False{}:
      qs.ev(p, alpha, beta, ply, chk, o, 0, ev.corr(p, E.eval.lazy(m, p, Opt.evm(o), alpha, beta)))
    case True{}:
      qs.tt.c(p, alpha, beta, ply, chk, o, i, m[U32.add(i, 1)])

def qs.tt?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt, +i: U32,
           r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +lock) = r
  qs.tt.b(m, p, alpha, beta, ply, chk, o, i, U32.is_eq(lock, B.P.hhi(p)))

def qs.deep?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt,
             deep: Bool) -> Array<U32> & U32:
  match deep:
    case True{}:
      E.eval(m, p, Opt.evm(o))
    case False{}:
      +i = tt.idx(B.P.hlo(p))
      qs.tt(p, alpha, beta, ply, chk, o, i, m[i])

def qs.a?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt,
          r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      (m, 0)
    case (m, False{}):
      qs.deep(m, p, alpha, beta, ply, chk, o, U32.is_ge(ply, B.MAX_PLY()))

# selective depth: the deepest ply reached by quiescence this iteration
def seld.up?(+ply: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +sd) = r
  m[SELD()] <- U32.max(sd, ply)
  m

def qsearch?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt) ->
  Array<U32> & U32:
  m[U32.add(B.PVLEN(), ply)] <- 0
  m = seld.up(ply, m[SELD()])
  qs.a(p, alpha, beta, ply, chk, o, tick(m))

def Nd.beta(+x: Nd) -> U32:
  match x:
    case Nd{_, _, beta, _, _, _, _, _, _, _, _, _}:
      beta

def qs.cut?(m: Array<U32>, +nd: Nd, +lp: Lp, +best: U32, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, best)
    case False{}:
      qs.loop(m, nd, lp)

def qs.upd?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +s: U32) -> Array<U32> & U32:
  match lp:
    case Lp{alpha, best, bmv, i, legal, quiets, _}:
      +better = C.s.gt(s, best)
      +raise = C.s.gt(s, alpha)
      +best2 = C.sel(better, s, best)
      qs.cut(pv.upd.if(m, Nd.ply(nd), mv, raise), nd,
        Lp{C.sel(raise, s, alpha), best2, C.sel(better, mv, bmv), U32.add(i, 1), U32.add(legal, 1), quiets, 0},
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

def Nd.o(+x: Nd) -> Opt:
  match x:
    case Nd{_, _, _, _, _, _, _, _, o, _, _, _}:
      o

def qs.child?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, gc):
      qs.after(nd, lp, mv, np,
        qsearch(m, np, C.s.neg(Nd.beta(nd)), C.s.neg(Lp.alpha(lp)), U32.add(Nd.ply(nd), 1), gc, Nd.o(nd)))

def qs.gcx?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, special: Bool) -> Array<U32> & U32:
  match special:
    case True{}:
      qs.child(nd, lp, mv, np, G.in_check(m, np))
    case False{}:
      qs.child(nd, lp, mv, np, G.gchk.fast(m, np, mv))

def qs.legal?(+nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      qs.loop(B.unmake(m, np, mv), nd, Lp.skip(lp))
    case (m, False{}):
      qs.gcx(m, nd, lp, mv, np, G.gchk.special(mv))

def qs.ill?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, full: Bool) -> Array<U32> & U32:
  match full:
    case True{}:
      qs.legal(nd, lp, mv, np, G.left_in_check(m, np))
    case False{}:
      qs.legal(nd, lp, mv, np, G.pin.ill(m, np, mv))

def qs.made?(+nd: Nd, +lp: Lp, +mv: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  qs.ill(m, nd, lp, mv, np, G.illegal.full(np, mv, Nd.chk(nd)))

def Nd.p(+x: Nd) -> B.Pos:
  match x:
    case Nd{p, _, _, _, _, _, _, _, _, _, _, _}:
      p

def qs.seed.b?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, bad: Bool) -> Array<U32> & U32:
  match bad:
    case True{}:
      qs.loop(m, nd, Lp.pruned(lp))
    case False{}:
      qs.made(nd, lp, mv, B.make(m, Nd.p(nd), mv))

def qs.seed?(+nd: Nd, +lp: Lp, +mv: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sv) = r
  qs.seed.b(m, nd, lp, mv, C.s.lt(sv, 0))

def qs.seechk?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, test: Bool) -> Array<U32> & U32:
  match test:
    case False{}:
      qs.made(nd, lp, mv, B.make(m, Nd.p(nd), mv))
    case True{}:
      qs.seed(nd, lp, mv, G.see(m, Nd.p(nd), mv))

# delta pruning first (from the victim on the board: no SEE, no make):
# a capture that cannot lift the stand-pat score near alpha is skipped
def qs.fut.b?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, futile: Bool) -> Array<U32> & U32:
  match futile:
    case True{}:
      qs.loop(m, nd, Lp.pruned(lp))
    case False{}:
      qs.seechk(m, nd, lp, mv, Bool.not(Nd.chk(nd)) && Bool.not(C.mv.is_promo(mv)))

def Nd.ev(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, ev, _, _, _, _, _, _}:
      ev

def qs.fut?(+nd: Nd, +lp: Lp, +mv: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +vic) = r
  +vt = C.sel(U32.is_eq(C.mv.flag(mv), 3), 1, C.pc.type(vic))
  +gain = U32.add(pval(U32.to_nat(vt)), 200)
  qs.fut.b(m, nd, lp, mv, Bool.not(Nd.chk(nd)) && Bool.not(C.mv.is_promo(mv)) &&
    C.s.le(U32.add(Nd.ev(nd), gain), Lp.alpha(lp)))

def qs.picked?(+nd: Nd, +lp: Lp, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mvk) = r
  +mv = C.mv.bare(mvk)
  qs.fut(nd, lp, mv, m[C.mv.to(mv)])

def Nd.base(+x: Nd) -> U32:
  ply_moves(Nd.ply(x))

def qs.loop.go?(m: Array<U32>, +nd: Nd, +lp: Lp, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      qs.done(m, nd, lp)
    case True{}:
      qs.picked(nd, lp, pick(m, Nd.base(nd), Lp.i(lp), Nd.n(nd)))

def qs.loop?(m: Array<U32>, +nd: Nd, +lp: Lp) -> Array<U32> & U32:
  qs.loop.go(m, nd, lp, U32.is_lt(Lp.i(lp), Nd.n(nd)))

# node flags: pv | chk << 1 | improving << 2 (| danger << 3, set in sr.sx)
def nd.fl(+pv: Bool, +chk: Bool, +imp: Bool) -> U32:
  U32.or(C.b2u(pv), U32.or(U32.shln(C.b2u(chk), 1n), U32.shln(C.b2u(imp), 2n)))

def qs.gen?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32, +best: U32,
            +base: U32, +o: Opt, +ttm: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  m = ord(m, B.P.side(p), base, 0, n, ttm, 0, 0, PK_NONE(), 0)
  qs.loop(m, Nd{p, 0, beta, ply, nd.fl(False{}, chk, False{}), ev, n, alpha, o, 768, 0, 0}, Lp{alpha, best, 0, 0, 0, 0, 0})

def qs.stand?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
              +o: Opt, +ttm: U32, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, ev)
    case False{}:
      +stand = Bool.not(chk)
      +base = ply_moves(ply)
      qs.gen(p, C.sel(stand, C.s.max(alpha, ev), alpha), beta, ply, chk, ev,
        C.sel(stand, ev, U32.add(C.s.neg(C.MATE()), ply)), base, o, ttm,
        G.gen(m, p, base, C.sel(chk, 0, 1)))

def qs.ev?(+p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt, +ttm: U32,
           r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +ev) = r
  qs.stand(m, p, alpha, beta, ply, chk, ev, o, ttm, Bool.not(chk) && C.s.ge(ev, beta))

# quiescence TT probe: any stored entry is deep enough; at non-PV nodes a
# usable bound answers directly, otherwise the TT move is tried first
def qs.tt.e?(m: Array<U32>, +p: B.Pos, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +o: Opt,
             +ttm: U32, +sc: U32, cut: Bool) -> Array<U32> & U32:
  match cut:
    case True{}:
      (m, sc)
    case False{}:
      qs.ev(p, alpha, beta, ply, chk, o, ttm, ev.corr(p, E.eval.lazy(m, p, Opt.evm(o), alpha, beta)))

def corr.upd(+i: U32, +depth: U32, +diff: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +c) = r
  +d16 = U32.mul(C.s.max(C.s.min(diff, 400), C.s.neg(400)), 16)
  +w = U32.mul(U32.min(U32.add(depth, 1), 16), 8)
  m[i] <- C.s.max(C.s.min(U32.add(c, C.s.div(U32.mul(d16, w), 256)), 1536), C.s.neg(1536))
  m

def corr.if(m: Array<U32>, +p: B.Pos, +depth: U32, +diff: U32, go: Bool) -> Array<U32>:
  match go:
    case True{}:
      corr.upd(corr.idx(p), depth, diff, m[corr.idx(p)])
    case False{}:
      m

def Nd.sx(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, _, _, _, _, _, sx}:
      sx

# a real node (not a singularity verification search)
def Nd.real(+x: Nd) -> Bool:
  U32.is_zero(U32.and(Nd.sx(x), 2147483648))

def tt.store.if(m: Array<U32>, +p: B.Pos, +ply: U32, +depth: U32, +bound: U32, +score: U32, +mv: U32,
                go: Bool) -> Array<U32>:
  match go:
    case True{}:
      tt.store(m, p, ply, depth, bound, score, mv)
    case False{}:
      m

def Nd.depth(+x: Nd) -> U32:
  match x:
    case Nd{_, depth, _, _, _, _, _, _, _, _, _, _}:
      depth

def Nd.oalpha(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, _, oalpha, _, _, _, _}:
      oalpha

# Main search
# -----------

def sr.done.b(+nd: Nd, +lp: Lp, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +vic) = r
  +nolegal = U32.is_zero(Lp.legal(lp))
  +score = C.sel(nolegal, C.sel(Nd.chk(nd), U32.add(C.s.neg(C.MATE()), Nd.ply(nd)), 0), Lp.best(lp))
  +exact = C.s.gt(Lp.best(lp), Nd.oalpha(nd))
  +bound = C.sel(exact || nolegal, 3, 1)
  +ev = Nd.ev(nd)
  m = corr.if(m, Nd.p(nd), Nd.depth(nd), U32.sub(score, ev),
    Bool.not(nolegal) && Bool.not(Nd.chk(nd)) && C.s.lt(C.s.abs(score), C.MATE_BOUND()) &&
    ((exact && U32.is_zero(vic)) || (Bool.not(exact) && C.s.lt(score, ev))) && Nd.real(nd))
  (tt.store.if(m, Nd.p(nd), Nd.ply(nd), Nd.depth(nd), bound, score, Lp.bmv(lp), Nd.real(nd)), score)

def sr.done?(m: Array<U32>, +nd: Nd, +lp: Lp) -> Array<U32> & U32:
  sr.done.b(nd, lp, m[C.sq.safe(C.mv.to(Lp.bmv(lp)))])

def good_quiet.if(m: Array<U32>, +side: U32, +ply: U32, +depth: U32, +mv: U32, +pk: U32, +nq: U32, go: Bool) ->
  Array<U32>:
  match go:
    case True{}:
      good_quiet(m, side, ply, depth, mv, pk, nq)
    case False{}:
      m

# static eval of this ply is stored for the "improving" test: is the side
# to move better off than two plies ago? (no in-check evals)
def EV_NONE() -> U32:
  2147483648

# per-ply singular-extension slot (see Nd.sx)
def sx.slot(+ply: U32) -> U32:
  U32.add(B.PLYAUX(), U32.add(U32.shln(ply, 2n), 3))

def Lp.nq(+x: Lp) -> U32:
  match x:
    case Lp{_, _, _, _, _, _, nq}:
      nq

# record a searched quiet move (for the malus) unless it caused the cutoff
def rec.quiet(m: Array<U32>, +ply: U32, +nq: U32, +mv: U32, go: Bool) -> Array<U32>:
  match go:
    case True{}:
      m[U32.add(QUIETS(), U32.add(U32.shln(ply, 6n), U32.min(nq, 63)))] <- mv
      m
    case False{}:
      m

def Opt.prune(+o: Opt) -> Bool:
  U32.is_ne(opt.bits(o, 2n, 1), 0)

def Nd.pv(+x: Nd) -> Bool:
  U32.is_ne(U32.and(Nd.fl(x), 1), 0)

def sr.cm?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, +k1: U32, +k2: U32, +pk: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +cm) = r
  sr.imp(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, base, n, k1, k2, pk, cm,
    m[U32.add(B.PLYAUX(), U32.add(U32.shln(ply, 2n), 2))])

def sr.pk?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, +k1: U32, +k2: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +pk0) = r
  +pk = C.sel(U32.is_zero(ply), PK_NONE(), U32.min(pk0, 768))
  sr.cm(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, base, n, k1, k2, pk, m[U32.add(CMOVE(), pk)])

def sr.k2?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, +k1: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +k2) = r
  sr.pk(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, base, n, k1, k2, m[U32.add(B.PLYAUX(), U32.shln(ply, 2n))])

def sr.k1?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +k1) = r
  sr.k2(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, base, n, k1,
    m[U32.add(U32.add(B.KILLERS(), U32.shln(ply, 1n)), 1)])

def Opt.cas(+o: Opt) -> U32:
  opt.bits(o, 3n, 7)

# CAS level 3 (in-tree allocation): a node with at most 3 pseudo-legal
# moves is a forced line (cheap to resolve, often decisive): +1 ply
def sr.gen?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
            +pv: Bool, +ttm: U32, +o: Opt, +base: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  +ext = C.b2u(U32.is_ge(Opt.cas(o), 3) && U32.is_le(n, 3) && U32.is_lt(ply, 40))
  sr.k1(p, U32.add(depth, ext), alpha, beta, ply, chk, ev, pv, ttm, o, base, n,
    m[U32.add(B.KILLERS(), U32.shln(ply, 1n))])

# internal iterative reduction: without a TT move a deep node is likely
# mis-ordered, so it is searched one ply shallower
def sr.moves.go?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool,
                 +ev: U32, +pv: Bool, +ttm: U32, +o: Opt) -> Array<U32> & U32:
  +base = ply_moves(ply)
  +d2 = C.sel(U32.is_zero(ttm) && U32.is_ge(depth, 4), U32.sub(depth, 1), depth)
  sr.gen(p, d2, alpha, beta, ply, chk, ev, pv, ttm, o, base, G.gen(m, p, base, 0))

def se.go?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +sbeta: U32, single: Bool, mcut: Bool) -> Array<U32> & U32:
  match single mcut:
    case True{} _:
      m[sx.slot(ply)] <- ttm
      sr.moves.go(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o)
    case False{} True{}:
      (m, sbeta)
    case False{} False{}:
      sr.moves.go(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o)

# Singular extensions: at a deep node whose TT entry (deep enough, lower or
# exact bound) proposes ttm, search the other moves at half depth against
# sbeta = ttsc - 2 * depth. All failing low: ttm is singular and is
# extended by one ply. Failing high with sbeta >= beta: several moves beat
# beta (multi-cut), answer sbeta.
def se.res?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32, +pv: Bool,
            +ttm: U32, +o: Opt, +sbeta: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  +single = C.s.lt(v, sbeta)
  se.go(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, sbeta, single,
    Bool.not(single) && C.s.ge(sbeta, beta) && Bool.not(pv))

def se.run?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
            +pv: Bool, +ttm: U32, +o: Opt, +sc: U32, ok: Bool) -> Array<U32> & U32:
  match ok:
    case False{}:
      sr.moves.go(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o)
    case True{}:
      +sbeta = U32.sub(sc, U32.mul(depth, 2))
      m[sx.slot(ply)] <- U32.or(ttm, 2147483648)
      se.res(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, sbeta,
        sr.moves.go(m, p, U32.div(U32.sub(depth, 1), 2), U32.sub(sbeta, 1), sbeta, ply, chk, ev, False{}, ttm, o))

def se.d?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32, +pv: Bool,
          +ttm: U32, +o: Opt, +data: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sc0) = r
  +bnd = U32.and(U32.shrn(data, 17n), 3)
  +ttd = U32.and(U32.shrn(data, 19n), 255)
  +sc = tt.from(sc0, ply)
  se.run(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, sc,
    U32.is_eq(U32.and(data, 131071), ttm) && U32.is_ge(bnd, 2) && U32.is_ge(U32.add(ttd, 3), depth) &&
    C.s.lt(C.s.abs(sc), C.MATE_BOUND()))

def se.c?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32, +pv: Bool,
          +ttm: U32, +o: Opt, +i: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +data) = r
  se.d(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, data, m[U32.add(i, 2)])

def se.b?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
          +pv: Bool, +ttm: U32, +o: Opt, +i: U32, hit: Bool) -> Array<U32> & U32:
  match hit:
    case True{}:
      se.c(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, i, m[U32.add(i, 1)])
    case False{}:
      sr.moves.go(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o)

def se.a?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32, +pv: Bool,
          +ttm: U32, +o: Opt, +i: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +lock) = r
  se.b(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, i, U32.is_eq(lock, B.P.hhi(p)))

def se.chk?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
            +pv: Bool, +ttm: U32, +o: Opt, cand: Bool) -> Array<U32> & U32:
  match cand:
    case True{}:
      +i = tt.idx(B.P.hlo(p))
      se.a(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, i, m[i])
    case False{}:
      sr.moves.go(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o)

def sr.moves.x?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32, +pv: Bool,
                +ttm: U32, +o: Opt, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sx0) = r
  se.chk(m, p, depth, alpha, beta, ply, chk, ev, pv, ttm, o,
    U32.is_zero(sx0) && U32.is_ge(depth, 8) && U32.is_ne(ttm, 0) && U32.is_gt(ply, 0))

def sr.moves?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool,
              +ev: U32, +pv: Bool, +ttm: U32, +o: Opt) -> Array<U32> & U32:
  sr.moves.x(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, m[sx.slot(ply)])

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

# null move: the child has no previous-move context
def sr.nm.a?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
             +pv: Bool, +ttm: U32, +o: Opt, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  +red = U32.add(3, U32.div(depth, 6))
  m[U32.add(B.PLYAUX(), U32.shln(U32.add(ply, 1), 2n))] <- PK_NONE()
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

def Opt.null(+o: Opt) -> Bool:
  U32.is_ne(opt.bits(o, 0n, 1), 0)

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

# danger: the side to move faces a queen-backed king attack worth about
# 60 cp or more, or two or more threats against its pieces (E.DSTM)
def danger(+d: U32) -> Bool:
  U32.is_ge(U32.and(d, 255), 20) || U32.is_ge(U32.shrn(d, 8n), 2)

def sr.ev.i?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
             +ttm: U32, +o: Opt, +ev: U32, +dg: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +prev) = r
  +imp = U32.is_ge(ply, 2) && Bool.not(chk) && U32.is_ne(prev, EV_NONE()) && C.s.gt(ev, prev)
  m[U32.add(B.PLYAUX(), U32.add(U32.shln(ply, 2n), 2))] <- U32.or(C.b2u(imp), U32.shln(C.b2u(danger(dg)), 1n))
  +pv = U32.is_gt(U32.sub(beta, alpha), 1)
  +bmate = C.s.lt(C.s.abs(beta), C.MATE_BOUND())
  sr.rfp(m, p, depth, alpha, beta, ply, nullok, chk, ev, pv, ttm, o,
    Opt.prune(o) && Bool.not(pv) && Bool.not(chk) && U32.is_gt(ply, 0) && U32.is_le(depth, 7) &&
    bmate && C.s.ge(U32.sub(ev, U32.mul(75, sub0(depth, C.b2u(imp)))), beta))

def sr.ev.d?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
             +ttm: U32, +o: Opt, +ev: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +dg) = r
  sr.ev.i(p, depth, alpha, beta, ply, nullok, chk, ttm, o, ev, dg,
    m[U32.add(B.PLYAUX(), U32.add(U32.shln(C.sel(U32.is_ge(ply, 2), U32.sub(ply, 2), 127), 2n), 1))])

def sr.ev?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +nullok: Bool, +chk: Bool,
           +ttm: U32, +o: Opt, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +ev) = r
  m[U32.add(B.PLYAUX(), U32.add(U32.shln(ply, 2n), 1))] <- C.sel(chk, EV_NONE(), ev)
  sr.ev.d(p, depth, alpha, beta, ply, nullok, chk, ttm, o, ev, m[E.DSTM()])

def sr.noprobe?(m: Array<U32>, +p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32,
                +nullok: Bool, +chk: Bool, +ttm: U32, +o: Opt) -> Array<U32> & U32:
  sr.ev(p, depth, alpha, beta, ply, nullok, chk, ttm, o, ev.corr(p, E.eval(m, p, Opt.evm(o))))

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
  +ttd = U32.and(U32.shrn(data, 19n), 255)
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

def Nd.pk(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, _, _, _, pk, _, _}:
      pk

def sr.cut?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +s: U32, +quiet: Bool, cut: Bool) ->
  Array<U32> & U32:
  match cut:
    case False{}:
      sr.loop(m, nd, lp)
    case True{}:
      m = good_quiet.if(m, B.P.side(Nd.p(nd)), Nd.ply(nd), Nd.depth(nd), mv, Nd.pk(nd), Lp.nq(lp), quiet)
      m = corr.if(m, Nd.p(nd), Nd.depth(nd), U32.sub(s, Nd.ev(nd)),
        quiet && Bool.not(Nd.chk(nd)) && C.s.gt(s, Nd.ev(nd)) && C.s.lt(C.s.abs(s), C.MATE_BOUND()) && Nd.real(nd))
      (tt.store.if(m, Nd.p(nd), Nd.ply(nd), Nd.depth(nd), 2, s, mv, Nd.real(nd)), s)

def sr.upd?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +s: U32, +quiet: Bool) -> Array<U32> & U32:
  match lp:
    case Lp{alpha, best, bmv, i, legal, quiets, nq}:
      +better = C.s.gt(s, best)
      +raise = C.s.gt(s, alpha)
      +cut = C.s.ge(s, Nd.beta(nd))
      m = rec.quiet(m, Nd.ply(nd), nq, mv, quiet && Bool.not(cut))
      sr.cut(pv.upd.if(m, Nd.ply(nd), mv, raise), nd,
        Lp{C.sel(raise, s, alpha), C.sel(better, s, best), C.sel(better, mv, bmv), U32.add(i, 1),
          U32.add(legal, 1), U32.add(quiets, C.b2u(quiet)), U32.add(nq, C.b2u(quiet && Bool.not(cut)))},
        mv, s, quiet, cut)

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

def sr.re2.b?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +np: B.Pos, +quiet: Bool, +gc: Bool,
              +raw: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      sr.after(nd, lp, mv, np, quiet, (m, raw))
    case True{}:
      sr.after(nd, lp, mv, np, quiet,
        search(m, np, U32.add(sub0(Nd.depth(nd), 1), C.b2u(U32.is_eq(mv, Nd.sx(nd)))), C.s.neg(Nd.beta(nd)),
          C.s.neg(Lp.alpha(lp)), U32.add(Nd.ply(nd), 1), True{}, gc, Nd.o(nd)))

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
        search(m, np, U32.add(sub0(Nd.depth(nd), 1), C.b2u(U32.is_eq(mv, Nd.sx(nd)))), C.s.neg(Nd.beta(nd)),
          C.s.neg(Lp.alpha(lp)), U32.add(Nd.ply(nd), 1), True{}, gc, Nd.o(nd)))
    case False{}:
      +a = Lp.alpha(lp)
      sr.re1(nd, lp, mv, np, quiet, gc, red,
        search(m, np, sub0(sub0(Nd.depth(nd), 1), red), C.s.neg(U32.add(a, 1)), C.s.neg(a),
          U32.add(Nd.ply(nd), 1), True{}, gc, Nd.o(nd)))

def Opt.lmr(+o: Opt) -> Bool:
  U32.is_ne(opt.bits(o, 1n, 1), 0)

# the side to move is in danger (see danger): no late-move or history
# pruning, and late moves are reduced one ply less
def Nd.dng(+x: Nd) -> Bool:
  U32.is_ne(U32.and(Nd.fl(x), 8), 0)

# reduction for a late quiet move (0 when LMR does not apply). The ordering
# key (history + continuation history; killers/countermove high) shifts it:
# well-scoring quiets are reduced one ply less, badly scoring ones one more.
# CAS level 3 adds a ply in very wide nodes (> 40 moves).
def sr.red(+nd: Nd, +lp: Lp, +key: U32, +quiet: Bool, +gc: Bool) -> U32:
  +d = Nd.depth(nd)
  +k = U32.add(Lp.legal(lp), 1)
  +ok = Opt.lmr(Nd.o(nd)) && quiet && Bool.not(gc) && Bool.not(Nd.chk(nd)) &&
    U32.is_ge(d, 3) && U32.is_gt(k, 3)
  +wide = C.b2u(U32.is_ge(Opt.cas(Nd.o(nd)), 3) && U32.is_gt(Nd.n(nd), 40) && U32.is_gt(k, 8))
  +good = C.b2u(U32.is_ge(key, 13000))
  +poor = C.b2u(U32.is_lt(key, 5000))
  +r0 = U32.add(U32.add(sub0(sub0(sub0(lmr.r(d, k), C.b2u(Nd.pv(nd))), C.b2u(Nd.dng(nd))), good), wide), poor)
  C.sel(ok, U32.min(r0, sub0(d, 2)), 0)

def sr.prune?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +key: U32, +np: B.Pos, +quiet: Bool, +gc: Bool,
              prune: Bool) -> Array<U32> & U32:
  match prune:
    case True{}:
      sr.loop(B.unmake(m, np, mv), nd, Lp.pruned(lp))
    case False{}:
      sr.child(m, nd, lp, mv, np, quiet, gc, sr.red(nd, lp, key, quiet, gc), U32.is_zero(Lp.legal(lp)))

# late-move pruning threshold: more quiet moves are tried when improving
def lmp.max(+d: U32, +imp: Bool) -> U32:
  U32.div(U32.add(3, U32.mul(d, d)), C.sel(imp, 1, 2))

def Nd.imp(+x: Nd) -> Bool:
  U32.is_ne(U32.and(Nd.fl(x), 4), 0)

def sr.gc?(+nd: Nd, +lp: Lp, +mv: U32, +key: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +gc) = r
  +quiet = U32.is_zero(B.P.cap(np)) && Bool.not(C.mv.is_promo(mv))
  +d = Nd.depth(nd)
  +base = Opt.prune(Nd.o(nd)) && Bool.not(Nd.pv(nd)) && Bool.not(Nd.chk(nd)) && Bool.not(gc) &&
    U32.is_gt(Lp.legal(lp), 0) && U32.is_le(d, 3) &&
    C.s.gt(Lp.best(lp), C.s.neg(C.MATE_BOUND()))
  +futile = C.s.le(U32.add(Nd.ev(nd), U32.add(100, U32.mul(d, 120))), Lp.alpha(lp))
  +late = U32.is_ge(Lp.quiets(lp), lmp.max(d, Nd.imp(nd)))
  # history pruning: quiet moves with a clearly bad history score (the
  # ordering key encodes history + continuation history, 9000 = neutral)
  +hbad = U32.is_lt(key, U32.sub(9000, U32.mul(d, 1100)))
  # SEE pruning: captures re-keyed as losing by the lazy SEE
  +badcap = Bool.not(quiet) && U32.is_lt(key, 30)
  +calm = Bool.not(Nd.dng(nd))
  sr.prune(m, nd, lp, mv, key, np, quiet, gc, base && ((quiet && (futile || (calm && (late || hbad)))) || badcap))

def sr.gcx?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +key: U32, +np: B.Pos, special: Bool) -> Array<U32> & U32:
  match special:
    case True{}:
      sr.gc(nd, lp, mv, key, np, G.in_check(m, np))
    case False{}:
      sr.gc(nd, lp, mv, key, np, G.gchk.fast(m, np, mv))

def sr.legal?(+nd: Nd, +lp: Lp, +mv: U32, +key: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      sr.loop(B.unmake(m, np, mv), nd, Lp.skip(lp))
    case (m, False{}):
      sr.gcx(m, nd, lp, mv, key, np, G.gchk.special(mv))

# legality: the full attack scan only where needed (see G.illegal)
def sr.ill?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +key: U32, +np: B.Pos, full: Bool) -> Array<U32> & U32:
  match full:
    case True{}:
      sr.legal(nd, lp, mv, key, np, G.left_in_check(m, np))
    case False{}:
      sr.legal(nd, lp, mv, key, np, G.pin.ill(m, np, mv))

# after making a move at this node: tell the child which move led to it
def sr.made?(+nd: Nd, +lp: Lp, +mv: U32, +key: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  m[U32.add(B.PLYAUX(), U32.shln(U32.add(Nd.ply(nd), 1), 2n))] <- mkey(B.P.mvd(np), C.mv.to(mv))
  sr.ill(m, nd, lp, mv, key, np, G.illegal.full(np, mv, Nd.chk(nd)))

# Lazy SEE: a capture by a more valuable piece is checked by SEE only when
# the move picker reaches it; a losing one is re-keyed as a bad capture
# and the picker runs again (most nodes cut off before this happens)
def sr.pk.d?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +key: U32, +vic: U32, bad: Bool) -> Array<U32> & U32:
  match bad:
    case True{}:
      m[U32.add(Nd.base(nd), Lp.i(lp))] <- U32.or(mv, U32.shln(U32.add(20, C.pc.type(vic)), 17n))
      sr.loop(m, nd, lp)
    case False{}:
      sr.made(nd, lp, mv, key, B.make(m, Nd.p(nd), mv))

def sr.pk.s?(+nd: Nd, +lp: Lp, +mv: U32, +key: U32, +vic: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sv) = r
  sr.pk.d(m, nd, lp, mv, key, vic, C.s.lt(sv, 0))

def sr.pk.c?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +key: U32, +vic: U32, need: Bool) -> Array<U32> & U32:
  match need:
    case True{}:
      sr.pk.s(nd, lp, mv, key, vic, G.see(m, Nd.p(nd), mv))
    case False{}:
      sr.made(nd, lp, mv, key, B.make(m, Nd.p(nd), mv))

def sr.pk.at?(+nd: Nd, +lp: Lp, +mv: U32, +key: U32, +vic: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +att) = r
  sr.pk.c(m, nd, lp, mv, key, vic, U32.is_ne(vic, 0) &&
    U32.is_gt(G.see.val(U32.to_nat(C.pc.type(att))), G.see.val(U32.to_nat(C.pc.type(vic)))))

def sr.pk.v?(+nd: Nd, +lp: Lp, +mv: U32, +key: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +vic) = r
  sr.pk.at(nd, lp, mv, key, vic, m[C.mv.from(mv)])

def sr.pk.a?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +key: U32, capband: Bool) -> Array<U32> & U32:
  match capband:
    case True{}:
      sr.pk.v(nd, lp, mv, key, m[C.mv.to(mv)])
    case False{}:
      sr.made(nd, lp, mv, key, B.make(m, Nd.p(nd), mv))

def sr.pk.x?(m: Array<U32>, +nd: Nd, +lp: Lp, +mv: U32, +key: U32, skip: Bool) -> Array<U32> & U32:
  match skip:
    case True{}:
      sr.loop(m, nd, Lp.skip(lp))
    case False{}:
      sr.pk.a(m, nd, lp, mv, key, U32.is_ge(key, 20000) && U32.is_lt(key, 30000) && U32.is_lt(C.mv.flag(mv), 3))

def sr.picked?(+nd: Nd, +lp: Lp, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mvk) = r
  +mv = C.mv.bare(mvk)
  sr.pk.x(m, nd, lp, mv, U32.shrn(mvk, 17n), U32.is_eq(U32.or(mv, 2147483648), Nd.sx(nd)))

def sr.loop.go?(m: Array<U32>, +nd: Nd, +lp: Lp, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      sr.done(m, nd, lp)
    case True{}:
      sr.picked(nd, lp, pick(m, Nd.base(nd), Lp.i(lp), Nd.n(nd)))

def sr.loop?(m: Array<U32>, +nd: Nd, +lp: Lp) -> Array<U32> & U32:
  sr.loop.go(m, nd, lp, U32.is_lt(Lp.i(lp), Nd.n(nd)))

def sr.sx?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
           +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, +k1: U32, +k2: U32, +pk: U32, +cm: U32,
           +imp: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +sx) = r
  m[sx.slot(ply)] <- 0
  m = ord(m, B.P.side(p), base, 0, n, ttm, k1, k2, pk, cm)
  sr.loop(m, Nd{p, depth, beta, ply, U32.or(nd.fl(pv, chk, U32.is_ne(U32.and(imp, 1), 0)), U32.shln(U32.and(imp, 2), 2n)),
    ev, n, alpha, o, pk, cm, sx},
    Lp{alpha, U32.add(C.s.neg(C.INF()), 0), 0, 0, 0, 0, 0})

def sr.imp?(+p: B.Pos, +depth: U32, +alpha: U32, +beta: U32, +ply: U32, +chk: Bool, +ev: U32,
            +pv: Bool, +ttm: U32, +o: Opt, +base: U32, +n: U32, +k1: U32, +k2: U32, +pk: U32, +cm: U32,
            r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +imp) = r
  sr.sx(p, depth, alpha, beta, ply, chk, ev, pv, ttm, o, base, n, k1, k2, pk, cm, imp, m[sx.slot(ply)])

# Table maintenance
# -----------------

def fill?(m: Array<U32>, +i: U32, +end: U32, +v: U32) -> Array<U32>:
  fill.go(m, i, end, v, U32.is_lt(i, end))

def fill.go?(m: Array<U32>, +i: U32, +end: U32, +v: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      m[i] <- v
      fill(m, U32.add(i, 1), end, v)

def halve.go?(m: Array<U32>, +i: U32, +end: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      halve.b(i, end, m[i])

def halve?(m: Array<U32>, +i: U32, +end: U32) -> Array<U32>:
  halve.go(m, i, end, U32.is_lt(i, end))

def halve.b?(+i: U32, +end: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +v) = r
  m[i] <- C.s.shr(v, 1n)
  halve(m, U32.add(i, 1), end)

# before a search: new TT generation, age the histories, clear killers
def prep.b(r: Array<U32> & U32) -> Array<U32>:
  (m, +age) = r
  m[TTAGE()] <- U32.and(U32.add(age, 1), 31)
  m = halve(m, B.HISTORY(), U32.add(B.HISTORY(), 32768))
  fill(m, B.KILLERS(), U32.add(B.KILLERS(), 256), 0)

def prep(m: Array<U32>) -> Array<U32>:
  prep.b(m[TTAGE()])

# new game: clear TT, histories, killers, countermoves
def clear(m: Array<U32>) -> Array<U32>:
  m = fill(m, B.TT(), U32.add(B.TT(), 4194304), 0)
  m = fill(m, B.HISTORY(), U32.add(B.HISTORY(), 32768), 0)
  m = fill(m, CMOVE(), U32.add(CHIST(), 590592), 0)
  m = fill(m, CORR(), U32.add(CORR(), 32768), 0)
  fill(m, B.KILLERS(), U32.add(B.KILLERS(), 256), 0)

def Opt.b(+o: Opt) -> U32:
  match o:
    case Opt{_, b}:
      b

def Opt.tp(+o: Opt) -> U32:
  opt.bits(o, 9n, 7)

def Opt.th(+o: Opt) -> U32:
  opt.bits(o, 12n, 15)

def Opt.pr(+o: Opt) -> U32:
  opt.bits(o, 16n, 255)

def Opt.nt(+o: Opt) -> U32:
  U32.and(Opt.b(o), 65535)

def Opt.ss(+o: Opt) -> U32:
  U32.shrn(Opt.b(o), 16n)

def Opt.mk(+null: Bool, +lmr: Bool, +prune: Bool, +cas: U32, +evm: U32, +nt: U32, +ss: U32, +tp: U32, +th: U32,
           +pr: U32) -> Opt:
  +a = U32.or(U32.or(U32.or(C.b2u(null), U32.shln(C.b2u(lmr), 1n)), U32.or(U32.shln(C.b2u(prune), 2n),
    U32.shln(U32.min(cas, 7), 3n))), U32.or(U32.or(U32.shln(U32.min(evm, 7), 6n), U32.shln(U32.min(tp, 7), 9n)),
    U32.or(U32.shln(U32.min(th, 15), 12n), U32.shln(U32.min(pr, 255), 16n))))
  Opt{a, U32.or(U32.min(nt, 65535), U32.shln(U32.min(ss, 65535), 16n))}

def Opt.default() -> Opt:
  Opt.mk(True{}, True{}, True{}, 1, 0, 0, 100, 3, 1, 0)

def Nd.cm(+x: Nd) -> U32:
  match x:
    case Nd{_, _, _, _, _, _, _, _, _, _, cm, _}:
      cm
