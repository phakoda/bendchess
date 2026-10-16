#!/usr/bin/env python3
"""Generate src/tables.bend: PeSTO tapered piece-square tables (material
included) as Bend Nat-match lookup functions.

Source values: PeSTO's evaluation function by Ronald Friederich, as published
on the Chess Programming Wiki. Tables are listed from White's point of view
with a8 first (index 0), h1 last (index 63), as on the wiki.

A 64..384-case Nat match compiles to a flat C if/else chain that clang turns
into a lookup table; we measured it at C-array speed (see docs/PROGRESS.md).
"""
import math
import os

MG_VAL = [82, 337, 365, 477, 1025, 0]
EG_VAL = [94, 281, 297, 512, 936, 0]

MG = {
    "P": [0, 0, 0, 0, 0, 0, 0, 0,
          98, 134, 61, 95, 68, 126, 34, -11,
          -6, 7, 26, 31, 65, 56, 25, -20,
          -14, 13, 6, 21, 23, 12, 17, -23,
          -27, -2, -5, 12, 17, 6, 10, -25,
          -26, -4, -4, -10, 3, 3, 33, -12,
          -35, -1, -20, -23, -15, 24, 38, -22,
          0, 0, 0, 0, 0, 0, 0, 0],
    "N": [-167, -89, -34, -49, 61, -97, -15, -107,
          -73, -41, 72, 36, 23, 62, 7, -17,
          -47, 60, 37, 65, 84, 129, 73, 44,
          -9, 17, 19, 53, 37, 69, 18, 22,
          -13, 4, 16, 13, 28, 19, 21, -8,
          -23, -9, 12, 10, 19, 17, 25, -16,
          -29, -53, -12, -3, -1, 18, -14, -19,
          -105, -21, -58, -33, -17, -28, -19, -23],
    "B": [-29, 4, -82, -37, -25, -42, 7, -8,
          -26, 16, -18, -13, 30, 59, 18, -47,
          -16, 37, 43, 40, 35, 50, 37, -2,
          -4, 5, 19, 50, 37, 37, 7, -2,
          -6, 13, 13, 26, 34, 12, 10, 4,
          0, 15, 15, 15, 14, 27, 18, 10,
          4, 15, 16, 0, 7, 21, 33, 1,
          -33, -3, -14, -21, -13, -12, -39, -21],
    "R": [32, 42, 32, 51, 63, 9, 31, 43,
          27, 32, 58, 62, 80, 67, 26, 44,
          -5, 19, 26, 36, 17, 45, 61, 16,
          -24, -11, 7, 26, 24, 35, -8, -20,
          -36, -26, -12, -1, 9, -7, 6, -23,
          -45, -25, -16, -17, 3, 0, -5, -33,
          -44, -16, -20, -9, -1, 11, -6, -71,
          -19, -13, 1, 17, 16, 7, -37, -26],
    "Q": [-28, 0, 29, 12, 59, 44, 43, 45,
          -24, -39, -5, 1, -16, 57, 28, 54,
          -13, -17, 7, 8, 29, 56, 47, 57,
          -27, -27, -16, -16, -1, 17, -2, 1,
          -9, -26, -9, -10, -2, -4, 3, -3,
          -14, 2, -11, -2, -5, 2, 14, 5,
          -35, -8, 11, 2, 8, 15, -3, 1,
          -1, -18, -9, 10, -15, -25, -31, -50],
    "K": [-65, 23, 16, -15, -56, -34, 2, 13,
          29, -1, -20, -7, -8, -4, -38, -29,
          -9, 24, 2, -16, -20, 6, 22, -22,
          -17, -20, -12, -27, -30, -25, -14, -36,
          -49, -1, -27, -39, -46, -44, -33, -51,
          -14, -14, -22, -46, -44, -30, -15, -27,
          1, 7, -8, -64, -43, -16, 9, 8,
          -15, 36, 12, -54, 8, -28, 24, 14],
}
EG = {
    "P": [0, 0, 0, 0, 0, 0, 0, 0,
          178, 173, 158, 134, 147, 132, 165, 187,
          94, 100, 85, 67, 56, 53, 82, 84,
          32, 24, 13, 5, -2, 4, 17, 17,
          13, 9, -3, -7, -7, -8, 3, -1,
          4, 7, -6, 1, 0, -5, -1, -8,
          13, 8, 8, 10, 13, 0, 2, -7,
          0, 0, 0, 0, 0, 0, 0, 0],
    "N": [-58, -38, -13, -28, -31, -27, -63, -99,
          -25, -8, -25, -2, -9, -25, -24, -52,
          -24, -20, 10, 9, -1, -9, -19, -41,
          -17, 3, 22, 22, 22, 11, 8, -18,
          -18, -6, 16, 25, 16, 17, 4, -18,
          -23, -3, -1, 15, 10, -3, -20, -22,
          -42, -20, -10, -5, -2, -20, -23, -44,
          -29, -51, -23, -15, -22, -18, -50, -64],
    "B": [-14, -21, -11, -8, -7, -9, -17, -24,
          -8, -4, 7, -12, -3, -13, -4, -14,
          2, -8, 0, -1, -2, 6, 0, 4,
          -3, 9, 12, 9, 14, 10, 3, 2,
          -6, 3, 13, 19, 7, 10, -3, -9,
          -12, -3, 8, 10, 13, 3, -7, -15,
          -14, -18, -7, -1, 4, -9, -15, -27,
          -23, -9, -23, -5, -9, -16, -5, -17],
    "R": [13, 10, 18, 15, 12, 12, 8, 5,
          11, 13, 13, 11, -3, 3, 8, 3,
          7, 7, 7, 5, 4, -3, -5, -3,
          4, 3, 13, 1, 2, 1, -1, 2,
          3, 5, 8, 4, -5, -6, -8, -11,
          -4, 0, -5, -1, -7, -12, -8, -16,
          -6, -6, 0, 2, -9, -9, -11, -3,
          -9, 2, 3, -1, -5, -13, 4, -20],
    "Q": [-9, 22, 22, 27, 27, 19, 10, 20,
          -17, 20, 32, 41, 58, 25, 30, 0,
          -20, 6, 9, 49, 47, 35, 19, 9,
          3, 22, 24, 45, 57, 40, 57, 36,
          -18, 28, 19, 47, 31, 34, 39, 23,
          -16, -27, 15, 6, 9, 17, 10, 5,
          -22, -23, -30, -16, -16, -23, -36, -32,
          -33, -28, -22, -43, -5, -32, -20, -41],
    "K": [-74, -35, -18, -18, -11, 15, 4, -17,
          -12, 17, 14, 17, 17, 38, 23, 11,
          10, 17, 23, 15, 20, 45, 44, 13,
          -8, 22, 24, 27, 26, 33, 26, 3,
          -18, -4, 21, 24, 27, 23, 9, -11,
          -19, -3, 11, 21, 23, 16, 7, -9,
          -27, -11, 4, 13, 14, 4, -5, -17,
          -53, -34, -21, -11, -28, -14, -24, -43],
}
ORDER = "PNBRQK"


def u32(v: int) -> int:
    return v & 0xFFFFFFFF


def table(name: str, vals, mats) -> str:
    # index = (type-1)*64 + i, where i is the wiki index (a8 = 0).
    out = [f"def {name}(n: Nat) -> U32:", "  match n:"]
    for t, p in enumerate(ORDER):
        for i in range(64):
            out.append(f"    case {t * 64 + i}n:")
            out.append(f"      {u32(vals[p][i] + mats[t])}")
    out += ["    case _:", "      0", ""]
    return "\n".join(out)


def delta_table() -> str:
    """0x88 delta table, index = (to - from) + 119.
    bits 0..7: 1 white pawn attacks along it, 2 black pawn, 4 knight,
    8 diagonal line (bishop/queen), 16 orthogonal line (rook/queen),
    32 king (adjacent); bits 8..15: unit step + 32 (lines only)."""
    info = [0] * 239
    for d, b in ((15, 1), (17, 1), (-15, 2), (-17, 2)):
        info[d + 119] |= b
    for d in (33, 31, 18, 14, -33, -31, -18, -14):
        info[d + 119] |= 4
    for step, bit in ((17, 8), (15, 8), (-17, 8), (-15, 8), (16, 16), (-16, 16), (1, 16), (-1, 16)):
        info[step + 119] |= 32
        for k in range(1, 8):
            info[step * k + 119] |= bit | ((step + 32) << 8)
    out = ["def delta(n: Nat) -> U32:", "  match n:"]
    for i, v in enumerate(info):
        if v:
            out += [f"    case {i}n:", f"      {v}"]
    out += ["    case _:", "      0", ""]
    return "\n".join(out)


def debruijn_table() -> str:
    """index ((x & -x) * 0x077CB531) >> 27 -> trailing-zero count of x."""
    tab = [0] * 32
    for i in range(32):
        tab[(((1 << i) * 0x077CB531) & 0xFFFFFFFF) >> 27] = i
    out = ["def debruijn(n: Nat) -> U32:", "  match n:"]
    for i, v in enumerate(tab):
        out += [f"    case {i}n:", f"      {v}"]
    out += ["    case _:", "      0", ""]
    return "\n".join(out)


M32 = 0xFFFFFFFF


def mix(x: int) -> int:
    """The engine's 32-bit mixer (core.bend `mix`)."""
    x &= M32
    x ^= x >> 16
    x = (x * 2146121005) & M32
    x ^= x >> 15
    x = (x * 2221713035) & M32
    return x ^ (x >> 16)


def nat_table(name: str, vals) -> str:
    out = [f"def {name}(n: Nat) -> U32:", "  match n:"]
    for i, v in enumerate(vals):
        out += [f"    case {i}n:", f"      {v}"]
    out += ["    case _:", "      0", ""]
    return "\n".join(out)


def zobrist_tables() -> str:
    """Zobrist keys, index (colour * 6 + type - 1) * 64 + square64; the same
    values core.bend's z.lo / z.hi compute (piece p on 0x88 square s)."""
    lo, hi = [], []
    for c in range(2):
        for t in range(1, 7):
            p = c * 8 + t
            for i in range(64):
                s = (i >> 3) * 16 + (i & 7)
                lo.append(mix((p << 7) + s + 2654435769))
                hi.append(mix((((p << 7) + s) ^ 1431655765) + 3735928559))
    cl = [mix(r + 1000003) for r in range(16)]
    ch = [mix(r + 2000003) for r in range(16)]
    el = [mix(f + 3000017) for f in range(8)]
    eh = [mix(f + 4000037) for f in range(8)]
    return "\n".join([nat_table("z_lo", lo), nat_table("z_hi", hi), nat_table("z_castle_lo", cl),
                      nat_table("z_castle_hi", ch), nat_table("z_ep_lo", el), nat_table("z_ep_hi", eh)])


def lmr_table() -> str:
    """ln(x) / 1.5 in 1/256 units for x < 64 (0 for x = 0): the late-move
    reduction floor(0.75 + ln d * ln k / 2.25) is (192 * 256 + L(d) * L(k)) >> 16."""
    return nat_table("lmr_ln", [round(math.log(x) / 1.5 * 256) if x > 0 else 0 for x in range(64)])


def leaper_tables() -> str:
    """Knight attacks and king neighbourhoods as 64-bit boards split in
    lo / hi 32-bit halves, by square64 (a1 = 0)."""
    def boards(steps):
        lo, hi = [], []
        for sq in range(64):
            f, r = sq % 8, sq // 8
            b = 0
            for df, dr in steps:
                if 0 <= f + df < 8 and 0 <= r + dr < 8:
                    b |= 1 << ((r + dr) * 8 + f + df)
            lo.append(b & 0xFFFFFFFF)
            hi.append(b >> 32)
        return lo, hi
    nl, nh = boards([(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)])
    kl, kh = boards([(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)])
    return "\n".join([nat_table("natt_lo", nl), nat_table("natt_hi", nh),
                      nat_table("katt_lo", kl), nat_table("katt_hi", kh)])


def ray_tables() -> str:
    """Rays (squares strictly beyond the origin up to the edge) for the
    eight directions of board.bend's dir() table (0x88 offsets 16, -16, 1,
    -1, 17, 15, -17, -15), index dir * 64 + square64, lo / hi halves."""
    steps = [(0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (-1, 1), (-1, -1), (1, -1)]
    lo, hi = [], []
    for df, dr in steps:
        for sq in range(64):
            f, r = sq % 8 + df, sq // 8 + dr
            b = 0
            while 0 <= f < 8 and 0 <= r < 8:
                b |= 1 << (r * 8 + f)
                f += df
                r += dr
            lo.append(b & 0xFFFFFFFF)
            hi.append(b >> 32)
    ul, uh = [], []
    for sq in range(64):
        a = b = 0
        for i in range(8):
            a |= lo[i * 64 + sq]
            b |= hi[i * 64 + sq]
        ul.append(a)
        uh.append(b)
    return "\n".join([nat_table("ray_lo", lo), nat_table("ray_hi", hi),
                      nat_table("rays_lo", ul), nat_table("rays_hi", uh)])


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    dst = os.path.join(here, "..", "src", "tables.bend")
    hdr = (
        "# GENERATED by tools/gen_tables.py -- do not edit by hand.\n"
        "# PeSTO tapered piece-square tables (Ronald Friederich, via the Chess\n"
        "# Programming Wiki), material included, as two's-complement U32.\n"
        "# Index: (piece type - 1) * 64 + i, i = 0 for a8 ... 63 for h1, from\n"
        "# White's point of view.\n\nimport Base\n\n"
    )
    with open(dst, "w") as f:
        f.write(hdr)
        f.write(table("pst_mg", MG, MG_VAL) + "\n")
        f.write(table("pst_eg", EG, EG_VAL) + "\n")
        f.write(delta_table() + "\n")
        f.write(debruijn_table() + "\n")
        f.write(zobrist_tables() + "\n")
        f.write(lmr_table() + "\n")
        f.write(leaper_tables() + "\n")
        f.write(ray_tables() + "\n")
    print("wrote", os.path.normpath(dst))


if __name__ == "__main__":
    main()
