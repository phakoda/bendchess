# BendChess evaluation.
#
# Base: PeSTO tapered piece-square tables (material included), kept
# incrementally in Pos (mg, eg, phase), so this term costs no board reads.
# The full evaluation adds terms from one board scan (see eval.full).
#
# All scores are centipawns, two's complement in a U32, from the point of
# view of the side to move.

import Base
import ./core.bend as C
import ./board.bend as B

def TEMPO() -> U32:
  10

# white-relative tapered score of mg/eg at phase ph (0..24, 24 = opening)
def taper(+mg: U32, +eg: U32, +ph0: U32) -> U32:
  +ph = U32.min(ph0, 24)
  C.s.div(U32.add(U32.mul(mg, ph), U32.mul(eg, U32.sub(24, ph))), 24)

# PeSTO only, side-to-move relative
def pesto(+p: B.Pos) -> U32:
  U32.add(B.neg_if(taper(B.P.mg(p), B.P.eg(p), B.P.ph(p)), B.P.side(p)), TEMPO())

def eval(m: Array<U32>, +p: B.Pos) -> Array<U32> & U32:
  (m, pesto(p))
