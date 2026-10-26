#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
set -o pipefail
export TERM=xterm

HERE=$(cd "$(dirname "$0")" && pwd)
CYT_DIR=${NIA_CYT_DIR:?set NIA_CYT_DIR to a Coyote tree supplying the support modules}
ROCE_RTL=${NIA_ROCE_RTL:?set NIA_ROCE_RTL to the generated rocev2 verilog directory}
FIXED_CQCNT=${NIA_FIXED_CQCNT:?set NIA_FIXED_CQCNT to the directory holding the rdma_cq_count.sv under test}
FIXED_RDMA=${NIA_FIXED_RDMA:?set NIA_FIXED_RDMA to the directory holding the rdma_flow.sv under test}
SOAK_RUNS=${NIA_SOAK_RUNS:-0}
LOGDIR=${LOGDIR:-$HERE/logs_chain}
WORKDIR=${WORKDIR:-$HERE/xsim_chain}

HDL="$CYT_DIR/hw/hdl"

mkdir -p "$LOGDIR" "$WORKDIR"
cd "$WORKDIR" || exit 2

overall=0

echo "CHAIN STAGE compile"
(
	xvlog -work xil_chain "$ROCE_RTL"/*.v -i "$ROCE_RTL" &&
	xvlog -sv -work xil_chain -i "$HDL/pkg" \
		"$HERE/lynx_pkg_rdma_sim.sv" \
		"$HDL/pkg/axi_intf.sv" \
		"$HDL/pkg/lynx_intf.sv" \
		"$HERE/axis_register_slice_meta_stubs.sv" \
		"$HERE/axis_data_fifo_cnfg_rdma_32_stub.sv" \
		"$HDL/common/queues/fifo.sv" \
		"$HDL/common/queues/queue.sv" \
		"$HDL/common/queues/queue_meta.sv" \
		"$HDL/common/queues/queue_stream.sv" \
		"$HDL/common/ram/sp_ram_nc.sv" \
		"$HDL/common/ram/tdp_ram_nc.sv" \
		"$HDL/common/regs/meta_reg.sv" \
		"$FIXED_RDMA/rdma_flow.sv" \
		"$HDL/network/rdma/rdma_meta_rx_arbiter.sv" \
		"$FIXED_CQCNT/rdma_cq_count.sv" \
		"$HERE/tb_rdma_chain.sv" &&
	xelab -relax -debug typical -s chain xil_chain.tb_rdma_chain -L xil_chain
) > "$LOGDIR/compile.log" 2>&1
rc=$?
echo "CHAIN COMPILE rc=$rc log=$LOGDIR/compile.log"
if [ "$rc" -ne 0 ]; then
	grep -E "^ERROR" "$LOGDIR/compile.log" | head -20
	echo "CHAIN DONE overall_rc=1"
	exit 1
fi

run_case() {
	local name="$1"; shift
	local targs=()
	for pa in "$@"; do targs+=(-testplusarg "$pa"); done
	xsim chain -runall "${targs[@]}" > "$LOGDIR/${name}_run.log" 2>&1
	local rc=$?
	grep -E "CHAIN (STATE|RESULT|NOTE)|DEADLOCK DETECTED" "$LOGDIR/${name}_run.log" | head -20
	echo "CHAIN RUN $name xsim_rc=$rc log=$LOGDIR/${name}_run.log"
	if ! grep -q "CHAIN RESULT PASS all cases" "$LOGDIR/${name}_run.log"; then
		overall=1
	fi
}

soak_case() {
	local name="$1"; shift
	local targs=()
	for pa in "$@"; do targs+=(-testplusarg "$pa"); done
	xsim chain -runall "${targs[@]}" > "$LOGDIR/${name}_run.log" 2>&1
	local rc=$?
	if grep -q "CHAIN RESULT PASS all cases" "$LOGDIR/${name}_run.log"; then
		echo "CHAIN SOAK $name PASS"
	else
		echo "CHAIN SOAK $name FAIL xsim_rc=$rc log=$LOGDIR/${name}_run.log"
		grep -E "CHAIN (STATE after_traffic|RESULT FAIL)|DEADLOCK DETECTED" "$LOGDIR/${name}_run.log" | head -8
		overall=1
	fi
}

if [ "$SOAK_RUNS" -gt 0 ]; then
	echo "CHAIN GROUP the constrained random soak, $SOAK_RUNS runs"
	for i in $(seq 1 "$SOAK_RUNS"); do
		soak_case "soak_$i" pattern=3 messages=16 gap=600 seed="$i" \
			reap_delay=$((i % 4)) stop_reaping_class=$((i % 4)) expect_all_reaped=1
	done
	echo "CHAIN DONE overall_rc=$overall"
	exit "$overall"
fi

echo "CHAIN GROUP the reference patterns, every completion reaped"
run_case write_only  pattern=0 messages=12 gap=600 reap_delay=0 stop_reaping_class=2 expect_all_reaped=1
run_case read_only   pattern=1 messages=12 gap=600 reap_delay=0 stop_reaping_class=2 expect_all_reaped=1
run_case alternating pattern=2 messages=24 gap=600 reap_delay=0 stop_reaping_class=2 expect_all_reaped=1

echo "CHAIN GROUP the lazy reaping host, which reaps every fourth message"
run_case lazy_reap   pattern=2 messages=24 gap=600 reap_delay=3 stop_reaping_class=2 expect_all_reaped=1

echo "CHAIN GROUP multi packet lengths"
run_case seg_8192    pattern=2 messages=12 gap=1200 size=8192 reap_delay=0 stop_reaping_class=2 expect_all_reaped=1

echo "CHAIN DONE overall_rc=$overall"
exit "$overall"
