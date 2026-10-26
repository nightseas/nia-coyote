#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGDIR=${LOGDIR:-$HERE/logs}
mkdir -p "$LOGDIR"
rc=0
rows=""

for amap in flat rdma_slot; do
  for seed in 1 2; do
    tag="${amap}_seed${seed}"
    xml="$LOGDIR/results_$tag.xml"
    log="$LOGDIR/run_$tag.log"
    echo "=== RUN $tag ==="
    ( cd "$HERE" && make -s clean >/dev/null 2>&1 )
    ( cd "$HERE" && make SEED=$seed ADDR_MAP=$amap \
        SOAK_BURSTS=${SOAK_BURSTS:-2500} TPUT_CYCLES=${TPUT_CYCLES:-20000} \
        RAW_N=${RAW_N:-400} COCOTB_RESULTS_FILE="$xml" ) > "$log" 2>&1
    r=$?
    line=$(grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+" "$log" | tail -1)
    xmlseed=$(grep -oE 'name="random_seed" value="[0-9]+"' "$xml" 2>/dev/null \
              | grep -oE '[0-9]+' | tail -1)
    logseed=$(grep -oE "supplied seed [0-9]+" "$log" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
    if [ "$xmlseed" = "$seed" ] && [ "$logseed" = "$seed" ]; then
      seedok="SEED_PROVEN=$seed (xml+log)"
    else
      seedok="SEED_NOT_PROVEN(xml=$xmlseed log=$logseed want=$seed)"
      rc=1
    fi
    nfail=$(grep -cE "<failure|<error" "$xml" 2>/dev/null)
    [ "$nfail" != "0" ] && rc=1
    [ "$r" != "0" ] && rc=1
    echo "  $line | $seedok | xml_failures=$nfail | make_rc=$r"
    rows="$rows| $amap | $seed | $line | $seedok | $nfail |\n"
  done
done

echo
echo "| ADDR_MAP | seed | result | seed check | xml failures |"
echo "|---|---|---|---|---|"
printf "$rows"
echo
echo "NIA_MATRIX_DONE rc=$rc"
exit $rc
