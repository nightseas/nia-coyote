#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
set -o pipefail
export TERM=xterm

HERE=$(cd "$(dirname "$0")" && pwd)
CYT_DIR=${NIA_CYT_DIR:-$(cd "$HERE/.." && pwd)}
GEN_PKG=${NIA_GEN_PKG:?set NIA_GEN_PKG to a generated lynx_pkg.sv of a built shell}
LOGDIR=${LOGDIR:-$HERE/logs_elab}
WORKDIR=${WORKDIR:-$HERE/xsim_elab}

HDL="$CYT_DIR/hw/hdl"

mkdir -p "$LOGDIR" "$WORKDIR"
cd "$WORKDIR" || exit 2

overall=0

SRCS=(
	"$GEN_PKG"
	"$HDL/pkg/axi_intf.sv"
	"$HDL/pkg/lynx_intf.sv"
	"$HDL/common/queues/fifo.sv"
	"$HDL/common/queues/queue.sv"
	"$HDL/common/queues/meta_queue.sv"
	"$HDL/common/queues/queue_meta.sv"
	"$HDL/common/queues/queue_stream.sv"
	"$HDL/common/ram/sp_ram_nc.sv"
	"$HDL/common/ram/tdp_ram_nc.sv"
	"$HDL/common/regs/meta_reg.sv"
	"$HDL/common/arbiters/meta_arbiter.sv"
	"$HDL/shell/rdma_cq_count.sv"
	"$HERE/axis_register_slice_meta_stubs.sv"
)

run_one() {
	local name="$1" slave="$2"
	echo "CNFGELAB STAGE $name"
	(
		xvlog -sv -work "xil_$name" -i "$HDL/pkg" "${SRCS[@]}" \
			"$HDL/shell/$slave.sv" "$HERE/tb_cnfg_slave_elab.sv" &&
		xelab -relax -debug typical -s "elab_$name" "xil_$name.tb_cnfg_slave_elab" -L "xil_$name" &&
		xsim "elab_$name" -runall
	) > "$LOGDIR/${name}.log" 2>&1
	local rc=$?
	grep -E "CNFGELAB (STATE|RESULT)" "$LOGDIR/${name}.log"
	echo "CNFGELAB RUN $name rc=$rc log=$LOGDIR/${name}.log"
	if [ "$rc" -ne 0 ] || ! grep -q "CNFGELAB RESULT PASS all cases" "$LOGDIR/${name}.log"; then
		grep -E "^ERROR" "$LOGDIR/${name}.log" | head -12
		overall=1
	fi
}

run_one avx cnfg_slave_avx

echo "CNFGELAB DONE overall_rc=$overall"
exit "$overall"
