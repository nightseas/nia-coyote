#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVID="${NIA_EVID:-$HERE/results}"
SUDO_PW="${NIA_SUDO_PW:-}"
PCI_VENDEV="${NIA_PCI_VENDEV:-10ee:b03f}"
SAMPLES="${NIA_DUMP_SAMPLES:-3}"
INTERVAL="${NIA_DUMP_INTERVAL:-1}"
SYSFS_GLOB="${NIA_SYSFS_GLOB:-/sys/kernel/coyote_sysfs_*}"
CLIENT_BIN="${NIA_RDMA_CLIENT:-$HERE/src/examples/09_perf_rdma/sw/build_client/test}"
SERVER_BIN="${NIA_RDMA_SERVER:-$HERE/src/examples/09_perf_rdma/sw/build_server/test}"
ARP_SRC="${NIA_ARP_SRC:-$HERE/arpprobe}"
ARP_BIN="${NIA_ARP_BIN:-$ARP_SRC/build/arpprobe}"

mkdir -p "$EVID"
say()  { printf '\033[1;36m[diag]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[diag]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[diag] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
SUDO() { if [ -n "$SUDO_PW" ]; then echo "$SUDO_PW" | sudo -S -p "" "$@"; else sudo "$@"; fi; }

deansi() { sed -e 's/\x1b\[[0-9;]*m//g'; }
rd()     { cat "$1" 2>/dev/null || SUDO cat "$1" 2>/dev/null; }
nodes()  { ls -d $SYSFS_GLOB 2>/dev/null || true; }
devid()  { basename "$1" | sed 's/coyote_sysfs_//'; }
driver_loaded() { grep -q '^coyote_driver ' /proc/modules; }
sysfs_ip() { cat "/sys/kernel/coyote_sysfs_$1/cyt_attr_ip" 2>/dev/null; }

MOVING_ATTRS="cyt_attr_nstats cyt_attr_hstats cyt_attr_prstats cyt_attr_qdma_debug_regs"

client_has_device_opt() {
  grep -aq -e 'device,d' -e 'Which FPGA to use' "$1"
}

sample_one() {
  { echo "--- sample $4  t=$(date +%s.%N) ---"; rd "$1/$2" | deansi; } >> "$3"
}

delta_table() {
  awk '
    /^--- sample/ { s++; next }
    /:[[:space:]]*[0-9]/ {
      key=$0; sub(/:.*/,"",key); val=$0; sub(/^[^:]*:[[:space:]]*/,"",val)
      if (val ~ /^0x/) next
      if (!(key in first)) { first[key]=val+0; order[++nk]=key }
      last[key]=val+0
    }
    END {
      if (nk==0) { print "--- DELTA: no decimal counters here (hex registers only) ---"; exit }
      print "--- DELTA (last sample - first sample) ---"
      for (i=1;i<=nk;i++) { k=order[i]; d=last[k]-first[k]
        printf "%-24s %14d -> %14d   delta %+d%s\n", k, first[k], last[k], d, (d!=0?"   <-- MOVING":"") }
    }' "$1"
}

last_val() {
  awk -v L="$2" -F': *' '$0 ~ "^"L":" { v=$2 } END { print (v==""?"":v+0) }' "$1"
}
first_val() {
  awk -v L="$2" -F': *' '$0 ~ "^"L":" { if (v=="") v=$2 } END { print (v==""?"":v+0) }' "$1"
}

collect() {
  local dir="$1" tag="$2" n="$3" iv="$4"
  mkdir -p "$dir"
  local nl; nl="$(nodes)"

  { echo "# NIA Coyote TU03 DIAG"
    echo "tag             : $tag"
    echo "when            : $(date -Is)"
    echo "host            : $(hostname)   kernel $(uname -r)"
    echo "sampling        : $n x every ${iv}s"
    echo "driver loaded   : $(grep '^coyote_driver ' /proc/modules || echo 'NO')"
    echo "devices         : $(ls /dev/coyote* 2>/dev/null | tr '\n' ' ')"
    echo "hugepages       : $(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
    echo "sysfs nodes     : $(echo $nl)"
    echo "image           : $(cat "$EVID/CURRENT_IMAGE.txt" 2>/dev/null | head -3 | tr '\n' ' ' || true)"
  } > "$dir/00_summary.txt"
  cat "$dir/00_summary.txt"

  [ -z "$nl" ] && warn "no ${SYSFS_GLOB} — driver not loaded or did not bind"

  local node id f a
  for node in $nl; do
    id="$(devid "$node")"
    for f in "$node"/*; do
      [ -f "$f" ] || continue; a="$(basename "$f")"
      { echo "=== dev $id / $a ==="; rd "$f" | deansi; echo; } >> "$dir/10_sysfs_dev${id}.txt"
    done
    say "dev $id: $(grep -c '^=== ' "$dir/10_sysfs_dev${id}.txt") attributes captured"
  done

  local i
  for i in $(seq 1 "$n"); do
    for node in $nl; do
      id="$(devid "$node")"
      for a in $MOVING_ATTRS; do
        [ -f "$node/$a" ] && sample_one "$node" "$a" "$dir/20_dev${id}_${a}.txt" "$i"
      done
    done
    [ "$i" -lt "$n" ] && sleep "$iv"
  done
  for f in "$dir"/20_dev*.txt; do [ -f "$f" ] && delta_table "$f" >> "$f"; done

  local bdf
  for bdf in $(lspci -D -d "$PCI_VENDEV" 2>/dev/null | awk '{print $1}'); do
    local sfx; sfx="$(echo "$bdf" | tr ':.' '__')"
    SUDO lspci -s "$bdf" -vvv 2>/dev/null | deansi > "$dir/30_lspci_${sfx}.txt"
    { echo "bdf   : $bdf"
      grep -m1 'LnkCap:' "$dir/30_lspci_${sfx}.txt" | sed 's/^[ \t]*//'
      grep -m1 'LnkSta:' "$dir/30_lspci_${sfx}.txt" | sed 's/^[ \t]*//'
      grep -m1 'MSI-X:'  "$dir/30_lspci_${sfx}.txt" | sed 's/^[ \t]*//'
      echo "-- BARs (a 0-sized BAR2 is the classic no-reboot symptom) --"
      grep -E '^[[:space:]]+Region [0-9]+:' "$dir/30_lspci_${sfx}.txt" | sed 's/^[[:space:]]*//'
      echo "-- error bits (a silent link fault shows HERE and nowhere else) --"
      grep -E 'DevSta:|CESta:|UESta:|UEMsk:|RootSta:' "$dir/30_lspci_${sfx}.txt" | sed 's/^[[:space:]]*//'
    } >> "$dir/32_pcie.txt"
  done
  [ -f "$dir/32_pcie.txt" ] || echo "no endpoint matching $PCI_VENDEV enumerates" > "$dir/32_pcie.txt"

  ( dmesg 2>/dev/null || SUDO dmesg 2>/dev/null ) | deansi > "$dir/40_dmesg.txt"
  grep -iE 'coyote|vfpga|tlb|hpid|iommu|WARN|BUG|Call Trace' "$dir/40_dmesg.txt" \
      > "$dir/41_dmesg_coyote.txt" 2>/dev/null
  ( cd "$dir" && md5sum ./* > MANIFEST.md5 2>/dev/null )
}

traffic_class() {
  local dtx="$1" drx="$2" txl="$3" rxl="$4" rocel="$5" retr="$6" psn="$7" prxl="$8" ptxl="$9" rc="${10}"
  if   [ "$retr" -gt 0 ] || [ "$psn" -gt 0 ];               then echo ROCE-PROTOCOL-FAILURE
  elif [ "$txl" -gt 0 ] && [ "$prxl" -gt 0 ] \
    && [ "$rxl" -gt 0 ] && [ "$ptxl" -gt 0 ];               then echo FRAMES-CROSSED-BOTH-WAYS
  elif [ "$txl" -eq 0 ] && [ "$rocel" -eq 0 ];              then echo STACK-SILENT
  elif [ "$dtx" -gt 0 ] && [ "$drx" -eq 0 ] && [ "$prxl" -eq 0 ]; then echo TX-MOVING-RX-DEAD
  elif [ "$dtx" -eq 0 ] && [ "$txl" -gt 0 ] && [ "$prxl" -eq 0 ] && [ "$rc" = "124" ]; then echo TX-PLATEAU
  elif [ "$drx" -gt 0 ];                                    then echo BIDIRECTIONAL
  else                                                           echo INCONCLUSIVE
  fi
}
run_state() {
  [ -f "$1/52_runstate.txt" ] && awk -F= -v k="$2" '$1==k{print $2}' "$1/52_runstate.txt"
}
cmd_verdict() {
  local dir="${1:?usage: verdict <dumpdir>}"
  [ -d "$dir" ] || die "no such dump directory: $dir"
  local out="$dir/90_VERDICT.txt"
  : > "$out"

  local delivered rc fatal rxl_note_ok=1
  delivered="$(run_state "$dir" RUN_DELIVERED)"
  rc="$(run_state "$dir" CLIENT_RC)"
  fatal="$(run_state "$dir" RUN_FATAL)"

  if [ -z "$delivered" ]; then
    { echo "CLASS: NO-RUN-CONTEXT"
      echo "  This dump has no run state (it came from \`dump\` or \`watch\`, not \`probe\`), so"
      echo "  nothing here knows whether traffic was being offered while it sampled."
      echo "  Counter LEVELS and DELTAS are reported below as data. NO conclusion about the MAC,"
      echo "  the link or the stack may be drawn from them without knowing what was running."
      echo; } >> "$out"
  elif [ "$delivered" != "yes" ]; then
    { echo "CLASS: RUN-ABORTED — NO TRAFFIC WAS OFFERED"
      echo "  The client exited $rc and never got as far as sending. First fatal line:"
      echo "      ${fatal:-<none captured>}"
      echo "  ⇒ THIS DUMP SAYS NOTHING ABOUT THE MAC, THE LINK OR THE STACK. Fix the run first;"
      echo "  the counters below are pre-existing levels, not a measurement."
      echo; } >> "$out"
  fi

  local f id devlist="" 
  declare -A DTX DRX TXL RXL RCL ATX ARX RETR PSN STRM
  for f in "$dir"/20_dev*_cyt_attr_nstats.txt; do
    [ -f "$f" ] || continue
    id="$(basename "$f" | sed -E 's/20_dev([0-9]+)_.*/\1/')"
    devlist="$devlist $id"
    local a b
    a="$(first_val "$f" 'TX pkgs')";      b="$(last_val "$f" 'TX pkgs')"
    TXL[$id]="${b:-0}"; DTX[$id]="$(( ${b:-0} - ${a:-0} ))"
    a="$(first_val "$f" 'RX pkgs')";      b="$(last_val "$f" 'RX pkgs')"
    RXL[$id]="${b:-0}"; DRX[$id]="$(( ${b:-0} - ${a:-0} ))"
    b="$(last_val "$f" 'ROCE TX pkgs')";  RCL[$id]="${b:-0}"
    b="$(last_val "$f" 'ARP TX pkgs')";   ATX[$id]="${b:-0}"
    b="$(last_val "$f" 'ARP RX pkgs')";   ARX[$id]="${b:-0}"
    b="$(last_val "$f" 'Retrans cnt')";   RETR[$id]="${b:-0}"
    b="$(last_val "$f" 'PSN drop cnt')";  PSN[$id]="${b:-0}"
    b="$(last_val "$f" 'STRM down')";     STRM[$id]="${b:-0}"
  done
  local any=0; [ -n "$devlist" ] && any=1

  local d peer c
  for d in $devlist; do
    peer=""
    for id in $devlist; do [ "$id" != "$d" ] && peer="$id"; done
    local prxl=0 ptxl=0
    [ -n "$peer" ] && { prxl="${RXL[$peer]}"; ptxl="${TXL[$peer]}"; }
    {
      echo "===== device $d ====="
      printf 'TX pkgs      %d   (delta %+d)\n' "${TXL[$d]}" "${DTX[$d]}"
      printf 'RX pkgs      %d   (delta %+d)\n' "${RXL[$d]}" "${DRX[$d]}"
      printf 'ROCE TX      %d\n' "${RCL[$d]}"
      printf 'ARP  TX/RX   %d/%d\n' "${ATX[$d]}" "${ARX[$d]}"
      printf 'retrans %s   PSN drop %s   STRM down %s\n' "${RETR[$d]}" "${PSN[$d]}" "${STRM[$d]}"
      if [ -n "$peer" ]; then
        printf 'cross-check  dev %s TX %d vs dev %s RX %d' "$d" "${TXL[$d]}" "$peer" "$prxl"
        if [ "${TXL[$d]}" -eq "$prxl" ] && [ "${TXL[$d]}" -gt 0 ]; then
          printf '   EQUAL => every frame this board sent ARRIVED at the peer\n'
        elif [ "${TXL[$d]}" -gt 0 ] && [ "$prxl" -eq 0 ]; then
          printf '   PEER GOT NOTHING\n'
        else
          printf '   (differ)\n'
        fi
      fi
      echo
      if [ "$rxl_note_ok" = "1" ] && [ "${RXL[$d]}" -gt 0 ]; then
        echo "  ★ RX pkgs LEVEL is ${RXL[$d]} (> 0): frames arrived FROM THE MAC on this board."
        echo "    That requires the rclk domain out of reset and the DCMAC RX path delivering."
        [ "${ARX[$d]}" -gt 0 ] && echo "    ARP RX = ${ARX[$d]} => at least some were ARP, i.e. a real peer answered on the wire."
      fi
      if [ -z "$delivered" ] || [ "$delivered" != "yes" ]; then
        echo "  (no traffic-based class emitted — see the gate at the top of this file)"
      else
        c="$(traffic_class "${DTX[$d]}" "${DRX[$d]}" "${TXL[$d]}" "${RXL[$d]}" "${RCL[$d]}" \
                           "${RETR[$d]}" "${PSN[$d]}" "$prxl" "$ptxl" "${rc:-0}")"
        echo "CLASS: $c"
        case "$c" in
          ROCE-PROTOCOL-FAILURE)
            echo "  retrans=${RETR[$d]} PSN drop=${PSN[$d]} on a link that is carrying frames."
            echo "  => THE MAC AND THE WIRE ARE EXONERATED. Frames cross; the RoCE engine rejects"
            echo "  them. PSN drop on one end with retrans on the other is a sequence-number"
            echo "  mismatch: rocev2's PSN/QP state, not the DCMAC. Look at the QP context written"
            echo "  by writeQpContext(), the initial PSN exchange, and rocev2's retransmit path."
            ;;
          FRAMES-CROSSED-BOTH-WAYS)
            echo "  Both boards sent AND received, and the cross-check above accounts for the frames."
            echo "  => the MAC and the link work at frame level. A stall is above the MAC."
            ;;
          STACK-SILENT)
            echo "  The stack emitted NOTHING although the run delivered => the MAC is EXONERATED"
            echo "  for this run. Look at the RoCE stack, the QP and the host software."
            ;;
          TX-MOVING-RX-DEAD)
            echo "  Our TX grows, the peer received NOTHING and nothing comes back."
            echo "  Suspect the wire, the peer's bring-up, or the peer's RX."
            ;;
          TX-PLATEAU)
            echo "  Our TX is flat across the window, the run stalled, AND the peer received"
            echo "  nothing at all => the MAC is not draining the TX path. Bring-up suspect (B-3)."
            echo "  ⚠ NOT PROVEN HERE: no DCMAC register is host-readable in this image."
            ;;
          BIDIRECTIONAL)
            echo "  Frames moved both ways during the window => frame level is fine; the stall is"
            echo "  a RoCE-level problem. Check retrans / PSN drop."
            ;;
          INCONCLUSIVE)
            echo "  The run delivered but the picture is not conclusive. Sample earlier/longer, or"
            echo "  the run never got past its bootstrap."
            ;;
        esac
      fi
      [ "${STRM[$d]}" != "0" ] && echo "  NOTE: STRM down=1 — RX back-pressure stall on s_axis_net (network_stack.sv:1103-1110), NOT a link indicator."
      echo
    } >> "$out"
  done

  if [ "$any" -eq 0 ]; then
    echo "CLASS: NO-DATA — no nstats samples in $dir (driver not loaded, or no sysfs node)" >> "$out"
  fi
  {
    echo "----- scope of this verdict -----"
    echo "This classifies the HOST + STACK half only. link_up / link_fault / access_fault /"
    echo "retry_cnt / RX_PHY_STATUS / FEC codeword counters are NOT host-readable in any image"
    echo "built to date (dcmac_axis_wrapper.sv:~248 ties the requests off), so no branch above"
    echo "may be quoted as a statement about the DCMAC. Closing that needs C16/C17's host"
    echo "window — doc/design/COYOTE_TU03_DESIGN_SPEC.md."
  } >> "$out"

  cat "$out"
  say "verdict -> $out"
}

cmd_dump() {
  local tag="${1:-dump}"
  local dir="$EVID/diag_${tag}_$(date +%Y%m%d_%H%M%S)"
  collect "$dir" "$tag" "$SAMPLES" "$INTERVAL"
  cmd_verdict "$dir"
  echo "NIA_DIAG[$tag]=$dir"
}

cmd_watch() {
  local secs="${1:?usage: watch <seconds> [tag]}" tag="${2:-watch}"
  local n=$(( secs / INTERVAL )); [ "$n" -lt 2 ] && n=2
  local dir="$EVID/diag_${tag}_$(date +%Y%m%d_%H%M%S)"
  say "sampling $n times at ${INTERVAL}s (~${secs}s) — start/keep your run in another shell"
  collect "$dir" "$tag" "$n" "$INTERVAL"
  cmd_verdict "$dir"
  echo "NIA_DIAG[$tag]=$dir"
}

cmd_arp() {
  local sdev=0 pdev=1 count=7 iv=100
  while [ $# -gt 0 ]; do
    case "$1" in
      --src-dev)  sdev="$2"; shift 2 ;;
      --peer-dev) pdev="$2"; shift 2 ;;
      -n|--count) count="$2"; shift 2 ;;
      --interval-ms) iv="$2"; shift 2 ;;
      *) die "unknown arp option '$1'" ;;
    esac
  done
  driver_loaded || die "coyote_driver is not loaded — do your driver-load step first"
  [ "$sdev" != "$pdev" ] || die "src and peer devices must differ"
  [ -x "$ARP_BIN" ] || die "arpprobe not built: $ARP_BIN
       Build it:  ./diag.sh build-arp    (from the images-pack root)
       (or set NIA_ARP_BIN)"

  local ip_s_raw ip_p_raw ip_s ip_p
  ip_s_raw="$(sysfs_ip "$sdev")"; ip_p_raw="$(sysfs_ip "$pdev")"
  ip_s="$(printf '%s' "$ip_s_raw" | sed -nE 's/.*IP address: *([0-9a-fA-F]+).*/\1/p')"
  ip_p="$(printf '%s' "$ip_p_raw" | sed -nE 's/.*IP address: *([0-9a-fA-F]+).*/\1/p')"
  [ -n "$ip_s" ] && [ -n "$ip_p" ] \
    || die "cannot parse the FPGA IPs from /sys/kernel/coyote_sysfs_{$sdev,$pdev}/cyt_attr_ip"
  [ "$ip_s" != "$ip_p" ] || die "dev $sdev and dev $pdev report the SAME FPGA IP ($ip_s).
       dev $sdev would be asked to ARP for its OWN address, which is not this test.
       Do your per-device IP step first, e.g.:
           ./rdma_test.sh setup
       or directly:
           sudo sh -c 'echo 0B01D4D2 > /sys/kernel/coyote_sysfs_$pdev/cyt_attr_ip'
           sudo sh -c 'echo 000A35029DE6 > /sys/kernel/coyote_sysfs_$pdev/cyt_attr_mac'
       then re-check with:  cat /sys/kernel/coyote_sysfs_*/cyt_attr_ip"

  local peer_ip="$ip_p"

  local tag="arp_d${sdev}to${pdev}_n${count}"
  local dir="$EVID/diag_${tag}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$dir"
  { echo "# ARP asymmetry test   ($DIAG_VERSION)"
    echo "source dev  : $sdev  ($(sysfs_ip "$sdev"))   <- issues $count lookups"
    echo "peer   dev  : $pdev  ($(sysfs_ip "$pdev"))   <- issues NONE"
    echo "target ip   : $peer_ip"
    echo "binary      : $ARP_BIN  (md5 $(md5sum "$ARP_BIN" | cut -d' ' -f1))"
  } > "$dir/49_preconditions.txt"
  cat "$dir/49_preconditions.txt"

  say "BEFORE snapshot"
  collect "$dir/pre" "${tag}_pre" 1 0
  say "issuing $count ARP lookups from device $sdev toward $peer_ip"
  ( cd "$(dirname "$ARP_BIN")" && LD_LIBRARY_PATH="$PWD:${LD_LIBRARY_PATH:-}" \
      timeout 60 ./"$(basename "$ARP_BIN")" --device "$sdev" --target-ip "$peer_ip" \
        --count "$count" --interval-ms "$iv" ) > "$dir/53_arpprobe.log" 2>&1
  local arc=$?
  tail -5 "$dir/53_arpprobe.log"
  say "AFTER snapshot"
  collect "$dir" "$tag" 1 0

  local out="$dir/91_ARP_VERDICT.txt"; : > "$out"
  local d pre post lbl
  {
    echo "# ARP ASYMMETRY VERDICT       (arpprobe exit $arc, $count lookups from dev $sdev only)"
    echo "source dev $sdev ip $ip_s   ->   target ip $peer_ip (= dev $pdev)"
    echo
    for d in "$sdev" "$pdev"; do
      pre="$dir/pre/20_dev${d}_cyt_attr_nstats.txt"; post="$dir/20_dev${d}_cyt_attr_nstats.txt"
      if [ ! -f "$pre" ] || [ ! -f "$post" ]; then echo "dev $d: samples missing"; continue; fi
      for lbl in 'ARP TX pkgs' 'ARP RX pkgs' 'TX pkgs' 'RX pkgs'; do
        local a b
        a="$(last_val "$pre" "$lbl")";  : "${a:=0}"
        b="$(last_val "$post" "$lbl")"; : "${b:=0}"
        printf 'dev %s   %-12s %10d -> %-10d (delta %+d)\n' "$d" "$lbl" "$a" "$b" "$((b-a))"
      done
      echo
    done
  } >> "$out"

  local satx sarx patx parx
  satx=$(( $(last_val "$dir/20_dev${sdev}_cyt_attr_nstats.txt" 'ARP TX pkgs') - $(last_val "$dir/pre/20_dev${sdev}_cyt_attr_nstats.txt" 'ARP TX pkgs') ))
  sarx=$(( $(last_val "$dir/20_dev${sdev}_cyt_attr_nstats.txt" 'ARP RX pkgs') - $(last_val "$dir/pre/20_dev${sdev}_cyt_attr_nstats.txt" 'ARP RX pkgs') ))
  patx=$(( $(last_val "$dir/20_dev${pdev}_cyt_attr_nstats.txt" 'ARP TX pkgs') - $(last_val "$dir/pre/20_dev${pdev}_cyt_attr_nstats.txt" 'ARP TX pkgs') ))
  parx=$(( $(last_val "$dir/20_dev${pdev}_cyt_attr_nstats.txt" 'ARP RX pkgs') - $(last_val "$dir/pre/20_dev${pdev}_cyt_attr_nstats.txt" 'ARP RX pkgs') ))
  { NIA_ARP_COUNT_HINT="$count" arp_narrate "$arc" "$satx" "$sarx" "$patx" "$parx" "$sdev" "$pdev"; } >> "$out"
  cat "$out"
  ( cd "$dir" && md5sum ./* > MANIFEST.md5 2>/dev/null )
  say "arp verdict -> $out"
  echo "NIA_DIAG[$tag]=$dir  ARP_RC=$arc"
}

arp_class() {
  if   [ "$1" -ne 0 ];  then echo ARP-PROBE-FAILED
  elif [ "$2" -le 0 ];  then echo ARP-NOT-EMITTED
  elif [ "$5" -gt 0 ] && [ "$3" -gt 0 ]; then echo WIRE-CONFIRMED-BOTH-WAYS
  elif [ "$5" -gt 0 ];  then echo ARP-ONE-WAY
  else                       echo ARP-EMITTED-NOT-RECEIVED
  fi
}
arp_narrate() {
  local NIA_ARP_COUNT_HINT="${NIA_ARP_COUNT_HINT:-0}"
  local arc="$1" satx="$2" sarx="$3" patx="$4" parx="$5" sdev="$6" pdev="$7"
  local c; c="$(arp_class "$arc" "$satx" "$sarx" "$patx" "$parx")"
  echo "CLASS: $c"
  case "$c" in
    ARP-PROBE-FAILED)
      echo "  arpprobe exited $arc; see 53_arpprobe.log. NO CONCLUSION about anything." ;;
    ARP-NOT-EMITTED)
      echo "  dev $sdev's ARP TX did not move, so the request never left the stack. The MAC is"
      echo "  NOT implicated: look at cnfg_slave's NET_ARP_REG path and the HLS arp_server." ;;
    WIRE-CONFIRMED-BOTH-WAYS)
      echo "  (the strongest result available without new RTL)"
      echo "  dev $sdev sent $satx ARP frames, dev $pdev RECEIVED $parx of them, replied $patx, and"
      echo "  dev $sdev received $sarx back. Only one side was asked to send, so the asymmetry rules"
      echo "  out a local artefact => THE DCMAC LINK CARRIES FRAMES IN BOTH DIRECTIONS on both"
      echo "  boards, which means dcmac_ctl_seq's bring-up WORKED and B-3 is NOT the fault."
      echo "  => Re-aim at the RoCE layer: read the probe verdict and retrans / PSN drop." ;;
    ARP-ONE-WAY)
      echo "  dev $pdev received $parx frames but dev $sdev got nothing back (replies sent: $patx)."
      echo "  So $sdev's TX and $pdev's RX work. Suspect $pdev's TX or $sdev's RX — one direction of"
      echo "  one board, which is what a half-brought-up MAC looks like."
      echo "  Re-run with --src-dev $pdev --peer-dev $sdev to see which half." ;;
    ARP-EMITTED-NOT-RECEIVED)
      echo "  dev $sdev emitted $satx ARP frames and dev $pdev saw NONE. Frames are leaving the"
      echo "  stack and not arriving. Suspect the DAC/cage, $sdev's MAC TX, or $pdev's MAC RX."
      echo "  This is CONSISTENT WITH B-3 but does NOT prove it: no DCMAC register is readable." ;;
  esac
  echo
  if [ "$satx" -gt 0 ] && [ "$satx" -lt "$NIA_ARP_COUNT_HINT" ]; then
    echo "NOTE: $NIA_ARP_COUNT_HINT lookups produced only $satx ARP frame(s). That is EXPECTED, not a"
    echo "  fault: the HLS arp_server_subnet caches resolved entries, so repeat lookups for an"
    echo "  address it already knows emit nothing. One frame is enough for this test."
    echo
  fi
  echo "----- scope -----"
  echo "ARP counters are the stack's view at s_axis_net / m_axis_net. They prove frames crossed"
  echo "or did not; they say NOTHING about PCS/FEC state, retry_cnt or link_up, which need"
  echo "C16/C17's host window (doc/design/COYOTE_TU03_DESIGN_SPEC.md 6.2)."
}

find_coyote_sw() {
  local c d
  for c in "${NIA_COYOTE_SW:-}" \
           "$ARP_SRC/../src/sw" "$HERE/src/sw" "$HERE/../src/sw" \
           "$ARP_SRC/../../src/sw" "$ARP_SRC/../../../sw"; do
    [ -n "$c" ] && [ -f "$c/CMakeLists.txt" ] && { (cd "$c" && pwd); return 0; }
  done
  for d in "$ARP_SRC" "$HERE"; do
    local p; p="$(cd "$d" 2>/dev/null && pwd)" || continue
    while [ "$p" != "/" ] && [ -n "$p" ]; do
      [ -f "$p/src/sw/CMakeLists.txt" ] && { echo "$p/src/sw"; return 0; }
      [ -f "$p/sw/CMakeLists.txt" ] && grep -qs 'Coyote' "$p/sw/CMakeLists.txt" && { echo "$p/sw"; return 0; }
      p="$(dirname "$p")"
    done
  done
  return 1
}

cmd_build_arp() {
  [ -f "$ARP_SRC/CMakeLists.txt" ] || die "arpprobe source not found at $ARP_SRC (set NIA_ARP_SRC)"
  command -v cmake >/dev/null || die "cmake not on PATH"
  local sw; sw="$(find_coyote_sw)" || die "cannot locate Coyote's sw/ (libcoyote) from here.
       Searched next to $ARP_SRC and upward from $HERE.
       Either run this from the IMAGES PACK root (where src/sw lives):
           cd <images-pack> && ./diag.sh build-arp
       or point at it:
           NIA_COYOTE_SW=<path-to>/src/sw ./diag.sh build-arp"
  say "building arpprobe from $ARP_SRC  (libcoyote: $sw)"
  cmake -S "$ARP_SRC" -B "$ARP_SRC/build" -DCOYOTE_SW_DIR="$sw" >/dev/null \
    || die "cmake configure failed"
  make -C "$ARP_SRC/build" -j"$(nproc)" || die "build failed"
  [ -x "$ARP_BIN" ] || die "built, but $ARP_BIN is missing"
  say "arpprobe -> $ARP_BIN"
}

DIAG_VERSION="v4 2026-07-31 (DEFECT-DIAG-1..7 fixed; selftest 33)"
RDMA_PORT="${NIA_RDMA_PORT:-18488}"

port_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -Htan "sport = :$RDMA_PORT" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tan 2>/dev/null | grep -q ":$RDMA_PORT "
  else
    local hx; hx="$(printf '%04X' "$RDMA_PORT")"
    grep -qi ":$hx " /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}

wait_port_free() {
  local n="${1:-90}" i=0
  while port_free_check=$(port_busy && echo busy || echo free); [ "$port_free_check" = busy ]; do
    i=$((i+1)); [ "$i" -ge "$n" ] && return 1
    sleep 1
  done
  return 0
}

kill_server() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge 10 ] && { kill -KILL "$pid" 2>/dev/null || true; break; }
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
}

cell_is_infra_fail() {
  grep -qE 'Could not bind a socket|Could not connect to master' \
    "$1/server.log" "$1/client.log" 2>/dev/null
}

cmd_sweep() {
  local sizes="64 4096 65536 1048576" ops="1 0" tmo=45 sdev=0 cdev=1 peer=127.0.0.1
  while [ $# -gt 0 ]; do
    case "$1" in
      --sizes) sizes="$2"; shift 2 ;;
      --ops)   ops="$2";   shift 2 ;;
      -t)      tmo="$2";   shift 2 ;;
      -i)      peer="$2";  shift 2 ;;
      --server-dev) sdev="$2"; shift 2 ;;
      --client-dev) cdev="$2"; shift 2 ;;
      *) die "unknown sweep option '$1'" ;;
    esac
  done
  driver_loaded || die "coyote_driver is not loaded"
  [ -x "$SERVER_BIN" ] && [ -x "$CLIENT_BIN" ] || die "example binaries missing (run your build step)"
  local i0 i1
  i0="$(sysfs_ip "$sdev" | sed -nE 's/.*IP address: *([0-9a-fA-F]+).*/\1/p')"
  i1="$(sysfs_ip "$cdev" | sed -nE 's/.*IP address: *([0-9a-fA-F]+).*/\1/p')"
  [ -n "$i0" ] && [ -n "$i1" ] && [ "$i0" != "$i1" ] \
    || die "dev $sdev and dev $cdev need DISTINCT FPGA IPs (got '$i0' / '$i1') — run your IP setup step"
  local hp; hp="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
  [ "$hp" -gt 0 ] || die "nr_hugepages is 0 — every cell would abort. sudo sh -c 'echo 2048 > /proc/sys/vm/nr_hugepages'"

  local dir="$EVID/diag_sweep_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$dir"
  local tbl="$dir/92_SWEEP.txt"
  { echo "# ROCE SWEEP — where does it break?"
    echo "diag   : $DIAG_VERSION"
    echo "when   : $(date -Is)"
    echo "server : dev $sdev ip $i0     client: dev $cdev ip $i1 -> $peer"
    echo "sizes  : $sizes"
    echo "ops    : $ops   (1=WRITE 0=READ)"
    echo "timeout: ${tmo}s per cell"
    echo
    printf '%-6s %-10s %-7s %-6s | %-22s | %-22s\n' OP SIZE RESULT RC \
      "server d(TX/RX/ROCE/psn)" "client d(TX/RX/ROCE/retr)"
    printf '%s\n' "----------------------------------------------------------------------------------------"
  } | tee "$tbl"

  local op sz cell rc pass=0 stall=0 abort=0 skip=0 first_pass="" last_pass="" first_fail=""
  for op in $ops; do
    for sz in $sizes; do
      cell="$dir/op${op}_sz${sz}"; mkdir -p "$cell"
      local d
      for d in "$sdev" "$cdev"; do
        { echo "--- sample 1  t=$(date +%s.%N) ---"; rd "/sys/kernel/coyote_sysfs_$d/cyt_attr_nstats" | deansi; } \
          > "$cell/pre_dev${d}.txt"
      done
      if ! wait_port_free 90; then
        echo "port $RDMA_PORT still busy after 90 s" > "$cell/server.log"
        cp "$cell/server.log" "$cell/client.log"
        rc=99
      else
        LD_LIBRARY_PATH="$(dirname "$SERVER_BIN"):${LD_LIBRARY_PATH:-}" \
          timeout "$tmo" "$SERVER_BIN" --device "$sdev" --operation "$op" \
            --runs 1 --min_size "$sz" --max_size "$sz" > "$cell/server.log" 2>&1 &
        local spid=$!
        sleep 3
        LD_LIBRARY_PATH="$(dirname "$CLIENT_BIN"):${LD_LIBRARY_PATH:-}" \
          timeout "$tmo" "$CLIENT_BIN" --device "$cdev" --ip_address "$peer" \
            --operation "$op" --runs 1 --min_size "$sz" --max_size "$sz" > "$cell/client.log" 2>&1
        rc=$?
        kill_server "$spid"
      fi
      sleep 1
      for d in "$sdev" "$cdev"; do
        { echo "--- sample 1  t=$(date +%s.%N) ---"; rd "/sys/kernel/coyote_sysfs_$d/cyt_attr_nstats" | deansi; } \
          > "$cell/post_dev${d}.txt"
      done
      dl() { echo $(( $(last_val "$cell/post_dev$1.txt" "$2") - $(last_val "$cell/pre_dev$1.txt" "$2") )); }
      local stx srx sro spsn ctx crx cro cretr res
      stx=$(dl "$sdev" 'TX pkgs');  srx=$(dl "$sdev" 'RX pkgs')
      sro=$(dl "$sdev" 'ROCE TX pkgs'); spsn=$(dl "$sdev" 'PSN drop cnt')
      ctx=$(dl "$cdev" 'TX pkgs');  crx=$(dl "$cdev" 'RX pkgs')
      cro=$(dl "$cdev" 'ROCE TX pkgs'); cretr=$(dl "$cdev" 'Retrans cnt')
      if cell_is_infra_fail "$cell" || [ "$rc" = "99" ]; then
        res=SKIP; skip=$((skip+1))
      else
        case "$rc" in
          0)   res=PASS;  pass=$((pass+1)); [ -z "$first_pass" ] && first_pass="op$op/$sz"; last_pass="op$op/$sz" ;;
          124) res=STALL; stall=$((stall+1)); [ -z "$first_fail" ] && first_fail="op$op/$sz" ;;
          *)   res=ABORT; abort=$((abort+1)) ;;
        esac
      fi
      printf '%-6s %-10s %-7s %-6s | %-22s | %-22s\n' \
        "$([ "$op" = 1 ] && echo WRITE || echo READ)" "$sz" "$res" "$rc" \
        "$stx/$srx/$sro/psn$spsn" "$ctx/$crx/$cro/retr$cretr" | tee -a "$tbl"
    done
  done

  { echo
    echo "totals: PASS=$pass STALL=$stall ABORT=$abort SKIP=$skip"
    echo
    if [ "$skip" -gt 0 ]; then
      echo "⚠ $skip cell(s) were SKIPPED — they failed to bind or reach 127.0.0.1:$RDMA_PORT and"
      echo "  never reached RoCE at all. They are EXCLUDED from the conclusion below. If most of"
      echo "  the matrix is SKIP, the conclusion is not usable: raise -t, or check that no stray"
      echo "  server is running (pgrep -af 09_perf_rdma)."
      echo
    fi
    if [ "$((pass+stall+abort))" -eq 0 ]; then
      echo "CLASS: SWEEP-NO-VALID-CELLS — nothing ran. This says NOTHING about RoCE."
    elif [ "$abort" -gt 0 ] && [ "$pass" -eq 0 ] && [ "$stall" -eq 0 ]; then
      echo "CLASS: SWEEP-ALL-ABORTED — no cell ran. Fix the run (hugepages / IPs / binaries)."
    elif [ "$pass" -eq 0 ]; then
      echo "CLASS: ROCE-BROKEN-AT-EVERY-SIZE"
      echo "  Not even a single-packet transfer completes => the mismatch is present from the"
      echo "  FIRST packet, so it is the initial PSN / QP context, not the increment across a"
      echo "  segmented transfer. Aim at what writeQpContext() programs (cThread.cpp:1109-1150:"
      echo "  RDMA_CTX_REG_0/1/2 pack local.psn and remote.psn; RDMA_CONN_REG_0 packs port and"
      echo "  both QPNs) and at rocev2's expected-PSN initialisation."
      echo "  NOTE: QPN 0 on both ends is NOT a bug — cThread.cpp:194 derives it as"
      echo "  ((vfid & N_REG_MASK) << PID_BITS) | (ctid & PID_MASK), so vFPGA 0 / ctid 0 gives 0."
    elif [ "$stall" -eq 0 ] && [ "$abort" -eq 0 ]; then
      echo "CLASS: SWEEP-ALL-PASS — every cell completed. Whatever failed before is not"
      echo "  size- or opcode-dependent; re-run the failing configuration and compare."
    else
      echo "CLASS: ROCE-BREAKS-AT-A-BOUNDARY"
      echo "  Some cells pass and some do not: last PASS = $first_pass..$last_pass, first"
      echo "  failure = $first_fail. If the boundary is a SIZE, single packets are fine and the"
      echo "  PSN increment across a segmented transfer is wrong (the stack MTU is the scale to"
      echo "  compare against). If the boundary is the OPERATION, it is opcode-specific:"
      echo "  rocev2's RDMA_WRITE and RDMA_READ paths differ in which end owns the PSN."
    fi
    echo
    echo "----- scope -----"
    echo "This localises the fault WITHIN rocev2 by behaviour only. No QP register is readable"
    echo "from user space (getCSR reads ctrl_reg, not cnfg_reg), and nothing DCMAC is visible."
  } | tee -a "$tbl"
  ( cd "$dir" && md5sum ./* > MANIFEST.md5 2>/dev/null )
  say "sweep -> $tbl"
  echo "NIA_DIAG[sweep]=$dir"
}

cmd_full() {
  say "checking preconditions for all stages"
  driver_loaded || die "coyote_driver is not loaded — do your driver-load step first"
  local devs; mapfile -t devs < <(ls /dev/coyote_fpga_*_v0 2>/dev/null | sed -E 's|.*coyote_fpga_([0-9]+)_v0|\1|' | sort -n)
  [ "${#devs[@]}" -ge 2 ] || die "need TWO coyote devices; found ${#devs[@]} (${devs[*]:-none})"
  local i0 i1
  i0="$(sysfs_ip "${devs[0]}" | sed -nE 's/.*IP address: *([0-9a-fA-F]+).*/\1/p')"
  i1="$(sysfs_ip "${devs[1]}" | sed -nE 's/.*IP address: *([0-9a-fA-F]+).*/\1/p')"
  [ -n "$i0" ] && [ -n "$i1" ] || die "cannot read the FPGA IPs from sysfs"
  [ "$i0" != "$i1" ] || die "dev ${devs[0]} and dev ${devs[1]} share the FPGA IP ($i0) — BOTH stages need
       distinct identities. Do your per-device IP step first:
           ./rdma_test.sh setup
       then:  cat /sys/kernel/coyote_sysfs_*/cyt_attr_ip"
  local hp; hp="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
  [ "$hp" -gt 0 ] || die "nr_hugepages is 0 — stage 3 would abort before sending. Reserve them:
           sudo sh -c 'echo 2048 > /proc/sys/vm/nr_hugepages'"
  [ -x "$ARP_BIN" ] || die "arpprobe not built — run:  ./diag.sh build-arp"
  say "preconditions OK: devs ${devs[*]}, ips $i0 / $i1, hugepages $hp"

  local rcs=""
  say "======== STAGE 1/4 — baseline dump ========"
  cmd_dump full_baseline || true; rcs="$rcs baseline=ok"
  say "======== STAGE 2/4 — ARP asymmetry (needs no hugepages) ========"
  ( cmd_arp "$@" ); rcs="$rcs arp=$?"
  say "======== STAGE 3/4 — RDMA probe at 1 MiB ========"
  ( cmd_probe );   rcs="$rcs probe=$?"
  say "======== STAGE 4/4 — final dump ========"
  cmd_dump full_final || true; rcs="$rcs final=ok"
  say "FULL DIAG COMPLETE:$rcs"
  say "read in order: stage 2's 91_ARP_VERDICT.txt, then stage 3's 90_VERDICT.txt"
  echo "NIA_DIAG_FULL=done"
}

cmd_probe() {
  local op=1 minsz=1048576 maxsz=1048576 runs=1 sdev=0 cdev=1 tmo=120 peer=127.0.0.1
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) op="$2"; shift 2 ;;
      -x) minsz="$2"; shift 2 ;;
      -X) maxsz="$2"; shift 2 ;;
      -r) runs="$2"; shift 2 ;;
      -t) tmo="$2"; shift 2 ;;
      -i) peer="$2"; shift 2 ;;
      --server-dev) sdev="$2"; shift 2 ;;
      --client-dev) cdev="$2"; shift 2 ;;
      *) die "unknown probe option '$1'" ;;
    esac
  done
  if [ "$minsz" -lt 262144 ]; then
    warn "min_size=$minsz B is at or below the >=32 KiB of FIFO downstream of tx_pkg_counter."
    warn "The result will NOT discriminate MAC-up from MAC-down. See this script's header."
  fi

  driver_loaded || die "coyote_driver is not loaded — do your driver-load step first"
  local devs; mapfile -t devs < <(ls /dev/coyote_fpga_*_v0 2>/dev/null | sed -E 's|.*coyote_fpga_([0-9]+)_v0|\1|' | sort -n)
  [ "${#devs[@]}" -ge 2 ] || die "need TWO coyote devices for a one-host run; found ${#devs[@]} (${devs[*]:-none})"
  [ "$sdev" != "$cdev" ] || die "server and client must use DIFFERENT devices (got $sdev twice)"
  [ -x "$SERVER_BIN" ] || die "server binary missing/not executable: $SERVER_BIN (set NIA_RDMA_SERVER)"
  [ -x "$CLIENT_BIN" ] || die "client binary missing/not executable: $CLIENT_BIN (set NIA_RDMA_CLIENT)"
  if [ "${NIA_SKIP_DEVICE_CHECK:-0}" = "1" ]; then
    warn "--device check SKIPPED by NIA_SKIP_DEVICE_CHECK=1 — if the binary is unpatched both ends collide on device 0"
  elif client_has_device_opt "$CLIENT_BIN"; then
    :
  else
    die "the client has no '--device' option string in it: looks like UNPATCHED 09_perf_rdma, and both ends
       would collide on device 0. Check with:  grep -ac 'device,d' '$CLIENT_BIN'
       If you are sure it is patched, re-run with NIA_SKIP_DEVICE_CHECK=1."
  fi
  local ip_s ip_c; ip_s="$(sysfs_ip "$sdev")"; ip_c="$(sysfs_ip "$cdev")"
  [ -n "$ip_s" ] && [ -n "$ip_c" ] || die "cannot read /sys/kernel/coyote_sysfs_{$sdev,$cdev}/cyt_attr_ip"
  [ "$ip_s" != "$ip_c" ] \
    || die "dev $sdev and dev $cdev report the SAME FPGA IP ($ip_s) — do your per-device IP setup step first"

  local hp hpfree need
  hp="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
  hpfree="$(awk '/^HugePages_Free:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  need=$(( 2 * ( (maxsz + 2097151) / 2097152 + 2 ) ))
  [ "$hp" -gt 0 ] || die "nr_hugepages is 0 — the run WILL abort with errno=12 before sending anything.
       Reserve them first (your step):   sudo sh -c 'echo 2048 > /proc/sys/vm/nr_hugepages'
       Then re-run. Needed for this size: >= $need x 2 MiB pages."
  [ "$hpfree" -ge "$need" ] || die "only $hpfree free hugepages of $hp reserved; this size needs >= $need.
       Raise nr_hugepages or lower -X."

  local tag="probe$( [ "$op" = 1 ] && echo W || echo R )_${minsz}"
  local dir="$EVID/diag_${tag}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$dir"
  { echo "# probe preconditions (CHECKED, never changed by this script)"
    echo "server dev $sdev  ip: $ip_s"
    echo "client dev $cdev  ip: $ip_c   peer: $peer"
    echo "operation  : $([ "$op" = 1 ] && echo WRITE || echo READ)"
    echo "size sweep : $minsz .. $maxsz   runs: $runs   timeout: ${tmo}s"
    echo "server bin : $SERVER_BIN  (md5 $(md5sum "$SERVER_BIN" | cut -d' ' -f1))"
    echo "client bin : $CLIENT_BIN  (md5 $(md5sum "$CLIENT_BIN" | cut -d' ' -f1))"
  } > "$dir/49_preconditions.txt"
  cat "$dir/49_preconditions.txt"

  say "pre-run snapshot"
  collect "$dir/pre" "${tag}_pre" 2 "$INTERVAL"

  say "starting SERVER on device $sdev"
  ( cd "$(dirname "$SERVER_BIN")" && LD_LIBRARY_PATH="$PWD:${LD_LIBRARY_PATH:-}" \
      setsid timeout "$tmo" ./"$(basename "$SERVER_BIN")" --device "$sdev" --operation "$op" \
        --runs "$runs" --min_size "$minsz" --max_size "$maxsz" > "$dir/50_server.log" 2>&1 & )
  sleep 4
  say "starting CLIENT on device $cdev -> $peer"
  ( cd "$(dirname "$CLIENT_BIN")" && LD_LIBRARY_PATH="$PWD:${LD_LIBRARY_PATH:-}" \
      timeout "$tmo" ./"$(basename "$CLIENT_BIN")" --device "$cdev" --ip_address "$peer" \
        --operation "$op" --runs "$runs" --min_size "$minsz" --max_size "$maxsz" \
        > "$dir/51_client.log" 2>&1 ) &
  local runpid=$!

  sleep 2
  say "sampling DURING the run — this is the measurement"
  local n=$(( (tmo - 8) / INTERVAL )); [ "$n" -lt 4 ] && n=4
  collect "$dir" "$tag" "$n" "$INTERVAL" &
  local colpid=$!
  wait "$runpid"; local rrc=$?
  wait "$colpid" 2>/dev/null || true

  { echo
    echo "client exit code: $rrc   (124 = timeout => STALLED, which is the interesting case)"
    echo "server log      : $dir/50_server.log"
    echo "client log      : $dir/51_client.log"
  } >> "$dir/00_summary.txt"

  local fatal="" delivered="yes"
  fatal="$(grep -m1 -E 'Hugepage allocation failed|Could not allocate|terminate called|std::runtime_error|Segmentation fault|dumped core|what\(\):' \
            "$dir/51_client.log" "$dir/50_server.log" 2>/dev/null | head -1)"
  case "$rrc" in 0|124) ;; *) delivered="no" ;; esac
  [ -n "$fatal" ] && delivered="no"
  grep -q 'Queue pair' "$dir/51_client.log" 2>/dev/null || delivered="no"
  { echo "CLIENT_RC=$rrc"
    echo "RUN_DELIVERED=$delivered"
    echo "RUN_FATAL=${fatal//$'\n'/ }"
    echo "OFFERED_BYTES_APPROX=$(( (1 + 32) * maxsz ))"
  } > "$dir/52_runstate.txt"
  [ "$delivered" = "no" ] && warn "the run DID NOT deliver traffic — the dump cannot say anything about the MAC"

  echo "--- client tail ---"; tail -15 "$dir/51_client.log" 2>/dev/null
  ( cd "$dir" && md5sum ./* > MANIFEST.md5 2>/dev/null )
  cmd_verdict "$dir"
  echo "NIA_DIAG[$tag]=$dir  CLIENT_RC=$rrc"
}

cmd_selftest() {
  local t; t="$(mktemp -d)" rc=0
  mkdir -p "$t/coyote_sysfs_0"
  local NS="$t/coyote_sysfs_0/cyt_attr_nstats"
  mk_nstats() {
    printf '\n -- \033[31mNET STATS\033[0m QSFP0\n\nRX pkgs: %d\nTX pkgs: %d\nARP RX pkgs: %d\nARP TX pkgs: 0\nROCE TX pkgs: %d\nPSN drop cnt: 0\nRetrans cnt: 0\nSTRM down: 0\n\n' "$1" "$2" "$4" "$3" > "$NS"
  }
  mkdir_ctx() {
    mkdir -p "$1"
    printf -- '--- sample 1  t=1 ---\nRX pkgs: %d\nTX pkgs: %d\nARP RX pkgs: 0\nROCE TX pkgs: %d\nSTRM down: 0\n--- sample 2  t=2 ---\nRX pkgs: %d\nTX pkgs: %d\nARP RX pkgs: 0\nROCE TX pkgs: %d\nSTRM down: 0\n' \
      "$5" "$6" "$7" "$8" "$9" "${10}" > "$1/20_dev0_cyt_attr_nstats.txt"
    printf 'CLIENT_RC=%s\nRUN_DELIVERED=%s\nRUN_FATAL=%s\n' "$2" "$3" "$4" > "$1/52_runstate.txt"
  }
  has() { grep -q "$2" "$1/90_VERDICT.txt"; }

  printf '\n -- CONFIG\n\nenabled RDMA: 1\n\n' > "$t/coyote_sysfs_0/cyt_attr_cnfg"
  printf '\n -- QDMA DEBUG REGISTERS\n\nQDMA_GLBL_ERR_STAT (0x248): 0x0\n\n' > "$t/coyote_sysfs_0/cyt_attr_qdma_debug_regs"

  mk_nstats 0 12 12 0
  ( sleep 1; mk_nstats 0 4096 4096 0 ) &
  NIA_SYSFS_GLOB="$t/coyote_sysfs_*" NIA_EVID="$t/e1" NIA_DUMP_SAMPLES=2 NIA_DUMP_INTERVAL=2 \
    "$0" dump st_collect >"$t/o1" 2>&1
  local d1; d1="$(ls -d "$t"/e1/diag_st_collect_* 2>/dev/null | head -1)"
  if [ -z "$d1" ]; then warn "selftest (a) FAILED — no dump directory"; rc=1; else
    grep -q '^=== dev 0 / cyt_attr_nstats ===' "$d1/10_sysfs_dev0.txt" \
      || { warn "selftest (a1) FAILED — attributes not captured"; rc=1; }
    grep -q 'TX pkgs .* delta +4084   <-- MOVING' "$d1/20_dev0_cyt_attr_nstats.txt" \
      || { warn "selftest (a2) FAILED — delta/MOVING not computed"; rc=1; }
    grep -qP '\x1b\[' "$d1/10_sysfs_dev0.txt" \
      && { warn "selftest (a3) FAILED — ANSI escapes leaked into evidence"; rc=1; }
    has "$d1" 'CLASS: NO-RUN-CONTEXT' \
      || { warn "selftest (a4) FAILED — runless dump lacks the NO-RUN-CONTEXT gate"; rc=1; }
    has "$d1" 'CLASS: TX-PLATEAU' \
      && { warn "selftest (a5) FAILED — TX-PLATEAU invented from a runless dump (DEFECT-DIAG-2)"; rc=1; }
  fi

  mkdir_ctx "$t/b" 124 yes "" 0 0 0 0 0 0
  "$0" verdict "$t/b" >/dev/null 2>&1
  has "$t/b" 'CLASS: STACK-SILENT' || { warn "selftest (b) FAILED — STACK-SILENT not reached"; rc=1; }

  mkdir_ctx "$t/c" 124 yes "" 0 100 100 0 9000 9000
  "$0" verdict "$t/c" >/dev/null 2>&1
  has "$t/c" 'CLASS: TX-MOVING-RX-DEAD' || { warn "selftest (c) FAILED — TX-MOVING-RX-DEAD not reached"; rc=1; }

  mkdir_ctx "$t/d" 124 yes "" 0 100 100 50 9000 9000
  "$0" verdict "$t/d" >/dev/null 2>&1
  has "$t/d" 'CLASS: BIDIRECTIONAL' || { warn "selftest (d) FAILED — BIDIRECTIONAL not reached"; rc=1; }

  printf 'junk\x00("device,d")\x00more\n'       > "$t/fake_patched"
  printf 'junk\x00("operation,o")\x00more\n'    > "$t/fake_unpatched"
  printf 'junk\x00Which FPGA to use (/dev/x)\n' > "$t/fake_patched2"
  client_has_device_opt "$t/fake_patched"   || { warn "selftest (e1) FAILED — patched binary rejected"; rc=1; }
  client_has_device_opt "$t/fake_patched2"  || { warn "selftest (e2) FAILED — help-text variant rejected"; rc=1; }
  client_has_device_opt "$t/fake_unpatched" && { warn "selftest (e3) FAILED — unpatched binary accepted"; rc=1; }

  mkdir_ctx "$t/g" 134 no "what():  Could not allocate memory; exiting..." 2 2 0 2 2 0
  "$0" verdict "$t/g" >/dev/null 2>&1
  has "$t/g" 'CLASS: RUN-ABORTED'   || { warn "selftest (g1) FAILED — aborted run not classified RUN-ABORTED"; rc=1; }
  has "$t/g" 'CLASS: TX-PLATEAU'    && { warn "selftest (g2) FAILED — TX-PLATEAU invented from an aborted run (DEFECT-DIAG-2)"; rc=1; }
  has "$t/g" 'Could not allocate memory' || { warn "selftest (g3) FAILED — fatal line not surfaced"; rc=1; }
  has "$t/g" 'RX pkgs LEVEL is 2'   || { warn "selftest (g4) FAILED — the RX-level observation was dropped"; rc=1; }

  mkdir_ctx "$t/h" 124 yes "" 0 512 512 0 512 512
  "$0" verdict "$t/h" >/dev/null 2>&1
  has "$t/h" 'CLASS: TX-PLATEAU' || { warn "selftest (h) FAILED — TX-PLATEAU unreachable on a real stall"; rc=1; }

  local got exp
  while read -r exp args; do
    got="$(arp_class $args)"
    [ "$got" = "$exp" ] || { warn "selftest (i) FAILED — arp_class $args gave '$got', expected '$exp'"; rc=1; }
  done <<'ARPCASES'
ARP-PROBE-FAILED 1 7 7 7 7
ARP-NOT-EMITTED 0 0 0 0 0
WIRE-CONFIRMED-BOTH-WAYS 0 7 7 7 7
ARP-ONE-WAY 0 7 0 0 7
ARP-EMITTED-NOT-RECEIVED 0 7 0 0 0
ARPCASES

  local fk="$t/fakepack"
  mkdir -p "$fk/src/sw" "$fk/arpprobe" "$fk/overlay/arpprobe"
  echo 'project(Coyote)' > "$fk/src/sw/CMakeLists.txt"
  ( ARP_SRC="$fk/arpprobe";         HERE="$fk";         NIA_COYOTE_SW=""; find_coyote_sw >/dev/null ) \
    || { warn "selftest (j1) FAILED — libcoyote not found in the images-pack layout"; rc=1; }
  ( ARP_SRC="$fk/overlay/arpprobe"; HERE="$fk/overlay"; NIA_COYOTE_SW=""; find_coyote_sw >/dev/null ) \
    || { warn "selftest (j2) FAILED — libcoyote not found from an overlay inside the pack (DEFECT-DIAG-4)"; rc=1; }
  mkdir -p "$t/orphan/arpprobe"
  ( ARP_SRC="$t/orphan/arpprobe"; HERE="$t/orphan"; NIA_COYOTE_SW=""; find_coyote_sw >/dev/null 2>&1 ) \
    && { warn "selftest (j3) FAILED — claimed to find libcoyote where there is none"; rc=1; }

  local n1 n2
  n1="$(NIA_ARP_COUNT_HINT=7 arp_narrate 0 1 1 1 1 0 1)"
  n2="$(NIA_ARP_COUNT_HINT=7 arp_narrate 0 7 7 7 7 0 1)"
  case "$n1" in *"lookups produced only 1 ARP frame"*) ;; *)
    warn "selftest (k1) FAILED — the ARP-cache note did not fire for 7 lookups -> 1 frame"; rc=1 ;; esac
  case "$n2" in *"lookups produced only"*)
    warn "selftest (k2) FAILED — the ARP-cache note fired when every lookup emitted"; rc=1 ;; esac
  case "$n1" in *"CLASS: WIRE-CONFIRMED-BOTH-WAYS"*) ;; *)
    warn "selftest (k3) FAILED — class lost when the cache note fires"; rc=1 ;; esac

  local tc
  tc="$(traffic_class 0 0 21 36 19 0 12 21 36 124)"
  [ "$tc" = "ROCE-PROTOCOL-FAILURE" ] \
    || { warn "selftest (l1) FAILED — dev0's real numbers gave '$tc', not ROCE-PROTOCOL-FAILURE"; rc=1; }
  tc="$(traffic_class 0 0 36 21 34 16 0 36 21 124)"
  [ "$tc" = "ROCE-PROTOCOL-FAILURE" ] \
    || { warn "selftest (l2) FAILED — dev1's real numbers gave '$tc', not ROCE-PROTOCOL-FAILURE"; rc=1; }
  tc="$(traffic_class 0 0 21 36 19 0 0 21 36 124)"
  [ "$tc" = "FRAMES-CROSSED-BOTH-WAYS" ] \
    || { warn "selftest (l3) FAILED — a clean cross-check gave '$tc'"; rc=1; }
  tc="$(traffic_class 0 0 512 0 512 0 0 0 0 124)"
  [ "$tc" = "TX-PLATEAU" ] \
    || { warn "selftest (l4) FAILED — TX-PLATEAU unreachable when the peer got nothing ('$tc')"; rc=1; }
  tc="$(traffic_class 0 0 0 0 0 0 0 0 0 124)"
  [ "$tc" = "STACK-SILENT" ] || { warn "selftest (l5) FAILED — STACK-SILENT gave '$tc'"; rc=1; }

  local ic="$t/cell"; mkdir -p "$ic"
  printf 'ERROR: Could not bind a socket\n' > "$ic/server.log"; : > "$ic/client.log"
  cell_is_infra_fail "$ic" || { warn "selftest (m1) FAILED — a bind failure was not detected as infra"; rc=1; }
  printf 'what():  ERROR: Could not connect to master: 127.0.0.1:18488\n' > "$ic/client.log"; : > "$ic/server.log"
  cell_is_infra_fail "$ic" || { warn "selftest (m2) FAILED — a connect failure was not detected as infra"; rc=1; }
  printf 'Average throughput: 42 MB/s\n' > "$ic/client.log"; printf 'server ok\n' > "$ic/server.log"
  cell_is_infra_fail "$ic" && { warn "selftest (m3) FAILED — a healthy cell was called infra"; rc=1; }
  port_busy >/dev/null 2>&1; [ $? -le 1 ] || { warn "selftest (m4) FAILED — port_busy errored"; rc=1; }

  rm -rf "$t"
  if [ "$rc" -eq 0 ]; then say "SELFTEST PASS (33/33)  —  $DIAG_VERSION"; echo "NIA_DIAG_SELFTEST=PASS"
  else warn "SELFTEST FAIL"; echo "NIA_DIAG_SELFTEST=FAIL"; fi
  return $rc
}

usage() { sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  dump)          shift; cmd_dump "$@" ;;
  arp)           shift; cmd_arp "$@" ;;
  build-arp)     shift; cmd_build_arp "$@" ;;
  full)          shift; cmd_full "$@" ;;
  sweep)         shift; cmd_sweep "$@" ;;
  watch)         shift; cmd_watch "$@" ;;
  probe)         shift; cmd_probe "$@" ;;
  verdict)       shift; cmd_verdict "$@" ;;
  selftest)      shift; cmd_selftest "$@" ;;
  version|--version|-V) echo "diag.sh $DIAG_VERSION"; echo "md5 $(md5sum "$0" | cut -d\  -f1)" ;;
  ""|-h|--help)  usage ;;
  *) die "unknown verb '$1'" ;;
esac
