#!/usr/bin/env python3
"""Reorder top-level Bend definitions so every def appears after the defs it
calls (Bend requires this for safe defs; @unsafe defs may call defs below).

Blocks are: leading comment lines + a `def`/`type`/`law`/`@unsafe` header and
its indented body. The sort is stable (original order wins whenever the
dependency graph allows) and edges inside cycles (mutually recursive @unsafe
defs) are ignored. Non-def preamble (imports, file comments) stays on top.

usage: bendsort.py FILE [FILE...]   (rewrites in place)
"""
import re
import sys

HDR = re.compile(r"^(?:@unsafe\s+)?(def|type|law)\s+([A-Za-z0-9_.]+)\??")


def split_blocks(text):
    lines = text.split("\n")
    pre, blocks, cur, pending = [], [], None, []
    for ln in lines:
        if ln.startswith("@unsafe") and not ln.strip().startswith("@unsafe def"):
            # bare @unsafe on its own line: belongs to the next def
            pending.append(ln)
            continue
        m = HDR.match(ln)
        if m:
            if cur is not None:
                blocks.append(cur)
            # comments/blank lines just above belong to this block
            lead = []
            src = pre if cur is None else cur["lines"]
            while src and (src[-1].startswith("#") or src[-1].strip() == ""):
                lead.insert(0, src.pop())
            while lead and lead[0].strip() == "":
                lead.pop(0)
            cur = {"name": m.group(2), "lines": lead + pending + [ln]}
            pending = []
        elif cur is None:
            pre.append(ln)
        else:
            cur["lines"].append(ln)
    if cur is not None:
        blocks.append(cur)
    return pre, blocks


def deps(block, names):
    body = "\n".join(l for l in block["lines"][1:] if not l.lstrip().startswith("#"))
    body = re.sub(r'"[^"\n]*"', "", body)
    found = set()
    for tok in re.findall(r"[A-Za-z_][A-Za-z0-9_.]*", body):
        if tok in names and tok != block["name"]:
            found.add(tok)
    return found


def main():
    for path in sys.argv[1:]:
        text = open(path).read()
        pre, blocks = split_blocks(text)
        names = {b["name"]: i for i, b in enumerate(blocks)}
        dep = [deps(b, names) for b in blocks]
        out, state = [], {}

        def visit(i, stack):
            if state.get(i) == 2:
                return
            if state.get(i) == 1:
                return  # cycle: ignore this edge
            state[i] = 1
            for d in sorted(names[x] for x in dep[i]):
                visit(d, stack)
            state[i] = 2
            out.append(i)

        for i in range(len(blocks)):
            visit(i, [])
        while pre and pre[-1].strip() == "":
            pre.pop()
        res = "\n".join(pre) + "\n\n"
        res += "\n\n".join("\n".join(l for l in blocks[i]["lines"]).rstrip("\n") for i in out)
        open(path, "w").write(res.rstrip("\n") + "\n")
        moved = sum(1 for k, i in enumerate(out) if i != k)
        print(f"{path}: {len(blocks)} blocks, {moved} moved")


if __name__ == "__main__":
    main()
