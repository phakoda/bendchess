# BendChess board: memory layout, position state, make/unmake, attacks,
# move generation, FEN, perft.
#
# Design
# ------
# The engine threads ONE mutable Array<U32> "memory" m through every
# function (Bend arrays are affine, updated in place, so this compiles to
# plain C array code). The 0x88 board lives at m[0..127]; the rest of m
# holds the move stacks, hash history, PV table, killers, history table
# and the transposition table (see the MEM section).
#
# The scalar state (side to move, castling rights, en passant, clocks,
# Zobrist hash, incremental PeSTO scores, king squares) is an immutable
# Data record, Pos. make() returns a fresh Pos and the caller keeps the
# old one, so unmake() only has to restore the board squares.
#
# Bend can only `match` on parameters, so every read m[i] (which answers
# the array and the value as a pair) hands its pair to the next def,
# which destructures it. Loops recurse on U32 counters and are marked
# @unsafe (the `?` suffix): termination is by construction (bounded
# counters), but not structurally checkable.

import Base
import ./core.bend as C
import ./tables.bend as T

# MEM: memory layout
# ------------------

# 2^23 words = 32 MB
def MEM_DEPTH() -> Nat:
  23n

# hash history: 2 words per game index (positions since the root FEN)
def HISTH() -> U32:
  1024

def HIST_MAX() -> U32:
  4000

# move lists: 256 words per search ply
def MOVES() -> U32:
  16384

def MAX_PLY() -> U32:
  120

# triangular PV table: 128 x 128
def PVT() -> U32:
  65536

def PVLEN() -> U32:
  81920

# killer moves: 2 per ply
def KILLERS() -> U32:
  82176

# counter/aux per ply: 4 words per ply (static eval, move made, etc.)
def PLYAUX() -> U32:
  82688

# history heuristic: side << 14 | from << 7 | to
def HISTORY() -> U32:
  98304

# root move table: 8 words per root move (see search.bend)
def ROOT() -> U32:
  131072

# scalar slots (node counter, limits, flags, options)
def SC() -> U32:
  135168

# transposition table: 2^20 entries x 4 words
def TT() -> U32:
  4194304

def TT_MASK() -> U32:
  1048575

def mem.new() -> Array<U32>:
  [0 : U32^23n]

# Position state
# --------------

# occupancy bitboards (0..63 indexing, a1 = 0), lo/hi halves per colour
type Occ is Data:
  Occ{w0: U32, w1: U32, b0: U32, b1: U32}

type Pos is Data:
  Pos{side: U32, castle: U32, ep: U32, half: U32, hidx: U32, wk: U32, bk: U32,
      hlo: U32, hhi: U32, mg: U32, eg: U32, ph: U32, cap: U32, mvd: U32, occ: Occ}

def P.side(+p: Pos) -> U32:
  match p:
    case Pos{side, _, _, _, _, _, _, _, _, _, _, _, _, _, _}:
      side

def P.castle(+p: Pos) -> U32:
  match p:
    case Pos{_, castle, _, _, _, _, _, _, _, _, _, _, _, _, _}:
      castle

def P.ep(+p: Pos) -> U32:
  match p:
    case Pos{_, _, ep, _, _, _, _, _, _, _, _, _, _, _, _}:
      ep

def P.half(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, half, _, _, _, _, _, _, _, _, _, _, _}:
      half

def P.hidx(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, hidx, _, _, _, _, _, _, _, _, _, _}:
      hidx

def P.wk(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, wk, _, _, _, _, _, _, _, _, _}:
      wk

def P.bk(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, bk, _, _, _, _, _, _, _, _}:
      bk

def P.hlo(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, _, hlo, _, _, _, _, _, _, _}:
      hlo

def P.hhi(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, _, _, hhi, _, _, _, _, _, _}:
      hhi

def P.mg(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, _, _, _, mg, _, _, _, _, _}:
      mg

def P.eg(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, _, _, _, _, eg, _, _, _, _}:
      eg

def P.ph(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, _, _, _, _, _, ph, _, _, _}:
      ph

def P.cap(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, _, _, _, _, _, _, cap, _, _}:
      cap

def P.occ(+p: Pos) -> Occ:
  match p:
    case Pos{_, _, _, _, _, _, _, _, _, _, _, _, _, _, occ}:
      occ

def P.mvd(+p: Pos) -> U32:
  match p:
    case Pos{_, _, _, _, _, _, _, _, _, _, _, _, _, mvd, _}:
      mvd

# the king square of colour c
def P.king(+p: Pos, +c: U32) -> U32:
  C.sel(U32.is_zero(c), P.wk(p), P.bk(p))

# a copy of p with the side to move flipped (for null-move search)
def P.null(+p: Pos) -> Pos:
  match p:
    case Pos{side, castle, ep, half, hidx, wk, bk, hlo, hhi, mg, eg, ph, cap, mvd, occ}:
      Pos{C.opp(side), castle, C.NO_SQ(), U32.add(half, 1), U32.add(hidx, 1), wk, bk,
        U32.xor(U32.xor(U32.xor(hlo, C.z.side.lo()), C.z.ep.lo(ep)), C.z.ep.lo(C.NO_SQ())),
        U32.xor(U32.xor(U32.xor(hhi, C.z.side.hi()), C.z.ep.hi(ep)), C.z.ep.hi(C.NO_SQ())),
        mg, eg, ph, 0, 0, occ}

# Incremental accumulators
# ------------------------

# the hash halves, the white-relative PeSTO mg/eg sums and the phase
type Acc is Data:
  Acc{hlo: U32, hhi: U32, mg: U32, eg: U32, ph: U32}

# table index of piece p on 0x88 square s (PeSTO layout, a8 = 0)
def pst.idx(+p: U32, +s: U32) -> Nat:
  +i64 = U32.xor(C.sq.to64(s), U32.and(56, C.bmask(U32.is_zero(C.pc.color(p)))))
  U32.to_nat(U32.add(U32.shln(U32.sub(C.pc.type(p), 1), 6n), i64))

# v negated when c is black
def neg_if(+v: U32, +c: U32) -> U32:
  +k = C.bmask(U32.is_eq(c, 1))
  U32.sub(U32.xor(v, k), k)

# white-relative mg / eg values of piece p on square s (0 for no piece)
def pst.mg(+p: U32, +s: U32) -> U32:
  U32.and(neg_if(T.pst_mg(pst.idx(p, s)), C.pc.color(p)), C.bmask(U32.is_ne(p, 0)))

def pst.eg(+p: U32, +s: U32) -> U32:
  U32.and(neg_if(T.pst_eg(pst.idx(p, s)), C.pc.color(p)), C.bmask(U32.is_ne(p, 0)))

# x + v, or x - v when rem
def addsub(+x: U32, +v: U32, rem: Bool) -> U32:
  match rem:
    case True{}:
      U32.sub(x, v)
    case False{}:
      U32.add(x, v)

# piece p appears on (rem = False) or leaves (rem = True) square s
def acc.tog(a: Acc, +p: U32, +s: U32, +rem: Bool) -> Acc:
  match a:
    case Acc{hlo, hhi, mg, eg, ph}:
      Acc{U32.xor(hlo, C.z.lo(p, s)), U32.xor(hhi, C.z.hi(p, s)),
        addsub(mg, pst.mg(p, s), rem), addsub(eg, pst.eg(p, s), rem),
        addsub(ph, C.pc.phase(p), rem)}

# Make / unmake
# -------------

# the square of the piece captured by mv (differs from the target for ep)
def capsq(+mv: U32, +side: U32) -> U32:
  +t = C.mv.to(mv)
  C.sel(U32.is_eq(C.mv.flag(mv), 3), U32.sub(U32.add(t, U32.shln(side, 5n)), 16), t)

def Pos.fin(+side: U32, +castle: U32, +ep: U32, +half: U32, +hidx: U32, +wk: U32,
            +bk: U32, +cap: U32, +mvd: U32, occ: Occ, a: Acc) -> Pos:
  match a:
    case Acc{hlo, hhi, mg, eg, ph}:
      Pos{side, castle, ep, half, hidx, wk, bk, hlo, hhi, mg, eg, ph, cap, mvd, occ}

# Occupancy bitboards
# -------------------

def bit64(+s: U32) -> U32:
  U32.shln(1, U32.to_nat(U32.and(C.sq.to64(s), 31)))

# toggle square s for colour c when `on` (and s is on the board)
def occ.tog(o: Occ, +c: U32, +s: U32, +on: Bool) -> Occ:
  match o:
    case Occ{w0, w1, b0, b1}:
      +i = C.sq.to64(s)
      +b = U32.and(bit64(s), C.bmask(on && C.sq.ok(s)))
      +hi = U32.is_ge(i, 32)
      +white = U32.is_zero(c)
      Occ{U32.xor(w0, C.sel(white && Bool.not(hi), b, 0)), U32.xor(w1, C.sel(white && hi, b, 0)),
        U32.xor(b0, C.sel(Bool.not(white) && Bool.not(hi), b, 0)), U32.xor(b1, C.sel(Bool.not(white) && hi, b, 0))}

# the state after mv, where pc is the moving piece and cap the captured one
def Pos.after(+p: Pos, +mv: U32, +pc: U32, +cap: U32, +epok: Bool) -> Pos:
  match p:
    case Pos{side, castle, ep, half, hidx, wk, bk, hlo, hhi, mg, eg, ph, _, _, occ}:
      +f = C.mv.from(mv)
      +t = C.mv.to(mv)
      +fl = C.mv.flag(mv)
      +isc = U32.is_eq(fl, 2)
      +npc = C.sel(C.mv.is_promo(mv), C.pc.make(side, C.mv.promo_type(mv)), pc)
      +rk = C.sel(isc, C.pc.make(side, 4), 0)
      +castle2 = U32.and(castle, U32.and(C.castle.keep(f), C.castle.keep(t)))
      +ep2 = C.sel(U32.is_eq(fl, 1) && epok, U32.shrn(U32.add(f, t), 1n), C.NO_SQ())
      +isp = U32.is_eq(C.pc.type(pc), 1)
      +half2 = C.sel(isp || U32.is_ne(cap, 0), 0, U32.add(half, 1))
      +isk = U32.is_eq(C.pc.type(pc), 6)
      +wk2 = C.sel(isk && U32.is_zero(side), t, wk)
      +bk2 = C.sel(isk && U32.is_eq(side, 1), t, bk)
      +hl = U32.xor(U32.xor(U32.xor(hlo, C.z.side.lo()), U32.xor(C.z.castle.lo(castle), C.z.castle.lo(castle2))),
        U32.xor(C.z.ep.lo(ep), C.z.ep.lo(ep2)))
      +hh = U32.xor(U32.xor(U32.xor(hhi, C.z.side.hi()), U32.xor(C.z.castle.hi(castle), C.z.castle.hi(castle2))),
        U32.xor(C.z.ep.hi(ep), C.z.ep.hi(ep2)))
      a0 = {Acc{hl, hh, mg, eg, ph} : Acc}
      a1 = acc.tog(a0, pc, f, True{})
      a2 = acc.tog(a1, npc, t, False{})
      a3 = acc.tog(a2, cap, capsq(mv, side), True{})
      a4 = acc.tog(a3, rk, C.castle.rook_from(t), True{})
      a5 = acc.tog(a4, rk, C.castle.rook_to(t), False{})
      o1 = occ.tog(occ, side, f, True{})
      o2 = occ.tog(o1, side, t, True{})
      o3 = occ.tog(o2, C.opp(side), capsq(mv, side), U32.is_ne(cap, 0))
      o4 = occ.tog(o3, side, C.castle.rook_from(t), isc)
      o5 = occ.tog(o4, side, C.castle.rook_to(t), isc)
      Pos.fin(C.opp(side), castle2, ep2, half2, U32.add(hidx, 1), wk2, bk2, cap, pc, o5, a5)

def make.c(+np: Pos, +mv: U32, +pc: U32, m: Array<U32>) -> Array<U32> & Pos:
  +side = C.opp(P.side(np))
  +f = C.mv.from(mv)
  +t = C.mv.to(mv)
  +isc = U32.is_eq(C.mv.flag(mv), 2)
  +npc = C.sel(C.mv.is_promo(mv), C.pc.make(side, C.mv.promo_type(mv)), pc)
  +rf = C.sel(isc, C.castle.rook_from(t), 8)
  +rt = C.sel(isc, C.castle.rook_to(t), 8)
  +h = U32.add(HISTH(), U32.shln(U32.and(P.hidx(np), 4095), 1n))
  m[f] <- 0
  m[capsq(mv, side)] <- 0
  m[t] <- npc
  m[rf] <- 0
  m[rt] <- C.sel(isc, C.pc.make(side, 4), 0)
  m[h] <- P.hlo(np)
  m[U32.add(h, 1)] <- P.hhi(np)
  (m, np)

def make.ep2(+p: Pos, +mv: U32, +pc: U32, +cap: U32, +a: U32, r: Array<U32> & U32) -> Array<U32> & Pos:
  (m, +b) = r
  +ep_pawn = C.pc.make(C.opp(P.side(p)), 1)
  make.c(Pos.after(p, mv, pc, cap, U32.is_eq(a, ep_pawn) || U32.is_eq(b, ep_pawn)), mv, pc, m)

def make.ep1(+p: Pos, +mv: U32, +pc: U32, +cap: U32, r: Array<U32> & U32) -> Array<U32> & Pos:
  (m, +a) = r
  make.ep2(p, mv, pc, cap, a, m[C.sq.safe(U32.add(C.mv.to(mv), 1))])

def make.ep(+p: Pos, +mv: U32, +pc: U32, +cap: U32, m: Array<U32>, dbl: Bool) -> Array<U32> & Pos:
  match dbl:
    case False{}:
      make.c(Pos.after(p, mv, pc, cap, False{}), mv, pc, m)
    case True{}:
      make.ep1(p, mv, pc, cap, m[C.sq.safe(U32.sub(C.mv.to(mv), 1))])

# a double push records its en-passant square only when an enemy pawn
# stands beside the target (a pseudo-legal ep capture exists), so that
# positions FIDE treats as identical also hash identically
def make.b(+p: Pos, +mv: U32, +pc: U32, r: Array<U32> & U32) -> Array<U32> & Pos:
  (m, +cap) = r
  make.ep(p, mv, pc, cap, m, U32.is_eq(C.mv.flag(mv), 1))

def make.a(+p: Pos, +mv: U32, r: Array<U32> & U32) -> Array<U32> & Pos:
  (m, +pc) = r
  make.b(p, mv, pc, m[capsq(mv, P.side(p))])

# play mv (pseudo-legal) in position p; answers the new state
def make(m: Array<U32>, +p: Pos, +mv: U32) -> Array<U32> & Pos:
  make.a(p, mv, m[C.mv.from(mv)])

# undo mv, where np is the state make() answered for it
def unmake(m: Array<U32>, +np: Pos, +mv: U32) -> Array<U32>:
  +us = C.opp(P.side(np))
  +f = C.mv.from(mv)
  +t = C.mv.to(mv)
  +isc = U32.is_eq(C.mv.flag(mv), 2)
  +rf = C.sel(isc, C.castle.rook_from(t), 8)
  +rt = C.sel(isc, C.castle.rook_to(t), 8)
  m[t] <- 0
  m[capsq(mv, us)] <- P.cap(np)
  m[f] <- P.mvd(np)
  m[rt] <- 0
  m[rf] <- C.sel(isc, C.pc.make(us, 4), 0)
  m

# Attack detection
# ----------------
# Square sq is attacked by colour `by` if some probe k in 0..25 finds an
# attacker. A probe walks up to len(k) squares from sq along off(k) (the
# offsets are negated for black, which only matters for pawns) and checks
# whether the first piece it meets is one of the two wanted types.

def att.off(k: Nat) -> U32:
  match k:
    case 0n:
      4294967281
    case 1n:
      4294967279
    case 2n:
      33
    case 3n:
      31
    case 4n:
      18
    case 5n:
      14
    case 6n:
      4294967263
    case 7n:
      4294967265
    case 8n:
      4294967278
    case 9n:
      4294967282
    case 10n:
      16
    case 11n:
      4294967280
    case 12n:
      1
    case 13n:
      4294967295
    case 14n:
      17
    case 15n:
      15
    case 16n:
      4294967279
    case 17n:
      4294967281
    case 18n:
      16
    case 19n:
      4294967280
    case 20n:
      1
    case 21n:
      4294967295
    case 22n:
      17
    case 23n:
      15
    case 24n:
      4294967279
    case _:
      4294967281

def att.len(k: Nat) -> U32:
  match k:
    case 18n+_:
      8
    case _:
      1

def att.w1.hi2(j: Nat) -> U32:
  match j:
    case 12n+_:
      3
    case _:
      4

def att.w1.hi(j: Nat) -> U32:
  match j:
    case 8n+_:
      att.w1.hi2(j)
    case _:
      6

def att.w1(k: Nat) -> U32:
  match k:
    case 0n:
      1
    case 1n:
      1
    case 10n+j:
      att.w1.hi(j)
    case _:
      2

def att.w2(k: Nat) -> U32:
  match k:
    case 18n+_:
      5
    case _:
      att.w1(k)

# Move generation
# ---------------
# gen(m, p, base, qs) writes pseudo-legal moves at m[base..] and answers
# their count. qs = 1 generates only captures and queen promotions.
#
# Direction table: 0..3 orthogonal, 4..7 diagonal, 8..15 knight jumps.

def dir(i: Nat) -> U32:
  match i:
    case 0n:
      16
    case 1n:
      4294967280
    case 2n:
      1
    case 3n:
      4294967295
    case 4n:
      17
    case 5n:
      15
    case 6n:
      4294967279
    case 7n:
      4294967281
    case 8n:
      33
    case 9n:
      31
    case 10n:
      18
    case 11n:
      14
    case 12n:
      4294967263
    case 13n:
      4294967265
    case 14n:
      4294967278
    case _:
      4294967282

# write move mv at m[base + n] when `keep`; answers the new count
def push(m: Array<U32>, +base: U32, +n: U32, +mv: U32, keep: Bool) -> Array<U32> & U32:
  match keep:
    case True{}:
      m[U32.add(base, n)] <- mv
      (m, U32.add(n, 1))
    case False{}:
      (m, n)

# promotions from f to t: queen only in qs mode, else all four
def gen.promos(m: Array<U32>, +base: U32, +n: U32, +f: U32, +t: U32, +qs: U32) ->
  Array<U32> & U32:
  +all = U32.is_zero(qs)
  m[U32.add(base, n)] <- C.mv.make(f, t, 7)
  m[U32.add(base, U32.add(n, 1))] <- C.mv.make(f, t, 4)
  m[U32.add(base, U32.add(n, 2))] <- C.mv.make(f, t, 6)
  m[U32.add(base, U32.add(n, 3))] <- C.mv.make(f, t, 5)
  (m, U32.add(n, C.sel(all, 4, 1)))

# a pawn move to t, as a promotion when it reaches the last rank
def gen.pmove(m: Array<U32>, +base: U32, +n: U32, +f: U32, +t: U32, +qs: U32, promo: Bool,
              keep: Bool) -> Array<U32> & U32:
  match promo keep:
    case _ False{}:
      (m, n)
    case True{} True{}:
      gen.promos(m, base, n, f, t, qs)
    case False{} True{}:
      m[U32.add(base, n)] <- C.mv.make(f, t, 0)
      (m, U32.add(n, 1))

# double push: the square beyond t is read in r
def gen.dbl(+base: U32, +f: U32, +t2: U32, +qs: U32, +n: U32, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +v) = r
  push(m, base, n, C.mv.make(f, t2, 1), U32.is_zero(v) && U32.is_zero(qs))

def gen.dbl.if(+base: U32, +f: U32, +t2: U32, +qs: U32, ok: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  match ok:
    case False{}:
      r
    case True{}:
      (m, +n) = r
      gen.dbl(base, f, t2, qs, n, m[t2])

# single push read in r; then maybe the double push
def gen.push1(+base: U32, +f: U32, +t: U32, +fwd: U32, +qs: U32, +n: U32, +promo: Bool,
              +start: Bool, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  +empty = U32.is_zero(v)
  gen.dbl.if(base, f, U32.add(t, fwd), qs, empty && start,
    gen.pmove(m, base, n, f, t, qs, promo, empty && (promo || U32.is_zero(qs))))

def gen.pcap.e(+base: U32, +f: U32, +t: U32, +n0: U32, isep: Bool, r: Array<U32> & U32) ->
  Array<U32> & U32:
  (m, +n) = r
  push(m, base, n, C.mv.make(f, t, 3), isep)

# pawn capture toward t (read in r): a capture, an en passant, or nothing
def gen.pcap.d(+us: U32, +ep: U32, +base: U32, +f: U32, +t: U32, +qs: U32, +n: U32,
               +promo: Bool, +ok: Bool, r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +v) = r
  +isep = ok && U32.is_eq(t, ep)
  +iscap = ok && U32.is_ne(v, 0) && U32.is_ne(C.pc.color(v), us)
  gen.pcap.e(base, f, t, n, isep, gen.pmove(m, base, n, f, t, qs, promo, iscap))

def gen.pcap(m: Array<U32>, +us: U32, +ep: U32, +base: U32, +f: U32, +t: U32, +qs: U32,
             +n: U32, +promo: Bool) -> Array<U32> & U32:
  gen.pcap.d(us, ep, base, f, t, qs, n, promo, C.sq.ok(t), m[C.sq.safe(t)])

def gen.pawn.c(+us: U32, +ep: U32, +base: U32, +f: U32, +t: U32, +qs: U32, +promo: Bool,
               r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  gen.pcap(m, us, ep, base, f, U32.add(t, 1), qs, n, promo)

def gen.pawn.b(+us: U32, +ep: U32, +base: U32, +f: U32, +t: U32, +qs: U32, +promo: Bool,
               r: Array<U32> & U32) -> Array<U32> & U32:
  (m, +n) = r
  gen.pawn.c(us, ep, base, f, t, qs, promo, gen.pcap(m, us, ep, base, f, U32.sub(t, 1), qs, n, promo))

def gen.pawn(m: Array<U32>, +us: U32, +ep: U32, +base: U32, +qs: U32, +f: U32, +n: U32) ->
  Array<U32> & U32:
  +white = U32.is_zero(us)
  +fwd = C.sel(white, 16, 4294967280)
  +t = U32.add(f, fwd)
  +promo = U32.is_eq(C.sq.rank(t), C.sel(white, 7, 0))
  +start = U32.is_eq(C.sq.rank(f), C.sel(white, 1, 6))
  gen.pawn.b(us, ep, base, f, t, qs, promo, gen.push1(base, f, t, fwd, qs, n, promo, start, m[t]))

# Check chains: small combinators threading (memory, ok) pairs.

def chk.e2(r: Array<U32> & U32) -> Array<U32> & Bool:
  (m, +v) = r
  (m, U32.is_zero(v))

# still ok and square sq empty?
def chk.empty(+sq: U32, r: Array<U32> & Bool) -> Array<U32> & Bool:
  match r:
    case (m, False{}):
      (m, False{})
    case (m, True{}):
      chk.e2(m[sq])

def chk.not(r: Array<U32> & Bool) -> Array<U32> & Bool:
  match r:
    case (m, True{}):
      (m, False{})
    case (m, False{}):
      (m, True{})

def chk.push(+base: U32, +n: U32, +mv: U32, r: Array<U32> & Bool) -> Array<U32> & U32:
  match r:
    case (m, True{}):
      m[U32.add(base, n)] <- mv
      (m, U32.add(n, 1))
    case (m, False{}):
      (m, n)

def occ.lo(o: Occ, +c: U32) -> U32:
  match o:
    case Occ{w0, w1, b0, b1}:
      C.sel(U32.is_zero(c), w0, b0)

def occ.hi(o: Occ, +c: U32) -> U32:
  match o:
    case Occ{w0, w1, b0, b1}:
      C.sel(U32.is_zero(c), w1, b1)

# index of the lowest set bit of x (x != 0)
def ctz(+x: U32) -> U32:
  T.debruijn(U32.to_nat(U32.shrn(U32.mul(U32.and(x, U32.sub(0, x)), 125613361), 27n)))

# Text helpers
# ------------

def str.char(+c: U32) -> String:
  SCon{Chr{c}, SNil{}}

def str.nth.m(x: Maybe<&2, String>, d: String) -> String:
  match x:
    case None{}:
      d
    case Some{v}:
      v

# the n-th element of a list of strings, or d
def str.nth(xs: List<&2, String>, n: Nat, d: String) -> String:
  str.nth.m(List.get(&2, String, xs, n), d)

def str.u32.m(x: Maybe<&2, U32>, +d: U32) -> U32:
  match x:
    case None{}:
      d
    case Some{v}:
      v

def str.u32(s: String, +d: U32) -> U32:
  str.u32.m(U32.read(s), d)

# "e4" for 0x88 square s
def sq.name(+s: U32) -> String:
  SCon{Chr{U32.add(97, C.sq.file(s))}, SCon{Chr{U32.add(49, C.sq.rank(s))}, SNil{}}}

def promo.suffix(fl: Nat) -> String:
  match fl:
    case 4n:
      "n"
    case 5n:
      "b"
    case 6n:
      "r"
    case 7n:
      "q"
    case _:
      ""

def mv.uci.go(+mv: U32, null: Bool) -> String:
  match null:
    case True{}:
      "0000"
    case False{}:
      sq.name(C.mv.from(mv)) ++ sq.name(C.mv.to(mv)) ++ promo.suffix(U32.to_nat(C.mv.flag(mv)))

# long algebraic (UCI) notation of a move, "0000" for the null move
def mv.uci(+mv: U32) -> String:
  mv.uci.go(mv, U32.is_zero(C.mv.bare(mv)))

# a move's identity as UCI sees it: from, to and promotion piece only
def mv.ukey(+mv: U32) -> U32:
  +fl = C.mv.flag(mv)
  U32.or(U32.and(mv, 16383), U32.shln(C.sel(U32.is_ge(fl, 4), fl, 0), 14n))

def promo.of_char(c: Nat) -> U32:
  match c:
    case 110n:
      4
    case 98n:
      5
    case 114n:
      6
    case 113n:
      7
    case _:
      0

def uci.key.promo(s: String) -> U32:
  match s:
    case SCon{c, _}:
      promo.of_char(U32.to_nat(Char.to_u32(c)))
    case SNil{}:
      0

# the ukey of a UCI move string ("e7e8q"); 0 when malformed
def uci.key(s: String) -> U32:
  match s:
    case SCon{a, SCon{b, SCon{c, SCon{d, rest}}}}:
      +f = C.sq.make(U32.sub(Char.to_u32(a), 97), U32.sub(Char.to_u32(b), 49))
      +t = C.sq.make(U32.sub(Char.to_u32(c), 97), U32.sub(Char.to_u32(d), 49))
      U32.or(U32.or(f, U32.shln(t, 7n)), U32.shln(uci.key.promo(rest), 14n))
    case _:
      0

# FEN parsing
# -----------

def fen.piece(c: Nat) -> U32:
  match c:
    case 80n:
      1
    case 78n:
      2
    case 66n:
      3
    case 82n:
      4
    case 81n:
      5
    case 75n:
      6
    case 112n:
      9
    case 110n:
      10
    case 98n:
      11
    case 114n:
      12
    case 113n:
      13
    case 107n:
      14
    case _:
      0

def b2n(b: Bool) -> U32:
  C.b2u(b)

def fen.castle.bit(c: Nat) -> U32:
  match c:
    case 75n:
      1
    case 81n:
      2
    case 107n:
      4
    case 113n:
      8
    case _:
      0

def fen.castle(s: String, +acc: U32) -> U32:
  match s:
    case SNil{}:
      acc
    case SCon{c, rest}:
      fen.castle(rest, U32.or(acc, fen.castle.bit(U32.to_nat(Char.to_u32(c)))))

def fen.ep(s: String) -> U32:
  match s:
    case SCon{a, SCon{b, _}}:
      +f = U32.sub(Char.to_u32(a), 97)
      +r = U32.sub(Char.to_u32(b), 49)
      C.sel(U32.is_lt(f, 8) && U32.is_lt(r, 8), C.sq.make(f, r), C.NO_SQ())
    case _:
      C.NO_SQ()

def fen.side(s: String) -> U32:
  match s:
    case SCon{c, _}:
      C.b2u(U32.is_eq(Char.to_u32(c), 98))
    case SNil{}:
      0

# Board scan: recompute kings, hash and PeSTO sums from scratch
type Scan is Data:
  Scan{a: Acc, wk: U32, bk: U32, occ: Occ}

def scan.add(s: Scan, +v: U32, +sq: U32) -> Scan:
  match s:
    case Scan{a, wk, bk, occ}:
      Scan{acc.tog(a, v, sq, False{}), C.sel(U32.is_eq(v, 6), sq, wk), C.sel(U32.is_eq(v, 14), sq, bk),
        occ.tog(occ, C.pc.color(v), sq, U32.is_ne(v, 0))}

def fen.pos.a(+side: U32, +castle: U32, +ep: U32, +half: U32, +wk: U32, +bk: U32, occ: Occ,
              m: Array<U32>, a: Acc) -> Array<U32> & Pos:
  match a:
    case Acc{+hlo, +hhi, mg, eg, ph}:
      +np = {Pos{side, castle, ep, half, 0, wk, bk, hlo, hhi, mg, eg, ph, 0, 0, occ} : Pos}
      m[HISTH()] <- hlo
      m[U32.add(HISTH(), 1)] <- hhi
      (m, np)

def fen.pos(+side: U32, +castle: U32, +ep: U32, +half: U32, r: Array<U32> & Scan) ->
  Array<U32> & Pos:
  (m, s) = r
  match s:
    case Scan{a, wk, bk, occ}:
      fen.pos.a(side, castle, ep, half, wk, bk, occ, m, a)

def START_FEN() -> String:
  "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

# FEN output
# ----------

def fen.pchar(p: Nat) -> String:
  match p:
    case 1n:
      "P"
    case 2n:
      "N"
    case 3n:
      "B"
    case 4n:
      "R"
    case 5n:
      "Q"
    case 6n:
      "K"
    case 9n:
      "p"
    case 10n:
      "n"
    case 11n:
      "b"
    case 12n:
      "r"
    case 13n:
      "q"
    case 14n:
      "k"
    case _:
      "?"

def fen.gap.go(+e: U32, z: Bool) -> String:
  match z:
    case True{}:
      ""
    case False{}:
      U32.show(e)

# the run of empty squares, if any
def fen.gap(+e: U32) -> String:
  fen.gap.go(e, U32.is_zero(e))

def fen.cflag.go(s: String, on: Bool) -> String:
  match on:
    case True{}:
      s
    case False{}:
      ""

def fen.cflag(+c: U32, +bit: U32, s: String) -> String:
  fen.cflag.go(s, U32.is_ne(U32.and(c, bit), 0))

def fen.castle.str.go(+c: U32, none: Bool) -> String:
  match none:
    case True{}:
      "-"
    case False{}:
      fen.cflag(c, 1, "K") ++ fen.cflag(c, 2, "Q") ++ fen.cflag(c, 4, "k") ++ fen.cflag(c, 8, "q")

def fen.castle.str(+c: U32) -> String:
  fen.castle.str.go(c, U32.is_zero(c))

def fen.ep.str.go(+e: U32, ok: Bool) -> String:
  match ok:
    case True{}:
      sq.name(e)
    case False{}:
      "-"

def fen.ep.str(+e: U32) -> String:
  fen.ep.str.go(e, C.sq.ok(e))

def fen.side.str.go(w: Bool) -> String:
  match w:
    case True{}:
      "w"
    case False{}:
      "b"

def fen.side.str(+s: U32) -> String:
  fen.side.str.go(U32.is_zero(s))

def fen.tail.b(+p: Pos, +full0: U32, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +side0) = r
  +full = U32.add(full0, U32.shrn(U32.add(P.hidx(p), side0), 1n))
  (m, " " ++ fen.side.str(P.side(p)) ++ " " ++ fen.castle.str(P.castle(p)) ++ " " ++
      fen.ep.str(P.ep(p)) ++ " " ++ U32.show(P.half(p)) ++ " " ++ U32.show(full))

def fen.tail(+p: Pos, r: Array<U32> & U32) -> Array<U32> & String:
  (m, +full0) = r
  fen.tail.b(p, full0, m[U32.add(SC(), 11)])

def fen.out.c(board: String, r: Array<U32> & String) -> Array<U32> & String:
  (m, tail) = r
  (m, board ++ tail)

def fen.out.b(+p: Pos, r: Array<U32> & String) -> Array<U32> & String:
  (m, board) = r
  fen.out.c(board, fen.tail(p, m[U32.add(SC(), 10)]))

# Legal moves
# -----------

# answer (m, legal?) for pseudo-legal move mv in position p
def legal.b(+np: Pos, +mv: U32, r: Array<U32> & Bool) -> Array<U32> & Bool:
  match r:
    case (m, ill):
      (unmake(m, np, mv), Bool.not(ill))

# Delta-table attack helpers
# --------------------------
# T.delta(to - from + 119): which piece kinds attack along that 0x88
# difference (1 white pawn, 2 black pawn, 4 knight, 8 diagonal line,
# 16 orthogonal line, 32 king) and the unit step of a line (bits 8..15,
# biased by 32).

def dinfo(+from: U32, +to: U32) -> U32:
  T.delta(U32.to_nat(U32.and(U32.add(U32.sub(to, from), 119), 255)))

def dstep(+info: U32) -> U32:
  U32.sub(U32.and(U32.shrn(info, 8n), 255), 32)

# is the packed piece `found` a colour-c slider moving along lines of kind
# lineb (8 diagonal, 16 orthogonal)?
def slider.hits(+found: U32, +c: U32, +lineb: U32) -> Bool:
  +p = U32.and(found, 255)
  +t = C.pc.type(p)
  U32.is_ne(p, 0) && U32.is_eq(C.pc.color(p), c) &&
    (U32.is_eq(t, 5) || (U32.is_eq(lineb, 8) && U32.is_eq(t, 3)) || (U32.is_eq(lineb, 16) && U32.is_eq(t, 4)))

def ray.hit(+c: U32, +lineb: U32, r: Array<U32> & U32) -> Array<U32> & Bool:
  (m, +found) = r
  (m, slider.hits(found, c, lineb))

# play a null move (side to move passes); records the hash history
def null.make(m: Array<U32>, +p: Pos) -> Array<U32> & Pos:
  +np = P.null(p)
  +h = U32.add(HISTH(), U32.shln(U32.and(P.hidx(np), 4095), 1n))
  m[h] <- P.hlo(np)
  m[U32.add(h, 1)] <- P.hhi(np)
  (m, np)

def popcnt(+x0: U32) -> U32:
  +x1 = U32.sub(x0, U32.and(U32.shrn(x0, 1n), 1431655765))
  +x2 = U32.add(U32.and(x1, 858993459), U32.and(U32.shrn(x1, 2n), 858993459))
  +x3 = U32.and(U32.add(x2, U32.shrn(x2, 4n)), 252645135)
  U32.shrn(U32.mul(x3, 16843009), 24n)

def npieces.o(o: Occ) -> U32:
  match o:
    case Occ{w0, w1, b0, b1}:
      U32.add(U32.add(popcnt(w0), popcnt(w1)), U32.add(popcnt(b0), popcnt(b1)))

# number of pieces on the board (kings included)
def npieces(+p: Pos) -> U32:
  npieces.o(P.occ(p))

# dead position (no sequence of legal moves can mate): K v K, K+minor v K
def dead(+p: Pos) -> Bool:
  +n = npieces(p)
  U32.is_eq(n, 2) || (U32.is_eq(n, 3) && U32.is_eq(P.ph(p), 1))
