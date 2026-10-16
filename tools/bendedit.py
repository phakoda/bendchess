#!/usr/bin/env python3
"""Block-level editing of Bend files: upsert(file, text) replaces every
top-level def/type/law of `text` that already exists in `file` (matched by
name) and appends the others; remove(file, names) deletes blocks.
Used during development so edits do not depend on block order."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bendsort import split_blocks  # noqa: E402


def _join(pre, blocks):
    return "\n".join(pre).rstrip() + "\n\n" + "\n\n".join(
        "\n".join(b["lines"]).rstrip("\n") for b in blocks) + "\n"


def upsert(path, text):
    pre, blocks = split_blocks(open(path).read())
    _, new = split_blocks("\n" + text.strip("\n") + "\n")
    idx = {b["name"]: i for i, b in enumerate(blocks)}
    added, replaced = [], []
    for nb in new:
        if nb["name"] in idx:
            blocks[idx[nb["name"]]] = nb
            replaced.append(nb["name"])
        else:
            blocks.append(nb)
            added.append(nb["name"])
    open(path, "w").write(_join(pre, blocks))
    return replaced, added


def remove(path, names):
    pre, blocks = split_blocks(open(path).read())
    blocks = [b for b in blocks if b["name"] not in set(names)]
    open(path, "w").write(_join(pre, blocks))


if __name__ == "__main__":
    path, src = sys.argv[1], sys.argv[2]
    r, a = upsert(path, open(src).read())
    print("replaced:", r, "added:", a)
