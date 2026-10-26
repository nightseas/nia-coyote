#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
INDEX="$HERE/images/index.tsv"
HW="$HERE/coyote_tu03_hw_test.sh"
export NIA_EVID="${NIA_EVID:-$HERE/results}"
mkdir -p "$NIA_EVID"

say()  { printf '\033[1;36m[all]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[all]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[all] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$INDEX" ] || die "images/index.tsv not found — run this from inside the unpacked pack"
[ -x "$HW" ]    || die "coyote_tu03_hw_test.sh not found or not executable"

row()   { awk -F'\t' -v t="$1" -v f="$2" '!/^#/ && $1==t {print $f}' "$INDEX"; }
tags()  { awk -F'\t' '!/^#/ && NF>=2 {print $1}' "$INDEX"; }
have()  { tags | grep -qx "$1"; }

example_cmd() {
  case "$1" in
    02_hls_vadd)        echo "src/examples/02_hls_vadd/sw/build_hw/test|--size 1024" ;;
    04_user_interrupts) echo "src/examples/04_user_interrupts/sw/build_hw/test|" ;;
    08_multithreading)  echo "src/examples/08_multithreading/sw/build_hw/test|--threads 4 --runs 50" ;;
    07_perf_fpga)       echo "src/examples/07_perf_fpga/sw/build_hw/test|--operation 0 --runs 50" ;;
    09_perf_rdma_stub)  echo "|" ;;
    09_perf_rdma_dcmac) echo "|" ;;
    *) echo "|" ;;
  esac
}

cmd_list() {
  printf '  %-22s %-10s %-20s %s\n' TAG SIZE EXAMPLE 'RESULT'
  awk -F'\t' '!/^#/ && NF>=2 {printf "  %-22s %-10s %-20s %s\n", $1, $4, $5, $6}' "$INDEX"
  echo
  echo "  09_perf_rdma_stub has NO run step: that image is DCMAC_PHY=stub (no MAC at all)"
  echo "  and 09_perf_rdma is a two-node benchmark, so one vFPGA cannot be both ends."
  echo "  stage2 on it stops after driver-load, which is the part that IS meaningful."
  echo
  echo "  09_perf_rdma_dcmac is EXTERNAL (build it with the source pack) and also has no run"
  echo "  step here: RDMA is two-node. After stage2 loads the driver, use:"
  echo "      ./rdma_test.sh check && ./rdma_test.sh setup && ./rdma_test.sh run1host"
}

cmd_plan() {
  local tag="${1:?usage: plan <tag>}"; have "$tag" || die "unknown tag '$tag'"
  local pdi; pdi="$(row "$tag" 2)"
  local ec bin args runline
  ec="$(example_cmd "$tag")"; bin="${ec%%|*}"; args="${ec##*|}"
  if [ -z "$bin" ]; then
    runline="(none for this image — see ./run_all.sh list)"
  elif [ -n "$args" ]; then
    runline="./coyote_tu03_hw_test.sh run $tag $bin -- $args"
  else
    runline="./coyote_tu03_hw_test.sh run $tag $bin"
  fi
  cat <<EOF
Sequence for '$tag':

  1. ./build_sw.sh
  2. NIA_TAG=$tag ./coyote_tu03_hw_test.sh program $pdi
  3. sudo rmmod coyote_driver 2>/dev/null; sudo reboot
  4. export NIA_KO=\$PWD/src/driver/build/coyote_driver.ko
     ./coyote_tu03_hw_test.sh env
     ./coyote_tu03_hw_test.sh driver-load
  5. $runline

  Steps 1-2 are 'stage1'. Steps 4-5 are 'stage2'. Step 3 is yours.
  Evidence is written to: $NIA_EVID
EOF
}

cmd_stage1() {
  local marked=0
  [ "${1:-}" = "--marked" ] && { marked=1; shift; }
  local tag="${1:?usage: stage1 [--marked] <tag>}"; have "$tag" || die "unknown tag '$tag'"
  local pdi; pdi="$HERE/$(row "$tag" 2)"
  if [ ! -f "$pdi" ]; then
    if [ "$(row "$tag" 3)" = "EXTERNAL" ]; then
      die "$tag is an EXTERNAL image and is not here yet. Build it with the source pack
       (./build_dcmac.sh build 09_perf_rdma_dcmac), then copy the PDI to: $pdi"
    fi
    die "image missing from the pack: $pdi"
  fi
  local want; want="$(row "$tag" 3)"
  if [ "$want" = "EXTERNAL" ]; then
    say "$tag: EXTERNAL image, md5 NOT verifiable against this pack"
    say "$tag: md5 $(md5sum "$pdi" | cut -d' ' -f1)  size $(stat -c%s "$pdi")"
  else
    local got; got="$(md5sum "$pdi" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || die "image md5 mismatch for $tag: index says $want, file is $got"
    say "$tag: md5 matches the pack index"
  fi

  [ -f "$HERE/src/driver/build/coyote_driver.ko" ] || warn "driver not built yet — run ./build_sw.sh (you can do it after the reboot too)"

  if [ "$marked" = 1 ]; then
    say "$tag: --marked, so NOT programming. Program this exact file yourself:"
    say "      $pdi"
    "$HW" mark "$tag" "$pdi" || die "could not record the image"
    echo "$tag" > "$NIA_EVID/EXPECTED_TAG.txt"
    cat <<EOF

$(printf '\033[1;33m')★ Program that PDI (if you have not already), then REBOOT THE HOST.$(printf '\033[0m')

    sudo rmmod coyote_driver 2>/dev/null; sudo reboot

  Then:   ./run_all.sh stage2 $tag
EOF
    return 0
  fi

  NIA_TAG="$tag" "$HW" program "$pdi" || die "programming failed"
  echo "$tag" > "$NIA_EVID/EXPECTED_TAG.txt"
  cat <<EOF

$(printf '\033[1;33m')★ STOP HERE. REBOOT THE HOST NOW.$(printf '\033[0m')

    sudo rmmod coyote_driver 2>/dev/null; sudo reboot

  BAR2 and the MSI-X table are assigned at POST. Without a reboot the driver aborts with
  'pci IRQ error' / -12. JTAG configuration survives a warm reboot, so the image stays.

  Then:   ./run_all.sh stage2 $tag
EOF
}

cmd_stage2() {
  local tag="${1:?usage: stage2 <tag>}"; have "$tag" || die "unknown tag '$tag'"
  local expected; expected="$(cat "$NIA_EVID/EXPECTED_TAG.txt" 2>/dev/null || echo '')"
  if [ -n "$expected" ] && [ "$expected" != "$tag" ]; then
    die "the last image programmed was '$expected', not '$tag' — a run must be attributed to the right image"
  fi
  local ko="$HERE/src/driver/build/coyote_driver.ko"
  [ -f "$ko" ] || die "driver not built: run ./build_sw.sh"
  export NIA_KO="$ko"

  "$HW" env "$NIA_EVID/env_${tag}.txt" || true
  "$HW" driver-load || die "driver did not load/bind — see $NIA_EVID"

  local ec bin args; ec="$(example_cmd "$tag")"; bin="${ec%%|*}"; args="${ec##*|}"
  if [ -z "$bin" ]; then
    say "$tag: no run step by design (see ./run_all.sh list). The driver bound, which is the"
    say "$tag: meaningful part for this image. Stopping here."
    return 0
  fi
  [ -x "$HERE/$bin" ] || die "example binary missing: $bin (run ./build_sw.sh)"
  if [ -n "$args" ]; then
    # shellcheck disable=SC2086
    "$HW" run "$tag" "$HERE/$bin" -- $args
  else
    "$HW" run "$tag" "$HERE/$bin"
  fi
}

cmd_cycle_noreboot() {
  local tag="${1:?usage: cycle-noreboot <tag>}"; have "$tag" || die "unknown tag '$tag'"
  local pdi; pdi="$HERE/$(row "$tag" 2)"
  local want got; want="$(row "$tag" 3)"; got="$(md5sum "$pdi" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || die "image md5 mismatch for $tag"
  warn "EXPERIMENTAL and UNVERIFIED — no session has yet swapped images without a reboot."
  warn "If anything looks wrong, stop and use: stage1 <tag> ; reboot ; stage2 <tag>"
  "$HW" driver-unload || true
  NIA_TAG="$tag" "$HW" program "$pdi" || die "programming failed"
  echo "$tag" > "$NIA_EVID/EXPECTED_TAG.txt"
  if ! "$HW" hotreset; then
    warn "re-enumeration did not come back clean. REBOOT, then: ./run_all.sh stage2 $tag"
    return 1
  fi
  cmd_stage2 "$tag"
}

case "${1:-}" in
  list)   shift; cmd_list "$@" ;;
  cycle-noreboot) shift; cmd_cycle_noreboot "$@" ;;
  plan)   shift; cmd_plan "$@" ;;
  stage1) shift; cmd_stage1 "$@" ;;
  stage2) shift; cmd_stage2 "$@" ;;
  *) sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
