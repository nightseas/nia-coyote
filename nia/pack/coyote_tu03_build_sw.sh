#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

say()  { printf '\033[1;36m[sw]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sw]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[sw] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

JOBS="${NIA_JOBS:-$(nproc 2>/dev/null || echo 8)}"
LOG="$HERE/build_sw.log"; : > "$LOG"

check_deps() {
  local miss=0
  command -v gcc   >/dev/null || { warn "gcc missing";   miss=1; }
  command -v make  >/dev/null || { warn "make missing";  miss=1; }
  command -v cmake >/dev/null || { warn "cmake missing"; miss=1; }
  [ -d "/lib/modules/$(uname -r)/build" ] || { warn "kernel headers for $(uname -r) missing (/lib/modules/$(uname -r)/build)"; miss=1; }
  ls /usr/include/boost/version.hpp >/dev/null 2>&1 || warn "Boost headers not in /usr/include — cmake may still find them"
  [ "$miss" -eq 0 ] || die "install the missing tools and retry"
  say "gcc   : $(gcc --version | head -1)"
  say "cmake : $(cmake --version | head -1)"
  say "kernel: $(uname -r)"
}

build_driver() {
  [ -d src/driver ] || die "src/driver not in this pack"
  say "building the driver (TARGET_PLATFORM=versal) ..."
  ( cd src/driver && make TARGET_PLATFORM=versal ) >>"$LOG" 2>&1
  local rc=$?
  local ko="$HERE/src/driver/build/coyote_driver.ko"
  if [ "$rc" -ne 0 ] || [ ! -f "$ko" ]; then
    warn "driver build FAILED (rc=$rc) — see $LOG"; tail -20 "$LOG" >&2; return 1
  fi
  say "driver OK: $ko"
  say "  md5     : $(md5sum "$ko" | cut -d' ' -f1)"
  say "  vermagic: $(modinfo "$ko" 2>/dev/null | awk '/^vermagic/{ $1=""; print $0}')"
  if modinfo "$ko" 2>/dev/null | grep -qi 'd0000B03F'; then
    say "  alias   : 10ee:b03f present -> can bind the TU03 endpoint"
  else
    warn "  alias   : 10ee:b03f NOT in the alias table — this driver cannot bind TU03"
  fi
  say ""
  say "  ★ export NIA_KO=$ko      (absolute: ~ expands to /root under sudo)"
  return 0
}

build_examples() {
  local rc=0 d bin
  for d in src/examples/*/sw; do
    [ -d "$d" ] || continue
    local ex; ex="$(basename "$(dirname "$d")")"
    if [ -d "$d/src/client" ] && [ -d "$d/src/server" ]; then
      local inst
      for inst in client server; do
        rm -rf "$d/build_$inst"; mkdir -p "$d/build_$inst"
        ( cd "$d/build_$inst" && cmake .. -DINSTANCE=$inst && make -j"$JOBS" ) >>"$LOG" 2>&1
        bin="$d/build_$inst/test"
        if [ -x "$bin" ]; then say "$ex ($inst): $bin"; else warn "$ex ($inst): FAILED — see $LOG"; rc=1; fi
      done
      continue
    fi
    rm -rf "$d/build_hw"; mkdir -p "$d/build_hw"
    ( cd "$d/build_hw" && cmake .. && make -j"$JOBS" ) >>"$LOG" 2>&1
    bin="$d/build_hw/test"
    if [ -x "$bin" ]; then say "$ex: $bin"; else warn "$ex: FAILED — see $LOG"; rc=1; fi
  done
  return $rc
}

case "${1:-all}" in
  driver)   check_deps; build_driver ;;
  examples) check_deps; build_examples ;;
  all)      check_deps; rc=0; build_driver || rc=1; build_examples || rc=1
            say "log: $LOG"; exit $rc ;;
  *) die "usage: $0 [all|driver|examples]" ;;
esac
