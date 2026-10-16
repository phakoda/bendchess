# BendChess analysis: game-state report, complexity estimates and the
# ranked candidate-move table.
#
# Complexity quantities are kept apart and always labelled:
#   A  legal move sequences of length d (perft(d)): exact for small d,
#      extrapolated beyond with a measured-branching model (an estimate,
#      with an uncertainty band);
#   B  distinct positions reachable in exactly d plies: exact for small d
#      (hash set over the perft tree; positions identified by placement,
#      side to move, castling rights and a pseudo-legal ep square);
#   C  complete-game continuations: a Shannon-style order-of-magnitude
#      heuristic (expected remaining plies x mean log branching), NOT a
#      count, with a wide band;
#   D  search nodes needed to resolve the position: measured per
#      iteration, with the effective branching factor and the predicted
#      cost of the next iteration (and its error once it is known).

import Base
import ./core.bend as C
import ./board.bend as B
import ./movegen.bend as G
import ./eval.bend as E
import ./search.bend as S
import ./root.bend as R

# scratch slots: 16 piece counters
def SCR() -> U32:
  U32.add(B.SC(), 64)

# hash set for distinct-position counts: 2^19 entries x 2 words
def SET() -> U32:
  2097152

def SET_MASK() -> U32:
  524287

# count pieces by code into SCR[0..15]
def cnt?(m: Array<U32>, +lo: U32, +hi: U32) -> Array<U32>:
  cnt.go(m, lo, hi, U32.is_ne(lo, 0), U32.is_ne(hi, 0))

def cnt.inc?(+lo: U32, +hi: U32, +i: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +c) = r
  m[i] <- U32.add(c, 1)
  cnt(m, lo, hi)

# Material
# --------

def cnt.k?(+lo: U32, +hi: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +v) = r
  cnt.inc(lo, hi, U32.add(SCR(), v), m[U32.add(SCR(), v)])

def cnt.go?(m: Array<U32>, +lo: U32, +hi: U32, nzlo: Bool, nzhi: Bool) -> Array<U32>:
  match nzlo nzhi:
    case True{} _:
      cnt.k(U32.and(lo, U32.sub(lo, 1)), hi, m[C.sq.from64(B.ctz(lo))])
    case False{} True{}:
      cnt.k(lo, U32.and(hi, U32.sub(hi, 1)), m[C.sq.from64(U32.add(B.ctz(hi), 32))])
    case False{} False{}:
      m

def counts.o(m: Array<U32>, o: B.Occ) -> Array<U32>:
  match o:
    case B.Occ{w0, w1, b0, b1, _, _, _, _, _}:
      cnt(m, U32.or(w0, b0), U32.or(w1, b1))

def counts(m: Array<U32>, +p: B.Pos) -> Array<U32>:
  m = S.fill(m, SCR(), U32.add(SCR(), 16), 0)
  counts.o(m, B.P.occ(p))

# "P8 N2 B2 R2 Q1 (39)" for colour c, from the counters
def side.mat.e(+c: U32, +pn: U32, +nn: U32, +bn: U32, +rn: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +qn) = r
  +pts = U32.add(U32.add(pn, U32.mul(U32.add(nn, bn), 3)), U32.add(U32.mul(rn, 5), U32.mul(qn, 9)))
  (m, "P" ++ U32.show(pn) ++ " N" ++ U32.show(nn) ++ " B" ++ U32.show(bn) ++ " R" ++ U32.show(rn) ++
      " Q" ++ U32.show(qn) ++ " (" ++ U32.show(pts) ++ " pts)")

def side.mat.d(+c: U32, +pn: U32, +nn: U32, +bn: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +rn) = r
  side.mat.e(c, pn, nn, bn, rn, m[U32.add(SCR(), C.pc.make(c, 5))])

def side.mat.c(+c: U32, +pn: U32, +nn: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +bn) = r
  side.mat.d(c, pn, nn, bn, m[U32.add(SCR(), C.pc.make(c, 4))])

def side.mat.b(+c: U32, +pn: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +nn) = r
  side.mat.c(c, pn, nn, m[U32.add(SCR(), C.pc.make(c, 3))])

def side.mat.a(+c: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +pn) = r
  side.mat.b(c, pn, m[U32.add(SCR(), C.pc.make(c, 2))])

def side.mat(m: Array<U32>, +c: U32) -> Array<U32> & String:
  side.mat.a(c, m[U32.add(SCR(), C.pc.make(c, 1))])

def reps.go?(m: Array<U32>, +hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, +n: U32, go: Bool) ->
  Array<U32> & U32:
  match go:
    case False{}:
      (m, n)
    case True{}:
      reps.b(hlo, hhi, hidx, k, lim, n, m[S.rep.slot(hidx, k)])

# earlier occurrences of the current position (same side, rights, ep)
def reps?(m: Array<U32>, +hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, +n: U32) -> Array<U32> & U32:
  reps.go(m, hlo, hhi, hidx, k, lim, n, U32.is_le(k, lim))

# Repetitions of the current position in the game + search history
# ----------------------------------------------------------------

def reps.c?(+hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, +n: U32, +lo: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +hi) = r
  reps(m, hlo, hhi, hidx, U32.add(k, 2), lim, U32.add(n, C.b2u(U32.is_eq(lo, hlo) && U32.is_eq(hi, hhi))))

def reps.b?(+hlo: U32, +hhi: U32, +hidx: U32, +k: U32, +lim: U32, +n: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +lo) = r
  reps.c(hlo, hhi, hidx, k, lim, n, lo, m[U32.add(S.rep.slot(hidx, k), 1)])

# Legal move census: count, captures, checks, promotions
# ------------------------------------------------------

type Cen is Data:
  Cen{n: U32, caps: U32, chks: U32, proms: U32}

def cen.mk?(+p: B.Pos, +base: U32, +i: U32, +n: U32, +chk: Bool, cen: Cen, +mv: U32, r: Array<U32> & B.Pos) ->
  Array<U32> & Cen:
  (m, +np) = r
  cen.k(p, base, i, n, chk, cen, mv, np, G.illegal(m, np, mv, chk))

def cen.mv?(+p: B.Pos, +base: U32, +i: U32, +n: U32, +chk: Bool, cen: Cen, r: Array<U32> & U32) ->
  Array<U32> & Cen:
  (m, +mvk) = r
  +mv = C.mv.bare(mvk)
  cen.mk(p, base, i, n, chk, cen, mv, B.make(m, p, mv))

def cen.loop.go?(m: Array<U32>, +p: B.Pos, +base: U32, +i: U32, +n: U32, +chk: Bool, cen: Cen, go: Bool) ->
  Array<U32> & Cen:
  match go:
    case False{}:
      (m, cen)
    case True{}:
      cen.mv(p, base, i, n, chk, cen, m[U32.add(base, i)])

def cen.loop?(m: Array<U32>, +p: B.Pos, +base: U32, +i: U32, +n: U32, +chk: Bool, cen: Cen) -> Array<U32> & Cen:
  cen.loop.go(m, p, base, i, n, chk, cen, U32.is_lt(i, n))

def cen.gc?(+p: B.Pos, +base: U32, +i: U32, +n: U32, +chk: Bool, cen: Cen, +mv: U32, +np: B.Pos,
            r: Array<U32> & Bool) -> Array<U32> & Cen:
  match cen:
    case Cen{k, caps, chks, proms}:
      (m, +gc) = r
      cen.loop(B.unmake(m, np, mv), p, base, U32.add(i, 1), n, chk,
        Cen{U32.add(k, 1), U32.add(caps, C.b2u(U32.is_ne(B.P.cap(np), 0))), U32.add(chks, C.b2u(gc)),
          U32.add(proms, C.b2u(C.mv.is_promo(mv)))})

def cen.k?(+p: B.Pos, +base: U32, +i: U32, +n: U32, +chk: Bool, cen: Cen, +mv: U32, +np: B.Pos,
           r: Array<U32> & Bool) -> Array<U32> & Cen:
  match r:
    case (m, True{}):
      cen.loop(B.unmake(m, np, mv), p, base, U32.add(i, 1), n, chk, cen)
    case (m, False{}):
      cen.gc(p, base, i, n, chk, cen, mv, np, G.gchk(m, np, mv))

def cen.gen?(+p: B.Pos, +chk: Bool, r: Array<U32> & U32) -> Array<U32> & Cen:
  (m, +n) = r
  cen.loop(m, p, S.ply_moves(0), 0, n, chk, Cen{0, 0, 0, 0})

def census(m: Array<U32>, +p: B.Pos, +chk: Bool) -> Array<U32> & Cen:
  cen.gen(p, chk, G.gen(m, p, S.ply_moves(0), 0))

# insert (lo, hi) by linear probing; answers 1 when it was new
def set.ins?(m: Array<U32>, +lo: U32, +hi: U32, +i: U32) -> Array<U32> & U32:
  set.ins.c(lo, hi, i, m[U32.add(SET(), U32.shln(i, 1n))])

def set.ins.e?(m: Array<U32>, +lo: U32, +hi: U32, +i: U32, +k0: U32, +k1: U32, empty: Bool, same: Bool) ->
  Array<U32> & U32:
  match empty same:
    case True{} _:
      m[U32.add(SET(), U32.shln(i, 1n))] <- lo
      m[U32.add(SET(), U32.add(U32.shln(i, 1n), 1))] <- hi
      (m, 1)
    case False{} True{}:
      (m, 0)
    case False{} False{}:
      set.ins(m, lo, hi, U32.and(U32.add(i, 1), SET_MASK()))

# Distinct positions at depth d (exact): perft tree into a hash set
# ------------------------------------------------------------------

def set.ins.d?(+lo: U32, +hi: U32, +i: U32, +k0: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +k1) = r
  set.ins.e(m, lo, hi, i, k0, k1, U32.is_zero(k0) && U32.is_zero(k1), U32.is_eq(k0, lo) && U32.is_eq(k1, hi))

def set.ins.c?(+lo: U32, +hi: U32, +i: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +k0) = r
  set.ins.d(lo, hi, i, k0, m[U32.add(SET(), U32.add(U32.shln(i, 1n), 1))])

def up.gen?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +n) = r
  up.loop(m, p, depth, ply, base, chk, 0, n, 0, U32.is_lt(0, n))

def up.chk?(+p: B.Pos, +depth: U32, +ply: U32, r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +chk) = r
  +base = S.ply_moves(ply)
  up.gen(p, depth, ply, base, chk, G.gen(m, p, base, 0))

# new distinct positions (inserted into the set) among the leaves at depth
def uperft?(m: Array<U32>, +p: B.Pos, +depth: U32, +ply: U32) -> Array<U32> & U32:
  up.chk(p, depth, ply, G.in_check(m, p))

def up.sub?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
            +mv: U32, +np: B.Pos, m: Array<U32>, leaf: Bool) -> Array<U32> & U32:
  match leaf:
    case True{}:
      +lo = B.P.hlo(np)
      up.add(p, depth, ply, base, chk, i, n, acc, mv, np,
        set.ins(m, lo, B.P.hhi(np), U32.and(U32.xor(lo, U32.shrn(lo, 13n)), SET_MASK())))
    case False{}:
      up.add(p, depth, ply, base, chk, i, n, acc, mv, np, uperft(m, np, U32.sub(depth, 1), U32.add(ply, 1)))

def up.legal?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
              +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      up.next(p, depth, ply, base, chk, i, n, acc, B.unmake(m, np, mv))
    case (m, False{}):
      up.sub(p, depth, ply, base, chk, i, n, acc, mv, np, m, U32.is_eq(depth, 1))

def up.made?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
             +mv: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  up.legal(p, depth, ply, base, chk, i, n, acc, mv, np, G.illegal(m, np, mv, chk))

def up.mv?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
           r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mv) = r
  up.made(p, depth, ply, base, chk, i, n, acc, mv, B.make(m, p, mv))

def up.loop?(m: Array<U32>, +p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32,
             +acc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      up.mv(p, depth, ply, base, chk, i, n, acc, m[U32.add(base, i)])

def up.next?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
             m: Array<U32>) -> Array<U32> & U32:
  up.loop(m, p, depth, ply, base, chk, U32.add(i, 1), n, acc, U32.is_lt(U32.add(i, 1), n))

def up.add?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
            +mv: U32, +np: B.Pos, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +c) = r
  up.next(p, depth, ply, base, chk, i, n, U32.add(acc, c), B.unmake(m, np, mv))

# distinct positions exactly `depth` plies from p (set cleared first)
def distinct(m: Array<U32>, +p: B.Pos, +depth: U32) -> Array<U32> & U32:
  uperft(S.fill(m, SET(), U32.add(SET(), 1048576), 0), p, depth, 0)

# Numbers to text
# ---------------

# F32 with one decimal
def f1(+x: F32) -> String:
  +t = F32.to_u32((x * 10.0 + 0.5 : F32))
  U32.show(U32.div(t, 10)) ++ "." ++ U32.show(U32.mod(t, 10))

def log10u(+x: U32) -> F32:
  F32.log10(U32.to_f32(U32.max(x, 1)))

# Branching model for quantity A beyond the exact horizon
# -------------------------------------------------------
# With exact perft counts N1..Nk (k >= 2) the per-ply branching ratios
# r_j = N_j / N_(j-1) alternate between the two sides; plies beyond k
# reuse the last ratio of the same side. The band is the drift between the
# last two same-side ratios, compounded over the extrapolated plies.

def est.a(+lnk: F32, +la: F32, +lb: F32, +k: U32, +d: U32) -> F32:
  +extra = U32.to_f32(S.sub0(d, k))
  +half_a = F32.floor(((extra + 1.0) / 2.0 : F32))
  +half_b = F32.floor((extra / 2.0 : F32))
  (lnk + half_a * la + half_b * lb : F32)

# Report text
# -----------

def yesno(b: Bool) -> String:
  match b:
    case True{}:
      "yes"
    case False{}:
      "no"

def side.name.go(w: Bool) -> String:
  match w:
    case True{}:
      "white"
    case False{}:
      "black"

def side.name(+c: U32) -> String:
  side.name.go(U32.is_zero(c))

def phase.name.go(open: Bool, mid: Bool) -> String:
  match open mid:
    case True{} _:
      "opening"
    case False{} True{}:
      "middlegame"
    case False{} False{}:
      "endgame"

def phase.name(+ph: U32) -> String:
  phase.name.go(U32.is_ge(ph, 18), U32.is_ge(ph, 8))

def say(s: String) -> String:
  "info string " ++ s ++ "\n"

def fl.c(b: Bool) -> String:
  match b:
    case True{}:
      "x"
    case False{}:
      "-"

def fl.k(b: Bool) -> String:
  match b:
    case True{}:
      "+"
    case False{}:
      "-"

def fl.p(b: Bool) -> String:
  match b:
    case True{}:
      "="
    case False{}:
      "-"

# The ranked candidate table (from the root table)
# ------------------------------------------------

def flag.str(+f: U32) -> String:
  fl.c(U32.is_ne(U32.and(f, 1), 0)) ++ fl.k(U32.is_ne(U32.and(f, 2), 0)) ++ fl.p(U32.is_ne(U32.and(f, 4), 0))

def bound.str.go(exact: Bool, lower: Bool) -> String:
  match exact lower:
    case True{} _:
      " "
    case False{} True{}:
      ">"
    case False{} False{}:
      "<"

def bound.str(+b: U32) -> String:
  bound.str.go(U32.is_eq(b, 3), U32.is_eq(b, 2))

def pad(+s: String, +w: U32) -> String:
  s ++ String.repeat(" ", U32.to_nat(S.sub0(w, U32.from_nat(String.length(s)))))

def row.f4?(+i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, +mv: U32, +sc: U32, +nodes: U32,
            +bnd: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +rep) = r
  row.f5(i, n, k, best, mean, acc, mv, sc, nodes, bnd, rep, m[R.rslot(i, 5)])

def row.f3?(+i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, +mv: U32, +sc: U32, +nodes: U32,
            r: Array<U32> & U32) -> Array<U32> & String:
  (m, +bnd) = r
  row.f4(i, n, k, best, mean, acc, mv, sc, nodes, bnd, m[R.rslot(i, 4)])

def row.f2?(+i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, +mv: U32, +sc: U32,
            r: Array<U32> & U32) -> Array<U32> & String:
  (m, +nodes) = r
  row.f3(i, n, k, best, mean, acc, mv, sc, nodes, m[R.rslot(i, 3)])

def row.f1?(+i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, +mv: U32, r: Array<U32> & U32) ->
  Array<U32> & String:
  (m, +sc) = r
  row.f2(i, n, k, best, mean, acc, mv, sc, m[R.rslot(i, 2)])

def row.f0?(+i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, r: Array<U32> & U32) ->
  Array<U32> & String:
  (m, +mv) = r
  row.f1(i, n, k, best, mean, acc, mv, m[R.rslot(i, 1)])

def rows.go?(m: Array<U32>, +i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, go: Bool) ->
  Array<U32> & String:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      row.f0(i, n, k, best, mean, acc, m[R.rslot(i, 0)])

def rows?(m: Array<U32>, +i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String) -> Array<U32> & String:
  rows.go(m, i, n, k, best, mean, acc, U32.is_lt(i, U32.min(n, k)))

def row.f7?(+i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, +mv: U32, +sc: U32, +nodes: U32,
            +bnd: U32, +rep: U32, +fl: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +fluct) = r
  +pr = R.prio(best, sc, fluct)
  +line = pad(U32.show(U32.add(i, 1)) ++ ".", 5) ++ pad(B.mv.uci(mv), 7) ++
    pad(bound.str(bnd) ++ C.s.show(sc), 8) ++ pad(U32.show(nodes), 11) ++ pad(U32.show(rep), 9) ++
    pad(flag.str(fl), 7) ++ pad(U32.show(fluct), 7) ++ pad(U32.show(pr), 6) ++ U32.show(R.voi(pr, nodes, mean))
  rows(m, U32.add(i, 1), n, k, best, mean, acc ++ say(line))

def row.f5?(+i: U32, +n: U32, +k: U32, +best: U32, +mean: U32, acc: String, +mv: U32, +sc: U32, +nodes: U32,
            +bnd: U32, +rep: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +fl) = r
  row.f7(i, n, k, best, mean, acc, mv, sc, nodes, bnd, rep, fl, m[R.rslot(i, 7)])

def table.c(+n: U32, +k: U32, +best: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +mean) = r
  rows(m, 0, n, k, best, mean,
    say("rank move   score   nodes      replies  flags  fluct  prio  voi") ++
    say("     (score: search value for the side to move, cp; '<' upper bound, '>' lower bound;") ++
    say("      flags: x capture, + check, = promotion; replies: opponent legal moves after it;") ++
    say("      fluct: score change across iterations; prio/voi: search-priority estimates)"))

def table.b(+k: U32, +n: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +best) = r
  table.c(n, k, best, R.mean(m, 0, n, 0))

def table.a(+k: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +n) = r
  table.b(k, n, m[R.rslot(0, 1)])

# the top k rows of the root table, as info strings
def table(m: Array<U32>, +k: U32) -> Array<U32> & String:
  table.a(k, m[R.RN()])
