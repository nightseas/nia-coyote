#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGDIR=${LOGDIR:-$HERE/logs}
mkdir -p "$LOGDIR"
rc=0
rows=""

run_cfg () {
  local tag="$1" seed="$2"; shift 2
  local xml="$LOGDIR/results_$tag.xml" log="$LOGDIR/run_$tag.log"
  echo "=== RUN $tag ==="
  ( cd "$HERE" && make -s clean >/dev/null 2>&1 )
  ( cd "$HERE" && make SEED="$seed" "$@" COCOTB_RESULTS_FILE="$xml" ) > "$log" 2>&1
  local r=$?
  local line
  line=$(grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+" "$log" | tail -1)
  local xmlseed logseed seedok
  xmlseed=$(grep -oE 'name="random_seed" value="[0-9]+"' "$xml" 2>/dev/null \
            | grep -oE '[0-9]+' | tail -1)
  logseed=$(grep -oE "supplied seed [0-9]+" "$log" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
  if [ "$xmlseed" = "$seed" ] && [ "$logseed" = "$seed" ]; then
    seedok="SEED_PROVEN=$seed (xml+log)"
  else
    seedok="SEED_NOT_PROVEN(xml=$xmlseed log=$logseed want=$seed)"
    rc=1
  fi
  local nfail
  nfail=$(grep -cE "<failure|<error" "$xml" 2>/dev/null)
  [ "$nfail" != "0" ] && rc=1
  [ "$r" != "0" ] && rc=1
  echo "  $line | $seedok | xml_failures=$nfail | make_rc=$r"
  rows="$rows| $tag | $seed | $line | $seedok | $nfail |\n"
}

for seed in 1 2; do
  run_cfg "np1_seed${seed}"  "$seed" NPORTS=1 ANCHOR=0 RATE_CODE=0 RATE_FIELD=4  DONE_MASK=3
  run_cfg "np4_seed${seed}"  "$seed" NPORTS=4 ANCHOR=0 RATE_CODE=2 RATE_FIELD=16 DONE_MASK=255
done

neg () {
  local tag="$1" frag="$2"; shift 2
  local log="$LOGDIR/neg_$tag.log"
  echo "=== NEG $tag (must fail) ==="
  ( cd "$HERE" && make -s clean >/dev/null 2>&1 )
  ( cd "$HERE" && make SEED=1 "$@" ) > "$log" 2>&1
  local r=$?
  if grep -q "$frag" "$log"; then
    echo "  GUARD_FIRED  ($frag)  make_rc=$r"
    rows="$rows| neg_$tag | - | GUARD_FIRED | n/a | 0 |\n"
  else
    echo "  GUARD_DID_NOT_FIRE — expected '$frag' in $log"
    rows="$rows| neg_$tag | - | GUARD_DID_NOT_FIRE | n/a | 1 |\n"
    rc=1
  fi
}
neg b10_gap    "B10 violated"  GAP_MS=10
neg rx_cycles  "B15 violated"  RX_CYCLES_G=12
neg portgroup  "exceeds PORT_MAX" NPORTS=4 ANCHOR=4

echo
echo "| config | seed | result | seed check | xml failures |"
echo "|---|---|---|---|---|"
printf "$rows"
echo
echo "NIA_MATRIX_DONE rc=$rc"
exit $rc
