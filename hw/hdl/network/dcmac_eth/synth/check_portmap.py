#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DCMAC_ETH = os.path.normpath(os.path.join(HERE, ".."))
WORKSPACE = os.path.normpath(os.path.join(DCMAC_ETH, "..", "..", "..", "..", "..", "..", ".."))

SHIM = os.path.join(DCMAC_ETH, "dcmac_axis_wrapper.sv")
RESET_GEN = os.path.join(DCMAC_ETH, "dcmac_usr_reset_gen.sv")

VENDORED_TOP = os.path.join(DCMAC_ETH, "nia_eth", "dcmac_axis_top.sv")
FALLBACK_TOP = os.path.join(WORKSPACE, "repo", "nia-eth", "rtl", "dcmac_axis_top.sv")

PAIRS = [
    ("dcmac_axis_top", "u_mac", None),
    ("dcmac_usr_reset_gen", "u_usr_reset", RESET_GEN),
]


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def declared_ports(text, module):
    m = re.search(r"\bmodule\s+" + re.escape(module) + r"\b(.*?)\n\s*\);", text, re.S)
    if not m:
        raise SystemExit(f"FAIL: module {module} not found")
    body = m.group(1)
    idx = body.rfind(")(")
    if idx == -1:
        idx = body.find("(")
    else:
        idx += 1
    body = body[idx:]
    names = []
    for line in body.split("\n"):
        line = line.strip()
        if not re.match(r"^(input|output|inout)\b", line):
            continue
        toks = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", line.rstrip(","))
        if toks:
            names.append(toks[-1])
    return names


def instance_body(text, module, inst):
    m = re.search(r"\b" + re.escape(module) + r"\b[^;]*?\b" + re.escape(inst) + r"\b\s*\(", text)
    if not m:
        raise SystemExit(f"FAIL: instance {module} {inst} not found")
    i = m.end() - 1
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    raise SystemExit(f"FAIL: unbalanced parens in {module} {inst}")


def connected_ports(body):
    names, depth = [], 0
    for tok in re.finditer(r"[()]|\.\s*([A-Za-z_]\w*)\s*\(", body):
        if tok.group(0) in "()":
            depth += 1 if tok.group(0) == "(" else -1
        elif depth == 0:
            names.append(tok.group(1))
            depth += 1
    return names


def main():
    shim = strip_comments(open(SHIM).read())

    top_path = VENDORED_TOP if os.path.exists(VENDORED_TOP) else FALLBACK_TOP
    if not os.path.exists(top_path):
        print(f"FAIL: neither {VENDORED_TOP} nor {FALLBACK_TOP} exists")
        return 2
    print(f"SHIM = {SHIM}")
    print(f"TOP  = {top_path}")
    if top_path == FALLBACK_TOP:
        print("NOTE: the sources are not vendored yet, the reference is repo/nia-eth")

    ok = True
    for module, inst, path in PAIRS:
        src = top_path if path is None else path
        decl = declared_ports(strip_comments(open(src).read()), module)
        conn = connected_ports(instance_body(shim, module, inst))
        sd, sc = set(decl), set(conn)
        missing = sorted(sd - sc)
        invented = sorted(sc - sd)
        dup = len(conn) - len(sc)
        good = not missing and not invented and dup == 0 and len(decl) > 0
        ok &= good
        print(f"\n== {module} ({inst}) ==")
        print(f"  declared={len(decl)} connected={len(conn)} duplicates={dup}")
        print(f"  declared but not connected: {missing or 'none'}")
        print(f"  connected but not declared: {invented or 'none'}")
        print(f"  VERDICT: {'COMPLETE' if good else 'INCOMPLETE'}")

    print(f"\nPORTMAP RESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
