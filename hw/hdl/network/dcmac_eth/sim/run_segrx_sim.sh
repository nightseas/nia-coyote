#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETH_RTL="$(cd "$HERE/../nia_eth" && pwd)"
WORK="${NIA_SEGRX_WORK:-/tmp/dcmac_seg_axis_rx_sim}"
IN_REG="${NIA_SEGRX_IN_REG:-1}"

rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"

xvlog -sv -d TB_IN_REG="$IN_REG" \
    "$ETH_RTL/dcmac_seg_axis_adapter.sv" \
    "$HERE/tb_dcmac_seg_axis_rx.sv" > "$WORK/xvlog.log" 2>&1
if [ $? -ne 0 ]; then
    echo "SEGRX_SIM xvlog failed"
    tail -25 "$WORK/xvlog.log"
    exit 2
fi

xelab -debug off -O0 tb_dcmac_seg_axis_rx -s segrx_sim > "$WORK/xelab.log" 2>&1
if [ $? -ne 0 ]; then
    echo "SEGRX_SIM xelab failed"
    tail -25 "$WORK/xelab.log"
    exit 2
fi

xsim segrx_sim -runall > "$WORK/xsim.log" 2>&1
grep -E '^TEST |^\*\* |^FRAME |^TB_IN_REG' "$WORK/xsim.log" | head -40
fails="$(sed -n 's/^\*\* TESTS=[0-9]* PASS=[0-9]* FAIL=\([0-9]*\).*/\1/p' "$WORK/xsim.log" | head -1)"
[ -n "$fails" ] || { echo "SEGRX_SIM no summary"; exit 2; }
[ "$fails" = "0" ] || exit 1
exit 0
