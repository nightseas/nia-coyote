#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

rc=0
fail=""

run() {
    local name="$1"
    shift
    echo "=== $name"
    if "$@"; then
        echo "--- $name OK"
    else
        echo "--- $name FAILED"
        rc=1
        fail="$fail $name"
    fi
}

run gate_shim_static python3 "$HERE/gate_shim_static.py"
run check_portmap    python3 "$HERE/../synth/check_portmap.py"
run elaborate_m1     env NIA_ELAB_MODE=1 bash "$HERE/elab.sh"
run elaborate_m2     env NIA_ELAB_MODE=2 bash "$HERE/elab.sh"
run cocotb_arms      make -C "$HERE" arms
run mutations        python3 "$HERE/run_mutations.py"

echo
if [ "$rc" -eq 0 ]; then
    echo "DCMAC_ETH GATES: PASS"
else
    echo "DCMAC_ETH GATES: FAIL:$fail"
fi
exit "$rc"
