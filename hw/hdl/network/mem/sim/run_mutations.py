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

SMALL = {"SOAK_BURSTS": "30", "TPUT_CYCLES": "3000", "RAW_N": "30"}

MUTANTS = [
    ("X1", "axi_uram_mem.sv",
     "    assign s_axi_bid    = bq_d[bq_rp];",
     "    assign s_axi_bid    = '0;",
     "flat",
     "write-response ID reflection broken (bid always 0) — M7",
     ["test_id_echo_and_ordering"]),

    ("X2", "axi_uram_mem.sv",
     "                of_id[of_wp] <= pl_id [RD_LAT-1];",
     "                of_id[of_wp] <= '0;",
     "flat",
     "read-response ID reflection broken (rid always 0) — M7",
     ["test_id_echo_and_ordering", "test_axi_protocol_soak"]),

    ("X3", "axi_uram_mem.sv",
     "            pl_lst[0] <= (rd_beat == rd_len);",
     "            pl_lst[0] <= (rd_beat == rd_len - 8'd1);",
     "flat",
     "rlast off by one (asserted one beat early / never) — M8",
     ["test_axi_protocol_soak"]),

    ("X4", "nia_uram_sdp.sv",
     "                    if (wr_strb[s]) mem[wr_addr[BANK_AB-1:0]][s*8 +: 8] <= wr_data[s*8 +: 8];",
     "                    mem[wr_addr[BANK_AB-1:0]][s*8 +: 8] <= wr_data[s*8 +: 8];",
     "flat",
     "byte strobes ignored (every beat writes all 64 bytes) — M6",
     ["test_byte_strobes_honoured"]),

    ("X5", "axi_uram_mem.sv",
     "        mw_en   = wr_fire && !cur_oob;               // M3: never alias into the span",
     "        mw_en   = wr_fire;                           // M3: never alias into the span",
     "flat",
     "out-of-span writes no longer suppressed, so they ALIAS onto a live session — M3",
     ["test_oob_not_aliased_and_counted"]),

    ("X6", "axi_uram_mem.sv",
     "                    wr_addr <= wr_next;\n                    wr_beat <= wr_beat + 8'd1;",
     "                    wr_addr <= {wr_base[ADDR_BITS-1:WINDOW_BITS], wr_next[WINDOW_BITS-1:0]};\n                    wr_beat <= wr_beat + 8'd1;",
     "flat",
     "the shim silently wraps a burst inside the session ring — M12 (the reference does the "
     "wrapping itself; doing it here too corrupts the ring base)",
     ["test_no_implicit_ring_wrap"]),

    ("X7", "axi_uram_mem.sv",
     "                slot = { addr[PID_LSB  +: PID_BITS],\n                         addr[OFFS_LSB +: RDMA_OST_BITS] };",
     "                slot = { {PID_BITS{1'b0}},\n                         addr[OFFS_LSB +: RDMA_OST_BITS] };",
     "rdma_slot",
     "RDMA slot compression drops the pid field, so 64 pids alias onto one slot — M18",
     ["test_rdma_slot_address_compression"]),

    ("X8", "axi_uram_mem.sv",
     "                    if (ADDR_MAP == \"rdma_slot\" && wr_slot_now && !wr_slot_seen) begin",
     "                    if (ADDR_MAP == \"rdma_slot\" && 1'b0 && !wr_slot_seen) begin",
     "rdma_slot",
     "an over-length RDMA retransmit burst is no longer flagged — M19",
     ["test_rdma_slot_size_bound"]),
]

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

def run_suite(tag, addr_map):
    os.makedirs(LOGDIR, exist_ok=True)
    xml = os.path.join(LOGDIR, f"results_mut_{tag}.xml")
    log = os.path.join(LOGDIR, f"mut_{tag}.log")
    subprocess.run(["make", "-s", "clean"], cwd=HERE, capture_output=True)
    args = ["make", "SEED=1", f"ADDR_MAP={addr_map}", f"COCOTB_RESULTS_FILE={xml}"]
    args += [f"{k}={v}" for k, v in SMALL.items()]
    with open(log, "w") as fh:
        subprocess.run(args, cwd=HERE, stdout=fh, stderr=subprocess.STDOUT, timeout=3600)
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
    for mid, fname, old, new, amap, what, expect in MUTANTS:
        if only and mid != only:
            continue
        path = os.path.join(RTL, fname)
        orig = open(path).read()
        orig_md5 = md5(path)
        assert old in orig, f"{mid}: anchor not found in {fname}"
        open(path, "w").write(orig.replace(old, new, 1))
        assert md5(path) != orig_md5, f"{mid}: mutation did not change the file"
        try:
            n, failed, err, log = run_suite(mid, amap)
        finally:
            open(path, "w").write(orig)
            assert md5(path) == orig_md5, f"{mid}: FAILED TO REVERT {fname}"
        caught = (err is None and failed is not None and len(failed) > 0
                  and all(any(e in f for f in failed) for e in expect))
        rows.append((mid, fname, amap, what, expect, n, failed, err, caught, log))
        print(f"{mid}: map={amap} tests={n} failed={failed} err={err} caught={caught}",
              flush=True)

    print("\n| mutant | file | ADDR_MAP | injected defect | expected to fail | observed | caught |")
    print("|---|---|---|---|---|---|---|")
    ok = True
    for mid, fname, amap, what, expect, n, failed, err, caught, log in rows:
        obs = err if err else f"TESTS={n} FAIL={len(failed)}: {', '.join(failed) or 'none'}"
        print(f"| {mid} | `{fname}` | {amap} | {what} | {', '.join(expect)} | {obs} | "
              f"{'YES' if caught else 'NO'} |")
        ok &= caught
    print(f"\nMUTATION RESULT: {'PASS (every mutant caught)' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
