#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGDIR=${LOGDIR:-$HERE/logs_golden}
mkdir -p "$LOGDIR"
rc=0

one () {
  local tag="$1"; shift
  echo "=== GOLDEN $tag ==="
  ( cd "$HERE" && make -s clean >/dev/null 2>&1 )
  ( cd "$HERE" && TRACE_DIR="$LOGDIR" make SEED=1 "$@" \
      COCOTB_RESULTS_FILE="$LOGDIR/results_$tag.xml" ) > "$LOGDIR/run_$tag.log" 2>&1
  local r=$?
  local np
  np=$(echo "$@" | grep -oE "NPORTS=[0-9]+" | grep -oE '[0-9]+')
  local g="$LOGDIR/trace_golden_np${np}.txt"
  local o="$LOGDIR/trace_observed_np${np}.txt"
  if [ ! -s "$g" ] || [ ! -s "$o" ]; then
    echo "GOLDEN_$tag=NO_TRACE (make_rc=$r, see $LOGDIR/run_$tag.log)"
    rc=1; return
  fi
  local n
  n=$(wc -l < "$g")
  if diff -u "$g" "$o" > "$LOGDIR/diff_np${np}.txt"; then
    echo "GOLDEN_$tag=IDENTICAL records=$n diff=$LOGDIR/diff_np${np}.txt(empty)"
    echo "GOLDEN_${tag}_MD5_GOLDEN=$(md5sum "$g" | cut -d' ' -f1)"
    echo "GOLDEN_${tag}_MD5_OBSERVED=$(md5sum "$o" | cut -d' ' -f1)"
  else
    echo "GOLDEN_$tag=MISMATCH  see $LOGDIR/diff_np${np}.txt"
    head -30 "$LOGDIR/diff_np${np}.txt"
    rc=1
  fi
  [ "$r" != "0" ] && rc=1
}

one np1 NPORTS=1 ANCHOR=0 RATE_CODE=0 RATE_FIELD=4  DONE_MASK=3
one np4 NPORTS=4 ANCHOR=0 RATE_CODE=2 RATE_FIELD=16 DONE_MASK=255

echo "GOLDEN_DONE rc=$rc"
exit $rc
