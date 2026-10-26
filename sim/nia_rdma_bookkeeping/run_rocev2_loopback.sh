#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
set -o pipefail
export TERM=xterm

HERE=$(cd "$(dirname "$0")" && pwd)
ROCE_RTL=${NIA_ROCE_RTL:?set NIA_ROCE_RTL to the generated rocev2 verilog directory}
LOGDIR=${LOGDIR:-$HERE/logs_roce}
WORKDIR=${WORKDIR:-$HERE/xsim_roce}

mkdir -p "$LOGDIR" "$WORKDIR"
cd "$WORKDIR" || exit 2

overall=0

run_case() {
	local name="$1"; shift
	echo "ROCELB STAGE run $name $*"
	local targs=()
	for pa in "$@"; do targs+=(-testplusarg "$pa"); done
	xsim roce_lb -runall "${targs[@]}" > "$LOGDIR/${name}_run.log" 2>&1
	local rc=$?
	grep -E "ROCELB (CONFIG|STATE|WIRE|NOTE|DONE|RESULT)|DEADLOCK" "$LOGDIR/${name}_run.log" | grep -v ACKMETA | head -20
	echo "ROCELB RUN $name xsim_rc=$rc log=$LOGDIR/${name}_run.log"
	if ! grep -qE "ROCELB RESULT PASS" "$LOGDIR/${name}_run.log"; then
		overall=1
	fi
}

echo "ROCELB STAGE compile"
{
	xvlog -work xil_roce "$ROCE_RTL"/*.v || exit 21
	xvlog -sv -work xil_roce "$HERE/tb_rocev2_loopback.sv" || exit 22
	xelab -relax -debug typical -s roce_lb xil_roce.tb_rocev2_loopback -L xil_roce || exit 23
} > "$LOGDIR/compile.log" 2>&1
rc=$?
echo "ROCELB COMPILE rc=$rc log=$LOGDIR/compile.log"
if [ "$rc" -ne 0 ]; then
	grep -E "^ERROR" "$LOGDIR/compile.log" | head -20
	echo "ROCELB DONE overall_rc=1"
	exit 1
fi

echo "ROCELB GROUP paced traffic, the reference"
run_case paced_write    pattern=0 messages=12 gap=400
run_case paced_read     pattern=1 messages=12 gap=400
run_case paced_alt      pattern=2 messages=12 gap=400

echo "ROCELB GROUP back to back traffic, which is what the host offers"
run_case rate_write     pattern=0 messages=24 gap=0
run_case rate_read      pattern=1 messages=24 gap=0
run_case rate_alt       pattern=2 messages=24 gap=0

echo "ROCELB GROUP multi packet lengths at rate, the size that lost frames on silicon"
run_case paced_alt_8192 pattern=2 messages=12 gap=1200 size=8192

echo "ROCELB DONE overall_rc=$overall"
exit "$overall"
