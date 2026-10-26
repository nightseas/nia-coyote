#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCMAC_ETH="$(cd "$HERE/.." && pwd)"
WORKSPACE="$(cd "$DCMAC_ETH/../../../../../../.." && pwd)"

VENDORED="$DCMAC_ETH/nia_eth"
FALLBACK="$WORKSPACE/repo/nia-eth"

if [ -d "$VENDORED" ]; then
    ETH_RTL="$VENDORED"
    ETH_MODEL="$VENDORED"
    SRC=vendored
else
    ETH_RTL="$FALLBACK/rtl"
    ETH_MODEL="$FALLBACK/sim/model"
    SRC=repo
fi

MODE="${NIA_ELAB_MODE:-1}"
WORK="${NIA_ELAB_WORK:-/tmp/dcmac_eth_elab}"
rm -rf "$WORK" && mkdir -p "$WORK"
FILES="$WORK/files.f"

{
  echo "$DCMAC_ETH/synth/lynx_pkg_min.sv"
  echo "$DCMAC_ETH/synth/axi4s_min.sv"
  for f in ctl/dcmac_ctl_pkg.sv ctl/dcmac_ctl_seq.sv ctl/wdt.sv ctl/dcmac_link_sample.sv \
           ctl/dcmac_link_wdt.sv ctl/dcmac_axil_exec.sv ctl/dcmac_axil_arb.sv \
           ctl/dcmac_mac_ctl_fsm.sv ctl/dcmac_link_ctl.sv dcmac_sync2.sv gt_rst_req_gate.sv \
           dcmac_seg_axis_adapter.sv eth_axis_dwidth.sv dcmac_axis_frame_fifo.sv \
           dcmac_axis_adapter.sv dcmac_port.sv dcmac_axis_top.sv dcmac_phy_model.sv; do
      echo "$ETH_RTL/$f"
  done
  echo "$ETH_MODEL/eth_axis_async_fifo.sv"
  echo "$ETH_MODEL/tx_frame_fifo.sv"
  echo "$DCMAC_ETH/dcmac_usr_reset_gen.sv"
  echo "$DCMAC_ETH/dcmac_axis_wrapper.sv"
} > "$FILES"

missing=0
while read -r f; do
    [ -f "$f" ] || { echo "MISSING $f"; missing=1; }
done < "$FILES"
if [ "$missing" -ne 0 ]; then
    echo "ELAB RESULT: FAIL (missing sources, sources=$SRC)"
    exit 2
fi

DEFS=""
[ "$MODE" != "1" ] && DEFS="+define+DCMAC_ETH_USR_RESET_MODE=$MODE"

cd "$WORK"
verilator --lint-only -sv --timing --top-module dcmac_axis_wrapper \
  -Wno-fatal --stats $DEFS -f "$FILES" > "$WORK/elab.log" 2>&1
vrc=$?

errors=$(grep -c '%Error' "$WORK/elab.log")
ours=$(grep -E '%Error|%Warning' "$WORK/elab.log" | grep -c 'dcmac_eth/dcmac_')
modules=$(grep -oE 'in [0-9]+ modules' "$WORK/elab.log" | grep -oE '[0-9]+' | head -1)

echo "ELAB sources=$SRC mode=$MODE verilator_rc=$vrc errors=$errors ours=$ours modules=${modules:-0}"
grep -E '%Error' "$WORK/elab.log" | head -10
grep -E '%Warning' "$WORK/elab.log" | grep 'dcmac_eth/dcmac_' | head -10

if [ "$errors" -eq 0 ] && [ "$ours" -eq 0 ] && [ "${modules:-0}" -ge 20 ]; then
    echo "ELAB RESULT: PASS"
    exit 0
fi
echo "ELAB RESULT: FAIL"
exit 1
