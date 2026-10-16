# BendChess build. `make setup` once (fetches Bend 2), then `make`.
BEND ?= $(shell command -v bend 2>/dev/null || echo tools/bin/bend)
SRC := $(wildcard src/*.bend)

build/bendchess: $(SRC)
	@mkdir -p build
	$(BEND) src/main.bend -o build/bendchess 2>&1 | grep -v "rely on unsafe\|^defs that depend" || true
	@test -x build/bendchess

setup:
	tools/setup_bend.sh

tables:
	python3 tools/gen_tables.py

check:
	$(BEND) src/main.bend --check-only 2>&1 | grep -v "^defs that depend" | head -20

proofs:
	$(BEND) PROOF.bend

test: build/bendchess
	python3 tests/test_perft.py --quick --random 40
	python3 tests/test_engine.py

test-full: build/bendchess
	python3 tests/test_perft.py --random 200
	python3 tests/test_engine.py

clean:
	rm -rf build

.PHONY: setup tables check proofs test test-full clean
