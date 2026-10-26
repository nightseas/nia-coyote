#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DCMAC_ETH = os.path.normpath(os.path.join(HERE, ".."))
COYOTE_HW = os.path.normpath(os.path.join(DCMAC_ETH, "..", "..", ".."))
COYOTE = os.path.normpath(os.path.join(COYOTE_HW, ".."))
WORKSPACE = os.path.normpath(os.path.join(COYOTE, "..", "..", ".."))

SHIM = os.path.join(DCMAC_ETH, "dcmac_axis_wrapper.sv")
RESET_GEN = os.path.join(DCMAC_ETH, "dcmac_usr_reset_gen.sv")
CMAC = os.path.join(COYOTE_HW, "hdl", "network", "cmac", "cmac_uplus_axis_wrapper.sv")
CR_SHELL = os.path.join(COYOTE, "scripts", "cr_prjcts", "cr_shell.tcl.in")
CONTRACT = os.path.join(WORKSPACE, "nia-dev", "doc", "design",
                        "NIA_COYOTE_DCMAC_ETH_SEAM_CONTRACT.md")

EXPECT_PARAMS = {
    "N_SEG": "2",
    "SEG_W": "128",
    "DATA_W": "AXI_NET_BITS",
    "PTP_TS_EN": "0",
    "PTP_TS_W": "80",
    "TX_TAG_W": "0",
    "RX_FIFO_AW": "9",
    "RX_CDC_AW": "9",
    "TX_FIFO_AW": "8",
    "TX_CDC_AW": "9",
    "TX_CPL_AW": "4",
    "PORT_MAX": "6",
    "NPORTS": "1",
    "ANCHOR": "0",
    "EN_CTL_SEQ": "1",
    "SEG_CYC_PER_MS": "391000",
    "CTL_CYC_PER_MS": "250000",
    "T_RXDP_MS": "100",
    "T_SERDES_MS": "100",
    "LINK_WDT_MS": "750",
}

CONTRACT_VALUE = dict(EXPECT_PARAMS, DATA_W="512")

EXPECT_PORTS = [
    "init_clk", "sys_reset",
    "gt_ref_clk_p", "gt_ref_clk_n", "gt_rxp_in", "gt_rxn_in",
    "gt_txn_out", "gt_txp_out",
    "m_rx_axis", "s_tx_axis",
    "usr_clk", "tx_rst",
]

EXPECT_UNUSED = [
    "init_clk", "m_rx_axis.tready",
    "mac_rx_clk", "mac_rx_rst", "mac_seg_clk", "rx_tuser",
    "tx_cpl_valid", "tx_cpl_ts", "tx_cpl_tag",
    "mac_tx_status", "mac_rx_status",
    "mac_rx_overflow", "mac_rx_trunc",
    "mac_rx_err_frames", "mac_rx_align_stat", "mac_rx_drop_frames",
    "mac_tx_cpl_overflow", "mac_fsm_state",
    "ctl_link_fault", "ctl_access_fault", "ctl_seq_busy",
    "ctl_rx_phy_status", "ctl_retry_cnt",
    "ctl_seq_state", "ctl_seq_pc", "ctl_stat_rd_data",
]

problems = []
checks = 0


def check(cond, name, detail=""):
    global checks
    checks += 1
    if not cond:
        problems.append(f"{name}: {detail}")


def nonempty(items, name):
    if not items:
        problems.append(f"{name}: the check evaluated an empty set and would have passed vacuously")
        return False
    return True


def read(path):
    if not os.path.exists(path):
        problems.append(f"missing file: {path}")
        return ""
    return open(path, encoding="utf-8", errors="replace").read()


def port_names(text, module):
    m = re.search(r"\bmodule\s+" + module + r"\b[^(]*\((.*?)\n\s*\);", text, re.S)
    if not m:
        return []
    body = m.group(1)
    body = re.sub(r"//[^\n]*", "", body)
    out = []
    for line in body.split("\n"):
        line = line.strip().rstrip(",")
        if not line:
            continue
        toks = re.findall(r"[A-Za-z_][A-Za-z0-9_.]*", line)
        if toks:
            out.append(toks[-1])
    return out


shim = read(SHIM)
rgen = read(RESET_GEN)
cmac = read(CMAC)
crsh = read(CR_SHELL)
contract = read(CONTRACT)

shim_ports = port_names(shim, "dcmac_axis_wrapper")
cmac_ports = port_names(cmac, "cmac_axis_wrapper")
if nonempty(shim_ports, "C1a") and nonempty(cmac_ports, "C1b"):
    check(shim_ports == EXPECT_PORTS, "C1",
          f"shim port list {shim_ports} is not the 12-port face {EXPECT_PORTS}")
    check(cmac_ports == EXPECT_PORTS, "C1c",
          f"the CMAC face moved: {cmac_ports}")

lp = dict(re.findall(r"localparam\s+int\s+([A-Z0-9_]+)\s*=\s*([A-Za-z0-9_']+)\s*;", shim))
if nonempty(lp, "C2a"):
    wrong = {k: (lp[k], EXPECT_PARAMS[k])
             for k in EXPECT_PARAMS if k in lp and lp[k] != EXPECT_PARAMS[k]}
    check(lp == EXPECT_PARAMS, "C2",
          f"shim parameters differ from the contract table: "
          f"missing={sorted(set(EXPECT_PARAMS) - set(lp))} "
          f"extra={sorted(set(lp) - set(EXPECT_PARAMS))} "
          f"wrong={wrong}")

if nonempty(contract, "C3a"):
    for name, value in CONTRACT_VALUE.items():
        rows = [ln for ln in contract.split("\n") if f"`{name}`" in ln and ln.startswith("|")]
        ok = any(re.search(r"(?<![A-Za-z0-9_])" + re.escape(value) + r"(?![A-Za-z0-9_])", ln)
                 for ln in rows)
        check(bool(rows) and ok, f"C3.{name}",
              f"the contract does not carry {name} = {value} (rows found: {len(rows)})")

if nonempty(shim, "C4a"):
    check(not re.search(r"assign\s+tx_rst\b", shim), "C4",
          "the shim assigns tx_rst directly instead of through dcmac_usr_reset_gen")
    check(not re.search(r"always[_a-z]*\s*@[^;]*\btx_rst\s*<=", shim), "C4b",
          "the shim drives tx_rst from an always block")
    tx_rst_hits = re.findall(r"(?<![A-Za-z0-9_.])tx_rst(?![A-Za-z0-9_])", shim)
    check(len(tx_rst_hits) == 2, "C5",
          f"tx_rst appears {len(tx_rst_hits)} times, expected 2: the port declaration and the "
          f"u_usr_reset actual")
    mac_tx_rst_hits = re.findall(r"(?<![A-Za-z0-9_.])mac_tx_rst(?![A-Za-z0-9_])", shim)
    check(len(mac_tx_rst_hits) == 3, "C6",
          f"mac_tx_rst appears {len(mac_tx_rst_hits)} times, expected 3: the declaration, the u_mac "
          f"actual and the u_usr_reset actual")
    tready_hits = re.findall(r"m_rx_axis\.tready", shim)
    check(len(tready_hits) == 1, "C7",
          f"m_rx_axis.tready appears {len(tready_hits)} times, expected 1 inside the unused net")
    check(not re.search(r"assign\s+\w*(rst|reset)\w*\s*=", shim), "C8",
          "the shim drives a reset net of its own")

m = re.search(r"wire\s+unused_seam\s*=\s*\|\{(.*?)\};", shim, re.S)
if m is None:
    problems.append("C9: the shim has no unused_seam aggregate")
    checks += 1
else:
    names = [t.strip() for t in m.group(1).replace("\n", " ").split(",") if t.strip()]
    if nonempty(names, "C9a"):
        check(sorted(names) == sorted(EXPECT_UNUSED), "C9",
              f"unused_seam set differs from the contract: "
              f"missing={sorted(set(EXPECT_UNUSED) - set(names))} "
              f"extra={sorted(set(names) - set(EXPECT_UNUSED))}")

if nonempty(rgen, "C10a"):
    check(re.search(r"parameter\s+int\s+MODE\s*=\s*1\b", rgen) is not None, "C10",
          "dcmac_usr_reset_gen's default MODE is not 1")
    check(re.search(r"`define\s+DCMAC_ETH_USR_RESET_MODE\s+1\b", shim) is not None, "C11",
          "the shim's DCMAC_ETH_USR_RESET_MODE default is not 1")
    branches = re.findall(r"begin\s*:\s*(g_link_tracking|g_one_shot)(.*?)\n  end", rgen, re.S)
    if nonempty(branches, "C12a"):
        seen = {}
        for label, body in branches:
            seen[label] = body
        check(set(seen) == {"g_link_tracking", "g_one_shot"}, "C12",
              f"the two reset modes are not both present: {sorted(seen)}")
        check("mac_tx_rst" in seen.get("g_link_tracking", ""), "C13",
              "g_link_tracking does not read mac_tx_rst, so the control arm is not the control arm")
        check("mac_tx_rst" not in seen.get("g_one_shot", ""), "C14",
              "g_one_shot reads mac_tx_rst, so alignment can still reach tx_rst")

if nonempty(crsh, "C15a"):
    check("hdl/network/dcmac_eth/dcmac_axis_wrapper.sv" in crsh, "C15",
          "the build list does not add the shim")
    check("hdl/network/dcmac_eth/dcmac_usr_reset_gen.sv" in crsh, "C16",
          "the build list does not add dcmac_usr_reset_gen")
    stale = re.findall(r"hdl/network/dcmac/[A-Za-z0-9_./$()]+", crsh)
    check(not stale, "C17",
          f"the build list still references the replaced Coyote DCMAC sources: {sorted(set(stale))}")

XDC = os.path.join(COYOTE_HW, "constraints", "vp1552", "dcmac", "dcmac_bank202_qsfp0.xdc")
VENDORED_PHY = os.path.join(DCMAC_ETH, "nia_eth", "dcmac_phy_wrapper.sv")
FALLBACK_PHY = os.path.join(WORKSPACE, "repo", "nia-eth", "rtl", "dcmac_phy_wrapper.sv")

XDC_HIER_NAMES = [
    "i_dcmac_clk_wiz",
    "i_usr_clk_wiz",
    "dcmac_IBUFDS_GTE5_REFCLK0_gt0",
]

xdc = read(XDC)
xdc_active = "\n".join(re.sub(r"#.*$", "", ln) for ln in xdc.split("\n"))
phy_path = VENDORED_PHY if os.path.exists(VENDORED_PHY) else FALLBACK_PHY
phy = read(phy_path) if os.path.exists(phy_path) else ""
if nonempty(xdc_active.strip(), "C20a") and nonempty(phy, "C20b"):
    for name in XDC_HIER_NAMES:
        in_xdc = name in xdc_active
        in_phy = re.search(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])", phy) is not None
        check(in_xdc and in_phy, f"C20.{name}",
              f"the constraints file and the PHY disagree on this instance name: "
              f"in_xdc={in_xdc} in_phy={in_phy} phy={phy_path}")
    check("GTME5_QUAD" in xdc_active, "C21",
          "the constraints file no longer places the GT quad by reference name")

for path in (SHIM, RESET_GEN, os.path.join(HERE, "run_mutations.py"),
             os.path.join(HERE, "test_dcmac_usr_reset_gen.py"),
             os.path.join(HERE, "Makefile"), os.path.abspath(__file__)):
    text = read(path)
    if not text:
        continue
    bad = [(i + 1, ch) for i, line in enumerate(text.split("\n"))
           for ch in line if (ord(ch) < 0x20 and ch != "\t") or ord(ch) > 0x7E]
    check(not bad, f"C18.{os.path.basename(path)}",
          f"non-ASCII or control characters at {bad[:4]}")

for path in (SHIM, RESET_GEN):
    text = read(path)
    if not text:
        continue
    lines = text.split("\n")
    header = [i for i, ln in enumerate(lines) if ln.startswith("//")]
    allowed = set(range(0, 3))
    stray = [i + 1 for i in header if i not in allowed]
    check(not stray, f"C19.{os.path.basename(path)}",
          f"explanatory comments outside the license header at lines {stray}")

print(f"gate_shim_static: {checks} checks, {len(problems)} problems")
for p in problems:
    print(f"  BAD {p}")
print("GATE RESULT: " + ("PASS" if not problems else "FAIL"))
sys.exit(0 if not problems else 1)
