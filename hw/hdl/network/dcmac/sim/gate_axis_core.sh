#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
L=${NIA_LOG_DIR:-$D/sim/logs}
mkdir -p "$L"
echo $$ > "$L/run.pid"
exec > "$L/build.log" 2>&1
rc=0

echo "NIA_STAGE_BEGIN env"
verilator --version; cocotb-config --version; python3 -V
echo "NIA_STAGE_END env"

echo "NIA_STAGE_BEGIN portmap"
python3 "$D/synth/check_portmap.py" "$D/legacy/dcmac_axis_wrapper_phaseb_legacy.sv" \
        "$D/dcmac_100g_phy_dcmac.sv" > "$L/portmap.log" 2>&1 || rc=1
tail -3 "$L/portmap.log"
echo "NIA_STAGE_END portmap rc=$rc"

echo "NIA_STAGE_BEGIN sim_matrix"
( cd "$D/sim" && LOGDIR="$L/sim" bash ./run_matrix.sh ) > "$L/matrix.log" 2>&1 || rc=1
tail -3 "$L/matrix.log"
echo "NIA_STAGE_END sim_matrix rc=$rc"

echo "NIA_STAGE_BEGIN mutations"
( cd "$D/sim" && LOGDIR="$L/mut" python3 ./run_mutations.py ) > "$L/mutations.log" 2>&1 || rc=1
tail -4 "$L/mutations.log"
echo "NIA_STAGE_END mutations rc=$rc"

source /tools/Xilinx/2025.2/Vivado/settings64.sh
echo "NIA_STAGE_BEGIN ooc_core"
( cd "$L" && env TERM=xterm vivado -mode batch -nojournal -log "$L/vivado_core.log" \
    -source "$D/synth/ooc_synth.tcl" -tclargs core ) > "$L/ooc_core.log" 2>&1 || rc=1
grep -E "^OOC_(TOP|ERRORS|CRITICAL_WARNINGS|DONE)" "$L/ooc_core.log"
echo "NIA_STAGE_END ooc_core rc=$rc"

echo "NIA_STAGE_BEGIN ooc_wrapper"
( cd "$L" && env TERM=xterm vivado -mode batch -nojournal -log "$L/vivado_wrapper.log" \
    -source "$D/synth/ooc_synth.tcl" -tclargs wrapper ) > "$L/ooc_wrapper.log" 2>&1 || rc=1
grep -E "^OOC_(TOP|ERRORS|CRITICAL_WARNINGS|DONE)" "$L/ooc_wrapper.log"
echo "NIA_STAGE_END ooc_wrapper rc=$rc"

echo "NIA_STAGE_BEGIN area_probe"
( cd "$L" && env TERM=xterm vivado -mode batch -nojournal -log "$L/vivado_area.log" \
    -source "$D/synth/area_probe.tcl" ) > "$L/area_probe.log" 2>&1 || rc=1
grep -E "^PROBE=|NIA_AREA_PROBE_DONE" "$L/area_probe.log"
echo "NIA_STAGE_END area_probe rc=$rc"

echo "NIA_BUILD_DONE rc=$rc"
