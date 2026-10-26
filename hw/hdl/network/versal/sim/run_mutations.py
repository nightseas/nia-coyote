#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import hashlib, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM = os.environ.get("SHIM", os.path.join(HERE, "..", "axis_interconnect_512_shim.sv"))
SHIM = os.path.abspath(SHIM)
TB = os.path.join(HERE, "tb_axis_shim.sv")
IPDIR = os.environ.get("IPDIR", os.path.join(HERE, "ip"))
LOGDIR = os.environ.get("LOGDIR", os.path.join(HERE, "logs"))
SEED = os.environ.get("MUT_SEED", "1")
os.makedirs(LOGDIR, exist_ok=True)

M = []

M.append(("M1", "4to1",
          "reverse the slave TDATA concatenation only (S03 into the LSBs)",
          [("wire [4*512-1:0]        s_tdata  = {S03_AXIS_TDATA, S02_AXIS_TDATA, S01_AXIS_TDATA, S00_AXIS_TDATA};",
            "wire [4*512-1:0]        s_tdata  = {S00_AXIS_TDATA, S01_AXIS_TDATA, S02_AXIS_TDATA, S03_AXIS_TDATA};")],
          "caught"))

M.append(("M2", "4to1",
          "swap the s_tready fan-out order for S00/S01",
          [("assign {S03_AXIS_TREADY, S02_AXIS_TREADY, S01_AXIS_TREADY, S00_AXIS_TREADY} = s_tready;",
            "assign {S03_AXIS_TREADY, S02_AXIS_TREADY, S00_AXIS_TREADY, S01_AXIS_TREADY} = s_tready;")],
          "caught"))

M.append(("M3", "4to1",
          "drop the S00 TKEEP slice (tie it to all-ones)",
          [("wire [4*64-1:0]         s_tkeep  = {S03_AXIS_TKEEP, S02_AXIS_TKEEP, S01_AXIS_TKEEP, S00_AXIS_TKEEP};",
            "wire [4*64-1:0]         s_tkeep  = {S03_AXIS_TKEEP, S02_AXIS_TKEEP, S01_AXIS_TKEEP, {64{1'b1}}};")],
          "caught"))

M.append(("M4", "4to1",
          "mis-unpack m_tlast[0] (tie M00_AXIS_TLAST low)",
          [("    assign M00_AXIS_TVALID = m_tvalid[0];\n    assign M00_AXIS_TLAST  = m_tlast[0];\n\n    axis_switch_512_4to1 inst_axis_switch (",
            "    assign M00_AXIS_TVALID = m_tvalid[0];\n    assign M00_AXIS_TLAST  = 1'b0;\n\n    axis_switch_512_4to1 inst_axis_switch (")],
          "caught"))

M.append(("M5", "4to1",
          "FULLY self-consistent reversal of every slave vector (a pure relabelling)",
          [("wire [3:0]              s_tvalid = {S03_AXIS_TVALID, S02_AXIS_TVALID, S01_AXIS_TVALID, S00_AXIS_TVALID};",
            "wire [3:0]              s_tvalid = {S00_AXIS_TVALID, S01_AXIS_TVALID, S02_AXIS_TVALID, S03_AXIS_TVALID};"),
           ("wire [4*512-1:0]        s_tdata  = {S03_AXIS_TDATA, S02_AXIS_TDATA, S01_AXIS_TDATA, S00_AXIS_TDATA};",
            "wire [4*512-1:0]        s_tdata  = {S00_AXIS_TDATA, S01_AXIS_TDATA, S02_AXIS_TDATA, S03_AXIS_TDATA};"),
           ("wire [4*64-1:0]         s_tkeep  = {S03_AXIS_TKEEP, S02_AXIS_TKEEP, S01_AXIS_TKEEP, S00_AXIS_TKEEP};",
            "wire [4*64-1:0]         s_tkeep  = {S00_AXIS_TKEEP, S01_AXIS_TKEEP, S02_AXIS_TKEEP, S03_AXIS_TKEEP};"),
           ("wire [3:0]              s_tlast  = {S03_AXIS_TLAST, S02_AXIS_TLAST, S01_AXIS_TLAST, S00_AXIS_TLAST};",
            "wire [3:0]              s_tlast  = {S00_AXIS_TLAST, S01_AXIS_TLAST, S02_AXIS_TLAST, S03_AXIS_TLAST};"),
           ("wire [3:0]              s_supp   = {S03_ARB_REQ_SUPPRESS, S02_ARB_REQ_SUPPRESS, S01_ARB_REQ_SUPPRESS, S00_ARB_REQ_SUPPRESS};",
            "wire [3:0]              s_supp   = {S00_ARB_REQ_SUPPRESS, S01_ARB_REQ_SUPPRESS, S02_ARB_REQ_SUPPRESS, S03_ARB_REQ_SUPPRESS};"),
           ("assign {S03_AXIS_TREADY, S02_AXIS_TREADY, S01_AXIS_TREADY, S00_AXIS_TREADY} = s_tready;",
            "assign {S00_AXIS_TREADY, S01_AXIS_TREADY, S02_AXIS_TREADY, S03_AXIS_TREADY} = s_tready;")],
          "caught"))

M.append(("M6", "4to1",
          "reverse the ARB_REQ_SUPPRESS concatenation only",
          [("wire [3:0]              s_supp   = {S03_ARB_REQ_SUPPRESS, S02_ARB_REQ_SUPPRESS, S01_ARB_REQ_SUPPRESS, S00_ARB_REQ_SUPPRESS};",
            "wire [3:0]              s_supp   = {S00_ARB_REQ_SUPPRESS, S01_ARB_REQ_SUPPRESS, S02_ARB_REQ_SUPPRESS, S03_ARB_REQ_SUPPRESS};")],
          "caught"))

M.append(("M7", "2to1",
          "reverse the slave TDATA concatenation only, 2-to-1 shim",
          [("wire [2*512-1:0]        s_tdata  = {S01_AXIS_TDATA, S00_AXIS_TDATA};",
            "wire [2*512-1:0]        s_tdata  = {S00_AXIS_TDATA, S01_AXIS_TDATA};")],
          "caught"))

M.append(("M8", "2to1",
          "FULLY self-consistent reversal, 2-to-1 shim (expected NOT caught: +1 == -1 mod 2)",
          [("wire [1:0]              s_tvalid = {S01_AXIS_TVALID, S00_AXIS_TVALID};",
            "wire [1:0]              s_tvalid = {S00_AXIS_TVALID, S01_AXIS_TVALID};"),
           ("wire [2*512-1:0]        s_tdata  = {S01_AXIS_TDATA, S00_AXIS_TDATA};",
            "wire [2*512-1:0]        s_tdata  = {S00_AXIS_TDATA, S01_AXIS_TDATA};"),
           ("wire [2*64-1:0]         s_tkeep  = {S01_AXIS_TKEEP, S00_AXIS_TKEEP};",
            "wire [2*64-1:0]         s_tkeep  = {S00_AXIS_TKEEP, S01_AXIS_TKEEP};"),
           ("wire [1:0]              s_tlast  = {S01_AXIS_TLAST, S00_AXIS_TLAST};",
            "wire [1:0]              s_tlast  = {S00_AXIS_TLAST, S01_AXIS_TLAST};"),
           ("wire [1:0]              s_supp   = {S01_ARB_REQ_SUPPRESS, S00_ARB_REQ_SUPPRESS};",
            "wire [1:0]              s_supp   = {S00_ARB_REQ_SUPPRESS, S01_ARB_REQ_SUPPRESS};"),
           ("assign {S01_AXIS_TREADY, S00_AXIS_TREADY} = s_tready;",
            "assign {S00_AXIS_TREADY, S01_AXIS_TREADY} = s_tready;")],
          "coverage-hole-expected"))

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

def sh(cmd, log):
    with open(log, "a") as f:
        f.write("\n$ " + cmd + "\n")
        f.flush()
        return subprocess.call(cmd, shell=True, stdout=f, stderr=subprocess.STDOUT, cwd=HERE)

def build_and_run(dut, tag):
    ip = "axis_switch_512_%s" % dut
    log = os.path.join(LOGDIR, "mut_%s.log" % tag)
    open(log, "w").close()
    rc = sh('xvlog -sv -work xil_defaultlib "%s" "%s"' % (SHIM, TB), log)
    if rc != 0:
        return None, log, "COMPILE_FAIL(xvlog)"
    rc = sh('xelab -relax -debug off -s snap_%s xil_defaultlib.tb_shim_%s '
            '-L xil_defaultlib -L unisims_ver -L unisim -L secureip' % (tag, dut), log)
    if rc != 0:
        return None, log, "COMPILE_FAIL(xelab)"
    sh('xsim snap_%s -runall -testplusarg SEED=%s -testplusarg NEG=0' % (tag, SEED), log)
    txt = open(log, errors="replace").read()
    m = re.search(r"S23_DONE rc=(\d+)", txt)
    done = int(m.group(1)) if m else 99
    failed = re.findall(r"S23 TEST (\S+) FAIL", txt)
    return (done, failed), log, "OK"

pristine_md5 = md5(SHIM)
backup = SHIM + ".s23_pristine"
shutil.copyfile(SHIM, backup)
print("NIA_S23_MUT_PRISTINE_MD5=%s  (%s)" % (pristine_md5, SHIM))
print("NIA_S23_MUT_SEED=%s" % SEED)

rows = []
gate_rc = 0
for mid, dut, desc, subs, expectation in M:
    src = open(backup).read()
    ok = True
    for old, new in subs:
        if src.count(old) != 1:
            print("  %s: PATTERN NOT UNIQUE/ABSENT (%d hits) -> %r" % (mid, src.count(old), old[:60]))
            ok = False
            break
        src = src.replace(old, new)
    if not ok:
        rows.append((mid, dut, desc, "APPLY_FAIL", "-", expectation))
        gate_rc = 1
        continue
    open(SHIM, "w").write(src)
    mut_md5 = md5(SHIM)
    res, log, status = build_and_run(dut, "%s_%s" % (mid, dut))
    shutil.copyfile(backup, SHIM)
    back_md5 = md5(SHIM)
    revert_ok = (back_md5 == pristine_md5)
    if not revert_ok:
        gate_rc = 1

    if res is None:
        verdict, caught_by = status, "-"
    else:
        done, failed = res
        caught_by = ",".join(sorted(set(failed))) if failed else "-"
        if done != 0:
            verdict = "CAUGHT"
        else:
            verdict = "NOT_CAUGHT"
    if expectation == "caught" and verdict not in ("CAUGHT",):
        gate_rc = 1
    print("  %-3s %-5s mut_md5=%s  %-11s caught_by=%-45s revert_md5_equal=%s" %
          (mid, dut, mut_md5[:8], verdict, caught_by, revert_ok))
    rows.append((mid, dut, desc, verdict, caught_by, expectation))

print()
print("| mutant | shim | what was broken | verdict | caught by (named test) | expectation |")
print("|---|---|---|---|---|---|")
for r in rows:
    print("| %s | %s | %s | %s | `%s` | %s |" % (r[0], r[1], r[2], r[3], r[4], r[5]))
print()
print("NIA_S23_MUT_FINAL_MD5=%s equal_to_pristine=%s" % (md5(SHIM), md5(SHIM) == pristine_md5))
os.remove(backup)
print("NIA_S23_MUTATIONS_DONE rc=%d" % gate_rc)
sys.exit(gate_rc)
