#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

SIMS="${NIA_SIMS:-verilator}"
ARMS="${NIA_ARMS:-1:16:1 1:64:2 0:16:1 2:16:1}"

rm -f results_*.xml
rc=0

for sim in $SIMS; do
  for arm in $ARMS; do
    mode="${arm%%:*}"
    rest="${arm#*:}"
    hold="${rest%%:*}"
    seed="${rest##*:}"
    tag="${sim}_mode${mode}_hold${hold}_seed${seed}"
    echo "=== ARM $tag"
    make clean >/dev/null 2>&1
    make SIM="$sim" MODE="$mode" HOLD_CYCLES="$hold" SEED="$seed"
    if [ -f results.xml ]; then
      cp results.xml "results_${tag}.xml"
    else
      echo "ARM $tag produced no results.xml"
      rc=1
    fi
  done
done

python3 - <<'PY'
import glob
import sys
import xml.etree.ElementTree as ET

total = 0
failed = []
files = sorted(glob.glob("results_*.xml"))
if not files:
    print("ARMS RESULT: FAIL (no results.xml collected)")
    sys.exit(1)
for f in files:
    n = 0
    bad = []
    for case in ET.parse(f).getroot().iter("testcase"):
        n += 1
        for child in case:
            if child.tag in ("failure", "error"):
                bad.append(case.get("name"))
                break
    total += n
    failed += [(f, b) for b in bad]
    print(f"{f}: tests={n} failed={len(bad)} {bad}")
print(f"\nARMS TOTAL testcase-runs={total} arms={len(files)} failures={len(failed)}")
print("ARMS RESULT: " + ("PASS" if not failed else "FAIL"))
sys.exit(0 if not failed else 1)
PY
agg=$?

echo
if [ "$rc" -eq 0 ] && [ "$agg" -eq 0 ]; then
    echo "RUN_ARMS: PASS"
else
    echo "RUN_ARMS: FAIL"
fi
exit $(( rc | agg ))
