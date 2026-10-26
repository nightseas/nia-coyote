#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_NEW = os.path.normpath(os.path.join(HERE, "..", "dcmac_100g_phy_dcmac.sv"))
DEFAULT_OLD = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "..", "..", "..", "..",
    "app/nic_sim/dcmac_mac/rtl/dcmac_axis_wrapper_phaseb_legacy.sv"))

INSTANCES = [("dcmac_0", "i_dcmac_0", 250), ("dcmac_0_gtwiz_versal_0", "i_gtwiz", 73)]

def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)

def instance_body(text, module, inst):
    m = re.search(r"\b%s\b[^;()]*\b%s\b\s*\(" % (re.escape(module), re.escape(inst)), text)
    if not m:
        raise SystemExit("FAIL: instance %s %s not found" % (module, inst))
    i = m.end() - 1
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    raise SystemExit("FAIL: unbalanced parens in %s %s" % (module, inst))

def port_names(body):
    names, depth = [], 0
    for tok in re.finditer(r"[()]|\.\s*([A-Za-z_]\w*)\s*\(", body):
        if tok.group(0) in "()":
            depth += 1 if tok.group(0) == "(" else -1
        elif depth == 0:
            names.append(tok.group(1))
            depth += 1          # the '(' consumed by this match
    return names

def main():
    old_p = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OLD
    new_p = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_NEW
    print("OLD = %s" % old_p)
    print("NEW = %s" % new_p)
    old = strip_comments(open(old_p).read())
    new = strip_comments(open(new_p).read())
    ok = True
    for module, inst, expect in INSTANCES:
        o = port_names(instance_body(old, module, inst))
        n = port_names(instance_body(new, module, inst))
        so, sn = set(o), set(n)
        missing = sorted(so - sn)
        extra = sorted(sn - so)
        dup_o = len(o) - len(so)
        dup_n = len(n) - len(sn)
        good = not missing and not extra and dup_o == 0 and dup_n == 0
        ok &= good and len(n) == expect
        print("\n== %s (%s) ==" % (module, inst))
        print("  ports OLD=%d NEW=%d (expected %d)  duplicates OLD=%d NEW=%d"
              % (len(o), len(n), expect, dup_o, dup_n))
        print("  missing in NEW: %s" % (missing or "none"))
        print("  extra   in NEW: %s" % (extra or "none"))
        print("  VERDICT: %s" % ("IDENTICAL" if good else "DIFFERENT"))
    print("\nPORTMAP RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
