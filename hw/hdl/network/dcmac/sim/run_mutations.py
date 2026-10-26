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

MUTANTS = [
    ("M1", "dcmac_seg_axis_adapter.sv",
     "      if (rx_seg_ena[s])\n",
     "      if (rx_seg_ena[s] && s == 0)\n",
     "RX drops every segment except segment 0 (a lost segment)",
     ["test_rx_byte_exact"]),
    ("M2", "dcmac_seg_axis_adapter.sv",
     "      tx_seg_mty[s*4 +: 4] = eop_s ? (SEG_B[3:0] - $countones(keepseg)) : 4'd0;",
     "      tx_seg_mty[s*4 +: 4] = eop_s ? (SEG_B[3:0] - $countones(keepseg) + 4'd1) : 4'd0;",
     "TX last-beat byte count off by one (corrupt tkeep/mty on EOP)",
     ["test_tx_byte_exact"]),
    ("M3", "dcmac_mac_ctl_fsm.sv",
     "    tx_rst_r <= ~seg_rstn | (state != S_XFER) | ~stat_rx_aligned;",
     "    tx_rst_r <= 1'b0;",
     "reset handshake broken: tx_rst released before the link is up",
     ["test_bringup_sequence"]),
    ("M4", "dcmac_axis_core.sv",
     "  assign tx_gate    = ctl_tx_enable | tx_in_frame;",
     "  assign tx_gate    = 1'b1;",
     "TX gate removed: frames leave before ctl_tx_enable",
     ["test_tx_gated_before_enable"]),
    ("M5", "dcmac_mac_ctl_fsm.sv",
     "  assign tx_datapath_reset   = tx_datapath_reset_req;  // W14: no FSM path here",
     "  assign tx_datapath_reset   = tx_datapath_reset_req | rx_dp_reset_r;",
     "the vendor exdes defect reproduced: an RX re-align also resets the TX datapath",
     ["test_align_loss_recovery"]),
    ("M6", "dcmac_axis_frame_fifo.sv",
     "  assign m_axis_tvalid = (rd_ptr != wr_commit);",
     "  assign m_axis_tvalid = (rd_ptr != wr_cur);",
     "store-and-forward defeated (a plain FIFO): S2 W7 gaplessness lost",
     ["test_tx_gapless"]),
    ("M7", "dcmac_axis_core.sv",
     "    .DROP_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1),    // RX cannot be back-pressured",
     "    .DROP_BAD_FRAME(1'b0), .DROP_WHEN_FULL(1'b1),    // RX cannot be back-pressured",
     "errored RX frames forwarded instead of dropped whole (S2 W8)",
     ["test_rx_err_frame_dropped"]),

    ("M8", "dcmac_axis_frame_fifo.sv",
     "  wire bad_eop  = DROP_BAD_FRAME & (s_axis_tuser | err_seen);",
     "  wire bad_eop  = DROP_BAD_FRAME & s_axis_tuser;",
     "DEFECT-N5-1 restored: the errored-frame drop becomes beat-scoped again, so an error "
     "flagged before the final 512-bit beat is ignored and the frame is committed (X5)",
     ["test_rx_err_midframe_dropped"]),
    ("M9", "dcmac_axis_core.sv",
     "    else if (rxa_tvalid && rxa_tlast && (rxa_tuser | rxa_err_seen) &&",
     "    else if (rxa_tvalid && rxa_tlast && rxa_tuser &&",
     "DEFECT-N5-1 restored in the counter: a mid-frame RX error is not counted (X6)",
     ["test_rx_err_midframe_counted"]),
    ("M10", "dcmac_axis_frame_fifo.sv",
     "          if (full)          drop_frame <= 1'b1;       // no room: kill this frame",
     "          if (full)          drop_frame <= 1'b0;       // no room: kill this frame",
     "whole-frame drop on overflow defeated: beats are skipped mid-frame (wr_store is "
     "gated by ~full) and the frame is committed TRUNCATED, so a partial frame reaches "
     "the stack and can fuse onto the next (X1/X2/X3)",
     ["test_rx_frames_whole_under_backpressure"]),
]

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

def run_suite(tag):
    os.makedirs(LOGDIR, exist_ok=True)
    xml = os.path.join(LOGDIR, f"results_mut_{tag}.xml")
    log = os.path.join(LOGDIR, f"mut_{tag}.log")
    subprocess.run(["make", "-s", "clean"], cwd=HERE, capture_output=True)
    with open(log, "w") as fh:
        subprocess.run(["make", "SEED=1", "USR_MHZ=250", f"COCOTB_RESULTS_FILE={xml}"],
                       cwd=HERE, stdout=fh, stderr=subprocess.STDOUT)
    try:
        root = ET.parse(xml).getroot()
    except Exception as e:
        return None, None, f"no/unparsable XML ({e})", log
    tcs = list(root.iter("testcase"))
    failed = [c.get("name") for c in tcs if len(list(c))]
    return len(tcs), failed, None, log

def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None

    stale = []
    for mid, fname, old, _new, _what, _expect in MUTANTS:
        path = os.path.join(RTL, fname)
        if not os.path.exists(path):
            stale.append((mid, fname, "file missing"))
        elif old not in open(path).read():
            stale.append((mid, fname, "anchor not found"))
    if stale:
        print("ANCHOR PRE-FLIGHT FAILED — these mutants cannot be applied:")
        for mid, fname, why in stale:
            print(f"  {mid}: {fname}: {why}")
        print("\nMUTATION RESULT: FAIL (stale harness, not necessarily broken RTL)")
        return 2
    print(f"anchor pre-flight OK: {len(MUTANTS)} mutants applicable")

    rows = []
    for mid, fname, old, new, what, expect in MUTANTS:
        if only and mid != only:
            continue
        path = os.path.join(RTL, fname)
        orig = open(path).read()
        orig_md5 = md5(path)
        assert old in orig, f"{mid}: anchor not found in {fname}"
        open(path, "w").write(orig.replace(old, new, 1))
        assert md5(path) != orig_md5, f"{mid}: mutation did not change the file"
        try:
            n, failed, err, log = run_suite(mid)
        finally:
            open(path, "w").write(orig)
            assert md5(path) == orig_md5, f"{mid}: FAILED TO REVERT {fname}"
        caught = err is None and failed is not None and \
            all(any(e in f for f in failed) for e in expect) and len(failed) > 0
        rows.append((mid, fname, what, expect, n, failed, err, caught, log))
        print(f"{mid}: tests={n} failed={failed} err={err} caught={caught}")

    print("\n| mutant | file | injected defect | expected to fail | observed | caught |")
    print("|---|---|---|---|---|---|")
    ok = True
    for mid, fname, what, expect, n, failed, err, caught, log in rows:
        obs = err if err else f"TESTS={n} FAIL={len(failed)}: {', '.join(failed) or 'none'}"
        print(f"| {mid} | `{fname}` | {what} | {', '.join(expect)} | {obs} | "
              f"{'YES' if caught else 'NO'} |")
        ok &= caught
    print(f"\nMUTATION RESULT: {'PASS (every mutant caught)' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
