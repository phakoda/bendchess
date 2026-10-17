# Loss analysis (169 lost games)

Referee: Stockfish 16 depth 14. Decisive error = largest drop from >= -100 to <= -150 cp (BendChess's view). 49 games had one; 120 declined gradually.


**Opponent / source**

| | games | share |
|---|---|---|
| sf16_elo3190_v2.pgn | 66 | 39% |
| sf16_full_timeodds10.pgn | 37 | 22% |
| sf16_full_60s.pgn | 35 | 21% |
| magnus_proxy_2850_v2.pgn | 31 | 18% |

**Cause (re-search diagnosis, sharp errors)**

| | games | share |
|---|---|---|
| depth/time | 21 | 43% |
| knowledge | 17 | 35% |
| pruning | 11 | 22% |

**Phase of the decisive error**

| | games | share |
|---|---|---|
| opening/middlegame | 36 | 73% |
| late middlegame | 10 | 20% |
| endgame | 3 | 6% |

**Our move type**

| | games | share |
|---|---|---|
| quiet piece move | 23 | 47% |
| pawn push | 12 | 24% |
| capture | 7 | 14% |
| castle | 3 | 6% |
| check | 2 | 4% |
| king move | 2 | 4% |

**Referee's better move type**

| | games | share |
|---|---|---|
| quiet piece move | 21 | 43% |
| pawn push | 11 | 22% |
| capture | 11 | 22% |
| check | 3 | 6% |
| king move | 2 | 4% |
| castle | 1 | 2% |

**Tactical refutation (capture/check best move or drop > 300)**

| | games | share |
|---|---|---|
| positional | 35 | 71% |
| tactical | 14 | 29% |

**Queens on the board**

| | games | share |
|---|---|---|
| queens on | 37 | 76% |
| queens off | 12 | 24% |

Move number of the decisive error: median 18, quartiles [15.0, 18.0, 27.0]
BendChess's own score minus the referee's score after its move: median +181 cp (positive = over-optimistic).
Size of the decisive drop: median 108 cp.
Blunders (>= 100 cp) per lost game: mean 3.4; mistakes (50-99 cp): 5.2.

## Sharp errors

| source | move | phase | played | better | drop | cause | 10x move | no-prune move |
|---|---|---|---|---|---|---|---|---|
| magnus_proxy_2850_v2 | 41 | late middlegame | e4e8 (quiet piece move) | e4h1 (quiet piece move) | 246 | depth/time | e4h1 | e4h1 |
| sf16_full_timeodds10 | 13 | opening/middlegame | e8g8 (castle) | c8e6 (quiet piece move) | 241 | depth/time | c8e6 | e8g8 |
| magnus_proxy_2850_v2 | 55 | endgame | c6f3 (quiet piece move) | e8f8 (king move) | 217 | depth/time | e8f8 | f4e2 |
| magnus_proxy_2850_v2 | 27 | opening/middlegame | d7f5 (quiet piece move) | h7h6 (pawn push) | 211 | knowledge | f8e8 | d7f5 |
| sf16_elo3190_v2 | 29 | opening/middlegame | d4d5 (pawn push) | h6e6 (check) | 186 | depth/time | h6e6 | h6e6 |
| sf16_elo3190_v2 | 31 | endgame | b5b6 (pawn push) | b1a1 (quiet piece move) | 185 | knowledge | b5b6 | b5b6 |
| magnus_proxy_2850_v2 | 12 | opening/middlegame | g7g5 (pawn push) | d8e8 (quiet piece move) | 178 | depth/time | d8e8 | g7g5 |
| sf16_elo3190_v2 | 25 | opening/middlegame | c2g6 (capture) | d5e6 (capture) | 173 | knowledge | e1e6 | a4a5 |
| magnus_proxy_2850_v2 | 53 | late middlegame | f4f3 (quiet piece move) | f4d4 (quiet piece move) | 168 | pruning | f4f3 | f4d4 |
| sf16_full_timeodds10 | 14 | opening/middlegame | h7h5 (pawn push) | e7e2 (check) | 168 | pruning | c4c5 | c4d4 |
| magnus_proxy_2850_v2 | 33 | late middlegame | c6c7 (check) | g5e5 (check) | 164 | depth/time | g5e5 | c6c7 |
| sf16_full_timeodds10 | 24 | opening/middlegame | f3d4 (quiet piece move) | d3d4 (quiet piece move) | 161 | depth/time | e2c2 | f3d4 |
| sf16_elo3190_v2 | 18 | opening/middlegame | f3e5 (quiet piece move) | a3b4 (capture) | 145 | depth/time | a3b4 | a3a4 |
| magnus_proxy_2850_v2 | 31 | late middlegame | d8c8 (king move) | g6g5 (pawn push) | 143 | knowledge | d8c8 | d8c8 |
| sf16_elo3190_v2 | 11 | opening/middlegame | d4e3 (capture) | c5b6 (quiet piece move) | 131 | depth/time | a7a6 | c5b6 |
| magnus_proxy_2850_v2 | 14 | opening/middlegame | b4c5 (quiet piece move) | f7f6 (pawn push) | 129 | knowledge | b4c5 | b4c5 |
| magnus_proxy_2850_v2 | 15 | opening/middlegame | b3c2 (quiet piece move) | c5b6 (capture) | 128 | pruning | b3a2 | c5b6 |
| magnus_proxy_2850_v2 | 17 | opening/middlegame | h6h5 (quiet piece move) | h6e3 (quiet piece move) | 128 | depth/time | h6e3 | h6h7 |
| sf16_full_60s | 19 | late middlegame | e4d6 (quiet piece move) | e4g5 (quiet piece move) | 126 | knowledge | e4d6 | e4d6 |
| sf16_full_timeodds10 | 12 | opening/middlegame | e8g8 (castle) | h7h6 (pawn push) | 123 | knowledge | f7f6 | e8g8 |
| sf16_elo3190_v2 | 14 | opening/middlegame | g1f1 (king move) | d3e4 (capture) | 120 | knowledge | h3h4 | d1e2 |
| sf16_full_timeodds10 | 11 | opening/middlegame | e1c1 (castle) | a2a3 (pawn push) | 119 | pruning | e1c1 | a2a3 |
| magnus_proxy_2850_v2 | 22 | opening/middlegame | e5e4 (pawn push) | d4c3 (capture) | 116 | knowledge | d4c3 | d4c3 |
| sf16_full_timeodds10 | 29 | late middlegame | d6b8 (check) | d6d1 (quiet piece move) | 113 | knowledge | f2f4 | d6b8 |
| sf16_full_timeodds10 | 15 | opening/middlegame | f4f3 (pawn push) | f7f6 (pawn push) | 108 | knowledge | g8f6 | a4b5 |
| sf16_full_timeodds10 | 14 | opening/middlegame | d3e4 (capture) | d2e4 (capture) | 102 | depth/time | d2e4 | d2e4 |
| magnus_proxy_2850_v2 | 30 | opening/middlegame | g3f4 (capture) | e1e6 (capture) | 100 | knowledge | g3f4 | g3f4 |
| sf16_full_60s | 15 | opening/middlegame | d8d6 (quiet piece move) | c6e5 (quiet piece move) | 99 | pruning | f8e8 | c6e5 |
| sf16_full_timeodds10 | 17 | opening/middlegame | b1c3 (quiet piece move) | b1a3 (quiet piece move) | 99 | depth/time | b6b8 | b1a3 |
| magnus_proxy_2850_v2 | 27 | opening/middlegame | g5h6 (capture) | g5f4 (quiet piece move) | 97 | knowledge | g5g3 | g5h6 |
| sf16_full_timeodds10 | 25 | late middlegame | c2b2 (quiet piece move) | f5c8 (quiet piece move) | 94 | knowledge | c2b2 | f6e4 |
| sf16_elo3190_v2 | 22 | opening/middlegame | f5f4 (pawn push) | h7g5 (quiet piece move) | 93 | depth/time | h7g5 | h7g5 |
| sf16_elo3190_v2 | 21 | opening/middlegame | h6g7 (quiet piece move) | h6f4 (capture) | 93 | pruning | d1d7 | h6f4 |
| sf16_full_60s | 18 | opening/middlegame | e5d3 (capture) | e8c8 (castle) | 89 | knowledge | e5d3 | e5d3 |
| sf16_elo3190_v2 | 17 | late middlegame | f8e8 (quiet piece move) | d8d6 (quiet piece move) | 87 | depth/time | d8d6 | d8d7 |
| sf16_full_60s | 17 | opening/middlegame | f4e5 (quiet piece move) | c3e4 (capture) | 86 | pruning | a2a3 | c3e4 |
| sf16_elo3190_v2 | 11 | opening/middlegame | a7a5 (pawn push) | f7f5 (pawn push) | 85 | depth/time | e8g8 | f7f6 |
| sf16_elo3190_v2 | 18 | opening/middlegame | e2e4 (pawn push) | f2f4 (pawn push) | 82 | depth/time | d2f4 | e2e4 |
| sf16_elo3190_v2 | 11 | opening/middlegame | g5e5 (quiet piece move) | g5d8 (quiet piece move) | 79 | depth/time | g5d8 | g5e5 |
| sf16_elo3190_v2 | 16 | opening/middlegame | f1e1 (quiet piece move) | b1b3 (quiet piece move) | 77 | depth/time | a4a5 | a4a5 |
| sf16_elo3190_v2 | 23 | opening/middlegame | g5g4 (pawn push) | g5g4 (pawn push) | 77 | pruning | g5g4 | b4b3 |
| sf16_elo3190_v2 | 43 | endgame | h2h8 (quiet piece move) | h2h8 (quiet piece move) | 76 | knowledge | h2h8 | h2h8 |
| sf16_full_timeodds10 | 16 | opening/middlegame | a2a4 (pawn push) | e3d4 (quiet piece move) | 76 | pruning | f3d2 | h2h3 |
| sf16_elo3190_v2 | 22 | late middlegame | e1e3 (capture) | f2e3 (capture) | 71 | knowledge | e1e3 | e1e3 |
| magnus_proxy_2850_v2 | 19 | opening/middlegame | a5a4 (quiet piece move) | g7g6 (pawn push) | 70 | depth/time | a5b6 | a5a4 |
| sf16_elo3190_v2 | 29 | opening/middlegame | f8e8 (quiet piece move) | g8h8 (king move) | 69 | pruning | c2a2 | f7f5 |
| sf16_full_60s | 19 | late middlegame | c1g5 (quiet piece move) | e4b7 (capture) | 62 | pruning | c1g5 | c1d2 |
| sf16_elo3190_v2 | 15 | opening/middlegame | h6h5 (pawn push) | f6d5 (quiet piece move) | 61 | depth/time | e7d6 | a6a5 |
| sf16_full_timeodds10 | 17 | opening/middlegame | b6g6 (quiet piece move) | a7a5 (pawn push) | 61 | depth/time | a7a5 | b6g6 |
