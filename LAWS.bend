# BendChess laws: correctness properties of the engine's core encodings
# and of its make-move state transition, stated over the engine's own
# definitions (src/core.bend, src/board.bend). PROOF.bend proves each one;
# `bend PROOF.bend` checks them.
#
# What is and is not covered: these laws cover square coordinates and the
# 0x88 off-board test, the direction table, colours, piece and move
# encodings, promotion metadata, the castling-rights table, branch-free
# selection, and the side-to-move / ply / undo-record / castling-rights
# behaviour of Pos.after (the state update inside make()) for EVERY position
# and move. They do not cover move generation, legality, search or
# evaluation; those are tested (perft, rules and search tests), not proven.
#
# Finite-domain laws quantify over the enumerations below; the others
# quantify over all U32 values or all positions.

import Base
import ./src/core.bend as C
import ./src/board.bend as B

# Finite domains
# --------------

type Column is Data:
  FA{}
  FB{}
  FC{}
  FD{}
  FE{}
  FF{}
  FG{}
  FH{}

type Rank is Data:
  R1{}
  R2{}
  R3{}
  R4{}
  R5{}
  R6{}
  R7{}
  R8{}

type Color is Data:
  White{}
  Black{}

type PType is Data:
  Pawn{}
  Knight{}
  Bishop{}
  Rook{}
  Queen{}
  King{}

type Flag is Data:
  Quiet{}
  Double{}
  Castle{}
  EnPassant{}
  PromoN{}
  PromoB{}
  PromoR{}
  PromoQ{}

# king steps and knight jumps, as (dx, dy)
type Step is Data:
  N{}
  S{}
  E{}
  W{}
  NE{}
  NW{}
  SW{}
  SE{}
  NNE{}
  NNW{}
  NEE{}
  NWW{}
  SSW{}
  SSE{}
  SWW{}
  SEE{}

def file.u32(f: Column) -> U32:
  match f:
    case FA{}:
      0
    case FB{}:
      1
    case FC{}:
      2
    case FD{}:
      3
    case FE{}:
      4
    case FF{}:
      5
    case FG{}:
      6
    case FH{}:
      7

def rank.u32(r: Rank) -> U32:
  match r:
    case R1{}:
      0
    case R2{}:
      1
    case R3{}:
      2
    case R4{}:
      3
    case R5{}:
      4
    case R6{}:
      5
    case R7{}:
      6
    case R8{}:
      7

def color.u32(c: Color) -> U32:
  match c:
    case White{}:
      0
    case Black{}:
      1

def ptype.u32(t: PType) -> U32:
  match t:
    case Pawn{}:
      1
    case Knight{}:
      2
    case Bishop{}:
      3
    case Rook{}:
      4
    case Queen{}:
      5
    case King{}:
      6

def flag.u32(g: Flag) -> U32:
  match g:
    case Quiet{}:
      0
    case Double{}:
      1
    case Castle{}:
      2
    case EnPassant{}:
      3
    case PromoN{}:
      4
    case PromoB{}:
      5
    case PromoR{}:
      6
    case PromoQ{}:
      7

# step components as two's-complement U32 (4294967295 = -1)
def step.dx(s: Step) -> U32:
  match s:
    case N{}:
      0
    case S{}:
      0
    case E{}:
      1
    case W{}:
      4294967295
    case NE{}:
      1
    case NW{}:
      4294967295
    case SW{}:
      4294967295
    case SE{}:
      1
    case NNE{}:
      1
    case NNW{}:
      4294967295
    case NEE{}:
      2
    case NWW{}:
      4294967294
    case SSW{}:
      4294967295
    case SSE{}:
      1
    case SWW{}:
      4294967294
    case SEE{}:
      2

def step.dy(s: Step) -> U32:
  match s:
    case N{}:
      1
    case S{}:
      4294967295
    case E{}:
      0
    case W{}:
      0
    case NE{}:
      1
    case NW{}:
      1
    case SW{}:
      4294967295
    case SE{}:
      4294967295
    case NNE{}:
      2
    case NNW{}:
      2
    case NEE{}:
      1
    case NWW{}:
      1
    case SSW{}:
      4294967294
    case SSE{}:
      4294967294
    case SWW{}:
      4294967295
    case SEE{}:
      4294967295

# the step as a 0x88 offset: dy * 16 + dx
def step.off(+s: Step) -> U32:
  U32.add(U32.mul(step.dy(s), 16), step.dx(s))

# the engine's direction-table index of each step (board.bend: dir)
def step.idx(s: Step) -> Nat:
  match s:
    case N{}:
      0n
    case S{}:
      1n
    case E{}:
      2n
    case W{}:
      3n
    case NE{}:
      4n
    case NW{}:
      5n
    case SW{}:
      6n
    case SE{}:
      7n
    case NNE{}:
      8n
    case NNW{}:
      9n
    case NEE{}:
      10n
    case NWW{}:
      11n
    case SSW{}:
      12n
    case SSE{}:
      13n
    case SWW{}:
      14n
    case SEE{}:
      15n

def square(+f: Column, +r: Rank) -> U32:
  C.sq.make(file.u32(f), rank.u32(r))

# Specifications written independently of the engine code
# -------------------------------------------------------

# the promoted piece type of each flag (0: not a promotion)
def promo.spec(g: Flag) -> U32:
  match g:
    case PromoN{}:
      2
    case PromoB{}:
      3
    case PromoR{}:
      4
    case PromoQ{}:
      5
    case _:
      0

# castling rights kept by a move touching a square: a king's home square
# clears both of its side's rights, a rook's home square clears that one
# right (bits: 1 white O-O, 2 white O-O-O, 4 black O-O, 8 black O-O-O)
def keep.spec(f: Column, r: Rank) -> U32:
  match f r:
    case FE{} R1{}:
      12
    case FA{} R1{}:
      13
    case FH{} R1{}:
      14
    case FE{} R8{}:
      3
    case FA{} R8{}:
      7
    case FH{} R8{}:
      11
    case _ _:
      15

# Laws: encodings
# ---------------

# every (file, rank) is an on-board square whose coordinates, 0..63 index
# and off-board guard round-trip
law square_coordinates:
  for +f: Column
  for +r: Rank
  Pair({C.sq.file(square(f, r)) == file.u32(f) : U32},
    Pair({C.sq.rank(square(f, r)) == rank.u32(r) : U32},
      Pair({C.sq.ok(square(f, r)) == True{} : Bool},
        Pair({C.sq.from64(C.sq.to64(square(f, r))) == square(f, r) : U32},
          {C.sq.safe(square(f, r)) == square(f, r) : U32}))))

# the 0x88 test accepts a king step or knight jump from any square exactly
# when the target coordinates stay inside 0..7 (no wrap-around)
law step_detection:
  for +f: Column
  for +r: Rank
  for +s: Step
  {C.sq.ok(U32.add(square(f, r), step.off(s))) ==
    (U32.is_lt(U32.add(file.u32(f), step.dx(s)), 8) && U32.is_lt(U32.add(rank.u32(r), step.dy(s)), 8)) : Bool}

# the engine's direction table holds exactly these geometric steps
law direction_table:
  for +s: Step
  {B.dir(step.idx(s)) == step.off(s) : U32}

# the side to move alternates: opp is an involution without fixed points
law side_alternates:
  for +c: Color
  Pair({C.opp(C.opp(color.u32(c))) == color.u32(c) : U32},
    {U32.is_ne(C.opp(color.u32(c)), color.u32(c)) == True{} : Bool})

# piece codes are non-empty and decode to their colour and type
law piece_encoding:
  for +c: Color
  for +t: PType
  Pair({C.pc.color(C.pc.make(color.u32(c), ptype.u32(t))) == color.u32(c) : U32},
    Pair({C.pc.type(C.pc.make(color.u32(c), ptype.u32(t))) == ptype.u32(t) : U32},
      {U32.is_ne(C.pc.make(color.u32(c), ptype.u32(t)), 0) == True{} : Bool}))

# moves decode to the origin, target and flag they were built from
law move_encoding:
  for +f1: Column
  for +r1: Rank
  for +f2: Column
  for +r2: Rank
  for +g: Flag
  Pair({C.mv.from(C.mv.make(square(f1, r1), square(f2, r2), flag.u32(g))) == square(f1, r1) : U32},
    Pair({C.mv.to(C.mv.make(square(f1, r1), square(f2, r2), flag.u32(g))) == square(f2, r2) : U32},
      {C.mv.flag(C.mv.make(square(f1, r1), square(f2, r2), flag.u32(g))) == flag.u32(g) : U32}))

# a pawn move to the last rank is a promotion exactly for the promotion
# flags, and promotes to the piece the flag names
law promotion_metadata:
  for +f: Column
  for +g: Flag
  {C.sel(C.mv.is_promo(C.mv.make(square(f, R7{}), square(f, R8{}), flag.u32(g))),
      C.mv.promo_type(C.mv.make(square(f, R7{}), square(f, R8{}), flag.u32(g))), 0) == promo.spec(g) : U32}

# the castling-rights mask of every square matches the specification
law castling_rights_table:
  for +f: Column
  for +r: Rank
  {C.castle.keep(square(f, r)) == keep.spec(f, r) : U32}

# Laws: branch-free selection (used throughout the engine)
# --------------------------------------------------------

law select_true:
  for +x: U32
  for +y: U32
  {C.sel(True{}, x, y) == x : U32}

law select_false:
  for +x: U32
  for +y: U32
  {C.sel(False{}, x, y) == y : U32}

# Laws: the make-move state transition (all positions, all moves)
# ---------------------------------------------------------------

# after any move the other side is to move
law make_flips_side:
  for p: B.Pos
  for +mv: U32
  for pc: U32
  for cap: U32
  for e: Bool
  {B.P.side(B.Pos.after(p, mv, pc, cap, e)) == C.opp(B.P.side(p)) : U32}

# every move advances the history index by one ply
law make_counts_ply:
  for p: B.Pos
  for +mv: U32
  for pc: U32
  for cap: U32
  for e: Bool
  {B.P.hidx(B.Pos.after(p, mv, pc, cap, e)) == U32.add(B.P.hidx(p), 1) : U32}

# the new state records what unmake() needs: the captured and moved piece
law make_records_undo:
  for p: B.Pos
  for +mv: U32
  for pc: U32
  for cap: U32
  for e: Bool
  Pair({B.P.cap(B.Pos.after(p, mv, pc, cap, e)) == cap : U32},
    {B.P.mvd(B.Pos.after(p, mv, pc, cap, e)) == pc : U32})

# no move ever grants a castling right that was not already held
law make_never_adds_rights:
  for p: B.Pos
  for +mv: U32
  for pc: U32
  for cap: U32
  for e: Bool
  {U32.and(B.P.castle(B.Pos.after(p, mv, pc, cap, e)), U32.not(B.P.castle(p))) == 0 : U32}

# a null move passes the turn, clears en passant and counts a ply
law null_move_state:
  for p: B.Pos
  Pair({B.P.side(B.P.null(p)) == C.opp(B.P.side(p)) : U32},
    Pair({B.P.ep(B.P.null(p)) == C.NO_SQ() : U32},
      {B.P.hidx(B.P.null(p)) == U32.add(B.P.hidx(p), 1) : U32}))
