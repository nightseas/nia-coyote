#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WB=${1:-18}
NS=${2:-16}
MSS=${3:-4096}
NOPS=${4:-60}
SEED=${5:-20260726}

STACK=${STACK:-$HERE/../../../../services/network/hls}
if [ ! -f "$STACK/toe/dummy_memory.hpp" ]; then
  echo "REF_ERROR: $STACK/toe/dummy_memory.hpp not found (set STACK=)"; exit 2
fi

INC=""
for c in /tools/Xilinx/Vitis_HLS/2021.1/include \
         /tools/Xilinx/Vivado/2021.1/include \
         /tools/Xilinx/2025.2/Vitis/include; do
  [ -f "$c/ap_int.h" ] && INC="$c" && break
done
if [ -z "$INC" ]; then echo "REF_ERROR: no ap_int.h found"; exit 2; fi
echo "REF_INC=$INC"

echo "REF_STAGE_BEGIN reparam"
python3 "$HERE/reparam_dummy_memory.py" "$STACK/toe/dummy_memory.hpp" \
        "$HERE/dummy_memory_reparam.hpp" "$WB" || exit 1
echo "REF_STAGE_END reparam"

echo "REF_STAGE_BEGIN compile"
g++ -O2 -std=c++14 -w \
    -I"$INC" -I"$HERE" -I"$STACK" -I"$STACK/toe" \
    -o "$HERE/ref_dummy_mem" "$HERE/ref_main.cpp" 2>&1 | tail -25
[ -x "$HERE/ref_dummy_mem" ] || { echo "REF_ERROR: compile failed"; exit 1; }
echo "REF_STAGE_END compile"

echo "REF_STAGE_BEGIN trace"
python3 "$HERE/gen_trace.py" "$HERE/ref_trace.txt" "$NS" "$WB" "$MSS" "$NOPS" "$SEED" || exit 1
echo "REF_STAGE_END trace"

echo "REF_STAGE_BEGIN run"
"$HERE/ref_dummy_mem" "$HERE/ref_trace.txt" "$HERE/ref_golden.txt" || exit 1
wc -l "$HERE/ref_trace.txt" "$HERE/ref_golden.txt"
md5sum "$HERE/ref_trace.txt" "$HERE/ref_golden.txt" "$HERE/dummy_memory_reparam.hpp"
echo "REF_STAGE_END run"
echo "REF_BUILD_DONE rc=0"
