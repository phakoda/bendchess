#!/bin/sh
# Fetch the 3- and 4-piece Syzygy tables (plus a few 5-piece ones) that the
# python-chess repository ships as test data, into third_party/syzygy.
# For full 5/6/7-piece support, point SyzygyPath at your own table set.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
git clone --depth 1 --filter=blob:none --sparse https://github.com/niklasf/python-chess "$TMP/pc"
git -C "$TMP/pc" sparse-checkout set data/syzygy/regular
mkdir -p "$ROOT/third_party/syzygy"
cp "$TMP/pc/data/syzygy/regular/"*.rtb? "$ROOT/third_party/syzygy/"
rm -rf "$TMP"
ls "$ROOT/third_party/syzygy" | wc -l
