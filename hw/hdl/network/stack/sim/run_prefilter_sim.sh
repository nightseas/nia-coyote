#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$HERE/.." && pwd)"
SCAFFOLD="$(cd "$HERE/../../dcmac_eth/synth" && pwd)"
WORK="${NIA_PREFILTER_WORK:-/tmp/host_networking_prefilter_sim}"
DEFINES="${NIA_PREFILTER_DEFINES:-EN_RDMA}"
PREFILTER_RTL="${NIA_PREFILTER_RTL:-$STACK_DIR/host_networking_prefilter.sv}"

rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"

DEFINE_ARGS=()
for define in $DEFINES; do DEFINE_ARGS+=(-d "$define"); done

xvlog -sv "${DEFINE_ARGS[@]}" \
    "$SCAFFOLD/lynx_pkg_min.sv" \
    "$SCAFFOLD/axi4s_min.sv" \
    "$PREFILTER_RTL" \
    "$HERE/host_networking_prefilter_flat.sv" \
    "$HERE/tb_host_networking_prefilter.sv" > "$WORK/xvlog.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "PREFILTER_SIM xvlog failed"
    tail -30 "$WORK/xvlog.log"
    exit 2
fi

xelab -debug off -O0 tb_host_networking_prefilter -s prefilter_sim > "$WORK/xelab.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "PREFILTER_SIM xelab failed"
    tail -30 "$WORK/xelab.log"
    exit 2
fi

xsim prefilter_sim -runall > "$WORK/xsim.log" 2>&1
rc=$?
grep -E '^TEST |^\*\* ' "$WORK/xsim.log"
if [ "$rc" -ne 0 ]; then
    echo "PREFILTER_SIM xsim exit $rc"
    tail -20 "$WORK/xsim.log"
fi
fails="$(sed -n 's/^\*\* TESTS=[0-9]* PASS=[0-9]* FAIL=\([0-9]*\)/\1/p' "$WORK/xsim.log" | head -1)"
[ -n "$fails" ] || { echo "PREFILTER_SIM no summary"; exit 2; }
[ "$fails" = "0" ] || exit 1
exit 0
