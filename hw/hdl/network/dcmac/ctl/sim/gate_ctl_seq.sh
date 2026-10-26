#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
L=${NIA_LOG_DIR:-$D/sim/logs}
mkdir -p "$L"
echo $$ > "$L/gate.pid"
exec > "$L/gate.log" 2>&1
rc=0

echo "NIA_STAGE_BEGIN env"
verilator --version; cocotb-config --version; python3 -V; uname -a
echo "NIA_STAGE_END env"

echo "NIA_STAGE_BEGIN sim_matrix"
( cd "$D/sim" && LOGDIR="$L/sim" bash ./run_matrix.sh ) > "$L/matrix.log" 2>&1 || rc=1
sed -n '/| config | seed |/,$p' "$L/matrix.log"
grep -E "NIA_MATRIX_DONE" "$L/matrix.log"
echo "NIA_STAGE_END sim_matrix rc=$rc"

echo "NIA_STAGE_BEGIN golden_trace"
( cd "$D/sim" && LOGDIR="$L/gold" bash ./run_golden.sh ) > "$L/golden.log" 2>&1 || rc=1
grep -E "^GOLDEN_" "$L/golden.log"
echo "NIA_STAGE_END golden_trace rc=$rc"

echo "NIA_STAGE_BEGIN mutations"
( cd "$D/sim" && LOGDIR="$L/mut" python3 ./run_mutations.py ) > "$L/mutations.log" 2>&1 || rc=1
sed -n '/| mutant | file |/,$p' "$L/mutations.log"
echo "NIA_STAGE_END mutations rc=$rc"

source /tools/Xilinx/2025.2/Vivado/settings64.sh
for t in np1 np4; do
  echo "NIA_STAGE_BEGIN ooc_$t"
  mkdir -p "$L/ooc_$t"
  ( cd "$L/ooc_$t" && env TERM=xterm vivado -mode batch -nojournal \
      -log "$L/ooc_$t/vivado.log" -source "$D/synth/ooc_synth.tcl" -tclargs "$t" ) \
      > "$L/ooc_$t/out.log" 2>&1 || rc=1
  grep -E "^OOC_" "$L/ooc_$t/out.log"
  echo "NIA_STAGE_END ooc_$t rc=$rc"
done

echo "NIA_GATE_DONE rc=$rc"
