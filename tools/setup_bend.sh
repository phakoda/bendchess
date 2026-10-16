#!/bin/sh
# Fetch the Bend 2 toolchain (pinned) into third_party/bend and create a
# `bend` wrapper at tools/bin/bend. Needs git, bun (>= 1.2) and clang (>= 14).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REV=d2aeefc1902d617340e26f7fab5c1ef50fe28efa   # bend 2.0.37
if [ ! -d "$ROOT/third_party/bend/.git" ]; then
  git clone https://github.com/bendlang/bend "$ROOT/third_party/bend"
fi
git -C "$ROOT/third_party/bend" fetch --depth 1 origin "$REV" 2>/dev/null || true
git -C "$ROOT/third_party/bend" checkout -q "$REV" 2>/dev/null || \
  echo "warning: could not pin $REV; using the checked-out revision"
mkdir -p "$ROOT/tools/bin"
cat > "$ROOT/tools/bin/bend" <<EOS
#!/bin/sh
exec bun "$ROOT/third_party/bend/bend2/main.ts" "\$@"
EOS
chmod +x "$ROOT/tools/bin/bend"
"$ROOT/tools/bin/bend" version
