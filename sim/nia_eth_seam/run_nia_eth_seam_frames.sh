#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
export TERM=xterm

HERE=$(cd "$(dirname "$0")" && pwd)
COYOTE_DIR=${NIA_SEAM_COYOTE_DIR:-$(cd "$HERE/../.." && pwd)}
ETH_DIR=${NIA_SEAM_ETH_DIR:?set NIA_SEAM_ETH_DIR to the nia-eth-scenic tree}
IPDIR=${IPDIR:-$HERE/ip}
LOGDIR=${LOGDIR:-$HERE/logs}
WORKDIR=${WORKDIR:-$HERE/xsim_work}

mkdir -p "$LOGDIR" "$WORKDIR"
cd "$WORKDIR"

eth_sources() {
    awk -v sections="COMMON TOP_SEAM PHY_STUB FIFO_MODEL" -v root="$ETH_DIR/rtl" '
        BEGIN { split(sections, wanted, " "); for (i in wanted) keep[wanted[i]] = 1 }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^\[.*\]$/ { section = substr($0, 2, length($0) - 2); next }
        keep[section] { print root "/" $1 }
    ' "$ETH_DIR/rtl/dcmac_seam_files.f"
}

ip_sim_sources() {
    cat "$IPDIR"/*.simfiles 2>/dev/null | grep -E '\.s?v$' | awk '
        { name = $0; sub(/.*\//, "", name); if (!seen[name]++) print }
    '
}

ip_include_dirs() {
    for dir in "$IPDIR"/*/hdl; do
        [ -d "$dir" ] || continue
        printf ' -i %s' "$dir"
    done
}

if [ ! -d "$IPDIR" ] || [ -z "$(ls -A "$IPDIR" 2>/dev/null)" ]; then
    echo "SEAMSIM STAGE ip"
    vivado -mode batch -nojournal -notrace -log "$LOGDIR/gen_ip.log" \
        -source "$HERE/gen_nia_eth_seam_ip.tcl" -tclargs "$IPDIR" \
        > "$LOGDIR/gen_ip_stdout.log" 2>&1
    echo "SEAMSIM IP rc=$? files=$(ls -1 "$IPDIR"/*.simfiles 2>/dev/null | wc -l)"
fi

echo "SEAMSIM STAGE compile"
{
    xvlog -sv -work xpm \
        "$XILINX_VIVADO/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
        "$XILINX_VIVADO/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \
        "$XILINX_VIVADO/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv" || exit 20
    xvlog -work xil_defaultlib $(ip_include_dirs) $(ip_sim_sources) || exit 21
    xvlog -sv -work xil_defaultlib \
        -i "$COYOTE_DIR/hw/hdl/pkg" \
        "$HERE/lynx_pkg_seam_sim.sv" \
        "$COYOTE_DIR/hw/hdl/pkg/axi_intf.sv" \
        "$COYOTE_DIR/hw/hdl/common/regs/axis_reg.sv" \
        "$COYOTE_DIR/hw/hdl/common/regs/axis_reg_array.sv" \
        "$COYOTE_DIR/hw/hdl/network/stack/network_ccross_early.sv" \
        "$HERE/ethernet_frame_padding_512_ip_passthrough.sv" \
        $(eth_sources) \
        "$COYOTE_DIR/hw/hdl/network/nia_eth/network_module_nia_eth_200g.sv" \
        "$HERE/tb_nia_eth_seam_frames.sv" || exit 22
    xvlog -work xil_defaultlib "$XILINX_VIVADO/data/verilog/src/glbl.v" || exit 24
    xelab -relax -debug off -s seam_frames \
        "xil_defaultlib.tb_nia_eth_seam_frames" "xil_defaultlib.glbl" \
        -L xil_defaultlib -L xpm -L unisims_ver -L unisim -L secureip || exit 23
} > "$LOGDIR/compile.log" 2>&1
compile_rc=$?
echo "SEAMSIM COMPILE rc=$compile_rc log=$LOGDIR/compile.log"
[ "$compile_rc" -eq 0 ] || { tail -n 40 "$LOGDIR/compile.log"; exit "$compile_rc"; }

rc=0
rows=""

run_one() {
    local tag=$1 must_pass=$2 want_refusals=$3 want_clean=$4; shift 4
    local log="$LOGDIR/run_$tag.log"
    local args=""
    for arg in "$@"; do args="$args -testplusarg $arg"; done
    echo "SEAMSIM CMDLINE $tag: xsim seam_frames -runall $args" > "$log"
    xsim seam_frames -runall $args >> "$log" 2>&1
    local xsim_rc=$? result config refusals byte_errors length_errors
    result=$(grep -oE "SEAMSIM RESULT .*" "$log" | tail -1)
    config=$(grep -oE "SEAMSIM CONFIG .*" "$log" | tail -1)
    refusals=$(echo "$result" | grep -oE "refusals=[0-9]+" | grep -oE "[0-9]+$")
    byte_errors=$(echo "$result" | grep -oE "rx_byte=[0-9]+" | grep -oE "[0-9]+$")
    length_errors=$(echo "$result" | grep -oE "rx_len=[0-9]+" | grep -oE "[0-9]+$")
    local outcome
    case "$must_pass:$result" in
    1:*PASS*) outcome=PASS ;;
    0:*FAIL*) outcome=GUARD_FIRED ;;
    1:*)      outcome=FAIL; rc=1 ;;
    0:*)      outcome=GUARD_DID_NOT_FIRE; rc=1 ;;
    esac
    if [ "$want_refusals" = "1" ] && [ "${refusals:-0}" -eq 0 ]; then
        outcome="$outcome REFUSALS_NOT_REACHED"
        rc=1
    fi
    if [ "$want_refusals" = "0" ] && [ "${refusals:-0}" -ne 0 ]; then
        outcome="$outcome UNEXPECTED_REFUSALS"
        rc=1
    fi
    if [ "$want_clean" = "1" ] && { [ "${byte_errors:-0}" -ne 0 ] || [ "${length_errors:-0}" -ne 0 ]; }; then
        outcome="$outcome DROP_NOT_CLEAN"
        rc=1
    fi
    echo "  $tag: $outcome | ${result:-none} | xsim_rc=$xsim_rc"
    grep -E "SEAMSIM (RX|TX) (SWEEP|BURST|TIMEOUT)" "$log" | sed 's/^/    /'
    rows="$rows| $tag | $outcome | ${result:-none} | ${config:-none} |\n"
}

run_one equal_rate 1 0 0 shell_period_ps=2571 stream_period_ps=2571 mac_beat_gap_cycles=1
run_one shell_350 1 0 0 shell_period_ps=2857 stream_period_ps=2571 mac_beat_gap_cycles=1
run_one sink_stall 1 0 0 shell_period_ps=2571 stream_period_ps=2571 mac_beat_gap_cycles=1 sink_stall_period=4
run_one long_burst 1 0 0 shell_period_ps=2571 stream_period_ps=2571 mac_beat_gap_cycles=1 burst_repeat=40
run_one tx_backpressure 1 0 0 shell_period_ps=2571 stream_period_ps=2571 mac_beat_gap_cycles=1 tx_stall_period=3
run_one tx_backpressure_tight 1 0 0 shell_period_ps=2571 stream_period_ps=2571 mac_beat_gap_cycles=1 tx_stall_period=2
run_one negative_control 0 0 0 shell_period_ps=2571 stream_period_ps=2571 mac_beat_gap_cycles=1 negative_control=1
run_one overrun_control 0 0 1 shell_period_ps=2571 stream_period_ps=2571 mac_beat_gap_cycles=0 frame_gap_cycles=0 burst_repeat=400

echo
echo "| config | outcome | result | config line |"
echo "|---|---|---|---|"
printf "$rows"
echo
echo "SEAMSIM MATRIX DONE rc=$rc"
exit $rc
