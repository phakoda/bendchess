"""A small balanced opening suite (common master lines, 4-8 plies deep).

Each line is played twice in a match (once with each colour) so opening
bias cancels out. Lines are given in UCI and converted to FEN on demand.
"""
import chess

LINES = [
    "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6",          # Ruy Lopez
    "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5",          # Italian
    "e2e4 e7e5 g1f3 g8f6 f3e5 d7d6",          # Petroff
    "e2e4 e7e5 b1c3 g8f6 f2f4 d7d5",          # Vienna
    "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6",  # Sicilian Najdorf-ish
    "e2e4 c7c5 g1f3 b8c6 d2d4 c5d4 f3d4 e7e6",  # Sicilian Taimanov
    "e2e4 c7c5 b1c3 b8c6 g2g3 g7g6",          # Closed Sicilian
    "e2e4 c7c5 c2c3 g8f6 e4e5 f6d5",          # Alapin
    "e2e4 e7e6 d2d4 d7d5 b1c3 g8f6",          # French Classical
    "e2e4 e7e6 d2d4 d7d5 e4e5 c7c5",          # French Advance
    "e2e4 c7c6 d2d4 d7d5 e4e5 c8f5",          # Caro-Kann Advance
    "e2e4 c7c6 d2d4 d7d5 b1c3 d5e4 c3e4 c8f5",  # Caro-Kann Classical
    "e2e4 d7d6 d2d4 g8f6 b1c3 g7g6",          # Pirc
    "e2e4 d7d5 e4d5 d8d5 b1c3 d5a5",          # Scandinavian
    "e2e4 g8f6 e4e5 f6d5 d2d4 d7d6",          # Alekhine
    "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6",          # QGD
    "d2d4 d7d5 c2c4 c7c6 g1f3 g8f6",          # Slav
    "d2d4 d7d5 c2c4 d5c4 g1f3 g8f6",          # QGA
    "d2d4 g8f6 c2c4 e7e6 b1c3 f8b4",          # Nimzo-Indian
    "d2d4 g8f6 c2c4 e7e6 g1f3 b7b6",          # Queen's Indian
    "d2d4 g8f6 c2c4 g7g6 b1c3 f8g7 e2e4 d7d6",  # King's Indian
    "d2d4 g8f6 c2c4 g7g6 b1c3 d7d5",          # Grunfeld
    "d2d4 g8f6 c2c4 c7c5 d4d5 e7e6",          # Benoni
    "d2d4 f7f5 g2g3 g8f6 f1g2 g7g6",          # Dutch
    "d2d4 d7d5 g1f3 g8f6 c1f4 e7e6",          # London
    "c2c4 e7e5 b1c3 g8f6 g1f3 b8c6",          # English Four Knights
    "c2c4 c7c5 g1f3 g8f6 b1c3 b8c6",          # Symmetrical English
    "c2c4 g8f6 b1c3 e7e6 e2e4 d7d5",          # Mikenas
    "g1f3 d7d5 g2g3 g8f6 f1g2 e7e6",          # Reti / KIA
    "g1f3 g8f6 c2c4 b7b6 g2g3 c8b7",          # Reti double fianchetto
    "e2e4 e7e5 f2f4 e5f4 g1f3 g7g5",          # King's Gambit
    "d2d4 d7d5 c2c4 e7e6 b1c3 c7c5",          # Tarrasch
]


def fen_of(line: str) -> str:
    b = chess.Board()
    for u in line.split():
        b.push_uci(u)
    return b.fen()


def suite():
    return [(line, fen_of(line)) for line in LINES]
