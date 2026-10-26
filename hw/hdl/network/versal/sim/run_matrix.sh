#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
export TERM=xterm

HERE=$(cd "$(dirname "$0")" && pwd)
IPDIR=${IPDIR:-$HERE/ip}
LOGDIR=${LOGDIR:-$HERE/logs}
SHIM=${SHIM:-$HERE/../axis_interconnect_512_shim.sv}
TB=$HERE/tb_axis_shim.sv
SEEDS=${SEEDS:-"1 2"}
WITH_NEG=${WITH_NEG:-1}

mkdir -p "$LOGDIR"
cd "$HERE"
rc=0
rows=""

compile_one () {
  local d=$1 log="$LOGDIR/compile_$d.log"
  local ip="axis_switch_512_$d"
  : > "$log"
  (
    echo "NIA_S23_COMPILE=$d"
    xvlog -work xil_defaultlib -i "$IPDIR/$ip/hdl" \
        "$IPDIR/$ip/hdl/axis_infrastructure_v1_1_vl_rfs.v" \
        "$IPDIR/$ip/hdl/axis_register_slice_v1_1_vl_rfs.v" \
        "$IPDIR/$ip/hdl/axis_switch_v1_1_vl_rfs.v" \
        "$IPDIR/$ip/sim/$ip.v"                              || exit 21
    xvlog -sv -work xil_defaultlib "$SHIM" "$TB"            || exit 22
    xelab -relax -debug off -s "snap_$d" "xil_defaultlib.tb_shim_$d" \
        -L xil_defaultlib -L unisims_ver -L unisim -L secureip || exit 23
  ) >> "$log" 2>&1
  local r=$?
  echo "  compile_$d rc=$r ($log)"
  return $r
}

run_one () {
  local d=$1 seed=$2 ng=$3 tag=$4 must=$5
  local log="$LOGDIR/run_$tag.log"
  local cmd="xsim snap_$d -runall -testplusarg SEED=$seed -testplusarg NEG=$ng"
  { echo "NIA_S23_CMDLINE: $cmd"; echo "NIA_S23_WANT_SEED=$seed"; } > "$log"
  eval "$cmd" >> "$log" 2>&1
  local r=$?
  local cliseed dutseed res done_rc nerrs seedok
  cliseed=$(grep -oE "NIA_S23_WANT_SEED=[0-9]+" "$log" | grep -oE "[0-9]+$" | tail -1)
  dutseed=$(grep -oE "^S23_SEED=[0-9]+" "$log" | grep -oE "[0-9]+$" | tail -1)
  res=$(grep -oE "S23_RESULT .*" "$log" | tail -1)
  done_rc=$(grep -oE "S23_DONE rc=[0-9]+" "$log" | grep -oE "[0-9]+$" | tail -1)
  nerrs=$(grep -c "S23 ERROR" "$log")
  if [ "$cliseed" = "$seed" ] && [ "$dutseed" = "$seed" ]; then
    seedok="SEED_PROVEN=$seed (cmdline+dut)"
  else
    seedok="SEED_NOT_PROVEN(cli=$cliseed dut=$dutseed want=$seed)"
    rc=1
  fi
  local verdict
  if [ "$must" = "1" ]; then
    if [ "$done_rc" = "0" ] && [ "$nerrs" = "0" ] && [ "$r" = "0" ]; then verdict=PASS
    else verdict=FAIL; rc=1; fi
  else
    if [ "$done_rc" = "1" ] && [ "$nerrs" != "0" ]; then verdict="GUARD_FIRED"
    else verdict="GUARD_DID_NOT_FIRE"; rc=1; fi
  fi
  echo "  $tag: $verdict | $res | $seedok | S23_ERROR lines=$nerrs | xsim_rc=$r"
  rows="$rows| $tag | $d | $seed | $verdict | ${res:-none} | $seedok | $nerrs |\n"
}

echo "=== S23 XSIM gate: axis_interconnect_512_shim vs the real axis_switch:1.1 (xcvp1552) ==="
for d in 4to1 2to1; do
  compile_one "$d" || { echo "  COMPILE FAILED for $d"; rc=1; continue; }
  for s in $SEEDS; do
    run_one "$d" "$s" 0 "${d}_seed${s}" 1
  done
done

if [ "$WITH_NEG" = "1" ]; then
  echo "--- negative control (must fail) ---"
  run_one 4to1 1 1 "neg_4to1_keep" 0
  run_one 2to1 1 1 "neg_2to1_keep" 0
fi

echo
echo "| config | dut | seed | verdict | result | seed check | S23_ERROR lines |"
echo "|---|---|---|---|---|---|---|"
printf "$rows"
echo
echo "NIA_S23_MATRIX_DONE rc=$rc"
exit $rc
