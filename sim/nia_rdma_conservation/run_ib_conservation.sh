#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HLS_DIR=${NIA_HLS_DIR:?set NIA_HLS_DIR to the Coyote hw/services/network/hls directory}
HLS_INCLUDE=${NIA_HLS_INCLUDE:?set NIA_HLS_INCLUDE to the Vitis HLS include directory}
LOGDIR=${LOGDIR:-$HERE/logs}
BIN=${BIN:-$HERE/ib_conservation}

mkdir -p "$LOGDIR"

echo "CONSERVE STAGE compile"
g++ -O1 -std=c++14 -w \
	-I"$HERE/config" \
	-I"$HLS_INCLUDE" \
	-I"$HLS_DIR/rocev2" \
	-o "$BIN" \
	"$HERE/test_ib_conservation.cpp" > "$LOGDIR/compile.log" 2>&1
rc=$?
echo "CONSERVE COMPILE rc=$rc log=$LOGDIR/compile.log"
if [ "$rc" -ne 0 ]; then
	grep -m 20 -E "error:" "$LOGDIR/compile.log"
	exit "$rc"
fi

run_case() {
	local name="$1"
	shift
	"$BIN" "$@" > "$LOGDIR/${name}.log" 2>&1
	local crc=$?
	grep -E "CONSERVE (CONFIG|OFFER|TALLY|WINDOW|RESULT|COUNTERS)" "$LOGDIR/${name}.log"
	echo "CONSERVE CASE $name rc=$crc log=$LOGDIR/${name}.log"
	return "$crc"
}

overall=0

run_case exact_alternating --sizes 8192,20480 --messages 6 || overall=1
run_case partial_alternating --sizes 6144,20480 --messages 6 || overall=1
run_case partial_read_only --sizes 6144 --messages 6 --read-only || overall=1
run_case partial_write_only --sizes 6144 --messages 6 --write-only || overall=1
run_case subpmtu_alternating --sizes 64,128,256 --messages 6 || overall=1

echo "CONSERVE GROUP with packet loss, which reaches the negative acknowledgement and retransmission paths"
run_case drop8_partial_alternating --sizes 6144,20480 --messages 6 --drop 8 || overall=1
run_case drop8_subpmtu_alternating --sizes 64,128,256 --messages 6 --drop 8 || overall=1
run_case drop4_partial_alternating --sizes 6144,20480 --messages 6 --drop 4 || overall=1
run_case drop6_partial_alternating --sizes 6144,20480 --messages 6 --drop 6 || overall=1
run_case drop16_partial_alternating --sizes 6144,20480 --messages 6 --drop 16 || overall=1
run_case drop16_subpmtu_alternating --sizes 64,128,256 --messages 6 --drop 16 || overall=1
run_case single_loss_partial_alternating --sizes 6144,20480 --messages 6 --drop 200 || overall=1
run_case single_loss_subpmtu_alternating --sizes 64,128,256 --messages 6 --drop 200 || overall=1

echo "CONSERVE NOTE the cases named drop are negative controls that exhibit the leak, so a nonzero overall code is the expected outcome of this suite"
echo "CONSERVE DONE overall_rc=$overall"
exit "$overall"
