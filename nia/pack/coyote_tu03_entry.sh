#!/usr/bin/env bash
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1;36m[coyote-tu03]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[coyote-tu03] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
need() { [ -x "$HERE/$1" ] || die "missing component: $1 (is this a complete pack?)"; }

usage() { sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  build)
    need build_sw.sh; shift
    "$HERE/build_sw.sh" "$@" || die "software build failed"
    [ -x "$HERE/diag.sh" ] && [ -d "$HERE/arpprobe" ] && "$HERE/diag.sh" build-arp || true
    ;;
  program)
    need hw_test.sh; tag="${2:?usage: program <tag>}"
    pdi="$HERE/images/$tag.pdi"; [ -f "$pdi" ] || die "no such image: images/$tag.pdi"
    NIA_TAG="$tag" "$HERE/hw_test.sh" program "$pdi"
    say "now: sudo rmmod coyote_driver 2>/dev/null; sudo reboot     (REQUIRED for a new image)"
    ;;
  status)      need hw_test.sh; shift; "$HERE/hw_test.sh" env "$@" ;;
  load)        need hw_test.sh; shift; "$HERE/hw_test.sh" driver-load "$@" ;;
  unload)      need hw_test.sh; shift; "$HERE/hw_test.sh" driver-unload "$@" ;;
  net)
    need rdma_test.sh
    "$HERE/rdma_test.sh" setup && echo && cat /sys/kernel/coyote_sysfs_*/cyt_attr_ip
    ;;
  test)
    need hw_test.sh; tag="${2:?usage: test <tag>}"; shift 2
    bin="$HERE/src/examples/$tag/sw/build_hw/test"
    [ -x "$bin" ] || die "no built binary for '$tag' (run: ./coyote-tu03 build)"
    "$HERE/hw_test.sh" run "$tag" "$bin" -- "$@"
    ;;
  diag)        need diag.sh;      shift; "$HERE/diag.sh" "${@:-full}" ;;
  rdma)        need rdma_test.sh; shift; "$HERE/rdma_test.sh" "$@" ;;
  spec)        cat "$HERE/DESIGN_SPEC.md" 2>/dev/null || die "DESIGN_SPEC.md is missing" ;;
  ""|-h|--help) usage ;;
  *) die "unknown command '$1' — try: $0 --help" ;;
esac
