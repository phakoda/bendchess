# What BendChess's evaluation misses (positions from lost games)

2084 positions (BendChess to move, moves 10-70) from 169 lost games. gap = Stockfish depth 14 score - BendChess depth 9 score (side to move, cp).

Mean gap -116 cp, median -127 cp (negative = BendChess more optimistic than the referee). Share of positions where BendChess is >= 100 cp more optimistic: 61%.

Ridge fit of the gap on the features below: R^2 0.09 (in-sample).

| feature (ours - theirs) | mean | effect per unit (cp) | effect per SD (cp) | correlation |
|---|---|---|---|---|
| passed_free_ranks | -0.58 | -7.5 | -23.6 | -0.18 |
| space | -1.05 | -8.6 | -23.2 | -0.20 |
| king_zone_attacks | +0.36 | +5.6 | +17.2 | +0.11 |
| center_pawns | +0.06 | +20.2 | +16.0 | +0.06 |
| safe_mobility | -2.55 | -1.6 | -12.2 | -0.13 |
| king_shield_pawns | -0.19 | -8.6 | -9.9 | -0.10 |
| king_attackers | +0.14 | -5.8 | -9.4 | +0.08 |
| backward_pawns | +0.13 | -5.9 | -6.6 | -0.05 |
| king_castled | +0.09 | -10.0 | -5.7 | -0.06 |
| king_semiopen_files | +0.10 | -5.1 | -4.1 | +0.05 |
| bishop_pair | -0.08 | +7.9 | +3.4 | +0.02 |
| pawn_islands | +0.01 | -3.3 | -2.9 | -0.12 |
| queen_out_early | -0.00 | +14.3 | +2.2 | +0.01 |
| hanging_value | +0.29 | +1.0 | +2.2 | -0.01 |
| center_control | -0.43 | +0.7 | +1.8 | -0.06 |
| threatened_by_lesser | +0.42 | -0.7 | -1.7 | -0.04 |
| rooks_connected | -0.01 | +3.2 | +1.6 | -0.01 |
| undeveloped_minors | -0.02 | -1.4 | -0.9 | +0.02 |
| knight_outposts | -0.01 | -1.8 | -0.5 | -0.02 |
| king_open_files | +0.09 | -0.6 | -0.4 | +0.07 |

Reading: a positive effect means the referee values more of this feature for the side to move than BendChess does (BendChess under-rewards it); negative means BendChess under-penalises it.
