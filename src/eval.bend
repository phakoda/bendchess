# BendChess evaluation.
#
# score = PeSTO (tapered piece-square tables incl. material, kept
#         incrementally in Pos) + sum_i w_i * f_i (tapered mg/eg weights)
#
# The f_i are white-minus-black feature counts (see FEATURES below); the
# weights live in weights.bend (generated from tools/weights.json, which
# tools/tune.py can refit). With a weight set ws > 0 the weights become the
# one-hot vector e_(ws-1) and PeSTO is left out, so eval.white(m, p, k)
# answers feature k-1 itself: the feature dump used by the learning
# pipeline is the evaluation code, not a reimplementation.
#
# FEATURES (index: meaning)
#   0..5  passed pawn on relative rank 2..7 (index = relative rank - 1)
#   6     isolated pawn          7  doubled pawn (one per extra pawn)
#   8     bishop pair            9  rook on open file
#   10    rook on semi-open file 11 rook on the 7th rank
#   12..15 mobility of knight, bishop, rook, queen (squares reachable:
#         empty or enemy-occupied)
#   16    king attack: (sum of attack units on the enemy king zone)^2 / 8,
#         capped, counted only with 2+ attackers
#   17    pawn shield: own pawns 1-2 ranks in front of a castled-rank king
#
# All scores are centipawns, two's complement in a U32.

import Base
import ./core.bend as C
import ./board.bend as B
import ./weights.bend as W

def TEMPO() -> U32:
  10

# white-relative tapered score of mg/eg at phase ph (0..24, 24 = opening)
def taper(+mg: U32, +eg: U32, +ph0: U32) -> U32:
  +ph = U32.min(ph0, 24)
  C.s.div(U32.add(U32.mul(mg, ph), U32.mul(eg, U32.sub(24, ph))), 24)

# PeSTO only, side-to-move relative
def pesto(+p: B.Pos) -> U32:
  U32.add(B.neg_if(taper(B.P.mg(p), B.P.eg(p), B.P.ph(p)), B.P.side(p)), TEMPO())

# Pawn structure from the pawn bitboards
# --------------------------------------
# All pawn terms are bit arithmetic on the lo/hi halves of the pawn
# bitboards kept incrementally in Pos (no board reads).

type BB is Data:
  BB{lo: U32, hi: U32}

def NOT_A() -> U32:
  4278124286

def NOT_H() -> U32:
  2139062143

# squares strictly north of (in front of, for white) the set bits
def nfill(+lo: U32, +hi: U32) -> BB:
  +l1 = U32.shln(lo, 8n)
  +h1 = U32.or(U32.shln(hi, 8n), U32.shrn(lo, 24n))
  +l2 = U32.or(l1, U32.shln(l1, 8n))
  +h2 = U32.or(U32.or(h1, U32.shln(h1, 8n)), U32.shrn(l1, 24n))
  +l3 = U32.or(l2, U32.shln(l2, 16n))
  +h3 = U32.or(U32.or(h2, U32.shln(h2, 16n)), U32.shrn(l2, 16n))
  BB{l3, U32.or(h3, l3)}

# squares strictly south of the set bits
def sfill(+lo: U32, +hi: U32) -> BB:
  +l1 = U32.or(U32.shrn(lo, 8n), U32.shln(hi, 24n))
  +h1 = U32.shrn(hi, 8n)
  +l2 = U32.or(U32.or(l1, U32.shrn(l1, 8n)), U32.shln(h1, 24n))
  +h2 = U32.or(h1, U32.shrn(h1, 8n))
  +l3 = U32.or(U32.or(l2, U32.shrn(l2, 16n)), U32.shln(h2, 16n))
  +h3 = U32.or(h2, U32.shrn(h2, 16n))
  BB{U32.or(l3, h3), h3}

# x plus its east and west neighbours (one half-board)
def span(+x: U32) -> U32:
  U32.or(x, U32.or(U32.and(U32.shln(x, 1n), NOT_A()), U32.and(U32.shrn(x, 1n), NOT_H())))

# the files that hold a set bit, as a byte
def files(+lo: U32, +hi: U32) -> U32:
  +x = U32.or(lo, hi)
  +y = U32.or(x, U32.shrn(x, 16n))
  U32.and(U32.or(y, U32.shrn(y, 8n)), 255)

# a file byte repeated on every rank
def fmask(+f: U32) -> U32:
  U32.mul(f, 16843009)

# number of set bits on rank r (0..7)
def rankcnt(+lo: U32, +hi: U32, +r: U32) -> U32:
  B.popcnt(U32.and(U32.shrn(C.sel(U32.is_lt(r, 4), lo, hi), U32.to_nat(U32.shln(U32.and(r, 3), 3n))), 255))

def pc64(+lo: U32, +hi: U32) -> U32:
  U32.add(B.popcnt(lo), B.popcnt(hi))

# Accumulator
# -----------
# mg, eg: white-relative weighted sums; wu/bu: attack units of white/black
# pieces on the enemy king zone; wn/bn: number of such attackers; wb/bb:
# bishop counts.

type Ev is Data:
  Ev{mg: U32, eg: U32, wu: U32, wn: U32, bu: U32, bn: U32, wb: U32, bb: U32}

def wmg(+ws: U32, +i: U32) -> U32:
  +k = U32.and(ws, 255)
  C.sel(U32.is_zero(k), W.w_mg(U32.to_nat(i)), C.b2u(U32.is_eq(k, U32.add(i, 1))))

def weg(+ws: U32, +i: U32) -> U32:
  +k = U32.and(ws, 255)
  C.sel(U32.is_zero(k), W.w_eg(U32.to_nat(i)), C.b2u(U32.is_eq(k, U32.add(i, 1))))

# cnt occurrences of feature i for colour c
def ev.add(ev: Ev, +ws: U32, +i: U32, +cnt: U32, +c: U32) -> Ev:
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn, wb, bb}:
      Ev{U32.add(mg, B.neg_if(U32.mul(cnt, wmg(ws, i)), c)), U32.add(eg, B.neg_if(U32.mul(cnt, weg(ws, i)), c)),
        wu, wn, bu, bn, wb, bb}

# white-minus-black occurrences of feature i
def ev.add2(ev: Ev, +ws: U32, +i: U32, +wc: U32, +bc: U32) -> Ev:
  ev.add(ev.add(ev, ws, i, wc, 0), ws, i, bc, 1)

# a colour-c piece puts `units` attack units on the enemy king zone
def ev.att(+ev: Ev, +c: U32, +units: U32) -> Ev:
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn, wb, bb}:
      +w = U32.is_zero(c)
      +hit = C.b2u(U32.is_gt(units, 0))
      Ev{mg, eg, C.sel(w, U32.add(wu, units), wu), C.sel(w, U32.add(wn, hit), wn),
        C.sel(w, bu, U32.add(bu, units)), C.sel(w, bn, U32.add(bn, hit)), wb, bb}

# a colour-c bishop
def ev.bis(ev: Ev, +c: U32) -> Ev:
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn, wb, bb}:
      +w = C.b2u(U32.is_zero(c))
      Ev{mg, eg, wu, wn, bu, bn, U32.add(wb, w), U32.add(bb, U32.sub(1, w))}

# Pawn terms
# ----------
# passed pawns by relative rank (features 0..5): white pawns on rank i+1,
# black pawns on rank 6-i
def pawn.passed(ev: Ev, +ws: U32, +wlo: U32, +whi: U32, +blo: U32, +bhi: U32, +i: U32) -> Ev:
  ev.add2(ev, ws, i, rankcnt(wlo, whi, U32.add(i, 1)), rankcnt(blo, bhi, U32.sub(6, i)))

# pawns with no own pawn on an adjacent file (feature 6)
def iso(+lo: U32, +hi: U32) -> U32:
  +f = files(lo, hi)
  +m = fmask(U32.and(f, U32.not(U32.or(U32.shln(f, 1n), U32.shrn(f, 1n)))))
  pc64(U32.and(lo, m), U32.and(hi, m))

# pawns behind another pawn of the same colour on the same file (feature 7)
def dbl(+lo: U32, +hi: U32) -> U32:
  U32.sub(pc64(lo, hi), B.popcnt(files(lo, hi)))

# the files f-1..f+1 as a byte
def adj3(+f: U32) -> U32:
  U32.and(U32.shrn(U32.shln(7, U32.to_nat(f)), 1n), 255)

# pawn shield (feature 17): rearmost own pawns 1-2 ranks in front of a
# king standing on its first two ranks, on the king file and its neighbours
def shield.w(+k: U32, +rlo: U32) -> U32:
  +r = C.sq.rank(k)
  +a = adj3(C.sq.file(k))
  +z = U32.or(U32.shln(a, U32.to_nat(U32.and(U32.shln(U32.add(r, 1), 3n), 31))),
    U32.shln(a, U32.to_nat(U32.and(U32.shln(U32.add(r, 2), 3n), 31))))
  U32.and(B.popcnt(U32.and(rlo, z)), C.bmask(U32.is_le(r, 1)))

def shield.b(+k: U32, +rhi: U32) -> U32:
  +r = C.sq.rank(k)
  +a = adj3(C.sq.file(k))
  +z = U32.or(U32.shln(a, U32.to_nat(U32.and(U32.shln(U32.sub(r, 5), 3n), 31))),
    U32.shln(a, U32.to_nat(U32.and(U32.shln(U32.sub(r, 6), 3n), 31))))
  U32.and(B.popcnt(U32.and(rhi, z)), C.bmask(U32.is_ge(r, 6)))

# nw: squares north of white pawns, sb: squares south of black pawns
def pawns.c(ev: Ev, +ws: U32, +p: B.Pos, +wlo: U32, +whi: U32, +blo: U32, +bhi: U32, nw: BB, sb: BB) -> Ev:
  match nw sb:
    case BB{+nlo, +nhi} BB{+slo, +shi}:
      +pwl = U32.and(wlo, U32.not(span(slo)))
      +pwh = U32.and(whi, U32.not(span(shi)))
      +pbl = U32.and(blo, U32.not(span(nlo)))
      +pbh = U32.and(bhi, U32.not(span(nhi)))
      e0 = pawn.passed(ev, ws, pwl, pwh, pbl, pbh, 0)
      e1 = pawn.passed(e0, ws, pwl, pwh, pbl, pbh, 1)
      e2 = pawn.passed(e1, ws, pwl, pwh, pbl, pbh, 2)
      e3 = pawn.passed(e2, ws, pwl, pwh, pbl, pbh, 3)
      e4 = pawn.passed(e3, ws, pwl, pwh, pbl, pbh, 4)
      e5 = pawn.passed(e4, ws, pwl, pwh, pbl, pbh, 5)
      e6 = ev.add2(e5, ws, 6, iso(wlo, whi), iso(blo, bhi))
      e7 = ev.add2(e6, ws, 7, dbl(wlo, whi), dbl(blo, bhi))
      ev.add2(e7, ws, 17, shield.w(B.P.wk(p), U32.and(wlo, U32.not(nlo))),
        shield.b(B.P.bk(p), U32.and(bhi, U32.not(shi))))

def pawns(ev: Ev, +ws: U32, +p: B.Pos, +wlo: U32, +whi: U32, +blo: U32, +bhi: U32) -> Ev:
  pawns.c(ev, ws, p, wlo, whi, blo, bhi, nfill(wlo, whi), sfill(blo, bhi))

# 256 when square t touches the king square ek, else 0
def zone256(+t: U32, +ek: U32) -> U32:
  C.sel(U32.is_ne(U32.and(B.dinfo(t, ek), 32), 0), 256, 0)

# Mobility walks
# --------------
# acc packs reachable squares (low byte) and king-zone hits (<< 8).

def mob.walk.d?(m: Array<U32>, +t: U32, +d: U32, +len: U32, +c: U32, +ek: U32, +acc: U32, +v: U32,
                ok: Bool, empty: Bool) -> Array<U32> & U32:
  match ok empty:
    case False{} _:
      (m, acc)
    case True{} True{}:
      mob.walk(m, U32.add(t, d), d, U32.sub(len, 1), c, ek, U32.add(acc, U32.add(1, zone256(t, ek))))
    case True{} False{}:
      (m, U32.add(acc, U32.add(zone256(t, ek), C.b2u(U32.is_ne(C.pc.color(v), c)))))

def mob.walk.c?(+t: U32, +d: U32, +len: U32, +c: U32, +ek: U32, +acc: U32, ok: Bool,
                r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  mob.walk.d(m, t, d, len, c, ek, acc, v, ok, U32.is_zero(v))

def mob.walk?(m: Array<U32>, +t: U32, +d: U32, +len: U32, +c: U32, +ek: U32, +acc: U32) ->
  Array<U32> & U32:
  mob.walk.c(t, d, len, c, ek, acc, C.sq.ok(t) && U32.is_gt(len, 0), m[C.sq.safe(t)])

def mob.dirs.k?(+sq: U32, +c: U32, +ek: U32, +di: U32, +de: U32, +len: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +acc) = r
  mob.dirs(m, sq, c, ek, U32.add(di, 1), de, len, acc)

def mob.dirs.go?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, +di: U32, +de: U32, +len: U32, +acc: U32,
                 go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      +d = B.dir(U32.to_nat(di))
      mob.dirs.k(sq, c, ek, di, de, len, mob.walk(m, U32.add(sq, d), d, len, c, ek, acc))

def mob.dirs?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, +di: U32, +de: U32, +len: U32, +acc: U32) ->
  Array<U32> & U32:
  mob.dirs.go(m, sq, c, ek, di, de, len, acc, U32.is_lt(di, de))

# rook on an open / semi-open file and on the 7th rank; fl holds the white
# pawn files (low byte) and the black pawn files (next byte)
def rook.ev(ev: Ev, +ws: U32, +sq: U32, +c: U32, +fl: U32) -> Ev:
  +f = C.sq.file(sq)
  +w = U32.is_zero(c)
  +own = U32.and(U32.shrn(C.sel(w, fl, U32.shrn(fl, 8n)), U32.to_nat(f)), 1)
  +their = U32.and(U32.shrn(C.sel(w, U32.shrn(fl, 8n), fl), U32.to_nat(f)), 1)
  +rr = C.sel(w, C.sq.rank(sq), U32.sub(7, C.sq.rank(sq)))
  +open = U32.is_zero(own) && U32.is_zero(their)
  +semi = U32.is_zero(own) && U32.is_ne(their, 0)
  ev.add(ev.add(ev.add(ev, ws, 9, C.b2u(open), c), ws, 10, C.b2u(semi), c), ws, 11,
    C.b2u(U32.is_eq(rr, 6)), c)

# attack-unit weight per zone square, by piece type
def att.w(t: Nat) -> U32:
  match t:
    case 2n:
      2
    case 3n:
      2
    case 4n:
      3
    case 5n:
      5
    case _:
      0

# fold a mobility walk result into the accumulator
def mob.fin(ev: Ev, +ws: U32, +c: U32, +t: U32, r: Array<U32> & U32) -> Array<U32> & Ev:
  (m, +acc) = r
  (m, ev.att(ev.add(ev, ws, U32.add(t, 10), U32.and(acc, 255), c), c,
    U32.mul(U32.shrn(acc, 8n), att.w(U32.to_nat(t)))))

# ws bit 8 (256) selects the light evaluation: no mobility / king-zone walks
def light(+ws: U32) -> Bool:
  U32.is_ne(U32.and(ws, 256), 0)

# Pass B: the pieces other than pawns
# -----------------------------------

def pb.type.light(m: Array<U32>, +sq: U32, +c: U32, ev: Ev, +ws: U32, +fl: U32, t: Nat) -> Array<U32> & Ev:
  match t:
    case 3n:
      (m, ev.bis(ev, c))
    case 4n:
      (m, rook.ev(ev, ws, sq, c, fl))
    case _:
      (m, ev)

def pb.type.full?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, ev: Ev, +ws: U32, +fl: U32, t: Nat) ->
  Array<U32> & Ev:
  match t:
    case 2n:
      mob.fin(ev, ws, c, 2, mob.dirs(m, sq, c, ek, 8, 16, 1, 0))
    case 3n:
      mob.fin(ev.bis(ev, c), ws, c, 3, mob.dirs(m, sq, c, ek, 4, 8, 8, 0))
    case 4n:
      mob.fin(rook.ev(ev, ws, sq, c, fl), ws, c, 4, mob.dirs(m, sq, c, ek, 0, 4, 8, 0))
    case 5n:
      mob.fin(ev, ws, c, 5, mob.dirs(m, sq, c, ek, 0, 8, 8, 0))
    case _:
      (m, ev)

def pb.type.l?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, ev: Ev, +ws: U32, +fl: U32, t: Nat, lt: Bool) ->
  Array<U32> & Ev:
  match lt:
    case True{}:
      pb.type.light(m, sq, c, ev, ws, fl, t)
    case False{}:
      pb.type.full(m, sq, c, ek, ev, ws, fl, t)

def pb.type?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, ev: Ev, +ws: U32, +fl: U32, t: Nat) ->
  Array<U32> & Ev:
  pb.type.l(m, sq, c, ek, ev, ws, fl, t, light(ws))

def pb.go?(m: Array<U32>, +lo: U32, +hi: U32, ev: Ev, +ws: U32, +fl: U32, +wk: U32, +bk: U32,
           nzlo: Bool, nzhi: Bool) -> Array<U32> & Ev:
  match nzlo nzhi:
    case True{} _:
      +sq = C.sq.from64(B.ctz(lo))
      pb.k(U32.and(lo, U32.sub(lo, 1)), hi, sq, ev, ws, fl, wk, bk, m[sq])
    case False{} True{}:
      +sq = C.sq.from64(U32.add(B.ctz(hi), 32))
      pb.k(lo, U32.and(hi, U32.sub(hi, 1)), sq, ev, ws, fl, wk, bk, m[sq])
    case False{} False{}:
      (m, ev)

def pb?(m: Array<U32>, +lo: U32, +hi: U32, ev: Ev, +ws: U32, +fl: U32, +wk: U32, +bk: U32) ->
  Array<U32> & Ev:
  pb.go(m, lo, hi, ev, ws, fl, wk, bk, U32.is_ne(lo, 0), U32.is_ne(hi, 0))

def pb.n?(+lo: U32, +hi: U32, +ws: U32, +fl: U32, +wk: U32, +bk: U32, r: Array<U32> & Ev) -> Array<U32> & Ev:
  (m, ev) = r
  pb(m, lo, hi, ev, ws, fl, wk, bk)

def pb.k?(+lo: U32, +hi: U32, +sq: U32, ev: Ev, +ws: U32, +fl: U32, +wk: U32, +bk: U32,
          r: Array<U32> & U32) -> Array<U32> & Ev:
  (m, +v) = r
  +c = C.pc.color(v)
  pb.n(lo, hi, ws, fl, wk, bk, pb.type(m, sq, c, C.sel(U32.is_zero(c), bk, wk), ev, ws, fl,
    U32.to_nat(C.pc.type(v))))

# Final assembly
# --------------

# king-attack feature of one side: (units^2 / 8, capped) with 2+ attackers
def katt(+u: U32, +n: U32) -> U32:
  C.sel(U32.is_ge(n, 2), U32.div(U32.min(U32.mul(u, u), 2400), 8), 0)

def eval.fin.c(+p: B.Pos, +ws: U32, m: Array<U32>, ev: Ev) -> Array<U32> & U32:
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn, wb, bb}:
      +base = U32.is_zero(U32.and(ws, 255))
      (m, taper(U32.add(mg, C.sel(base, B.P.mg(p), 0)), U32.add(eg, C.sel(base, B.P.eg(p), 0)), B.P.ph(p)))

def eval.fin(+p: B.Pos, +ws: U32, r: Array<U32> & Ev) -> Array<U32> & U32:
  (m, ev) = r
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn, wb, bb}:
      e1 = ev.add2(Ev{mg, eg, 0, 0, 0, 0, 0, 0}, ws, 16, katt(wu, wn), katt(bu, bn))
      eval.fin.c(p, ws, m, ev.add2(e1, ws, 8, C.b2u(U32.is_ge(wb, 2)), C.b2u(U32.is_ge(bb, 2))))

def eval.occ(m: Array<U32>, +p: B.Pos, +ws: U32, o: B.Occ) -> Array<U32> & U32:
  match o:
    case B.Occ{+w0, +w1, +b0, +b1, +wp0, +wp1, +bp0, +bp1}:
      +lo = U32.and(U32.or(w0, b0), U32.not(U32.or(wp0, bp0)))
      +hi = U32.and(U32.or(w1, b1), U32.not(U32.or(wp1, bp1)))
      +fl = U32.or(files(wp0, wp1), U32.shln(files(bp0, bp1), 8n))
      ev = pawns(Ev{0, 0, 0, 0, 0, 0, 0, 0}, ws, p, wp0, wp1, bp0, bp1)
      eval.fin(p, ws, pb(m, lo, hi, ev, ws, fl, B.P.wk(p), B.P.bk(p)))

# white-relative evaluation with weight set ws (0 = the engine's weights)
def eval.white(m: Array<U32>, +p: B.Pos, +ws: U32) -> Array<U32> & U32:
  eval.occ(m, p, ws, B.P.occ(p))

def eval.rel(+p: B.Pos, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +s) = r
  (m, U32.add(B.neg_if(s, B.P.side(p)), TEMPO()))

# Eval hash: 2^19 entries x 2 words (lock = hhi, score) at EHASH
def EHASH() -> U32:
  1048576

def eh.idx(+p: B.Pos) -> U32:
  U32.add(EHASH(), U32.shln(U32.and(U32.shrn(B.P.hlo(p), 3n), 524287), 1n))

# the eval-hash lock mixes in the weight set, so modes never share entries
def eh.lock(+p: B.Pos, +ws: U32) -> U32:
  U32.xor(B.P.hhi(p), U32.mul(ws, 2654435761))

def eh.store(+p: B.Pos, +ws: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +s) = r
  +i = eh.idx(p)
  m[i] <- eh.lock(p, ws)
  m[U32.add(i, 1)] <- s
  (m, s)

def eh.hit(m: Array<U32>, +p: B.Pos, +ws: U32, hit: Bool) -> Array<U32> & U32:
  match hit:
    case True{}:
      m[U32.add(eh.idx(p), 1)]
    case False{}:
      eh.store(p, ws, eval.rel(p, eval.white(m, p, ws)))

def eh.probe(+p: B.Pos, +ws: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +lock) = r
  eh.hit(m, p, ws, U32.is_eq(lock, eh.lock(p, ws)))

def eval.mode(m: Array<U32>, +p: B.Pos, +mode: U32, pesto_only: Bool) -> Array<U32> & U32:
  match pesto_only:
    case False{}:
      eh.probe(p, C.sel(U32.is_eq(mode, 2), 256, 0), m[eh.idx(p)])
    case True{}:
      (m, pesto(p))

# side-to-move evaluation. mode 0: full; 1: PeSTO only; 2: light (no
# mobility or king-zone walks). Modes 0 and 2 go through the eval hash.
def eval(m: Array<U32>, +p: B.Pos, +mode: U32) -> Array<U32> & U32:
  eval.mode(m, p, mode, U32.is_eq(mode, 1))

# lazy evaluation for quiescence: when the cheap PeSTO score is LAZY cp
# outside (alpha, beta), the full terms almost never change the outcome of
# the stand-pat test, so PeSTO is answered instead (speculative shortcut)
def LAZY() -> U32:
  400

def eval.lazy.b(m: Array<U32>, +p: B.Pos, +mode: U32, +ps: U32, far: Bool) -> Array<U32> & U32:
  match far:
    case True{}:
      (m, ps)
    case False{}:
      eval(m, p, mode)

def eval.lazy(m: Array<U32>, +p: B.Pos, +mode: U32, +alpha: U32, +beta: U32) -> Array<U32> & U32:
  +ps = pesto(p)
  eval.lazy.b(m, p, mode, ps, C.s.le(U32.add(ps, LAZY()), alpha) || C.s.ge(U32.sub(ps, LAZY()), beta))
