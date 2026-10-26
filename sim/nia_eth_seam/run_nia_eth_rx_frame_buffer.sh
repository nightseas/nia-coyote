#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
export TERM=xterm

HERE=$(cd "$(dirname "$0")" && pwd)
ETH_DIR=${NIA_SEAM_ETH_DIR:?set NIA_SEAM_ETH_DIR to the nia-eth-scenic tree}
LOGDIR=${LOGDIR:-$HERE/logs}
WORKDIR=${WORKDIR:-$HERE/xsim_frame_buffer}

mkdir -p "$LOGDIR" "$WORKDIR"
cd "$WORKDIR"

echo "FRAMEBUF STAGE compile"
{
    xvlog -sv -work xil_defaultlib \
        "$ETH_DIR/rtl/dcmac_axis_frame_fifo.sv" \
        "$HERE/tb_nia_eth_rx_frame_buffer.sv" || exit 21
    xelab -relax -debug off -s frame_buffer "xil_defaultlib.tb_nia_eth_rx_frame_buffer" \
        -L xil_defaultlib || exit 23
} > "$LOGDIR/frame_buffer_compile.log" 2>&1
compile_rc=$?
echo "FRAMEBUF COMPILE rc=$compile_rc log=$LOGDIR/frame_buffer_compile.log"
[ "$compile_rc" -eq 0 ] || { tail -n 30 "$LOGDIR/frame_buffer_compile.log"; exit "$compile_rc"; }

xsim frame_buffer -runall > "$LOGDIR/frame_buffer_run.log" 2>&1
run_rc=$?
grep -E "FRAMEBUF (CONFIG|STATE|RESULT|BYTE|LENGTH)" "$LOGDIR/frame_buffer_run.log"
echo "FRAMEBUF DONE xsim_rc=$run_rc"
grep -q "FRAMEBUF RESULT PASS" "$LOGDIR/frame_buffer_run.log"
