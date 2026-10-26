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

NP4 = ["NPORTS=4", "ANCHOR=0", "RATE_CODE=2", "RATE_FIELD=16", "DONE_MASK=255"]
NP1 = ["NPORTS=1", "ANCHOR=0"]

MUTANTS = [
    ("MDROP", "dcmac_ctl_seq.sv", NP1,
     "      else if (pc == P_B9G + 1) begin op = OP_WR; a = gg(O_PCTL_RX); d = 32'h0; end",
     "      else if (pc == P_B9G + 1) begin op = OP_NOP; end",
     "B9's global PORT_CONTROL_RX release write is dropped",
     ["test_c6_golden_trace_config_phase"]),

    ("MORDER", "dcmac_ctl_seq.sv", NP1,
     "        a  = ((pc - P_B11) % 2 == 0) ? pp(p, O_CHCTL_TX) : pp(p, O_CHCTL_RX);",
     "        a  = ((pc - P_B11) % 2 == 0) ? pp(p, O_CHCTL_RX) : pp(p, O_CHCTL_TX);",
     "B11 releases CHANNEL_CONTROL_RX before _TX (two writes reordered)",
     ["test_c6_golden_trace_config_phase"]),

    ("MGAP", "dcmac_ctl_seq.sv", NP1,
     "      else if (pc == P_B10) begin op = OP_WAIT; w = (32'(T_PORT_CHAN_GAP_MS) * 32'(CYC_PER_MS)); end",
     "      else if (pc == P_B10) begin op = OP_NOP; end",
     "the B10 50 ms port->channel gap is skipped (it had been dropped once before)",
     ["test_c8_port_channel_gap"]),

    ("MB16", "dcmac_ctl_seq.sv", NP1,
     "  assign tx_datapath_reset       = tx_datapath_reset_req;",
     "  assign tx_datapath_reset       = tx_datapath_reset_req | pin_rx_dp;",
     "B16 violated: the TX datapath reset is coupled to the RX one — the real "
     "vendor exdes defect",
     ["test_b16_tx_datapath_reset_never_asserted"]),

    ("MANCH", "dcmac_ctl_seq.sv", NP4,
     "        op = OP_WR; a = pp(ANCHOR + (pc - P_GRP),  O_PCTL_RX); d = 32'h2;",
     "        op = OP_WR; a = pp(ANCHOR,                 O_PCTL_RX); d = 32'h2;",
     "DEFECT 3 reproduced: the MAC re-align pulses only the ANCHOR, not the group",
     ["test_c10_port_group_reset"]),

    ("MUNB", "dcmac_ctl_seq.sv", NP1,
     "      else if (pc == P_LADDER) begin op = OP_BRX; d = 32'(P_FAULT); end",
     "      else if (pc == P_LADDER) begin op = OP_NOP; end",
     "the retry ladder is unbounded — it never gives up and never reports",
     ["test_c12_ladder_bounded_and_reports"]),

    ("MMASK", "dcmac_ctl_pkg.sv", NP1,
     "  localparam logic [31:0] ALIGN_MASK     = 32'h0000_0005;",
     "  localparam logic [31:0] ALIGN_MASK     = 32'h0000_0001;",
     "C9's mask bug: lock declared on bit0 alone, ignoring stat_rx_status",
     ["test_c9_align_mask_and_bad_magic"]),
]

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

def run_suite(tag, mkvars):
    os.makedirs(LOGDIR, exist_ok=True)
    xml = os.path.join(LOGDIR, f"results_mut_{tag}.xml")
    log = os.path.join(LOGDIR, f"mut_{tag}.log")
    subprocess.run(["make", "-s", "clean"], cwd=HERE, capture_output=True)
    with open(log, "w") as fh:
        subprocess.run(["make", "SEED=1"] + mkvars + [f"COCOTB_RESULTS_FILE={xml}"],
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
    rows = []
    for mid, fname, mkvars, old, new, what, expect in MUTANTS:
        if only and mid != only:
            continue
        path = os.path.join(RTL, fname)
        orig = open(path).read()
        orig_md5 = md5(path)
        assert old in orig, f"{mid}: anchor not found in {fname}"
        open(path, "w").write(orig.replace(old, new, 1))
        assert md5(path) != orig_md5, f"{mid}: mutation did not change the file"
        try:
            n, failed, err, log = run_suite(mid, mkvars)
        finally:
            open(path, "w").write(orig)
            assert md5(path) == orig_md5, f"{mid}: FAILED TO REVERT {fname}"
        caught = err is None and failed is not None and len(failed) > 0 and \
            all(any(e in f for f in failed) for e in expect)
        rows.append((mid, fname, what, expect, n, failed, err, caught, log,
                     orig_md5))
        print(f"{mid}: tests={n} failed={failed} err={err} caught={caught} "
              f"reverted_md5={orig_md5}")

    print("\n| mutant | file | injected defect | expected to fail | observed | "
          "caught | md5 reverted |")
    print("|---|---|---|---|---|---|---|")
    ok = True
    for mid, fname, what, expect, n, failed, err, caught, log, m in rows:
        obs = err if err else f"TESTS={n} FAIL={len(failed)}: {', '.join(failed) or 'none'}"
        print(f"| {mid} | `{fname}` | {what} | {', '.join(expect)} | {obs} | "
              f"{'YES' if caught else 'NO'} | `{m}` |")
        ok &= caught
    print(f"\nMUTATION RESULT: {'PASS (every mutant caught)' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
