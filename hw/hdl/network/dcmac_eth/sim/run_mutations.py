#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import hashlib
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, ".."))
LOGDIR = os.environ.get("LOGDIR", os.path.join(HERE, "logs"))

RESET_GEN = "dcmac_usr_reset_gen.sv"

MUTANTS = [
    ("M1", RESET_GEN, "1",
     "    always_ff @(posedge clk) tx_rst_r <= ~released;",
     "    always_ff @(posedge clk) tx_rst_r <= sys_reset_sync || mac_tx_rst;",
     "clause R1 removed: tx_rst follows the MAC link state again",
     ["test_r1_alignment_dip_does_not_reassert"]),
    ("M2", RESET_GEN, "1",
     "    else if (mac_link_up) link_seen <= 1'b1;",
     "    else                  link_seen <= 1'b1;",
     "link_seen set without a link",
     ["test_r1_mode1_holds_until_first_link_up"]),
    ("M3", RESET_GEN, "1",
     "  wire release_cond = (MODE == 0) ? hold_done : (hold_done && link_seen);",
     "  wire release_cond = (MODE == 0) ? hold_done : (hold_done || link_seen);",
     "release condition weakened from and to or",
     ["test_r1_mode1_holds_until_first_link_up"]),
    ("M4", RESET_GEN, "1",
     "    if (sys_reset_sync)    released <= 1'b0;",
     "    if (1'b0)              released <= 1'b0;",
     "sys_reset no longer clears the release latch",
     ["test_r1_only_sys_reset_reasserts"]),
    ("M5", RESET_GEN, "1",
     "      hold_cnt  <= HCW'(HOLD_CYCLES);\n      hold_done <= 1'b0;",
     "      hold_cnt  <= '0;\n      hold_done <= 1'b0;",
     "the startup hold is not reloaded on sys_reset",
     ["test_r1_hold_cycles_are_respected"]),
    ("M6", RESET_GEN, "1",
     "    always_ff @(posedge clk) tx_rst_r <= ~released;",
     "    always_ff @(posedge clk) tx_rst_r <= 1'b0;",
     "tx_rst never asserts at all",
     ["test_r1_asserted_out_of_reset"]),
    ("M7", RESET_GEN, "1",
     "    else if (release_cond) released <= 1'b1;",
     "    else                   released <= 1'b1;",
     "the release latch ignores the release condition",
     ["test_r1_hold_cycles_are_respected"]),
    ("M8", RESET_GEN, "2",
     "    always_ff @(posedge clk) tx_rst_r <= sys_reset_sync || mac_tx_rst;",
     "    always_ff @(posedge clk) tx_rst_r <= sys_reset_sync;",
     "the MODE 2 control arm made vacuous",
     ["test_r1_mode2_is_the_control"]),
]


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def run_suite(tag, mode):
    os.makedirs(LOGDIR, exist_ok=True)
    log = os.path.join(LOGDIR, f"mut_{tag}_mode{mode}.log")
    env = dict(os.environ)
    env["MODE"] = mode
    env["HOLD_CYCLES"] = env.get("HOLD_CYCLES", "16")
    env["SEED"] = "1"
    with open(log, "w") as fh:
        subprocess.run(["make", "clean"], cwd=HERE, env=env,
                       stdout=fh, stderr=subprocess.STDOUT)
        subprocess.run(["make"], cwd=HERE, env=env,
                       stdout=fh, stderr=subprocess.STDOUT)
    xml = os.path.join(HERE, "results.xml")
    if not os.path.exists(xml):
        return None, None, "no results.xml", log
    root = ET.parse(xml).getroot()
    total = 0
    failed = []
    for case in root.iter("testcase"):
        total += 1
        for child in case:
            if child.tag in ("failure", "error"):
                failed.append(case.get("name"))
                break
    os.remove(xml)
    return total, failed, None, log


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None

    stale = []
    for mid, fname, _mode, old, _new, _what, _expect in MUTANTS:
        path = os.path.join(RTL, fname)
        if not os.path.exists(path):
            stale.append((mid, fname, "file missing"))
        elif old not in open(path).read():
            stale.append((mid, fname, "anchor not found"))
    if stale:
        print("ANCHOR PRE-FLIGHT FAILED, these mutants cannot be applied:")
        for mid, fname, why in stale:
            print(f"  {mid}: {fname}: {why}")
        print("\nMUTATION RESULT: FAIL (stale harness, not necessarily broken RTL)")
        return 2
    print(f"anchor pre-flight OK: {len(MUTANTS)} mutants applicable")

    for mode in ("1", "2"):
        n, failed, err, log = run_suite(f"control_mode{mode}", mode)
        if err is not None or failed:
            print(f"CONTROL ARM MODE={mode} DID NOT PASS: tests={n} failed={failed} err={err} log={log}")
            print("\nMUTATION RESULT: FAIL (a caught mutant would be meaningless)")
            return 2
        print(f"control arm MODE={mode}: tests={n} failed=0")

    rows = []
    for mid, fname, mode, old, new, what, expect in MUTANTS:
        if only and mid != only:
            continue
        path = os.path.join(RTL, fname)
        orig = open(path).read()
        orig_md5 = md5(path)
        assert old in orig, f"{mid}: anchor not found in {fname}"
        open(path, "w").write(orig.replace(old, new, 1))
        assert md5(path) != orig_md5, f"{mid}: mutation did not change the file"
        try:
            n, failed, err, log = run_suite(mid, mode)
        finally:
            open(path, "w").write(orig)
            assert md5(path) == orig_md5, f"{mid}: FAILED TO REVERT {fname}"
        caught = err is None and failed is not None and len(failed) > 0 and \
            all(any(e in f for f in failed) for e in expect)
        rows.append((mid, fname, mode, what, expect, n, failed, err, caught, log))
        print(f"{mid}: mode={mode} tests={n} failed={failed} err={err} caught={caught}")

    print("\n| mutant | file | arm | injected defect | expected to fail | observed | caught |")
    print("|---|---|---|---|---|---|---|")
    ok = True
    for mid, fname, mode, what, expect, n, failed, err, caught, log in rows:
        obs = err if err else f"TESTS={n} FAIL={len(failed)}: {', '.join(failed) or 'none'}"
        print(f"| {mid} | `{fname}` | MODE={mode} | {what} | {', '.join(expect)} | {obs} | "
              f"{'YES' if caught else 'NO'} |")
        ok &= caught
    print(f"\nMUTATION RESULT: {'PASS (every mutant caught)' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
