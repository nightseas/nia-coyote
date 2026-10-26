#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
set -o pipefail
export TERM=xterm

HERE=$(cd "$(dirname "$0")" && pwd)
CYT_DIR=${NIA_CYT_DIR:-$(cd "$HERE/.." && pwd)}
UPSTREAM_CREDITS=${NIA_UPSTREAM_CREDITS:-}
REPAIRED_CREDITS=${NIA_REPAIRED_CREDITS:?set NIA_REPAIRED_CREDITS to the directory holding the repaired req_credits_rd.sv}
BASELINE_RDMA=${NIA_BASELINE_RDMA:-}
FIXED_RDMA=${NIA_FIXED_RDMA:?set NIA_FIXED_RDMA to the directory holding the rdma_flow.sv under test}
FIXED_CQCNT=${NIA_FIXED_CQCNT:?set NIA_FIXED_CQCNT to the directory holding the rdma_cq_count.sv under test}
BASELINE_CQCNT=${NIA_BASELINE_CQCNT:-}
LOGDIR=${LOGDIR:-$HERE/logs}
WORKDIR=${WORKDIR:-$HERE/xsim_bookkeeping}

HDL="$CYT_DIR/hw/hdl"
PKG="$HERE/lynx_pkg_rdma_sim.sv"
STUBS="$HERE/axis_register_slice_meta_stubs.sv"
INTF="$HDL/pkg/lynx_intf.sv"

mkdir -p "$LOGDIR" "$WORKDIR"
cd "$WORKDIR" || exit 2

overall=0

run_one() {
	local name="$1" top="$2" plusargs="$3"
	shift 3
	local defs=()
	for d in ${XVLOG_DEFS:-}; do defs+=(-d "$d"); done
	echo "BOOKKEEPING STAGE compile $name"
	{
		xvlog -sv -work "xil_${name}" "${defs[@]}" -i "$HDL/pkg" "$PKG" "$INTF" "$STUBS" "$@" "$HERE/tb_${top}.sv" || exit 21
		xelab -relax -debug typical -s "$name" "xil_${name}.tb_${top}" -L "xil_${name}" || exit 23
	} > "$LOGDIR/${name}_compile.log" 2>&1
	local rc=$?
	echo "BOOKKEEPING COMPILE $name rc=$rc log=$LOGDIR/${name}_compile.log"
	if [ "$rc" -ne 0 ]; then
		tail -n 40 "$LOGDIR/${name}_compile.log"
		overall=1
		return "$rc"
	fi
	local targs=()
	for pa in $plusargs; do targs+=(-testplusarg "$pa"); done
	xsim "$name" -runall "${targs[@]}" > "$LOGDIR/${name}_run.log" 2>&1
	rc=$?
	grep -E "FLOWWIN|CREDRET|DCREDRET|WCREDRET|HOSTMUX|GAPRX|CQCNT" "$LOGDIR/${name}_run.log"
	echo "BOOKKEEPING RUN $name xsim_rc=$rc log=$LOGDIR/${name}_run.log"
	if ! grep -qE "RESULT PASS all cases" "$LOGDIR/${name}_run.log"; then
		overall=1
	fi
}

run_one flowwinfixed rdma_flow_window "expect_reset_clears_window=1 expect_entry_alias=0 expect_completion_loss=0" \
	"$HDL/common/ram/sp_ram_nc.sv" \
	"$HDL/common/queues/fifo.sv" \
	"$HDL/common/queues/queue_meta.sv" \
	"$HDL/common/regs/meta_reg.sv" \
	"$FIXED_RDMA/rdma_flow.sv"

if [ -n "$BASELINE_RDMA" ] && [ -f "$BASELINE_RDMA/rdma_flow.sv" ]; then
	run_one flowwinbase rdma_flow_window "expect_reset_clears_window=0 expect_entry_alias=1 expect_completion_loss=1" \
		"$HDL/common/ram/sp_ram_nc.sv" \
		"$HDL/common/queues/fifo.sv" \
		"$HDL/common/queues/queue_meta.sv" \
		"$HDL/common/regs/meta_reg.sv" \
		"$BASELINE_RDMA/rdma_flow.sv"
else
	echo "BOOKKEEPING SKIP flowwinbase, set NIA_BASELINE_RDMA to the pre-repair rdma directory"
fi

run_one credrepaired req_credits_retention "expect_reset_clears=1 expect_credits_initialised=1" \
	"$HDL/common/queues/fifo.sv" \
	"$HDL/common/queues/queue_stream.sv" \
	"$HDL/common/regs/meta_reg.sv" \
	"$REPAIRED_CREDITS/req_credits_rd.sv"

if [ -n "$UPSTREAM_CREDITS" ] && [ -f "$UPSTREAM_CREDITS/req_credits_rd.sv" ]; then
	run_one credupstream req_credits_retention "expect_reset_clears=0 expect_credits_initialised=0" \
		"$HDL/common/queues/fifo.sv" \
		"$HDL/common/queues/queue_stream.sv" \
		"$HDL/common/regs/meta_reg.sv" \
		"$UPSTREAM_CREDITS/req_credits_rd.sv"
else
	echo "BOOKKEEPING SKIP credupstream, set NIA_UPSTREAM_CREDITS to the pristine credits directory"
fi

run_one dcredrepaired dreq_credits_retention "expect_reset_clears=1 expect_credits_initialised=1" \
	"$HDL/common/queues/fifo.sv" \
	"$HDL/common/queues/queue_stream.sv" \
	"$HDL/common/regs/meta_reg.sv" \
	"$REPAIRED_CREDITS/dreq_credits_rd.sv"

if [ -n "$UPSTREAM_CREDITS" ] && [ -f "$UPSTREAM_CREDITS/dreq_credits_rd.sv" ]; then
	run_one dcredupstream dreq_credits_retention "expect_reset_clears=0 expect_credits_initialised=0" \
		"$HDL/common/queues/fifo.sv" \
		"$HDL/common/queues/queue_stream.sv" \
		"$HDL/common/regs/meta_reg.sv" \
		"$UPSTREAM_CREDITS/dreq_credits_rd.sv"
else
	echo "BOOKKEEPING SKIP dcredupstream, set NIA_UPSTREAM_CREDITS to the pristine credits directory"
fi

echo "BOOKKEEPING GROUP the write path credit blocks"
run_one wcredrepaired wr_credits_retention "expect_reset_clears=1" \
	"$HDL/common/queues/fifo.sv" \
	"$HDL/common/queues/queue_stream.sv" \
	"$HDL/common/regs/meta_reg.sv" \
	"$REPAIRED_CREDITS/req_credits_wr.sv"

if [ -n "$UPSTREAM_CREDITS" ] && [ -f "$UPSTREAM_CREDITS/req_credits_wr.sv" ]; then
	run_one wcredupstream wr_credits_retention "expect_reset_clears=1" \
		"$HDL/common/queues/fifo.sv" \
		"$HDL/common/queues/queue_stream.sv" \
		"$HDL/common/regs/meta_reg.sv" \
		"$UPSTREAM_CREDITS/req_credits_wr.sv"
else
	echo "BOOKKEEPING SKIP wcredupstream"
fi

XVLOG_DEFS="DREQ_WR" run_one dwcredbase wr_credits_retention "expect_reset_clears=1" \
	"$HDL/common/queues/fifo.sv" \
	"$HDL/common/queues/queue_stream.sv" \
	"$HDL/common/regs/meta_reg.sv" \
	"$UPSTREAM_CREDITS/dreq_credits_wr.sv"

echo "BOOKKEEPING GROUP the host request mux, which forks a remote write to the remote path and the host fetch"
XVLOG_DEFS="EN_NET" run_one hostmux host_req_mux "" \
	"$HDL/common/regs/meta_reg.sv" \
	"$HDL/user/mux_init/host_req_mux.sv"

echo "BOOKKEEPING GROUP the inbound gap enforcer and the buffer ahead of it"
XVLOG_DEFS="NET_DCMAC" run_one gaprx ack_gap_rx_path "fifo_depth=2048 resp_beats=64 messages=64" \
	"$HDL/pkg/axi_intf.sv" \
	"$HDL/network/rdma/ack_gap_enforcer.sv"

echo "BOOKKEEPING GROUP the host visible completion accounting of the shell"
run_one cqcntfixed rdma_cq_count "expect_read_counts=1 expect_no_discard=1 messages=12 gap=6" \
	"$HDL/common/queues/fifo.sv" \
	"$HDL/common/queues/queue_stream.sv" \
	"$HDL/common/ram/tdp_ram_nc.sv" \
	"$FIXED_CQCNT/rdma_cq_count.sv"

if [ -n "$BASELINE_CQCNT" ] && [ -f "$BASELINE_CQCNT/rdma_cq_count.sv" ]; then
	run_one cqcntbase rdma_cq_count "expect_read_counts=0 expect_no_discard=0 messages=12 gap=6" \
		"$HDL/common/queues/fifo.sv" \
		"$HDL/common/queues/queue_stream.sv" \
		"$HDL/common/ram/tdp_ram_nc.sv" \
		"$BASELINE_CQCNT/rdma_cq_count.sv"
else
	echo "BOOKKEEPING SKIP cqcntbase, set NIA_BASELINE_CQCNT to the upstream extract directory"
fi

echo "BOOKKEEPING DONE overall_rc=$overall"
exit "$overall"
