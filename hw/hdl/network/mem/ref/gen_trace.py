#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import random
import sys

out = sys.argv[1]
N_SESSIONS = int(sys.argv[2]) if len(sys.argv) > 2 else 16
WB = int(sys.argv[3]) if len(sys.argv) > 3 else 18
MSS = int(sys.argv[4]) if len(sys.argv) > 4 else 4096
N_OPS = int(sys.argv[5]) if len(sys.argv) > 5 else 60
SEED = int(sys.argv[6]) if len(sys.argv) > 6 else 20260726

WINDOW = 1 << WB
rng = random.Random(SEED)

lines = [f"# gen_trace.py N_SESSIONS={N_SESSIONS} WINDOW_BITS={WB} MSS={MSS} "
         f"N_OPS={N_OPS} SEED={SEED}"]
written = []            # (saddr, length)
ridx = 0

for i in range(N_OPS):
    sess = rng.randrange(N_SESSIONS)
    length = rng.randint(1, MSS)
    off = rng.randrange(0, WINDOW - length)
    saddr = (sess << WB) | off
    payload = bytes(rng.getrandbits(8) for _ in range(length))
    lines.append(f"W {saddr} {payload.hex()}")
    written.append((saddr, length))
    if written:
        wa, wl = written[rng.randrange(len(written))]
        skip = rng.randrange(0, wl)
        rl = rng.randint(1, wl - skip)
        lines.append(f"R {ridx} {wa + skip} {rl}")
        ridx += 1

lines.append(f"R {ridx} 0 64")
ridx += 1

open(out, "w").write("\n".join(lines) + "\n")
print(f"wrote {out}: {N_OPS} write commands, {ridx} read commands, "
      f"span {N_SESSIONS * WINDOW} B")
