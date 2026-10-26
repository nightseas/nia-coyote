#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -u
cd "$(dirname "$0")"
LOGDIR=${LOGDIR:-logs}
mkdir -p "$LOGDIR"
SEEDS=${SEEDS:-"1 2"}
FREQS=${FREQS:-"200 250 322.265625"}
rc=0; total=0; fails=0

verdict () {
  python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    print("0 1"); sys.exit(0)
tcs = list(root.iter('testcase'))
bad = [c for c in tcs if len(list(c))]
print(f"{len(tcs)} {len(bad) if tcs else 1}")
PY
}

run_one () {
  local tag="$1"; shift
  echo "=== $tag ==="
  make -s clean >/dev/null 2>&1
  make "$@" COCOTB_RESULTS_FILE="$LOGDIR/results_${tag}.xml" \
       > "$LOGDIR/core_${tag}.log" 2>&1 || rc=1
  read -r t f < <(verdict "$LOGDIR/results_${tag}.xml")
  total=$((total + t)); fails=$((fails + f))
  echo "  tests=$t failures=$f   log=$LOGDIR/core_${tag}.log"
  [ "$f" -eq 0 ] || rc=1
}

for s in $SEEDS; do
  for mhz in $FREQS; do
    run_one "usr${mhz}_seed${s}" SEED="$s" USR_MHZ="$mhz"
  done
  run_one "nports4_seed${s}" SEED="$s" USR_MHZ=250 NPORTS=4
  run_one "ffrx_seed${s}"   SEED="$s" USR_MHZ=250 FF_BRAM=1
  run_one "ffboth_seed${s}" SEED="$s" USR_MHZ=250 FF_BRAM=1 TX_FF_BRAM=1
done

echo "TOTAL testcase-runs=$total  FAILURES=$fails"
if [ "$rc" -eq 0 ] && [ "$total" -gt 0 ] && [ "$fails" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit $rc
