# BendChess move generation, attack detection, FEN text and perft.
#
# These are the loop-based routines (marked @unsafe: their loops recurse on
# U32 counters, so Bend cannot check termination structurally). They are
# kept apart from board.bend so that LAWS.bend can import the board state
# code, which is fully checked.

import Base
import ./core.bend as C
import ./tables.bend as T
import ./board.bend as B

def att.ray?(m: Array<U32>, +t: U32, +d: U32, +w1: U32, +w2: U32, +len: U32) ->
  Array<U32> & Bool:
  att.ray.c(t, d, w1, w2, len, C.sq.ok(t) && U32.is_gt(len, 0), m[C.sq.safe(t)])

# reads finished: decide the probe
def att.ray.d?(m: Array<U32>, +t: U32, +d: U32, +w1: U32, +w2: U32, +len: U32, +v: U32,
               ok: Bool, empty: Bool) -> Array<U32> & Bool:
  match ok empty:
    case False{} _:
      (m, False{})
    case True{} False{}:
      (m, U32.is_eq(v, w1) || U32.is_eq(v, w2))
    case True{} True{}:
      att.ray(m, U32.add(t, d), d, w1, w2, U32.sub(len, 1))

def att.ray.c?(+t: U32, +d: U32, +w1: U32, +w2: U32, +len: U32, ok: Bool,
               r: Array<U32> & U32) -> Array<U32> & Bool:
  (m, +v) = r
  att.ray.d(m, t, d, w1, w2, len, v, ok, U32.is_zero(v))

def att.seq?(m: Array<U32>, +sq: U32, +by: U32, +k: U32, go: Bool) -> Array<U32> & Bool:
  match go:
    case False{}:
      (m, False{})
    case True{}:
      +kn = U32.to_nat(k)
      +d = B.neg_if(B.att.off(kn), by)
      att.seq.r(sq, by, k, att.ray(m, U32.add(sq, d), d, C.pc.make(by, B.att.w1(kn)),
        C.pc.make(by, B.att.w2(kn)), B.att.len(kn)))

def att.seq.r?(+sq: U32, +by: U32, +k: U32, r: Array<U32> & Bool) -> Array<U32> & Bool:
  match r:
    case (m, True{}):
      (m, True{})
    case (m, False{}):
      att.seq(m, sq, by, U32.add(k, 1), U32.is_lt(U32.add(k, 1), 26))

# is square sq attacked by colour `by`?
def attacked(m: Array<U32>, +sq: U32, +by: U32) -> Array<U32> & Bool:
  att.seq(m, sq, by, 0, True{})

# is the side to move in check?
def in_check(m: Array<U32>, +p: B.Pos) -> Array<U32> & Bool:
  +us = B.P.side(p)
  attacked(m, B.P.king(p, us), C.opp(us))

# after make(): did the mover leave its own king attacked? (np is the new
# state, so the mover is opp(np.side) and the attacker np.side)
def left_in_check(m: Array<U32>, +np: B.Pos) -> Array<U32> & Bool:
  +side = B.P.side(np)
  attacked(m, B.P.king(np, C.opp(side)), side)

def gen.walk.e?(+us: U32, +base: U32, +qs: U32, +from: U32, +t: U32, +d: U32, +len: U32,
                r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  gen.walk(m, us, base, qs, from, U32.add(t, d), d, U32.sub(len, 1), n)

# walking from `from` along d, now at t with `len` steps left
def gen.walk.d?(m: Array<U32>, +us: U32, +base: U32, +qs: U32, +from: U32, +t: U32,
                +d: U32, +len: U32, +n: U32, +v: U32, ok: Bool, empty: Bool) ->
  Array<U32> & U32:
  match ok empty:
    case False{} _:
      (m, n)
    case True{} False{}:
      B.push(m, base, n, C.mv.make(from, t, 0), U32.is_ne(C.pc.color(v), us))
    case True{} True{}:
      gen.walk.e(us, base, qs, from, t, d, len, B.push(m, base, n, C.mv.make(from, t, 0), U32.is_zero(qs)))

def gen.walk.c?(+us: U32, +base: U32, +qs: U32, +from: U32, +t: U32, +d: U32, +len: U32,
                +n: U32, ok: Bool, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  gen.walk.d(m, us, base, qs, from, t, d, len, n, v, ok, U32.is_zero(v))

def gen.walk?(m: Array<U32>, +us: U32, +base: U32, +qs: U32, +from: U32, +t: U32,
              +d: U32, +len: U32, +n: U32) -> Array<U32> & U32:
  gen.walk.c(us, base, qs, from, t, d, len, n, C.sq.ok(t) && U32.is_gt(len, 0), m[C.sq.safe(t)])

# directions di..de-1 from square `from`, up to len steps each
def gen.dirs?(m: Array<U32>, +us: U32, +base: U32, +qs: U32, +from: U32, +n: U32, +di: U32,
              +de: U32, +len: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, n)
    case True{}:
      +d = B.dir(U32.to_nat(di))
      gen.dirs.k(us, base, qs, from, di, de, len,
        gen.walk(m, us, base, qs, from, U32.add(from, d), d, len, n))

def gen.dirs.k?(+us: U32, +base: U32, +qs: U32, +from: U32, +di: U32, +de: U32, +len: U32,
                r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  gen.dirs(m, us, base, qs, from, n, U32.add(di, 1), de, len, U32.is_lt(U32.add(di, 1), de))

def gen.type?(m: Array<U32>, +us: U32, +ep: U32, +base: U32, +qs: U32, +sq: U32, +n: U32,
              t: Nat) -> Array<U32> & U32:
  match t:
    case 1n:
      B.gen.pawn(m, us, ep, base, qs, sq, n)
    case 2n:
      gen.dirs(m, us, base, qs, sq, n, 8, 16, 1, True{})
    case 3n:
      gen.dirs(m, us, base, qs, sq, n, 4, 8, 8, True{})
    case 4n:
      gen.dirs(m, us, base, qs, sq, n, 0, 4, 8, True{})
    case 5n:
      gen.dirs(m, us, base, qs, sq, n, 0, 8, 8, True{})
    case 6n:
      gen.dirs(m, us, base, qs, sq, n, 0, 8, 1, True{})
    case _:
      (m, n)

def gen.piece?(m: Array<U32>, +us: U32, +ep: U32, +base: U32, +qs: U32, +sq: U32, +n: U32,
               +v: U32, mine: Bool) -> Array<U32> & U32:
  match mine:
    case False{}:
      (m, n)
    case True{}:
      gen.type(m, us, ep, base, qs, sq, n, U32.to_nat(C.pc.type(v)))

def gen.sq?(m: Array<U32>, +us: U32, +ep: U32, +base: U32, +qs: U32, +sq: U32, +n: U32,
            go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, n)
    case True{}:
      gen.pc(us, ep, base, qs, sq, n, m[sq])

def gen.next?(+us: U32, +ep: U32, +base: U32, +qs: U32, +sq: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +n) = r
  gen.sq(m, us, ep, base, qs, sq, n, U32.is_lt(sq, 128))

def gen.pc?(+us: U32, +ep: U32, +base: U32, +qs: U32, +sq: U32, +n: U32,
            r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  +s1 = U32.add(sq, 1)
  +nx = U32.add(s1, U32.and(s1, 8))
  gen.next(us, ep, base, qs, nx, gen.piece(m, us, ep, base, qs, sq, n, v,
    U32.is_ne(v, 0) && U32.is_eq(C.pc.color(v), us)))

# still ok and square sq not attacked by `by`?
def chk.safe(+sq: U32, +by: U32, r: Array<U32> & Bool) -> Array<U32> & Bool:
  match r:
    case (m, False{}):
      (m, False{})
    case (m, True{}):
      B.chk.not(attacked(m, sq, by))

def gen.castle.q(+us: U32, +rights: U32, +base: U32, +r0: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +n) = r
  +them = C.opp(us)
  +ok = U32.is_ne(U32.and(rights, C.sel(U32.is_zero(us), 2, 8)), 0)
  B.chk.push(base, n, C.mv.make(U32.add(r0, 4), U32.add(r0, 2), 2),
    chk.safe(U32.add(r0, 3), them, chk.safe(U32.add(r0, 4), them,
      B.chk.empty(U32.add(r0, 1), B.chk.empty(U32.add(r0, 2), B.chk.empty(U32.add(r0, 3), (m, ok)))))))

def gen.castle(m: Array<U32>, +us: U32, +rights: U32, +base: U32, +n: U32) ->
  Array<U32> & U32:
  +r0 = C.sel(U32.is_zero(us), 0, 112)
  +them = C.opp(us)
  +ok = U32.is_ne(U32.and(rights, C.sel(U32.is_zero(us), 1, 4)), 0)
  gen.castle.q(us, rights, base, r0,
    B.chk.push(base, n, C.mv.make(U32.add(r0, 4), U32.add(r0, 6), 2),
      chk.safe(U32.add(r0, 5), them, chk.safe(U32.add(r0, 4), them,
        B.chk.empty(U32.add(r0, 6), B.chk.empty(U32.add(r0, 5), (m, ok)))))))

def gen.fin(+us: U32, +rights: U32, +base: U32, full: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  match full:
    case True{}:
      (m, +n) = r
      gen.castle(m, us, rights, base, n)
    case False{}:
      r

def gen.bits.p?(+us: U32, +ep: U32, +base: U32, +qs: U32, +lo: U32, +hi: U32, +sq: U32, +n: U32,
                r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  gen.bits.n(us, ep, base, qs, lo, hi, gen.type(m, us, ep, base, qs, sq, n, U32.to_nat(C.pc.type(v))))

def gen.bits.a?(m: Array<U32>, +us: U32, +ep: U32, +base: U32, +qs: U32, +lo: U32, +hi: U32, +n: U32,
                nzlo: Bool, nzhi: Bool) -> Array<U32> & U32:
  match nzlo nzhi:
    case True{} _:
      +sq = C.sq.from64(B.ctz(lo))
      gen.bits.p(us, ep, base, qs, U32.and(lo, U32.sub(lo, 1)), hi, sq, n, m[sq])
    case False{} True{}:
      +sq = C.sq.from64(U32.add(B.ctz(hi), 32))
      gen.bits.p(us, ep, base, qs, lo, U32.and(hi, U32.sub(hi, 1)), sq, n, m[sq])
    case False{} False{}:
      (m, n)

# generate from every piece of colour us, iterating the occupancy bits
def gen.bits?(m: Array<U32>, +us: U32, +ep: U32, +base: U32, +qs: U32, +lo: U32, +hi: U32, +n: U32) ->
  Array<U32> & U32:
  gen.bits.a(m, us, ep, base, qs, lo, hi, n, U32.is_ne(lo, 0), U32.is_ne(hi, 0))

def gen.bits.n?(+us: U32, +ep: U32, +base: U32, +qs: U32, +lo: U32, +hi: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +n) = r
  gen.bits(m, us, ep, base, qs, lo, hi, n)

# all pseudo-legal moves (qs = 0) or captures and queen promotions (qs = 1)
def gen(m: Array<U32>, +p: B.Pos, +base: U32, +qs: U32) -> Array<U32> & U32:
  +us = B.P.side(p)
  gen.fin(us, B.P.castle(p), base, U32.is_zero(qs),
    gen.bits(m, us, B.P.ep(p), base, qs, B.occ.lo(B.P.occ(p), us), B.occ.hi(B.P.occ(p), us), 0))

def fen.clear?(m: Array<U32>, +i: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      m[i] <- 0
      fen.clear(m, U32.add(i, 1), U32.is_lt(U32.add(i, 1), 128))

def fen.place.d?(m: Array<U32>, rest: String, +f: U32, +r: U32, +code: U32, +pc: U32,
                 slash: Bool, digit: Bool) -> Array<U32>:
  match slash digit:
    case True{} _:
      fen.place(m, rest, 0, U32.sub(r, 1))
    case False{} True{}:
      fen.place(m, rest, U32.add(f, U32.sub(code, 48)), r)
    case False{} False{}:
      +ok = U32.is_ne(pc, 0) && U32.is_lt(f, 8) && U32.is_lt(r, 8)
      m[C.sel(ok, C.sq.make(f, r), 15)] <- C.sel(ok, pc, 0)
      fen.place(m, rest, U32.add(f, B.b2n(ok)), r)

def fen.place?(m: Array<U32>, s: String, +f: U32, +r: U32) -> Array<U32>:
  match s:
    case SNil{}:
      m
    case SCon{c, rest}:
      +code = Char.to_u32(c)
      fen.place.d(m, rest, f, r, code, B.fen.piece(U32.to_nat(code)), U32.is_eq(code, 47),
        U32.is_ge(code, 49) && U32.is_le(code, 56))

def scan.k?(+sq: U32, s: B.Scan, r: Array<U32> & U32) -> Array<U32> & B.Scan:
  (m, +v) = r
  +s1 = U32.add(sq, 1)
  +nx = U32.add(s1, U32.and(s1, 8))
  scan(m, nx, B.scan.add(s, v, sq), U32.is_lt(nx, 128))

def scan?(m: Array<U32>, +sq: U32, s: B.Scan, go: Bool) -> Array<U32> & B.Scan:
  match go:
    case False{}:
      (m, s)
    case True{}:
      scan.k(sq, s, m[sq])

# set up the board from a FEN string; answers the state. Missing trailing
# fields default to "w - - 0 1".
def fen.parse(m: Array<U32>, s: String) -> Array<U32> & B.Pos:
  +parts = String.split(s, ' ')
  +side = B.fen.side(B.str.nth(parts, 1n, "w"))
  +castle = B.fen.castle(B.str.nth(parts, 2n, "-"), 0)
  +ep = B.fen.ep(B.str.nth(parts, 3n, "-"))
  +half = B.str.u32(B.str.nth(parts, 4n, "0"), 0)
  +full = B.str.u32(B.str.nth(parts, 5n, "1"), 1)
  m = fen.clear(m, 0, True{})
  m = fen.place(m, B.str.nth(parts, 0n, ""), 0, 7)
  m[U32.add(B.SC(), 10)] <- full
  m[U32.add(B.SC(), 11)] <- side
  +a0 = {B.Acc{(U32.and(C.z.side.lo(), C.bmask(U32.is_eq(side, 1))) .^. C.z.castle.lo(castle) .^. C.z.ep.lo(ep) : U32),
           (U32.and(C.z.side.hi(), C.bmask(U32.is_eq(side, 1))) .^. C.z.castle.hi(castle) .^. C.z.ep.hi(ep) : U32),
           0, 0, 0} : B.Acc}
  B.fen.pos(side, castle, ep, half, scan(m, 0, B.Scan{a0, C.NO_SQ(), C.NO_SQ(), B.Occ{0, 0, 0, 0, 0, 0, 0, 0}}, True{}))

def fen.rows?(m: Array<U32>, +f: U32, +r: U32, +e: U32, acc: String) -> Array<U32> & String:
  fen.rows.go(m, f, r, e, acc, U32.is_lt(f, 8), U32.is_zero(r))

def fen.row.v?(m: Array<U32>, +f: U32, +r: U32, +e: U32, acc: String, +v: U32, empty: Bool) ->
  Array<U32> & String:
  match empty:
    case True{}:
      fen.rows(m, U32.add(f, 1), r, U32.add(e, 1), acc)
    case False{}:
      fen.rows(m, U32.add(f, 1), r, 0, acc ++ B.fen.gap(e) ++ B.fen.pchar(U32.to_nat(v)))

def fen.row.k?(+f: U32, +r: U32, +e: U32, acc: String, r2: Array<U32> & U32) -> Array<U32> & String:
  (m, +v) = r2
  fen.row.v(m, f, r, e, acc, v, U32.is_zero(v))

def fen.rows.go?(m: Array<U32>, +f: U32, +r: U32, +e: U32, acc: String, inrow: Bool, last: Bool) ->
  Array<U32> & String:
  match inrow last:
    case True{} _:
      fen.row.k(f, r, e, acc, m[C.sq.make(f, r)])
    case False{} True{}:
      (m, acc ++ B.fen.gap(e))
    case False{} False{}:
      fen.rows(m, 0, U32.sub(r, 1), 0, acc ++ B.fen.gap(e) ++ "/")

# the FEN of the current position (ep square shown whenever set)
def fen.out(m: Array<U32>, +p: B.Pos) -> Array<U32> & String:
  B.fen.out.b(p, fen.rows(m, 0, 7, 0, ""))

def legal.a(+mv: U32, r: Array<U32> & B.Pos) -> Array<U32> & Bool:
  (m, +np) = r
  B.legal.b(np, mv, left_in_check(m, np))

def is_legal(m: Array<U32>, +p: B.Pos, +mv: U32) -> Array<U32> & Bool:
  legal.a(mv, B.make(m, p, mv))

# find the legal move whose UCI key is k among the n moves at base; 0 if none
def find.v?(+p: B.Pos, +k: U32, +base: U32, +i: U32, +n: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +mv) = r
  find.w(p, k, base, i, n, mv, U32.is_eq(B.mv.ukey(mv), k), m)

def find.go.b?(m: Array<U32>, +p: B.Pos, +k: U32, +base: U32, +i: U32, +n: U32, go: Bool) ->
  Array<U32> & U32:
  match go:
    case False{}:
      (m, 0)
    case True{}:
      find.v(p, k, base, i, n, m[U32.add(base, i)])

def find.go?(m: Array<U32>, +p: B.Pos, +k: U32, +base: U32, +i: U32, +n: U32) -> Array<U32> & U32:
  find.go.b(m, p, k, base, i, n, U32.is_lt(i, n))

def find.x?(+p: B.Pos, +k: U32, +base: U32, +i: U32, +n: U32, +mv: U32, r: Array<U32> & Bool) ->
  Array<U32> & U32:
  match r:
    case (m, True{}):
      (m, mv)
    case (m, False{}):
      find.go(m, p, k, base, U32.add(i, 1), n)

def find.w?(+p: B.Pos, +k: U32, +base: U32, +i: U32, +n: U32, +mv: U32, hit: Bool, m: Array<U32>) ->
  Array<U32> & U32:
  match hit:
    case True{}:
      find.x(p, k, base, i, n, mv, is_legal(m, p, mv))
    case False{}:
      find.go(m, p, k, base, U32.add(i, 1), n)

def find.gen(+p: B.Pos, +k: U32, +base: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  find.go(m, p, k, base, 0, n)

# the legal move named by UCI string s in position p (0 if none). Uses the
# move list slot of ply `ply`.
def find_move(m: Array<U32>, +p: B.Pos, s: String, +ply: U32) -> Array<U32> & U32:
  +base = U32.add(B.MOVES(), U32.shln(ply, 8n))
  find.gen(p, B.uci.key(s), base, gen(m, p, base, 0))

def perft.chk?(+p: B.Pos, +depth: U32, +ply: U32, r: Array<U32> & Bool) -> Array<U32> & U32:
  (m, +chk) = r
  +base = U32.add(B.MOVES(), U32.shln(ply, 8n))
  perft.gen(p, depth, ply, base, chk, gen(m, p, base, 0))

# number of leaf nodes of the legal move tree of the given depth (>= 1)
def perft?(m: Array<U32>, +p: B.Pos, +depth: U32, +ply: U32) -> Array<U32> & U32:
  perft.chk(p, depth, ply, in_check(m, p))

# Perft
# -----

def perft.next?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
                m: Array<U32>) -> Array<U32> & U32:
  perft.loop(m, p, depth, ply, base, chk, U32.add(i, 1), n, acc, U32.is_lt(U32.add(i, 1), n))

def perft.add?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
               +mv: U32, +np: B.Pos, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +c) = r
  perft.next(p, depth, ply, base, chk, i, n, U32.add(acc, c), B.unmake(m, np, mv))

def perft.sub?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
               +mv: U32, +np: B.Pos, m: Array<U32>, leaf: Bool) -> Array<U32> & U32:
  match leaf:
    case True{}:
      perft.next(p, depth, ply, base, chk, i, n, U32.add(acc, 1), B.unmake(m, np, mv))
    case False{}:
      perft.add(p, depth, ply, base, chk, i, n, acc, mv, np,
        perft(m, np, U32.sub(depth, 1), U32.add(ply, 1)))

def perft.legal?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
                 +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      perft.next(p, depth, ply, base, chk, i, n, acc, B.unmake(m, np, mv))
    case (m, False{}):
      perft.sub(p, depth, ply, base, chk, i, n, acc, mv, np, m, U32.is_eq(depth, 1))

def first.d?(m: Array<U32>, +t: U32, +d: U32, +v: U32, ok: Bool, empty: Bool) -> Array<U32> & U32:
  match ok empty:
    case False{} _:
      (m, 0)
    case True{} False{}:
      (m, U32.or(v, U32.shln(t, 8n)))
    case True{} True{}:
      first(m, t, d)

def first.c?(+t: U32, +d: U32, ok: Bool, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  first.d(m, t, d, v, ok, U32.is_zero(v))

# the first piece along step d from s (exclusive), packed piece | sq << 8;
# 0 when the ray leaves the board first
def first?(m: Array<U32>, +s: U32, +d: U32) -> Array<U32> & U32:
  +t = U32.add(s, d)
  first.c(t, d, C.sq.ok(t), m[C.sq.safe(t)])

def line.att.b(m: Array<U32>, +s: U32, +info: U32, +lineb: U32, +c: U32, aligned: Bool) -> Array<U32> & Bool:
  match aligned:
    case False{}:
      (m, False{})
    case True{}:
      B.ray.hit(c, lineb, first(m, s, B.dstep(info)))

# a colour-c slider attacks square s through the line toward `via`?
def line.att(m: Array<U32>, +s: U32, +via: U32, +c: U32) -> Array<U32> & Bool:
  +info = B.dinfo(s, via)
  +lineb = U32.and(info, 24)
  line.att.b(m, s, info, lineb, c, U32.is_ne(lineb, 0))

def illegal.b(m: Array<U32>, +np: B.Pos, +mv: U32, +k: U32, +mover: U32, full: Bool) -> Array<U32> & Bool:
  match full:
    case True{}:
      left_in_check(m, np)
    case False{}:
      line.att(m, k, C.mv.from(mv), C.opp(mover))

# Legality after make(): mv was played from position p (chk: was the
# mover in check before it). Answers True when the move is ILLEGAL.
# Only king moves, en passant and check evasions need a full attack scan;
# any other move can only be illegal by uncovering an attack on the
# king through its origin square (a pin), which is one ray walk.
def illegal(m: Array<U32>, +np: B.Pos, +mv: U32, +chk: Bool) -> Array<U32> & Bool:
  +mover = C.opp(B.P.side(np))
  +k = B.P.king(np, mover)
  illegal.b(m, np, mv, k, mover, chk || U32.is_eq(C.mv.flag(mv), 3) || U32.is_eq(k, C.mv.to(mv)))

def perft.made?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
                +mv: U32, r: Array<U32> & B.Pos) -> Array<U32> & U32:
  (m, +np) = r
  perft.legal(p, depth, ply, base, chk, i, n, acc, mv, np, illegal(m, np, mv, chk))

def perft.mv?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32, +acc: U32,
              r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +mv) = r
  perft.made(p, depth, ply, base, chk, i, n, acc, mv, B.make(m, p, mv))

def perft.loop?(m: Array<U32>, +p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, +i: U32, +n: U32,
                +acc: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, acc)
    case True{}:
      perft.mv(p, depth, ply, base, chk, i, n, acc, m[U32.add(base, i)])

def perft.gen?(+p: B.Pos, +depth: U32, +ply: U32, +base: U32, +chk: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +n) = r
  perft.loop(m, p, depth, ply, base, chk, 0, n, 0, U32.is_lt(0, n))

def divide.loop.b?(m: Array<U32>, +p: B.Pos, +depth: U32, +base: U32, +i: U32, +n: U32, acc: String,
                   +tot: U32, go: Bool) -> Array<U32> & String:
  match go:
    case False{}:
      (m, acc ++ "total: " ++ U32.show(tot))
    case True{}:
      divide.mv(p, depth, base, i, n, acc, tot, m[U32.add(base, i)])

def divide.loop?(m: Array<U32>, +p: B.Pos, +depth: U32, +base: U32, +i: U32, +n: U32, acc: String,
                 +tot: U32) -> Array<U32> & String:
  divide.loop.b(m, p, depth, base, i, n, acc, tot, U32.is_lt(i, n))

# Divide: per root move, the perft of the subtree (depth >= 2), as text
def divide.add?(+p: B.Pos, +depth: U32, +base: U32, +i: U32, +n: U32, acc: String, +tot: U32,
                +mv: U32, +np: B.Pos, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +c) = r
  divide.loop(B.unmake(m, np, mv), p, depth, base, U32.add(i, 1), n,
    acc ++ B.mv.uci(mv) ++ ": " ++ U32.show(c) ++ "\n", U32.add(tot, c))

def divide.legal?(+p: B.Pos, +depth: U32, +base: U32, +i: U32, +n: U32, acc: String, +tot: U32,
                  +mv: U32, +np: B.Pos, r: Array<U32> & Bool) -> Array<U32> & String:
  match r:
    case (m, True{}):
      divide.loop(B.unmake(m, np, mv), p, depth, base, U32.add(i, 1), n, acc, tot)
    case (m, False{}):
      divide.add(p, depth, base, i, n, acc, tot, mv, np, perft(m, np, U32.sub(depth, 1), 1))

def divide.made?(+p: B.Pos, +depth: U32, +base: U32, +i: U32, +n: U32, acc: String, +tot: U32,
                 +mv: U32, r: Array<U32> & B.Pos) -> Array<U32> & String:
  (m, +np) = r
  divide.legal(p, depth, base, i, n, acc, tot, mv, np, left_in_check(m, np))

def divide.mv?(+p: B.Pos, +depth: U32, +base: U32, +i: U32, +n: U32, acc: String, +tot: U32,
               r: Array<U32> & U32) -> Array<U32> & String:
  (m, +mv) = r
  divide.made(p, depth, base, i, n, acc, tot, mv, B.make(m, p, mv))

def divide.gen?(+p: B.Pos, +depth: U32, +base: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +n) = r
  divide.loop(m, p, depth, base, 0, n, "", 0)

def divide?(m: Array<U32>, +p: B.Pos, +depth: U32) -> Array<U32> & String:
  +base = B.MOVES()
  divide.gen(p, depth, base, gen(m, p, base, 0))

def gchk.d(m: Array<U32>, +k: U32, +mover: U32, +from: U32, hit: Bool) -> Array<U32> & Bool:
  match hit:
    case True{}:
      (m, True{})
    case False{}:
      line.att(m, k, from, mover)

def gchk.c(+k: U32, +mover: U32, +from: U32, r: Array<U32> & U32) -> Array<U32> & Bool:
  (m, +found) = r
  gchk.d(m, k, mover, from, U32.is_eq(U32.shrn(found, 8n), k))

def gchk.b(m: Array<U32>, +k: U32, +mover: U32, +to: U32, +from: U32, +info: U32, leap: Bool, slide: Bool) ->
  Array<U32> & Bool:
  match leap slide:
    case True{} _:
      (m, True{})
    case False{} True{}:
      gchk.c(k, mover, from, first(m, to, B.dstep(info)))
    case False{} False{}:
      line.att(m, k, from, mover)

def gchk.a(m: Array<U32>, +np: B.Pos, +mv: U32, special: Bool) -> Array<U32> & Bool:
  match special:
    case True{}:
      in_check(m, np)
    case False{}:
      +them = B.P.side(np)
      +mover = C.opp(them)
      +k = B.P.king(np, them)
      +to = C.mv.to(mv)
      +pc = C.sel(C.mv.is_promo(mv), C.pc.make(mover, C.mv.promo_type(mv)), B.P.mvd(np))
      +t = C.pc.type(pc)
      +info = B.dinfo(to, k)
      +lineb = U32.and(info, 24)
      +leap = (U32.is_eq(t, 1) && U32.is_ne(U32.and(info, C.sel(U32.is_zero(mover), 1, 2)), 0)) ||
        (U32.is_eq(t, 2) && U32.is_ne(U32.and(info, 4), 0))
      +slide = U32.is_ne(lineb, 0) && (U32.is_eq(t, 5) || (U32.is_eq(t, 3) && U32.is_eq(lineb, 8)) ||
        (U32.is_eq(t, 4) && U32.is_eq(lineb, 16)))
      gchk.b(m, k, mover, to, C.mv.from(mv), info, leap, slide)

# Does mv (already made, giving np) check the side now to move?
def gchk(m: Array<U32>, +np: B.Pos, +mv: U32) -> Array<U32> & Bool:
  +fl = C.mv.flag(mv)
  gchk.a(m, np, mv, U32.is_eq(fl, 2) || U32.is_eq(fl, 3))

# Static exchange evaluation (SEE)
# --------------------------------
# The material balance of the capture sequence on one square when both
# sides always recapture with their least valuable attacker (and may stop).
# Capturing pieces are lifted off the board while the sequence is played
# out, which reveals x-ray attackers behind them; everything is restored
# afterwards. Pins and checks are ignored (the usual approximation).

def SEEST() -> U32:
  U32.add(B.SC(), 3000)

def SEEG() -> U32:
  U32.add(B.SC(), 3100)

def see.val(t: Nat) -> U32:
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
    case 6n:
      20000
    case _:
      0

# the first piece within len steps along d from s (exclusive), packed
# piece | sq << 8; 0 when none
def firstn?(m: Array<U32>, +s: U32, +d: U32, +len: U32) -> Array<U32> & U32:
  +t = U32.add(s, d)
  firstn.c(t, d, len, C.sq.ok(t) && U32.is_gt(len, 0), m[C.sq.safe(t)])

def firstn.d?(m: Array<U32>, +t: U32, +d: U32, +len: U32, +v: U32, ok: Bool, empty: Bool) -> Array<U32> & U32:
  match ok empty:
    case False{} _:
      (m, 0)
    case True{} False{}:
      (m, U32.or(v, U32.shln(t, 8n)))
    case True{} True{}:
      firstn(m, t, d, U32.sub(len, 1))

def firstn.c?(+t: U32, +d: U32, +len: U32, ok: Bool, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  firstn.d(m, t, d, len, v, ok, U32.is_zero(v))

def lva.k?(m: Array<U32>, +to: U32, +by: U32, +k: U32, +best: U32, +bestv: U32) -> Array<U32> & U32:
  lva.go(m, to, by, k, best, bestv, U32.is_lt(k, 26) && U32.is_gt(bestv, 100))

def lva.p?(+to: U32, +by: U32, +k: U32, +best: U32, +bestv: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +f) = r
  +p = U32.and(f, 255)
  +t = C.pc.type(p)
  +kn = U32.to_nat(k)
  +ok = U32.is_ne(p, 0) && U32.is_eq(C.pc.color(p), by) &&
    (U32.is_eq(t, B.att.w1(kn)) || U32.is_eq(t, B.att.w2(kn)))
  +v = see.val(U32.to_nat(t))
  +better = ok && U32.is_lt(v, bestv)
  lva.k(m, to, by, U32.add(k, 1), C.sel(better, f, best), C.sel(better, v, bestv))

def lva.go?(m: Array<U32>, +to: U32, +by: U32, +k: U32, +best: U32, +bestv: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case False{}:
      (m, best)
    case True{}:
      +kn = U32.to_nat(k)
      +d = B.neg_if(B.att.off(kn), by)
      lva.p(to, by, k, best, bestv, firstn(m, to, d, B.att.len(kn)))

# the least valuable piece of colour `by` attacking square `to` (packed
# piece | sq << 8), 0 when none
def lva(m: Array<U32>, +to: U32, +by: U32) -> Array<U32> & U32:
  lva.k(m, to, by, 0, 0, 100000)

def see.restore?(m: Array<U32>, +i: U32, +sp: U32) -> Array<U32>:
  see.restore.go(m, i, sp, U32.is_lt(i, sp))

def see.restore.b?(+i: U32, +sp: U32, r: Array<U32> & U32) -> Array<U32>:
  (m, +f) = r
  m[U32.shrn(f, 8n)] <- U32.and(f, 255)
  see.restore(m, U32.add(i, 1), sp)

def see.restore.go?(m: Array<U32>, +i: U32, +sp: U32, go: Bool) -> Array<U32>:
  match go:
    case False{}:
      m
    case True{}:
      see.restore.b(i, sp, m[U32.add(SEEST(), i)])

def see.back.fin?(+sp: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +g0) = r
  (see.restore(m, 0, sp), g0)

def see.back.go?(m: Array<U32>, +d: U32, +sp: U32, go: Bool) -> Array<U32> & U32:
  match go:
    case True{}:
      see.back.b(d, sp, m[U32.add(SEEG(), U32.sub(d, 2))])
    case False{}:
      see.back.fin(sp, m[SEEG()])

# fold the gain list back (gain[d-1] = -max(-gain[d-1], gain[d])), restore
def see.back?(m: Array<U32>, +d: U32, +sp: U32) -> Array<U32> & U32:
  see.back.go(m, d, sp, U32.is_gt(d, 1))

def see.back.c?(+d: U32, +sp: U32, +ga: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +gb) = r
  m[U32.add(SEEG(), U32.sub(d, 2))] <- C.s.neg(C.s.max(C.s.neg(ga), gb))
  see.back(m, U32.sub(d, 1), sp)

def see.back.b?(+d: U32, +sp: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +ga) = r
  see.back.c(d, sp, ga, m[U32.add(SEEG(), U32.sub(d, 1))])

def see.l2?(+to: U32, +stm: U32, +d: U32, +cur: U32, +sp: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +f) = r
  see.l2.b(m, to, stm, d, cur, sp, f, U32.is_zero(f) || U32.is_ge(d, 30))

def see.loop?(m: Array<U32>, +to: U32, +stm: U32, +d: U32, +cur: U32, +sp: U32) -> Array<U32> & U32:
  see.l2(to, stm, d, cur, sp, lva(m, to, stm))

def see.l3?(+to: U32, +stm: U32, +d: U32, +cur: U32, +sp: U32, +f: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +gprev) = r
  m[U32.add(SEEG(), d)] <- U32.sub(cur, gprev)
  m[U32.shrn(f, 8n)] <- 0
  m[U32.add(SEEST(), sp)] <- f
  see.loop(m, to, C.opp(stm), U32.add(d, 1), see.val(U32.to_nat(C.pc.type(U32.and(f, 255)))), U32.add(sp, 1))

def see.l2.b?(m: Array<U32>, +to: U32, +stm: U32, +d: U32, +cur: U32, +sp: U32, +f: U32, done: Bool) ->
  Array<U32> & U32:
  match done:
    case True{}:
      see.back(m, d, sp)
    case False{}:
      see.l3(to, stm, d, cur, sp, f, m[U32.add(SEEG(), U32.sub(d, 1))])

# when the capturer is worth no more than the victim the exchange cannot
# lose material: answer the victim's value without playing it out
def see.c?(m: Array<U32>, +from: U32, +to: U32, +side: U32, +att: U32, +vv: U32, +va: U32, cheap: Bool) ->
  Array<U32> & U32:
  match cheap:
    case True{}:
      (m, vv)
    case False{}:
      m[SEEG()] <- vv
      m[SEEST()] <- U32.or(att, U32.shln(from, 8n))
      m[from] <- 0
      see.loop(m, to, C.opp(side), 1, va, 1)

def see.b?(+from: U32, +to: U32, +side: U32, +att: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +vic) = r
  +va = see.val(U32.to_nat(C.pc.type(att)))
  +vv = see.val(U32.to_nat(C.pc.type(vic)))
  see.c(m, from, to, side, att, vv, va, U32.is_le(va, vv))

def see.a?(+from: U32, +to: U32, +side: U32, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +att) = r
  see.b(from, to, side, att, m[to])

def see.k?(m: Array<U32>, +mv: U32, +side: U32, special: Bool) -> Array<U32> & U32:
  match special:
    case True{}:
      (m, C.sel(U32.is_eq(C.mv.flag(mv), 3), 100, 800))
    case False{}:
      see.a(C.mv.from(mv), C.mv.to(mv), side, m[C.mv.from(mv)])

# SEE value (cp) of the capture mv by `side`; promotions and en passant are
# answered optimistically (as the plain victim value + promotion gain)
def see(m: Array<U32>, +mv: U32, +side: U32) -> Array<U32> & U32:
  see.k(m, mv, side, U32.is_ge(C.mv.flag(mv), 3))
