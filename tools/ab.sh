#!/bin/sh
# A/B test: tools/ab.sh NEW_BIN REF_BIN TAG [extra match.py args]
# default: 400 games (200 book openings x 2 colours), 5s+0.05s, 4 games in parallel
NEW=$1; REF=$2; TAG=$3; shift 3
ARGS=${*:-"--tc 5+0.05"}
python3 "$(dirname "$0")/match.py" "$NEW" "$REF" --games 400 --concurrency 4 \
  --out "$(dirname "$0")/../results/ab" --tag "$TAG" --event "$TAG" $ARGS | tail -1 >/dev/null
python3 - "$TAG" <<'PY'
import json, sys, os
s = json.load(open(os.path.join("results", "ab", sys.argv[1] + ".json")))["summary"]
print(f"{sys.argv[1]}: +{s['wins']} ={s['draws']} -{s['losses']} Elo {s['elo']:+.0f} [{s['elo_lo']:+.0f}, {s['elo_hi']:+.0f}] "
      f"distinct {s['distinct_games']} nodes A/B {s['a_total_nodes']/max(s['b_total_nodes'],1):.2f} "
      f"depth {s['a_avg_depth']:.1f}/{s['b_avg_depth']:.1f}")
PY
