#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVID="${NIA_EVID:-$HERE/results}"
SUDO_PW="${NIA_SUDO_PW:-}"
CLIENT_BIN="${NIA_RDMA_CLIENT:-$HERE/src/examples/09_perf_rdma/sw/build_client/test}"
SERVER_BIN="${NIA_RDMA_SERVER:-$HERE/src/examples/09_perf_rdma/sw/build_server/test}"
TIMEOUT="${NIA_RDMA_TIMEOUT:-180}"

mkdir -p "$EVID"
say()  { printf '\033[1;36m[rdma]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[rdma]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[rdma] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
SUDO() { if [ -n "$SUDO_PW" ]; then echo "$SUDO_PW" | sudo -S -p "" "$@"; else sudo "$@"; fi; }

driver_loaded() { grep -q '^coyote_driver ' /proc/modules; }
devices()  { ls /dev/coyote_fpga_*_v0 2>/dev/null | sed -E 's|.*coyote_fpga_([0-9]+)_v0|\1|' | sort -n; }
sysfs_ip() { cat "/sys/kernel/coyote_sysfs_$1/cyt_attr_ip"  2>/dev/null; }
sysfs_mac(){ cat "/sys/kernel/coyote_sysfs_$1/cyt_attr_mac" 2>/dev/null; }

cmd_check() {
  local rc=0
  driver_loaded || { warn "coyote_driver is NOT loaded — load it first"; rc=1; }

  local devs; mapfile -t devs < <(devices)
  say "coyote vFPGA devices: ${#devs[@]}  (${devs[*]:-none})"
  if [ "${#devs[@]}" -eq 0 ]; then
    warn "NO coyote device. Load the driver, and if the image was just programmed remember the"
    warn "reboot rule: BAR2 and the MSI-X table are assigned at POST, a hot rescan leaves BAR2 unassigned."
    rc=1
  elif [ "${#devs[@]}" -eq 1 ]; then
    say "one device ⇒ TWO-HOST mode, which is the only configuration in which a RoCE result is"
    say "  trustworthy. run1host is unavailable and that is intended."
  fi

  local d
  for d in "${devs[@]}"; do
    printf '  dev %s : %-34s %s\n' "$d" "$(sysfs_ip "$d" | tr -d '\n')" "$(sysfs_mac "$d" | tr -d '\n')"
  done

  if [ "${#devs[@]}" -ge 2 ]; then
    local ip0 ip1; ip0="$(sysfs_ip "${devs[0]}")"; ip1="$(sysfs_ip "${devs[1]}")"
    if [ "$ip0" = "$ip1" ]; then
      warn "★ BOTH FPGAs REPORT THE SAME IP. RoCE cannot work like this: 'ip_addr' is a"
      warn "  module parameter applied to every device the driver probes."
      warn "  Fix it now with:   $0 setup"
      rc=1
    else
      say "the two FPGAs have distinct IPs — good"
    fi
  elif [ "${#devs[@]}" -eq 1 ]; then
    local myip mymac; myip="$(sysfs_ip "${devs[0]}")"; mymac="$(sysfs_mac "${devs[0]}")"
    say "★ THIS HOST's FPGA identity: ip $myip  mac $mymac"
    warn "  Two-host mode cannot check this locally: 'ip_addr' is a module parameter and its"
    warn "  default is identical on every host, so BOTH FPGAs come up as 0B01D4D1 unless you"
    warn "  give one of them a different base:   $0 setup 0B01D4D2"
    warn "  Compare the line above against the peer host before running. Same IP ⇒ no RoCE."
    echo "NIA_RDMA_MYIP=$myip"
    echo "NIA_RDMA_MYMAC=$mymac"
  fi

  if SUDO dmesg 2>/dev/null | grep -q "enabled RDMA 1"; then
    say "driver reported 'enabled RDMA 1' ⇒ the image contains the RoCE stack"
  else
    warn "could not find 'enabled RDMA 1' in dmesg (it may have rotated). If the image is"
    warn "  DCMAC_PHY=stub or non-networking, there is nothing to test here."
  fi

  say ""
  say "★ LINK STATE is what decides whether a real DCMAC image can pass. This script cannot"
  say "  read the MAC's PCS/FEC status — that lives in the DCMAC control plane, not in sysfs."
  say "  Before believing a failure is a software problem, confirm the QSFP0<->QSFP0 DAC is"
  say "  seated and that the two boards are the ones you programmed."
  say ""
  say "binaries:"
  printf '  client : %s %s\n' "$([ -x "$CLIENT_BIN" ] && echo OK || echo MISSING)" "$CLIENT_BIN"
  printf '  server : %s %s\n' "$([ -x "$SERVER_BIN" ] && echo OK || echo MISSING)" "$SERVER_BIN"
  [ -x "$CLIENT_BIN" ] && [ -x "$SERVER_BIN" ] || { warn "run ./build_sw.sh"; rc=1; }

  if [ -x "$CLIENT_BIN" ]; then
    if "$CLIENT_BIN" --device 0 --ip_address 0.0.0.0 --max_size 64 --min_size 64 --runs 1 2>&1 \
         | grep -q "unrecognised option"; then
      warn "★ the client does NOT accept --device: this is an UNPATCHED 09_perf_rdma, and a"
      warn "  one-host two-board run would put both ends on device 0. Use the pack's own sources."
      rc=1
    else
      say "the client accepts --device ⇒ the patched example is in place"
    fi
  fi
  [ "$rc" -eq 0 ] && say "CHECK OK" || warn "CHECK found problems (above)"
  echo "NIA_RDMA_CHECK=$([ "$rc" -eq 0 ] && echo OK || echo PROBLEMS)"
  return $rc
}

cmd_setup() {
  driver_loaded || die "load the driver first"
  local devs; mapfile -t devs < <(devices)
  [ "${#devs[@]}" -ge 1 ] || die "no coyote devices"

  local base_ip="${1:-0B01D4D1}" ip1="${2:-}"
  local base_mac="${NIA_RDMA_BASE_MAC:-000A35029DE5}"
  local i d ip mac
  i=0
  for d in "${devs[@]}"; do
    if [ "$i" = 1 ] && [ -n "$ip1" ]; then
      ip="$ip1"
    else
      ip="$(printf '%08X' $(( 0x$base_ip + i )))"
    fi
    mac="$(printf '%012X' $(( 0x$base_mac + i )))"
    SUDO sh -c "echo $ip  > /sys/kernel/coyote_sysfs_$d/cyt_attr_ip"  || warn "dev $d: IP write failed"
    SUDO sh -c "echo $mac > /sys/kernel/coyote_sysfs_$d/cyt_attr_mac" || warn "dev $d: MAC write failed"
    say "dev $d -> ip $ip  mac $mac"
    i=$((i+1))
  done
  say "readback:"
  for d in "${devs[@]}"; do printf '  dev %s : %s %s\n' "$d" "$(sysfs_ip "$d"|tr -d '\n')" "$(sysfs_mac "$d"|tr -d '\n')"; done
  { echo "# per-device FPGA network identity, set $(date -Is)"
    for d in "${devs[@]}"; do echo "dev $d: $(sysfs_ip "$d"|tr -d '\n') $(sysfs_mac "$d"|tr -d '\n')"; done
  } > "$EVID/rdma_identity.txt"
  echo "NIA_RDMA_SETUP=OK"
}

OP=1; RUNS=1; MINSZ=64; MAXSZ=65536; SDEV=0; CDEV=1; DEV_EXPLICIT=0
parse_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--operation) OP="$2"; shift 2 ;;
      -r|--runs)      RUNS="$2"; shift 2 ;;
      -x|--min_size)  MINSZ="$2"; shift 2 ;;
      -X|--max_size)  MAXSZ="$2"; shift 2 ;;
      --server-dev)   SDEV="$2"; shift 2 ;;
      --client-dev)   CDEV="$2"; shift 2 ;;
      --dev)          SDEV="$2"; CDEV="$2"; DEV_EXPLICIT=1; shift 2 ;;
      *) warn "ignoring unknown option '$1'"; shift ;;
    esac
  done
}

resolve_single_dev() {
  local devs; mapfile -t devs < <(devices)
  [ "${#devs[@]}" -ge 1 ] || die "no coyote device on this host — is the driver loaded?"
  if [ "${#devs[@]}" -gt 1 ] && [ "${DEV_EXPLICIT:-0}" != 1 ]; then
    warn "this host has ${#devs[@]} devices; using dev ${devs[0]}. Pass --dev N to choose."
  fi
  if [ "${DEV_EXPLICIT:-0}" != 1 ]; then
    SDEV="${devs[0]}"; CDEV="${devs[0]}"
    say "two-host mode: using device $SDEV on this host"
  else
    printf '%s\n' "${devs[@]}" | grep -qx "$SDEV" || die "device $SDEV not present on this host (have: ${devs[*]})"
  fi
}

verdict() {
  local tag="$1" rc="$2" clog="$3"
  local thr; thr="$(grep -c 'Average throughput' "$clog" 2>/dev/null || true)"
  {
    echo "---- verdict ----"
    echo "client exit : $rc"
    echo "throughput lines: ${thr:-0}"
  } >> "$clog"
  if [ "$rc" = 0 ] && [ "${thr:-0}" -gt 0 ]; then
    say "★ RDMA PASS — client exited 0 with ${thr} throughput line(s)"
    grep -E 'Size:|Average' "$clog" | tail -12 | sed 's/^/    /'
    echo "NIA_RDMA[$tag]=PASS"; return 0
  fi
  if [ "$rc" = 124 ]; then
    warn "★ RDMA STALL — the client never completed within ${TIMEOUT}s."
    if grep -q 'Queue pair' "$clog" 2>/dev/null; then
      warn "  The QP exchange DID succeed (a queue pair was printed), so the host side and"
      warn "  the out-of-band bootstrap are fine. What did not happen is a completion coming"
      warn "  back ⇒ suspect the WIRE / MAC: DAC seated? both boards on the DCMAC image?"
      warn "  PCS/FEC locked? This is the expected first-light failure mode, not a host bug."
    else
      warn "  The QP exchange did not even print — the stall is in the TCP bootstrap, not RoCE."
    fi
    echo "NIA_RDMA[$tag]=STALL"; return 124
  fi
  warn "RDMA FAIL — client exit $rc"
  tail -20 "$clog" | sed 's/^/    /' >&2
  echo "NIA_RDMA[$tag]=FAIL"; return 1
}

cmd_run1host() {
  parse_opts "$@"
  driver_loaded || die "load the driver first"
  local devs; mapfile -t devs < <(devices)
  [ "${#devs[@]}" -ge 2 ] || die "need TWO coyote devices for a one-host run; found ${#devs[@]}. Use runserver/runclient across two hosts instead."
  [ "$SDEV" != "$CDEV" ] || die "server and client must use DIFFERENT devices (got $SDEV twice) — that is the collision this script exists to prevent"
  [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ] || die "binaries missing — run ./build_sw.sh"

  local ip_s ip_c; ip_s="$(sysfs_ip "$SDEV")"; ip_c="$(sysfs_ip "$CDEV")"
  [ "$ip_s" != "$ip_c" ] || die "dev $SDEV and dev $CDEV report the SAME FPGA IP ($ip_s). Run '$0 setup' first."

  local stamp; stamp="$(date +%Y%m%d_%H%M%S)"
  local slog="$EVID/rdma_server_$stamp.log" clog="$EVID/rdma_client_$stamp.log"
  { echo "# 09_perf_rdma, ONE host / TWO FPGAs"
    echo "when        : $(date -Is)"
    echo "server dev  : $SDEV   fpga ip: $ip_s"
    echo "client dev  : $CDEV   fpga ip: $ip_c"
    echo "operation   : $([ "$OP" = 1 ] && echo WRITE || echo READ)"
    echo "runs/min/max: $RUNS / $MINSZ / $MAXSZ"
    echo "timeout     : ${TIMEOUT}s"; } | tee "$slog" > "$clog"

  SUDO dmesg -C 2>/dev/null || true
  say "starting SERVER on device $SDEV"
  ( cd "$(dirname "$SERVER_BIN")" && LD_LIBRARY_PATH="$PWD" \
      setsid timeout "$TIMEOUT" ./test --device "$SDEV" --operation "$OP" \
        --runs "$RUNS" --min_size "$MINSZ" --max_size "$MAXSZ" >>"$slog" 2>&1 & )
  sleep 4
  say "starting CLIENT on device $CDEV -> 127.0.0.1"
  ( cd "$(dirname "$CLIENT_BIN")" && LD_LIBRARY_PATH="$PWD" \
      timeout "$TIMEOUT" ./test --device "$CDEV" --ip_address 127.0.0.1 --operation "$OP" \
        --runs "$RUNS" --min_size "$MINSZ" --max_size "$MAXSZ" >>"$clog" 2>&1 )
  local rc=$?
  sleep 1
  SUDO dmesg 2>/dev/null | tail -60 >> "$clog"
  say "server log: $slog"
  say "client log: $clog"
  verdict "1host" "$rc" "$clog"
}

cmd_runserver() {
  parse_opts "$@"
  driver_loaded || die "load the driver first"
  resolve_single_dev
  [ -x "$SERVER_BIN" ] || die "server binary missing — run ./build_sw.sh"
  local slog="$EVID/rdma_server_$(date +%Y%m%d_%H%M%S).log"
  say "SERVER on device $SDEV (fpga ip $(sysfs_ip "$SDEV" | tr -d '\n'))"
  say "give the CLIENT host this box's TCP address; log: $slog"
  ( cd "$(dirname "$SERVER_BIN")" && LD_LIBRARY_PATH="$PWD" \
      timeout "$TIMEOUT" ./test --device "$SDEV" --operation "$OP" \
        --runs "$RUNS" --min_size "$MINSZ" --max_size "$MAXSZ" 2>&1 | tee "$slog" )
  say "server exit: ${PIPESTATUS[0]}"
}

cmd_runclient() {
  local peer="${1:?usage: runclient <server-host-ip> [opts]}"; shift || true
  parse_opts "$@"
  driver_loaded || die "load the driver first"
  resolve_single_dev
  [ -x "$CLIENT_BIN" ] || die "client binary missing — run ./build_sw.sh"
  local clog="$EVID/rdma_client_$(date +%Y%m%d_%H%M%S).log"
  say "CLIENT on device $CDEV (fpga ip $(sysfs_ip "$CDEV" | tr -d '\n')) -> server host $peer"
  ( cd "$(dirname "$CLIENT_BIN")" && LD_LIBRARY_PATH="$PWD" \
      timeout "$TIMEOUT" ./test --device "$CDEV" --ip_address "$peer" --operation "$OP" \
        --runs "$RUNS" --min_size "$MINSZ" --max_size "$MAXSZ" >>"$clog" 2>&1 )
  local rc=$?
  SUDO dmesg 2>/dev/null | tail -40 >> "$clog"
  verdict "2host" "$rc" "$clog"
}

usage() { sed -n '4,30p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  check)     shift; cmd_check "$@" ;;
  setup)     shift; cmd_setup "$@" ;;
  run1host)  shift; cmd_run1host "$@" ;;
  runserver) shift; cmd_runserver "$@" ;;
  runclient) shift; cmd_runclient "$@" ;;
  ""|-h|--help) usage ;;
  *) die "unknown verb '$1'" ;;
esac
