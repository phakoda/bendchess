# BendChess core: total, @unsafe-free definitions shared by the engine and
# by LAWS.bend. Everything here is a pure function on U32 words.
#
# Squares are 0x88 indices: sq = rank * 16 + file, with file, rank in 0..7.
# A square is on the board iff sq & 0x88 == 0 (we test the full word with
# 0xFFFFFF88 so wrapped-around negative offsets are rejected too).
#
# Pieces: 0 empty; colour << 3 | type, colour 0 white / 1 black, type
# 1 pawn, 2 knight, 3 bishop, 4 rook, 5 queen, 6 king. So white 1..6,
# black 9..14.
#
# Moves (17 bits): from | to << 7 | flag << 14, with flag
#   0 normal (quiet or capture), 1 pawn double push, 2 castle,
#   3 en passant, 4..7 promotion to knight, bishop, rook, queen.
# In move lists the bits above 17 hold an ordering key.
#
# Scores are two's-complement signed values in a U32 (Bend has no signed
# integers); s.lt and friends compare them.

import Base

# Bool helpers
# ------------

def b2u(b: Bool) -> U32:
  match b:
    case False{}:
      0
    case True{}:
      1

# all ones when b, else 0
def bmask(b: Bool) -> U32:
  U32.sub(0, b2u(b))

# b ? x : y, computed without a branch (both sides are evaluated)
def sel(b: Bool, +x: U32, +y: U32) -> U32:
  +k = bmask(b)
  U32.or(U32.and(x, k), U32.and(y, U32.not(k)))

# Signed arithmetic
# -----------------

def s.lt(a: U32, b: U32) -> Bool:
  U32.is_lt(U32.xor(a, 2147483648), U32.xor(b, 2147483648))

def s.gt(a: U32, b: U32) -> Bool:
  s.lt(b, a)

def s.le(a: U32, b: U32) -> Bool:
  Bool.not(s.lt(b, a))

def s.ge(a: U32, b: U32) -> Bool:
  Bool.not(s.lt(a, b))

def s.neg(a: U32) -> U32:
  U32.sub(0, a)

def s.max(+a: U32, +b: U32) -> U32:
  sel(s.lt(a, b), b, a)

def s.min(+a: U32, +b: U32) -> U32:
  sel(s.lt(a, b), a, b)

def s.abs(+a: U32) -> U32:
  sel(s.lt(a, 0), s.neg(a), a)

# arithmetic shift right by n (floor division by 2^n for signed values)
def s.shr(+a: U32, n: Nat) -> U32:
  +neg = bmask(s.lt(a, 0))
  U32.xor(U32.shrn(U32.xor(a, neg), n), neg)

# signed division by a positive divisor, rounding toward zero
def s.div(+a: U32, +d: U32) -> U32:
  sel(s.lt(a, 0), s.neg(U32.div(s.neg(a), d)), U32.div(a, d))

def s.show.go(+a: U32, neg: Bool) -> String:
  match neg:
    case True{}:
      "-" ++ U32.show(s.neg(a))
    case False{}:
      U32.show(a)

# a signed value to text
def s.show(+a: U32) -> String:
  s.show.go(a, s.lt(a, 0))

# Scores
# ------

def INF() -> U32:
  32001

def MATE() -> U32:
  32000

# scores beyond this are mate scores
def MATE_BOUND() -> U32:
  31000

# Squares
# -------

def sq.make(+f: U32, +r: U32) -> U32:
  U32.add(U32.shln(r, 4n), f)

def sq.file(s: U32) -> U32:
  U32.and(s, 7)

def sq.rank(s: U32) -> U32:
  U32.shrn(s, 4n)

def sq.ok(s: U32) -> Bool:
  U32.is_zero(U32.and(s, 4294967176))

# an on-board square stays itself; anything else goes to 8, an off-board
# slot of the 0x88 array that always holds 0
def sq.safe(+s: U32) -> U32:
  sel(sq.ok(s), s, 8)

# 0x88 -> 0..63 and back
def sq.to64(+s: U32) -> U32:
  U32.shrn(U32.add(s, U32.and(s, 7)), 1n)

def sq.from64(+s: U32) -> U32:
  U32.add(s, U32.and(s, 56))

def NO_SQ() -> U32:
  128

# Colours and pieces
# ------------------

def WHITE() -> U32:
  0

def BLACK() -> U32:
  1

def PAWN() -> U32:
  1

def KNIGHT() -> U32:
  2

def BISHOP() -> U32:
  3

def ROOK() -> U32:
  4

def QUEEN() -> U32:
  5

def KING() -> U32:
  6

def pc.make(+c: U32, +t: U32) -> U32:
  U32.or(U32.shln(c, 3n), t)

def pc.color(p: U32) -> U32:
  U32.and(U32.shrn(p, 3n), 1)

def pc.type(p: U32) -> U32:
  U32.and(p, 7)

def opp(c: U32) -> U32:
  U32.xor(c, 1)

def pc.phase.t(t: Nat) -> U32:
  match t:
    case 2n:
      1
    case 3n:
      1
    case 4n:
      2
    case 5n:
      4
    case _:
      0

# game-phase weight of a piece (PeSTO): N 1, B 1, R 2, Q 4
def pc.phase(+p: U32) -> U32:
  pc.phase.t(U32.to_nat(pc.type(p)))

# Moves
# -----

def mv.make(+f: U32, +t: U32, +fl: U32) -> U32:
  U32.or(U32.or(f, U32.shln(t, 7n)), U32.shln(fl, 14n))

def mv.from(m: U32) -> U32:
  U32.and(m, 127)

def mv.to(m: U32) -> U32:
  U32.and(U32.shrn(m, 7n), 127)

def mv.flag(m: U32) -> U32:
  U32.and(U32.shrn(m, 14n), 7)

# the move without its ordering key
def mv.bare(m: U32) -> U32:
  U32.and(m, 131071)

def mv.is_promo(+m: U32) -> Bool:
  U32.is_ge(mv.flag(m), 4)

# promotion flag -> piece type (4..7 -> 2..5)
def mv.promo_type(+m: U32) -> U32:
  U32.sub(mv.flag(m), 2)

def FL_NORMAL() -> U32:
  0

def FL_DOUBLE() -> U32:
  1

def FL_CASTLE() -> U32:
  2

def FL_EP() -> U32:
  3

def castle.keep.n(s: Nat) -> U32:
  match s:
    case 0n:
      13
    case 4n:
      12
    case 7n:
      14
    case 112n:
      7
    case 116n:
      3
    case 119n:
      11
    case _:
      15

# Castling rights: 1 white king side, 2 white queen side,
# 4 black king side, 8 black queen side. A move that touches square s
# (as origin or target) keeps rights & castle.keep(s).
def castle.keep(+s: U32) -> U32:
  castle.keep.n(U32.to_nat(s))

def castle.rook_from.n(t: Nat) -> U32:
  match t:
    case 6n:
      7
    case 2n:
      0
    case 118n:
      119
    case 114n:
      112
    case _:
      128

# Castling geometry, by king target square: the rook's origin and target.
# For any other square both are NO_SQ.
def castle.rook_from(+t: U32) -> U32:
  castle.rook_from.n(U32.to_nat(t))

def castle.rook_to.n(t: Nat) -> U32:
  match t:
    case 6n:
      5
    case 2n:
      3
    case 118n:
      117
    case 114n:
      115
    case _:
      128

def castle.rook_to(+t: U32) -> U32:
  castle.rook_to.n(U32.to_nat(t))

# Hashing
# -------

# lowbias32 integer mixer (Chris Wellons): a fast bijective 32-bit hash
def mix(+x0: U32) -> U32:
  +x1 = U32.xor(x0, U32.shrn(x0, 16n))
  +x2 = U32.mul(x1, 2146121005)
  +x3 = U32.xor(x2, U32.shrn(x2, 15n))
  +x4 = U32.mul(x3, 2221713035)
  U32.xor(x4, U32.shrn(x4, 16n))

# Zobrist keys of piece p on square s; 0 for the empty piece so that
# toggling "no piece" is a no-op
def z.lo(+p: U32, +s: U32) -> U32:
  U32.and(mix(U32.add(U32.add(U32.shln(p, 7n), s), 2654435769)),
    bmask(U32.is_ne(p, 0)))

def z.hi(+p: U32, +s: U32) -> U32:
  U32.and(mix(U32.add(U32.xor(U32.add(U32.shln(p, 7n), s), 1431655765), 3735928559)),
    bmask(U32.is_ne(p, 0)))

def z.side.lo() -> U32:
  mix(305419896)

def z.side.hi() -> U32:
  mix(2271560481)

def z.castle.lo(+r: U32) -> U32:
  mix(U32.add(r, 1000003))

def z.castle.hi(+r: U32) -> U32:
  mix(U32.add(r, 2000003))

# en-passant key: by file, 0 when there is no ep square
def z.ep.lo(+e: U32) -> U32:
  U32.and(mix(U32.add(sq.file(e), 3000017)), bmask(sq.ok(e)))

def z.ep.hi(+e: U32) -> U32:
  U32.and(mix(U32.add(sq.file(e), 4000037)), bmask(sq.ok(e)))
