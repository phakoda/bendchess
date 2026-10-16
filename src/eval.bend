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

# Nibble arrays: 8 files x 4 bits in one U32
# -----------------------------------------

def nib(+x: U32, +f: U32) -> U32:
  U32.and(U32.shrn(x, U32.to_nat(U32.shln(U32.and(f, 7), 2n))), 15)

def nib.put(+x: U32, +f: U32, +v: U32) -> U32:
  +sh = U32.to_nat(U32.shln(U32.and(f, 7), 2n))
  U32.or(U32.and(x, U32.not(U32.shln(15, sh))), U32.shln(U32.and(v, 15), sh))

# the nibble at file f, or d when f is off the board
def nib.at(+x: U32, +f: U32, +d: U32) -> U32:
  C.sel(U32.is_lt(f, 8), nib(x, f), d)

# Pass A: pawn structure summary
# ------------------------------
# per file: lowest / highest rank of a white / black pawn (15 / 0 when
# none) and pawn counts; plus bishop counts.

type Pw is Data:
  Pw{wmin: U32, wmax: U32, bmin: U32, bmax: U32, wcnt: U32, bcnt: U32, wbis: U32, bbis: U32}

def Pw.init() -> Pw:
  Pw{4294967295, 0, 4294967295, 0, 0, 0, 0, 0}

def pw.wpawn(+pw: Pw, +f: U32, +r: U32) -> Pw:
  match pw:
    case Pw{wmin, wmax, bmin, bmax, wcnt, bcnt, wbis, bbis}:
      Pw{nib.put(wmin, f, U32.min(nib(wmin, f), r)), nib.put(wmax, f, U32.max(nib(wmax, f), r)), bmin, bmax,
        nib.put(wcnt, f, U32.add(nib(wcnt, f), 1)), bcnt, wbis, bbis}

def pw.bpawn(+pw: Pw, +f: U32, +r: U32) -> Pw:
  match pw:
    case Pw{wmin, wmax, bmin, bmax, wcnt, bcnt, wbis, bbis}:
      Pw{wmin, wmax, nib.put(bmin, f, U32.min(nib(bmin, f), r)), nib.put(bmax, f, U32.max(nib(bmax, f), r)),
        wcnt, nib.put(bcnt, f, U32.add(nib(bcnt, f), 1)), wbis, bbis}

def pw.bis(pw: Pw, +w: U32, +b: U32) -> Pw:
  match pw:
    case Pw{wmin, wmax, bmin, bmax, wcnt, bcnt, wbis, bbis}:
      Pw{wmin, wmax, bmin, bmax, wcnt, bcnt, U32.add(wbis, w), U32.add(bbis, b)}

def pw.add.t(+pw: Pw, +sq: U32, code: Nat) -> Pw:
  match code:
    case 1n:
      pw.wpawn(pw, C.sq.file(sq), C.sq.rank(sq))
    case 9n:
      pw.bpawn(pw, C.sq.file(sq), C.sq.rank(sq))
    case 3n:
      pw.bis(pw, 1, 0)
    case 11n:
      pw.bis(pw, 0, 1)
    case _:
      pw

def pw.add(+pw: Pw, +v: U32, +sq: U32) -> Pw:
  pw.add.t(pw, sq, U32.to_nat(v))

def pa?(m: Array<U32>, +lo: U32, +hi: U32, pw: Pw) -> Array<U32> & Pw:
  pa.go(m, lo, hi, pw, U32.is_ne(lo, 0), U32.is_ne(hi, 0))

def pa.k?(+lo: U32, +hi: U32, +sq: U32, pw: Pw, r: Array<U32> & U32) -> Array<U32> & Pw:
  (m, +v) = r
  pa(m, lo, hi, pw.add(pw, v, sq))

def pa.go?(m: Array<U32>, +lo: U32, +hi: U32, pw: Pw, nzlo: Bool, nzhi: Bool) -> Array<U32> & Pw:
  match nzlo nzhi:
    case True{} _:
      +sq = C.sq.from64(B.ctz(lo))
      pa.k(U32.and(lo, U32.sub(lo, 1)), hi, sq, pw, m[sq])
    case False{} True{}:
      +sq = C.sq.from64(U32.add(B.ctz(hi), 32))
      pa.k(lo, U32.and(hi, U32.sub(hi, 1)), sq, pw, m[sq])
    case False{} False{}:
      (m, pw)

# Accumulator
# -----------
# mg, eg: white-relative weighted sums; wu/bu: attack units of white/black
# pieces on the enemy king zone; wn/bn: number of such attackers.

type Ev is Data:
  Ev{mg: U32, eg: U32, wu: U32, wn: U32, bu: U32, bn: U32}

def wmg(+ws: U32, +i: U32) -> U32:
  +k = U32.and(ws, 255)
  C.sel(U32.is_zero(k), W.w_mg(U32.to_nat(i)), C.b2u(U32.is_eq(k, U32.add(i, 1))))

def weg(+ws: U32, +i: U32) -> U32:
  +k = U32.and(ws, 255)
  C.sel(U32.is_zero(k), W.w_eg(U32.to_nat(i)), C.b2u(U32.is_eq(k, U32.add(i, 1))))

# cnt occurrences of feature i for colour c
def ev.add(ev: Ev, +ws: U32, +i: U32, +cnt: U32, +c: U32) -> Ev:
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn}:
      Ev{U32.add(mg, B.neg_if(U32.mul(cnt, wmg(ws, i)), c)), U32.add(eg, B.neg_if(U32.mul(cnt, weg(ws, i)), c)),
        wu, wn, bu, bn}

# a colour-c piece puts `units` attack units on the enemy king zone
def ev.att(+ev: Ev, +c: U32, +units: U32) -> Ev:
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn}:
      +w = U32.is_zero(c)
      +hit = C.b2u(U32.is_gt(units, 0))
      Ev{mg, eg, C.sel(w, U32.add(wu, units), wu), C.sel(w, U32.add(wn, hit), wn),
        C.sel(w, bu, U32.add(bu, units)), C.sel(w, bn, U32.add(bn, hit))}

# 256 when square t touches the king square ek, else 0
def zone256(+t: U32, +ek: U32) -> U32:
  C.sel(U32.is_ne(U32.and(B.dinfo(t, ek), 32), 0), 256, 0)

def mob.walk?(m: Array<U32>, +t: U32, +d: U32, +len: U32, +c: U32, +ek: U32, +acc: U32) ->
  Array<U32> & U32:
  mob.walk.c(t, d, len, c, ek, acc, C.sq.ok(t) && U32.is_gt(len, 0), m[C.sq.safe(t)])

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

def mob.dirs?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, +di: U32, +de: U32, +len: U32, +acc: U32) ->
  Array<U32> & U32:
  mob.dirs.go(m, sq, c, ek, di, de, len, acc, U32.is_lt(di, de))

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

def pawn.ev.add(ev: Ev, +ws: U32, +c: U32, +rr: U32, +passed: U32, +iso: U32, +dbl: U32) -> Ev:
  ev.add(ev.add(ev.add(ev, ws, U32.sub(rr, 1), passed, c), ws, 6, iso, c), ws, 7, dbl, c)

def pawn.ev.c(ev: Ev, +ws: U32, +sq: U32, +c: U32, +pw: Pw, w: Bool) -> Ev:
  match pw w:
    case Pw{+wmin, +wmax, +bmin, +bmax, +wcnt, +bcnt, +wbis, +bbis} True{}:
      +f = C.sq.file(sq)
      +r = C.sq.rank(sq)
      +f0 = U32.sub(f, 1)
      +f2 = U32.add(f, 1)
      +passed = C.b2u(U32.is_le(U32.max(U32.max(nib.at(bmax, f0, 0), nib(bmax, f)), nib.at(bmax, f2, 0)), r))
      +iso = U32.is_zero(nib.at(wcnt, f0, 0)) && U32.is_zero(nib.at(wcnt, f2, 0))
      +dbl = C.b2u(U32.is_lt(nib(wmin, f), r))
      pawn.ev.add(ev, ws, c, r, passed, C.b2u(iso), dbl)
    case Pw{+wmin, +wmax, +bmin, +bmax, +wcnt, +bcnt, +wbis, +bbis} False{}:
      +f = C.sq.file(sq)
      +r = C.sq.rank(sq)
      +f0 = U32.sub(f, 1)
      +f2 = U32.add(f, 1)
      +passed = C.b2u(U32.is_ge(U32.min(U32.min(nib.at(wmin, f0, 15), nib(wmin, f)), nib.at(wmin, f2, 15)), r))
      +iso = U32.is_zero(nib.at(bcnt, f0, 0)) && U32.is_zero(nib.at(bcnt, f2, 0))
      +dbl = C.b2u(U32.is_gt(nib(bmax, f), r))
      pawn.ev.add(ev, ws, c, U32.sub(7, r), passed, C.b2u(iso), dbl)

def pawn.ev(ev: Ev, +ws: U32, +sq: U32, +c: U32, +pw: Pw) -> Ev:
  pawn.ev.c(ev, ws, sq, c, pw, U32.is_zero(c))

def rook.ev(ev: Ev, +ws: U32, +sq: U32, +c: U32, +pw: Pw) -> Ev:
  match pw:
    case Pw{+wmin, +wmax, +bmin, +bmax, +wcnt, +bcnt, +wbis, +bbis}:
      +f = C.sq.file(sq)
      +w = U32.is_zero(c)
      +own = nib(C.sel(w, wcnt, bcnt), f)
      +their = nib(C.sel(w, bcnt, wcnt), f)
      +rr = C.sel(w, C.sq.rank(sq), U32.sub(7, C.sq.rank(sq)))
      +open = U32.is_zero(own) && U32.is_zero(their)
      +semi = U32.is_zero(own) && U32.is_gt(their, 0)
      ev.add(ev.add(ev.add(ev, ws, 9, C.b2u(open), c), ws, 10, C.b2u(semi), c), ws, 11,
        C.b2u(U32.is_eq(rr, 6)), c)

def shield(w: Bool, +wmin: U32, +bmax: U32, +f: U32, +r: U32) -> U32:
  match w:
    case True{}:
      +x = nib.at(wmin, f, 15)
      C.b2u(U32.is_eq(x, U32.add(r, 1)) || U32.is_eq(x, U32.add(r, 2)))
    case False{}:
      +x = nib.at(bmax, f, 0)
      C.b2u(U32.is_eq(x, U32.sub(r, 1)) || U32.is_eq(x, U32.sub(r, 2)))

# shield pawns of a colour-c king on sq (only on its first two ranks)
def king.ev(ev: Ev, +ws: U32, +sq: U32, +c: U32, +pw: Pw) -> Ev:
  match pw:
    case Pw{+wmin, +wmax, +bmin, +bmax, +wcnt, +bcnt, +wbis, +bbis}:
      +f = C.sq.file(sq)
      +r = C.sq.rank(sq)
      +w = U32.is_zero(c)
      +home = C.sel(w, C.b2u(U32.is_le(r, 1)), C.b2u(U32.is_ge(r, 6)))
      +n = U32.add(U32.add(shield(w, wmin, bmax, U32.sub(f, 1), r), shield(w, wmin, bmax, f, r)),
        shield(w, wmin, bmax, U32.add(f, 1), r))
      ev.add(ev, ws, 17, U32.mul(n, home), c)

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

def pb.type.light(m: Array<U32>, +sq: U32, +c: U32, ev: Ev, +ws: U32, +pw: Pw, t: Nat) -> Array<U32> & Ev:
  match t:
    case 1n:
      (m, pawn.ev(ev, ws, sq, c, pw))
    case 4n:
      (m, rook.ev(ev, ws, sq, c, pw))
    case 6n:
      (m, king.ev(ev, ws, sq, c, pw))
    case _:
      (m, ev)

def pb.type.full?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, ev: Ev, +ws: U32, +pw: Pw, t: Nat) ->
  Array<U32> & Ev:
  match t:
    case 1n:
      (m, pawn.ev(ev, ws, sq, c, pw))
    case 2n:
      mob.fin(ev, ws, c, 2, mob.dirs(m, sq, c, ek, 8, 16, 1, 0))
    case 3n:
      mob.fin(ev, ws, c, 3, mob.dirs(m, sq, c, ek, 4, 8, 8, 0))
    case 4n:
      mob.fin(rook.ev(ev, ws, sq, c, pw), ws, c, 4, mob.dirs(m, sq, c, ek, 0, 4, 8, 0))
    case 5n:
      mob.fin(ev, ws, c, 5, mob.dirs(m, sq, c, ek, 0, 8, 8, 0))
    case 6n:
      (m, king.ev(ev, ws, sq, c, pw))
    case _:
      (m, ev)

def pb.type.l?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, ev: Ev, +ws: U32, +pw: Pw, t: Nat, lt: Bool) ->
  Array<U32> & Ev:
  match lt:
    case True{}:
      pb.type.light(m, sq, c, ev, ws, pw, t)
    case False{}:
      pb.type.full(m, sq, c, ek, ev, ws, pw, t)

def pb.type?(m: Array<U32>, +sq: U32, +c: U32, +ek: U32, ev: Ev, +ws: U32, +pw: Pw, t: Nat) ->
  Array<U32> & Ev:
  pb.type.l(m, sq, c, ek, ev, ws, pw, t, light(ws))

def pb.k?(+lo: U32, +hi: U32, +sq: U32, ev: Ev, +ws: U32, +pw: Pw, +wk: U32, +bk: U32,
          r: Array<U32> & U32) -> Array<U32> & Ev:
  (m, +v) = r
  +c = C.pc.color(v)
  pb.n(lo, hi, ws, pw, wk, bk, pb.type(m, sq, c, C.sel(U32.is_zero(c), bk, wk), ev, ws, pw,
    U32.to_nat(C.pc.type(v))))

def pb.go?(m: Array<U32>, +lo: U32, +hi: U32, ev: Ev, +ws: U32, +pw: Pw, +wk: U32, +bk: U32,
           nzlo: Bool, nzhi: Bool) -> Array<U32> & Ev:
  match nzlo nzhi:
    case True{} _:
      +sq = C.sq.from64(B.ctz(lo))
      pb.k(U32.and(lo, U32.sub(lo, 1)), hi, sq, ev, ws, pw, wk, bk, m[sq])
    case False{} True{}:
      +sq = C.sq.from64(U32.add(B.ctz(hi), 32))
      pb.k(lo, U32.and(hi, U32.sub(hi, 1)), sq, ev, ws, pw, wk, bk, m[sq])
    case False{} False{}:
      (m, ev)

def pb?(m: Array<U32>, +lo: U32, +hi: U32, ev: Ev, +ws: U32, +pw: Pw, +wk: U32, +bk: U32) ->
  Array<U32> & Ev:
  pb.go(m, lo, hi, ev, ws, pw, wk, bk, U32.is_ne(lo, 0), U32.is_ne(hi, 0))

def pb.n?(+lo: U32, +hi: U32, +ws: U32, +pw: Pw, +wk: U32, +bk: U32, r: Array<U32> & Ev) -> Array<U32> & Ev:
  (m, ev) = r
  pb(m, lo, hi, ev, ws, pw, wk, bk)

# Final assembly
# --------------

# king-attack feature of one side: (units^2 / 8, capped) with 2+ attackers
def katt(+u: U32, +n: U32) -> U32:
  C.sel(U32.is_ge(n, 2), U32.div(U32.min(U32.mul(u, u), 2400), 8), 0)

def eval.fin.c(+p: B.Pos, +ws: U32, m: Array<U32>, ev: Ev) -> Array<U32> & U32:
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn}:
      +base = U32.is_zero(U32.and(ws, 255))
      (m, taper(U32.add(mg, C.sel(base, B.P.mg(p), 0)), U32.add(eg, C.sel(base, B.P.eg(p), 0)), B.P.ph(p)))

def eval.fin.b(+p: B.Pos, +ws: U32, +pw: Pw, m: Array<U32>, ev: Ev) -> Array<U32> & U32:
  match pw:
    case Pw{+wmin, +wmax, +bmin, +bmax, +wcnt, +bcnt, +wbis, +bbis}:
      eval.fin.c(p, ws, m, ev.add(ev.add(ev, ws, 8, C.b2u(U32.is_ge(wbis, 2)), 0), ws, 8,
        C.b2u(U32.is_ge(bbis, 2)), 1))

def eval.fin(+p: B.Pos, +ws: U32, +pw: Pw, r: Array<U32> & Ev) -> Array<U32> & U32:
  (m, ev) = r
  match ev:
    case Ev{mg, eg, wu, wn, bu, bn}:
      eval.fin.b(p, ws, pw, m, ev.add(ev.add(Ev{mg, eg, 0, 0, 0, 0}, ws, 16, katt(wu, wn), 0),
        ws, 16, katt(bu, bn), 1))

def eval.b(+p: B.Pos, +ws: U32, +lo: U32, +hi: U32, r: Array<U32> & Pw) -> Array<U32> & U32:
  (m, +pw) = r
  eval.fin(p, ws, pw, pb(m, lo, hi, Ev{0, 0, 0, 0, 0, 0}, ws, pw, B.P.wk(p), B.P.bk(p)))

def eval.occ(m: Array<U32>, +p: B.Pos, +ws: U32, o: B.Occ) -> Array<U32> & U32:
  match o:
    case B.Occ{w0, w1, b0, b1}:
      +lo = U32.or(w0, b0)
      +hi = U32.or(w1, b1)
      eval.b(p, ws, lo, hi, pa(m, lo, hi, Pw.init()))

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
