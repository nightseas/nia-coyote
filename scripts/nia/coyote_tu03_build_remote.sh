#!/bin/bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

STAGE_NAME="${NIA_STAGE_NAME:-coyote-tu03}"
NIA_SRC="${NIA_SRC:-$(cd "$(dirname "$0")/../.." && pwd)}"
LOGDIR="${NIA_LOGDIR:-$NIA_SRC/build_logs/$STAGE_NAME}"
LOG="$LOGDIR/build.log"
EXAMPLE="${NIA_EXAMPLE:-07_perf_fpga}"
CMAKE_EXTRA="${NIA_CMAKE_EXTRA:-}"
JOBS="${NIA_JOBS:-16}"
VIVADO_SETTINGS="${NIA_VIVADO:-/tools/Xilinx/2025.2/Vivado/settings64.sh}"

FDEV="${NIA_FDEV:-vp1552}"
FPGA_PART="${NIA_FPGA_PART:-xcvp1552-vsva2785-2mhp-i-s}"
DCMAC_PHY="${NIA_DCMAC_PHY:-$(printf '%s' "${NIA_CMAKE_EXTRA:-}" | sed -nE 's/.*-DDCMAC_PHY=([A-Za-z_]+).*/\1/p')}"
[ -z "$DCMAC_PHY" ] && DCMAC_PHY=stub
FRESH="${NIA_FRESH:-1}"

CMAKE_FLAGS="-DFDEV_NAME=vp1552 -DBUILD_STATIC=1 -DBUILD_SHELL=0 -DBUILD_APP=0 -DEN_SHELL_PBLOCK=0 -DPCIE_GEN=5"

BUILD_DIR="$NIA_SRC/examples/$EXAMPLE/hw/build"

mkdir -p "$LOGDIR"
exec >> "$LOG" 2>&1
echo $$ > "$LOGDIR/run.pid"

ts() { date -Is; }
say() { echo "[$(ts)] $*"; }

trap 'rc=$?; if [ "${NIA_CLEAN_EXIT:-0}" != "1" ]; then echo "NIA_BUILD_DONE rc=$rc (unexpected exit at line $LINENO)"; fi' EXIT

RC=0
run_stage() {
  local name="$1"; shift
  if [ "$RC" -ne 0 ]; then
    echo "NIA_STAGE_SKIP $name (previous stage failed, rc=$RC)"
    return
  fi
  local t0 t1 rc
  echo "NIA_STAGE_BEGIN $name $(ts)"
  t0=$(date +%s)
  "$@"
  rc=$?
  t1=$(date +%s)
  echo "NIA_STAGE_END $name rc=$rc secs=$((t1 - t0))"
  [ "$rc" -ne 0 ] && RC=$rc
  return 0
}

say "=========================================================================="
say "NIA Coyote TU03 build — stage=$STAGE_NAME example=$EXAMPLE jobs=$JOBS"
say "src=$NIA_SRC  build=$BUILD_DIR"
say "cmake: $CMAKE_FLAGS $CMAKE_EXTRA"
say "=========================================================================="

if [ ! -f "$VIVADO_SETTINGS" ]; then
  say "no vivado settings at $VIVADO_SETTINGS"; echo "NIA_BUILD_DONE rc=90"; exit 90
fi
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"
export TERM=xterm
say "vivado: $(command -v vivado) / $(vivado -version 2>/dev/null | head -1)"
say "git:    $(git -C "$NIA_SRC" log --oneline -1 2>/dev/null)"

# shellcheck disable=SC1090
. "$NIA_SRC/scripts/nia/coyote_tu03_gates.sh"
say "gates:  $NIA_SRC/scripts/nia/coyote_tu03_gates.sh  fdev=$FDEV part=$FPGA_PART dcmac_phy=$DCMAC_PHY"

if [ "$FRESH" = "1" ]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || { echo "NIA_BUILD_DONE rc=91"; exit 91; }

# shellcheck disable=SC2086
run_stage cmake env TERM=xterm cmake ../ $CMAKE_FLAGS $CMAKE_EXTRA

for s in ${NIA_STAGES-project synth link shell bitgen}; do
  case "$s" in
    preflight)
      run_stage preflight nia_preflight "$NIA_SRC" "$FDEV" "$FPGA_PART" "$LOGDIR" \
                                       "$BUILD_DIR" "$DCMAC_PHY"
      if [ "$RC" -ne 0 ]; then
        say "PRE-FLIGHT REFUSED THE BUILD (rc=$RC). Nothing was dispatched."
        NIA_CLEAN_EXIT=1
        echo "NIA_BUILD_DONE rc=$RC"
        exit "$RC"
      fi
      ;;
    verify)
      run_stage verify nia_verify "$NIA_SRC" "$FDEV" "$FPGA_PART" "$LOGDIR" \
                                  "$BUILD_DIR" "$DCMAC_PHY" "$LOG"
      ;;
    *)
      run_stage "$s" env TERM=xterm make -j"$JOBS" "$s"
      ;;
  esac
done

if [ "$RC" -eq 0 ]; then
  echo "NIA_STAGE_BEGIN evidence $(ts)"
  for f in "$BUILD_DIR"/reports/*timing_summary* "$BUILD_DIR"/reports/*utilization* ; do
    [ -f "$f" ] && say "report: $f"
  done
  n_expect=0
  [ "${NIA_EXPECT_PDI:-0}" = "1" ] && n_expect=1
  [ "${NIA_LICENSED_DCMAC:-0}" = "1" ] && n_expect=1
  case " ${NIA_STAGES-project synth link shell bitgen} " in
    *" bitgen "*) ;;
    *) n_expect=0
       say "A7c: 'bitgen' is not in the stage chain, so no PDI is expected" ;;
  esac
  if [ "${NIA_EXPECT_PDI:-0}" = "1" ] && [ "$DCMAC_PHY" = "dcmac" ]; then
    say "note: NIA_EXPECT_PDI=1 with dcmac_phy=dcmac — under A7c this is no longer refused;"
    say "      whether the PDI is legitimate is decided from the build log, not from a flag."
  fi
  nia_gate_a7c_pdi_policy "$BUILD_DIR" "$LOG" "$n_expect" || RC=97
  echo "NIA_STAGE_END evidence rc=$RC secs=0"
fi

say "final rc=$RC"
NIA_CLEAN_EXIT=1
echo "NIA_BUILD_DONE rc=$RC"
exit "$RC"
