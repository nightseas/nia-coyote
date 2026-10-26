#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
SRC="$HERE/src"
OUT="$HERE/out"
PART="${NIA_FPGA_PART:-xcvp1552-vsva2785-2mhp-i-s}"

say()  { printf '\033[1;36m[dcmac]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dcmac]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[dcmac] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$SRC" ] || die "src/ not found — run this from inside the unpacked pack"

target_spec() {
  case "$1" in
    09_perf_rdma_dcmac) echo "09_perf_rdma|-DEN_RDMA=1 -DALLOW_VERSAL_NET=1 -DDCMAC_PHY=dcmac -DCOMP_CORES=16|dcmac|1" ;;
    09_perf_rdma_stub)  echo "09_perf_rdma|-DEN_RDMA=1 -DALLOW_VERSAL_NET=1 -DDCMAC_PHY=stub -DCOMP_CORES=16|stub|0" ;;
    02_hls_vadd)        echo "02_hls_vadd|-DCOMP_CORES=16|stub|0" ;;
    04_user_interrupts) echo "04_user_interrupts|-DCOMP_CORES=16|stub|0" ;;
    07_perf_fpga)       echo "07_perf_fpga|-DCOMP_CORES=16|stub|0" ;;
    08_multithreading)  echo "08_multithreading|-DCOMP_CORES=16|stub|0" ;;
    03_multitenancy)    echo "03_multitenancy|-DCOMP_CORES=16|stub|0" ;;
    *) return 1 ;;
  esac
}
TARGETS="09_perf_rdma_dcmac 09_perf_rdma_stub 02_hls_vadd 04_user_interrupts 07_perf_fpga 08_multithreading 03_multitenancy"

target_note() {
  case "$1" in
    09_perf_rdma_dcmac) echo "★ real DCMAC + GT on QSFP0 + RoCEv2. NEEDS THE LICENCE. ~3-4 h" ;;
    09_perf_rdma_stub)  echo "same example, loopback PHY. Licence-free control / smoke test. ~2.5 h" ;;
    02_hls_vadd)        echo "HLS vector add. Built + PASSED 6/6 on hardware 2026-07-30. ~1.6 h" ;;
    04_user_interrupts) echo "user interrupts. Built + PASSED with negative control. ~1.6 h" ;;
    07_perf_fpga)       echo "perf baseline, no networking. Built + PASSED. ~1.3 h" ;;
    08_multithreading)  echo "AES, N_STRM_AXI=4. Built + PASSED 4/4 threads. ~1.7 h" ;;
    03_multitenancy)    echo "⚠ N_REGIONS=4. FAILED synth rc=2 on 2026-07-29, NOT diagnosed" ;;
    *) echo "" ;;
  esac
}

find_vivado_src() {
  local c
  for c in "${NIA_VIVADO_SRC:-}" /tools/Xilinx/2025.2/Vivado/settings64.sh; do
    [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return; }
  done
  for c in /tools/Xilinx/*/Vivado/settings64.sh /opt/Xilinx/*/Vivado/settings64.sh; do
    [ -f "$c" ] && { echo "$c"; return; }
  done
  echo ""
}

load_tools() {
  local s; s="$(find_vivado_src)"
  if [ -n "$s" ]; then
    say "sourcing $s"
    set +u; . "$s"; set -u
  elif command -v vivado >/dev/null 2>&1; then
    say "using the vivado already on PATH"
  else
    die "Vivado not found — set NIA_VIVADO_SRC=/path/to/Vivado/settings64.sh"
  fi
  export TERM="${TERM:-xterm}"
}

cmd_list() {
  printf '  %-19s %-19s %-6s %-4s %s\n' TARGET EXAMPLE PHY LIC NOTE
  local t spec
  for t in $TARGETS; do
    spec="$(target_spec "$t")"
    printf '  %-19s %-19s %-6s %-4s %s\n' "$t" "$(echo "$spec"|cut -d'|' -f1)" \
      "$(echo "$spec"|cut -d'|' -f3)" \
      "$([ "$(echo "$spec"|cut -d'|' -f4)" = 1 ] && echo YES || echo '-')" \
      "$(target_note "$t")"
  done
  echo
  echo "  LIC=YES means a full DCMAC licence is required to reach a PDI. Everything else is"
  echo "  licence-free and will produce a PDI on any box with Vivado 2025.2."
  echo "  Build one:   ./build_dcmac.sh build <target>         (dispatch it detached)"
  echo "  Smoke test:  NIA_STAGES=preflight ./build_dcmac.sh build <target>    (~2 min)"
}

cmd_env() {
  say "part        : $PART"
  load_tools
  say "vivado      : $(vivado -version 2>/dev/null | head -1 || echo 'NOT FOUND')"
  case "$(vivado -version 2>/dev/null | head -1)" in
    *2025.2*) say "version     : 2025.2 — matches the tree" ;;
    *) warn "version     : NOT 2025.2. The tree and its IP were developed on 2025.2; a different version may regenerate IP differently." ;;
  esac
  for t in cmake make gcc g++ python3 bootgen; do
    if command -v "$t" >/dev/null 2>&1; then say "$t: $(command -v "$t")"; else warn "$t: MISSING"; fi
  done
  say "cpus        : $(nproc 2>/dev/null || echo '?')"
  say "free RAM    : $(free -g 2>/dev/null | awk '/^Mem:/{print $7" GiB available"}' || echo '?')"
  say "free disk   : $(df -h "$HERE" | awk 'NR==2{print $4}')  (a full build needs ~40 GB)"
  say "submodule   : $([ -f "$SRC/hw/services/network/CMakeLists.txt" ] && echo 'hw/services/network present' || echo 'hw/services/network MISSING — the build will fail')"

  mkdir -p "$OUT"
  cat > "$OUT/ip_probe.tcl" <<EOF
create_project -in_memory -part $PART
set n [llength [get_ipdefs -filter {NAME =~ "dcmac*"}]]
puts "NIA_IPPROBE dcmac_ipdefs=\$n"
foreach d [get_ipdefs -filter {NAME =~ "dcmac*"}] { puts "NIA_IPPROBE found=\$d" }
puts "NIA_IPPROBE gt_quad=[llength [get_ipdefs -filter {NAME =~ "gt_quad_base*"}]]"
puts "NIA_IPPROBE_DONE"
EOF
  say "probing the IP catalogue for '$PART' (~1 min) ..."
  ( cd "$OUT" && vivado -mode batch -nojournal -notrace -log ip_probe.log \
      -source ip_probe.tcl >/dev/null 2>&1 ) || true
  grep -E "NIA_IPPROBE" "$OUT/ip_probe.log" 2>/dev/null | sed 's/^/  /' || warn "IP probe produced no output — see $OUT/ip_probe.log"
  echo
  say "★ The licence TIER cannot be queried from Tcl (get_license_features does not exist)"
  say "  and xlicdiag -t does not report it. The only authoritative test is whether"
  say "  write_device_image succeeds — i.e. gate A7b at the very end of 'build rdma_dcmac'."
  echo
  cmd_list
}

cmd_build() {
  local t="${1:?usage: build <target>   (see ./build_dcmac.sh list)}"
  local spec; spec="$(target_spec "$t")" || die "unknown target '$t'"
  local example extras phy licensed
  example="$(echo "$spec"|cut -d'|' -f1)"
  extras="$(echo "$spec"|cut -d'|' -f2)"
  phy="$(echo "$spec"|cut -d'|' -f3)"
  licensed="$(echo "$spec"|cut -d'|' -f4)"

  local runner="$SRC/scripts/nia/coyote_tu03_build_remote.sh"
  [ -x "$runner" ] || die "the tree's build runner is missing: $runner"
  [ -f "$SRC/hw/services/network/CMakeLists.txt" ] || die "hw/services/network is empty — this pack cannot build"

  local chain="${NIA_STAGES:-preflight project synth link shell bitgen verify}"

  local logdir="$OUT/$t"; mkdir -p "$logdir"
  load_tools

  say "target      : $t"
  say "example     : $example"
  say "DCMAC_PHY   : $phy"
  say "extras      : $extras"
  say "stage chain : $chain"
  if [ "$licensed" = 1 ]; then
    say "gate A7b    : ENABLED (NIA_LICENSED_DCMAC=1) — a PDI is REQUIRED for this target"
  else
    say "gate A7     : NIA_EXPECT_PDI=1 (no DCMAC in this image, so a PDI is expected)"
  fi
  local want_pdi=1
  case " $chain " in *" bitgen "*) ;; *) want_pdi=0
    say "gate A7/A7b : DISABLED — '$chain' does not include bitgen, so no PDI is expected" ;;
  esac
  say "log         : $logdir/build.log"
  say ""
  if [ "$chain" != "preflight" ]; then
    warn "this takes ~3-4 h. If you did not dispatch it detached, Ctrl-C now and use:"
    warn "  setsid nohup ./build_dcmac.sh build $t > /dev/null 2>&1 &"
    sleep 3
  fi

  local -a envv=(
    "NIA_STAGE_NAME=packbuild-$t"
    "NIA_SRC=$SRC"
    "NIA_LOGDIR=$logdir"
    "NIA_EXAMPLE=$example"
    "NIA_CMAKE_EXTRA=$extras"
    "NIA_STAGES=$chain"
    "NIA_FPGA_PART=$PART"
    "NIA_JOBS=${NIA_JOBS:-16}"
    "NIA_FRESH=1"
  )
  if [ "$want_pdi" = 1 ]; then
    if [ "$licensed" = 1 ]; then envv+=("NIA_LICENSED_DCMAC=1"); else envv+=("NIA_EXPECT_PDI=1"); fi
  fi

  env "${envv[@]}" "$runner"
  local rc=$?

  echo
  say "--- markers ---"
  grep -E "NIA_STAGE_END|NIA_BUILD_DONE" "$logdir/build.log" 2>/dev/null | sed 's/^/  /'
  say "--- gates ---"
  grep -E "^NIA_GATE " "$logdir/build.log" 2>/dev/null | sed 's/^/  /' || echo "  (none reported)"
  say "--- errors ---"
  local n_err n_crit
  n_err=$(grep -c '^ERROR' "$logdir/build.log" 2>/dev/null || true)
  n_crit=$(grep -c 'CRITICAL WARNING' "$logdir/build.log" 2>/dev/null || true)
  say "  ERR=${n_err:-0}  CRIT=${n_crit:-0}"
  if grep -qE "Design Linking|17-69|<encrypted cellview>" "$logdir/build.log" 2>/dev/null; then
    warn "★ THE DCMAC LICENCE WAS REFUSED ON THIS BOX:"
    grep -E "Design Linking|17-69|<encrypted cellview>" "$logdir/build.log" | head -4 | sed 's/^/    /' >&2
    warn "  Implementation is permitted under Design_Linking; only write_device_image is not."
    warn "  There is no workaround from a checkpoint (§A.8) — a full DCMAC licence is required."
  fi
  say "rc=$rc"
  return $rc
}

cmd_collect() {
  local t="${1:-}"
  local list="$TARGETS"; [ -n "$t" ] && list="$t"
  local x bdir e
  for x in $list; do
    local spec; spec="$(target_spec "$x")" || continue
    bdir="$SRC/examples/$(echo "$spec"|cut -d'|' -f1)/hw/build"
    e="$OUT/$x/evidence"; mkdir -p "$e"
    say "$x: collecting from $bdir"
    find "$bdir" -name '*.pdi' -exec cp {} "$e/" \; 2>/dev/null || true
    for r in shell_timing_summary shell_utilization shell_route_status shell_drc_bitstream_checks; do
      [ -f "$bdir/reports/$r.rpt" ] && cp "$bdir/reports/$r.rpt" "$e/" 2>/dev/null || true
    done
    [ -f "$OUT/$x/build.log" ] && {
      grep -E "NIA_STAGE_|NIA_GATE|NIA_BUILD_DONE|^ERROR" "$OUT/$x/build.log" > "$e/markers.txt" 2>/dev/null || true
      cp "$OUT/$x/build.log" "$e/" 2>/dev/null || true
    }
    ( cd "$e" && md5sum ./* 2>/dev/null > MD5SUMS.txt ) || true
    ls -la "$e" | sed 's/^/    /'
    if compgen -G "$e/*.pdi" >/dev/null; then
      say "$x: ★ PDI collected:"; md5sum "$e"/*.pdi | sed 's/^/      /'
      say "$x: programming it needs NO licence — it can be tested on any box with a TU03 board."
    else
      warn "$x: no PDI. Check $e/markers.txt for the gate verdicts."
    fi
  done
}

case "${1:-}" in
  env)     shift; cmd_env "$@" ;;
  list)    shift; cmd_list "$@" ;;
  build)   shift; cmd_build "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  *) sed -n '4,22p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
