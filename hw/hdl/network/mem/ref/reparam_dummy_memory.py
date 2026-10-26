#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import re
import sys

SRC, DST, WB = sys.argv[1], sys.argv[2], int(sys.argv[3])
assert WB in (16, 18), "WINDOW_BITS must be 16 or 18 (toe_config.hpp.in:25-31)"

txt = open(SRC).read()
orig = txt
deltas = []

def sub(pat, rep, why, count=0):
    global txt
    new, n = re.subn(pat, rep, txt, count=count)
    assert n > 0, f"anchor not found: {pat}"
    deltas.append((why, pat, rep, n))
    txt = new

sub(r"readAddr = cmd\.saddr\(15, 0\);",
    f"readAddr = cmd.saddr({WB - 1}, 0);",
    "read offset field width (was a hard 16 b)")
sub(r"readId = cmd\.saddr\(31, 16\);",
    f"readId = cmd.saddr(29, {WB});",
    "read session field position (toe composes pkgAddr(29,WINDOW_BITS), tx_engine.cpp:233-235)")

sub(r"writeAddr = cmd\.saddr\(15, 0\);",
    f"writeAddr = cmd.saddr({WB - 1}, 0);",
    "write offset field width")
sub(r"writeId = cmd\.saddr\(31, 16\);",
    f"writeId = cmd.saddr(29, {WB});",
    "write session field position")

sub(r"ap_uint<16> readAddr; //<8>", f"ap_uint<{WB}> readAddr;",
    "readAddr member width (an ap_uint<16> wraps at 64 KiB by itself)")
sub(r"ap_uint<16> writeAddr; //<8>", f"ap_uint<{WB}> writeAddr;",
    "writeAddr member width")

sub(r"new ap_uint<8>\[65536\]", f"new ap_uint<8>[{1 << WB}]",
    "ring allocation (the one place S9 cited)")

n_bbt = len(re.findall(r"cmd\.bbt\(15, 0\)", orig))

open(DST, "w").write(txt)

print(f"# reparam_dummy_memory: {SRC} -> {DST}, WINDOW_BITS={WB}")
print(f"# {len(deltas)} substitutions applied ({sum(d[3] for d in deltas)} sites):")
for why, pat, rep, n in deltas:
    print(f"#   [{n}] {why}\n#        {pat}  ->  {rep}")
print(f"# NOT changed, reported only: {n_bbt} x `cmd.bbt(15, 0)` truncates a 23-bit btt "
      f"to 16 bits (harmless while commands are <= MSS).")
print(f"# => re-parameterising this model touches {len(deltas)} distinct places, not the "
      f"one line (`:140`) that S9 claim 22 cites.")
