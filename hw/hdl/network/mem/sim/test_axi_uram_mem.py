# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from axi_bfm import (AxiChecker, AxiMaster, DataMover, GoldenMem,
                     ToeTxAppStatusHandler)

DB = 64                                          # 512 b / 8
ADDR_MAP = os.environ.get("ADDR_MAP", "flat")
N_SESSIONS = int(os.environ.get("N_SESSIONS", "16"))
WINDOW_BITS = int(os.environ.get("WINDOW_BITS", "18"))
PMTU = int(os.environ.get("PMTU_BYTES", "4096"))
PID_BITS = int(os.environ.get("PID_BITS", "6"))
OST_BITS = int(os.environ.get("RDMA_OST_BITS", "4"))
RDMA_SHIFT = int(os.environ.get("RDMA_SHIFT", "27"))

WINDOW = 1 << WINDOW_BITS
FLAT_SPAN = N_SESSIONS * WINDOW
SLOTS = 1 << (PID_BITS + OST_BITS)
SLOT_SPAN = SLOTS * PMTU
SPAN = SLOT_SPAN if ADDR_MAP == "rdma_slot" else FLAT_SPAN

CLK_NS = 4.0                                     # ACLK_F = 250 MHz, FindCoyoteHW.cmake:199

async def setup(dut, seed_extra=0):
    cocotb.start_soon(Clock(dut.aclk, CLK_NS, units="ns").start())
    dut.aresetn.value = 0
    for sig in ("s_axi_awvalid", "s_axi_wvalid", "s_axi_wlast", "s_axi_arvalid",
                "s_axi_bready", "s_axi_rready"):
        getattr(dut, sig).value = 0
    dut.s_axi_awburst.value = 1
    dut.s_axi_arburst.value = 1
    dut.s_axi_awsize.value = 6
    dut.s_axi_arsize.value = 6
    dut.s_axi_wstrb.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_awaddr.value = 0
    dut.s_axi_araddr.value = 0
    dut.s_axi_awlen.value = 0
    dut.s_axi_arlen.value = 0
    dut.s_axi_awid.value = 0
    dut.s_axi_arid.value = 0
    await ClockCycles(dut.aclk, 10)
    dut.aresetn.value = 1
    await ClockCycles(dut.aclk, 5)
    m = AxiMaster(dut)
    chk = AxiChecker()
    gold = GoldenMem(SPAN, DB)
    rng = random.Random(cocotb.RANDOM_SEED + seed_extra)
    m.rng = rng
    return m, chk, gold, rng

def rand_line(rng):
    return rng.getrandbits(512)

def slot_addr(pid, offs, byte_off=0, vfid=0):
    inner = (vfid << (PID_BITS + OST_BITS + 12)) | (pid << (OST_BITS + 12)) | (offs << 12)
    return (inner << RDMA_SHIFT) | byte_off

def dense(a):
    if ADDR_MAP != "rdma_slot":
        return a
    offs = (a >> RDMA_SHIFT + 12) & ((1 << OST_BITS) - 1)
    pid = (a >> (RDMA_SHIFT + 12 + OST_BITS)) & ((1 << PID_BITS) - 1)
    slot = (pid << OST_BITS) | offs
    return (slot << 12) | (a & 0xFFF)

def flat_only(dut):
    if ADDR_MAP != "flat":
        dut._log.info("SKIP: this test applies to ADDR_MAP=flat only")
        return False
    return True

def slot_only(dut):
    if ADDR_MAP != "rdma_slot":
        dut._log.info("SKIP: this test applies to ADDR_MAP=rdma_slot only")
        return False
    return True

@cocotb.test()
async def test_capacity_every_session_ring(dut):
    if not flat_only(dut):
        return
    m, chk, gold, rng = await setup(dut)
    addrs = []
    for s in range(N_SESSIONS):
        addrs.append(s * WINDOW)
        addrs.append(s * WINDOW + WINDOW - DB)
    pats = {}
    for i, a in enumerate(addrs):
        pats[a] = rand_line(rng)
        bid, bresp = await m.write_burst(a, [(pats[a], (1 << DB) - 1)], awid=i % 64)
        chk.check_write_resp(bid, bresp, i % 64, tag=f"cap_wr@{a:#x}")
    for i, a in enumerate(addrs):
        beats = await m.read_burst(a, 1, arid=i % 64)
        chk.check_read_resp(beats, i % 64, 1, tag=f"cap_rd@{a:#x}")
        assert beats[0][0] == pats[a], \
            f"M2: addr {a:#x} read {beats[0][0]:#x} expected {pats[a]:#x}"
    assert chk.ok(), chk.report()
    assert int(dut.oob_cnt.value) == 0, "M2: in-span accesses must not be counted OOB"
    dut._log.info(f"M2 OK: {len(addrs)} boundary lines over {N_SESSIONS} rings, span {SPAN} B")

@cocotb.test()
async def test_oob_not_aliased_and_counted(dut):
    if not flat_only(dut):
        return
    m, chk, gold, rng = await setup(dut)
    keep = {}
    for s in (0, 1):
        keep[s] = rand_line(rng)
        await m.write_burst(s * WINDOW, [(keep[s], (1 << DB) - 1)], awid=s)
    assert int(dut.oob_cnt.value) == 0
    for k, s in enumerate((N_SESSIONS, N_SESSIONS + 1)):
        bid, bresp = await m.write_burst(s * WINDOW, [(rand_line(rng), (1 << DB) - 1)],
                                        awid=k)
        chk.check_write_resp(bid, bresp, k, tag="oob_wr")     # M9: still OKAY
    for s in (0, 1):
        beats = await m.read_burst(s * WINDOW, 1, arid=s)
        assert beats[0][0] == keep[s], f"M3: session {s} was clobbered by an OOB write"
    assert int(dut.oob_err.value) == 1, "M3: oob_err must be sticky-set"
    assert int(dut.oob_cnt.value) == 2, f"M3: oob_cnt={int(dut.oob_cnt.value)}, expected 2"
    assert chk.ok(), chk.report()

@cocotb.test()
async def test_software_addr_offset(dut):
    if not flat_only(dut):
        return
    m, chk, gold, rng = await setup(dut)
    OFFS = WINDOW
    src_sess, dst_sess = 8, 9
    marker = rand_line(rng)
    await m.write_burst(src_sess * WINDOW, [(marker, (1 << DB) - 1)], awid=1)
    pat = rand_line(rng)
    await m.write_burst(src_sess * WINDOW + OFFS, [(pat, (1 << DB) - 1)], awid=3)
    beats = await m.read_burst(dst_sess * WINDOW, 1, arid=3)
    assert beats[0][0] == pat, "M4: offset was masked or mis-applied"
    b0 = await m.read_burst(src_sess * WINDOW, 1, arid=4)
    assert b0[0][0] == marker, "M4: the nominal session must be untouched"
    assert int(dut.oob_cnt.value) == 0
    dut._log.info("M4 OK: a non-zero offset shifts the access, it is not swallowed")

@cocotb.test()
async def test_axi_protocol_soak(dut):
    m, chk, gold, rng = await setup(dut)
    n_bursts = int(os.environ.get("SOAK_BURSTS", "2500"))
    total_beats = 0
    for i in range(n_bursts):
        nb = rng.randint(1, 64)
        if ADDR_MAP == "rdma_slot":
            nb = min(nb, PMTU // DB)
            base = slot_addr(rng.randrange(1 << PID_BITS), rng.randrange(1 << OST_BITS))
            maxline = PMTU // DB - nb
            a = base + rng.randint(0, max(0, maxline)) * DB
            if (a % 4096) + nb * DB > 4096:
                a = base
        else:
            page = rng.randrange(SPAN // 4096)
            maxline = 4096 // DB - nb
            a = page * 4096 + rng.randint(0, maxline) * DB
        aid = rng.randrange(64)
        beats = [(rand_line(rng), (1 << DB) - 1) for _ in range(nb)]
        bid, bresp = await m.write_burst(a, beats, awid=aid)
        chk.check_write_resp(bid, bresp, aid, tag=f"soak_wr#{i}")
        for k, (d, s) in enumerate(beats):
            gold.write_beat(dense(a) + k * DB, d, s)
        rbeats = await m.read_burst(a, nb, arid=aid)
        chk.check_read_resp(rbeats, aid, nb, tag=f"soak_rd#{i}")
        for k, (d, _i, _l, _r) in enumerate(rbeats):
            exp = gold.read_beat(dense(a) + k * DB)
            assert d == exp, f"M5 soak#{i} beat {k} @{a + k * DB:#x}: {d:#x} != {exp:#x}"
        total_beats += nb
    assert chk.ok(), chk.report()
    assert int(dut.proto_cnt.value) == 0, "M5: legal traffic must not raise proto_err"
    dut._log.info(f"M5 OK: {n_bursts} bursts / {total_beats} beats, 0 violations")

@cocotb.test()
async def test_byte_strobes_honoured(dut):
    m, chk, gold, rng = await setup(dut)
    base = 0 if ADDR_MAP == "flat" else slot_addr(1, 1)
    AA = int.from_bytes(b"\xAA" * DB, "little")
    for t in range(64):
        a = base + t * DB
        await m.write_burst(a, [(AA, (1 << DB) - 1)], awid=1)
        strb = 0 if t == 0 else rng.getrandbits(DB)
        newd = int.from_bytes(b"\x55" * DB, "little")
        await m.write_burst(a, [(newd, strb)], awid=2)
        beats = await m.read_burst(a, 1, arid=2)
        got = beats[0][0].to_bytes(DB, "little")
        for b in range(DB):
            want = 0x55 if (strb >> b) & 1 else 0xAA
            assert got[b] == want, \
                f"M6 t={t} byte {b}: got {got[b]:#02x} want {want:#02x} (strb={strb:#x})"
    dut._log.info("M6 OK: 64 strobe patterns incl. all-zero and non-contiguous")

@cocotb.test()
async def test_id_echo_and_ordering(dut):
    m, chk, gold, rng = await setup(dut)
    base = 0 if ADDR_MAP == "flat" else slot_addr(2, 2)
    ids = [1, 5, 9, 17, 33, 63, 0, 42]
    got = []
    done = [False]

    async def b_sink():
        dut.s_axi_bready.value = 1
        while not done[0] or len(got) < len(ids):
            await RisingEdge(dut.aclk)
            if dut.s_axi_bvalid.value and dut.s_axi_bready.value:
                got.append(int(dut.s_axi_bid.value))
        dut.s_axi_bready.value = 0

    sink = cocotb.start_soon(b_sink())
    for i, aid in enumerate(ids):
        await m.send_aw(base + i * DB, 0, awid=aid)
        await m.send_w(rand_line(rng), (1 << DB) - 1, True)
    done[0] = True
    await sink
    assert got == ids, f"M7: bid order {got} != awid order {ids}"
    for i, aid in enumerate(ids):
        beats = await m.read_burst(base + i * DB, 2, arid=aid)
        chk.check_read_resp(beats, aid, 2, tag=f"idr#{aid}")
    assert chk.ok(), chk.report()
    dut._log.info("M7 OK: 8 distinct IDs echoed in order over a 6-bit space, "
                  "with up to 4 write responses outstanding")

@cocotb.test()
async def test_wlast_early_flagged_no_corruption(dut):
    m, chk, gold, rng = await setup(dut)
    base = 0 if ADDR_MAP == "flat" else slot_addr(3, 3)
    guard = base + 8 * DB
    gpat = rand_line(rng)
    await m.write_burst(guard, [(gpat, (1 << DB) - 1)], awid=0)
    assert int(dut.proto_cnt.value) == 0, "M8: precondition — no proto_err yet"
    beats = [(rand_line(rng), (1 << DB) - 1) for _ in range(4)]
    await m.write_burst(base, beats, awid=7, force_last_at=2)      # wlast on beat 2 of 4
    await ClockCycles(dut.aclk, 5)          # proto_err is registered 2 cycles behind wlast
    assert int(dut.proto_err.value) == 1, "M8: early wlast must set proto_err"
    rb = await m.read_burst(guard, 1, arid=0)
    assert rb[0][0] == gpat, "M8: storage beyond the truncated burst was corrupted"
    dut._log.info(f"M8 OK: proto_cnt={int(dut.proto_cnt.value)}, guard line intact")

@cocotb.test()
async def test_responses_always_okay(dut):
    m, chk, gold, rng = await setup(dut)
    cases = []
    if ADDR_MAP == "flat":
        cases += [(0, 1, 1), (SPAN - DB, 1, 1), (SPAN, 1, 1),
                  (SPAN + 12345 * DB, 4, 1), ((1 << 40), 1, 1)]
    else:
        cases += [(slot_addr(0, 0), 1, 1), (slot_addr(63, 15), 1, 1),
                  (slot_addr(0, 0, 0, 1), 1, 1), ((1 << 55), 1, 1)]
    for a, nb, _ in cases:
        bid, bresp = await m.write_burst(a, [(rand_line(rng), (1 << DB) - 1)] * nb, awid=5)
        assert bresp == 0, f"M9: bresp={bresp} at {a:#x}"
        beats = await m.read_burst(a, nb, arid=5)
        for d, i, l, r in beats:
            assert r == 0, f"M9: rresp={r} at {a:#x}"
    bid, bresp = await m.write_burst(0, [(rand_line(rng), (1 << DB) - 1)], awid=6, burst=2)
    assert bresp == 0, "M9: a WRAP burst must still respond OKAY"
    assert int(dut.proto_err.value) == 1, "M9/M5: a WRAP burst must be flagged"
    dut._log.info(f"M9 OK: {len(cases) + 1} pathological transactions, all OKAY")

@cocotb.test()
async def test_backpressure_and_stalls(dut):
    m, chk, gold, rng = await setup(dut)
    base = 0 if ADDR_MAP == "flat" else slot_addr(4, 4)
    for i in range(60):
        nb = rng.randint(1, 16)
        a = base + rng.randint(0, 32) * DB
        aid = rng.randrange(64)
        wgap = rng.randint(0, 16)
        bdel = rng.choice([0, 1, 8, 64])
        rdel = rng.choice([0, 1, 8, 64])
        beats = [(rand_line(rng), (1 << DB) - 1) for _ in range(nb)]
        bid, bresp = await m.write_burst(a, beats, awid=aid, wgap=wgap, bdelay=bdel)
        chk.check_write_resp(bid, bresp, aid, tag=f"bp_wr#{i}")
        for k, (d, s) in enumerate(beats):
            gold.write_beat(dense(a) + k * DB, d, s)
        rb = await m.read_burst(a, nb, arid=aid, rdelay=rdel)
        chk.check_read_resp(rb, aid, nb, tag=f"bp_rd#{i}")
        for k, (d, _i, _l, _r) in enumerate(rb):
            assert d == gold.read_beat(dense(a) + k * DB), f"M10 #{i} beat {k} mismatch"
    assert chk.ok(), chk.report()
    dut._log.info("M10 OK: 60 bursts with gaps up to 16 and B/R stalls up to 64 cycles")

@cocotb.test()
async def test_no_implicit_ring_wrap(dut):
    if not flat_only(dut):
        return
    m, chk, gold, rng = await setup(dut)
    a = WINDOW - 2 * DB                    # last two lines of session 0
    pats = [rand_line(rng) for _ in range(4)]
    assert int(dut.xsess_cnt.value) == 0
    await m.write_burst(a, [(p, (1 << DB) - 1) for p in pats], awid=1)
    assert int(dut.xsess_err.value) == 1, "M12: the boundary crossing must be recorded"
    b0 = await m.read_burst(0, 1, arid=2)
    assert b0[0][0] != pats[2], "M12: the burst was silently wrapped to the ring base"
    b1 = await m.read_burst(WINDOW, 2, arid=3)
    assert b1[0][0] == pats[2] and b1[1][0] == pats[3], \
        "M12: the overflow did not land in the next session's space"
    dut._log.info(f"M12 OK: xsess_cnt={int(dut.xsess_cnt.value)}, no implicit wrap")

@cocotb.test()
async def test_address_zero_is_ordinary(dut):
    m, chk, gold, rng = await setup(dut)
    a = 0 if ADDR_MAP == "flat" else slot_addr(0, 0)
    pat = rand_line(rng)
    bid, bresp = await m.write_burst(a, [(pat, (1 << DB) - 1)], awid=0)
    assert bresp == 0
    beats = await m.read_burst(a, 1, arid=0)
    assert beats[0][0] == pat, "M13: address 0 must be byte-exact"
    assert int(dut.oob_cnt.value) == 0, "M13: address 0 is in-span, not OOB"
    dut._log.info("M13 OK: address 0 read/write byte-exact")

@cocotb.test()
async def test_throughput_simultaneous_rw(dut):
    m, chk, gold, rng = await setup(dut)
    d = dut
    CYCLES = int(os.environ.get("TPUT_CYCLES", "20000"))
    NB = 64                                  # 64 beats x 64 B = 4 KiB
    base = 0 if ADDR_MAP == "flat" else slot_addr(5, 5)
    pages = (SPAN // 4096) if ADDR_MAP == "flat" else 1

    wbeats = [0]
    rbeats = [0]
    stop = [False]

    async def wr_driver():
        p = 0
        while not stop[0]:
            a = (base + (p % pages) * 4096) if ADDR_MAP == "flat" else base
            p += 1
            d.s_axi_awaddr.value = a
            d.s_axi_awlen.value = NB - 1
            d.s_axi_awsize.value = 6
            d.s_axi_awburst.value = 1
            d.s_axi_awid.value = 0
            d.s_axi_awvalid.value = 1
            while True:
                await RisingEdge(d.aclk)
                if stop[0]:
                    return
                if d.s_axi_awready.value:
                    break
            d.s_axi_awvalid.value = 0
            k = 0
            d.s_axi_wstrb.value = (1 << DB) - 1
            while k < NB:
                d.s_axi_wdata.value = k
                d.s_axi_wlast.value = 1 if k == NB - 1 else 0
                d.s_axi_wvalid.value = 1
                await RisingEdge(d.aclk)
                if stop[0]:
                    return
                if d.s_axi_wready.value:
                    k += 1
            d.s_axi_wvalid.value = 0
            d.s_axi_wlast.value = 0

    async def b_sink():
        d.s_axi_bready.value = 1
        while not stop[0]:
            await RisingEdge(d.aclk)

    async def rd_driver():
        p = 0
        while not stop[0]:
            a = (base + (p % pages) * 4096) if ADDR_MAP == "flat" else base
            p += 1
            d.s_axi_araddr.value = a
            d.s_axi_arlen.value = NB - 1
            d.s_axi_arsize.value = 6
            d.s_axi_arburst.value = 1
            d.s_axi_arid.value = 0
            d.s_axi_arvalid.value = 1
            while True:
                await RisingEdge(d.aclk)
                if stop[0]:
                    return
                if d.s_axi_arready.value:
                    break
            d.s_axi_arvalid.value = 0

    async def r_sink():
        d.s_axi_rready.value = 1
        while not stop[0]:
            await RisingEdge(d.aclk)

    async def counter():
        for _ in range(CYCLES):
            await RisingEdge(d.aclk)
            if d.s_axi_wvalid.value and d.s_axi_wready.value:
                wbeats[0] += 1
            if d.s_axi_rvalid.value and d.s_axi_rready.value:
                rbeats[0] += 1
        stop[0] = True

    cocotb.start_soon(wr_driver())
    cocotb.start_soon(rd_driver())
    cocotb.start_soon(b_sink())
    cocotb.start_soon(r_sink())
    await counter()
    await ClockCycles(d.aclk, 20)

    wbc = wbeats[0] * DB / CYCLES
    rbc = rbeats[0] * DB / CYCLES
    dut._log.info(f"M14: write {wbc:.2f} B/cycle ({wbc * 0.25:.2f} GB/s @250 MHz), "
                  f"read {rbc:.2f} B/cycle ({rbc * 0.25:.2f} GB/s)")
    assert wbc >= 50.0, f"M14: write {wbc:.2f} B/cycle < 50 (12.5 GB/s)"
    assert rbc >= 50.0, f"M14: read {rbc:.2f} B/cycle < 50 (12.5 GB/s)"

@cocotb.test()
async def test_read_after_write_coherence(dut):
    m, chk, gold, rng = await setup(dut)
    n = int(os.environ.get("RAW_N", "400"))
    base = 0 if ADDR_MAP == "flat" else slot_addr(6, 6)
    lines = (SPAN // DB) if ADDR_MAP == "flat" else (PMTU // DB)
    for i in range(n):
        a = base + rng.randrange(min(lines, 4096)) * DB
        pat = rand_line(rng)
        bid, bresp = await m.write_burst(a, [(pat, (1 << DB) - 1)], awid=i % 64)
        beats = await m.read_burst(a, 1, arid=i % 64)
        assert beats[0][0] == pat, \
            f"M15 #{i} @{a:#x}: read {beats[0][0]:#x} != just-written {pat:#x}"
    dut._log.info(f"M15 OK: {n} back-to-back write/bvalid/read triples")

@cocotb.test()
async def test_reference_dummy_memory_differential(dut):
    if not flat_only(dut):
        return
    here = os.path.dirname(os.path.abspath(__file__))
    tr = os.path.join(here, "..", "ref", "ref_trace.txt")
    gd = os.path.join(here, "..", "ref", "ref_golden.txt")
    if not (os.path.exists(tr) and os.path.exists(gd)):
        msg = ("M16: ref_trace.txt / ref_golden.txt absent — run ref/build_ref.sh first. "
               "This is a FAILURE, not a skip: the Rule-2 gate is the reference's own "
               "model, and a suite that quietly passes without it is not evidence. Set "
               "M16_ALLOW_SKIP=1 only to iterate locally.")
        if os.environ.get("M16_ALLOW_SKIP") == "1":
            dut._log.warning(msg)
            return
        assert False, msg
    m, chk, gold, rng = await setup(dut)
    dm = DataMover(m, chk)
    golden = {}
    for ln in open(gd):
        ln = ln.strip()
        if ln:
            i, hexs = ln.split()
            golden[int(i)] = bytes.fromhex(hexs)
    nrd = 0
    for ln in open(tr):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        f = ln.split()
        if f[0] == "W":
            await dm.write_cmd(int(f[1]), bytes.fromhex(f[2]))
        elif f[0] == "R":
            idx, saddr, nbytes = int(f[1]), int(f[2]), int(f[3])
            got = await dm.read_cmd(saddr, nbytes)
            exp = golden[idx]
            assert got == exp, (f"M16 read#{idx} @{saddr:#x} len {nbytes}: "
                                f"shim {got[:32].hex()}... != dummyMemory {exp[:32].hex()}...")
            nrd += 1
    assert chk.ok(), chk.report()
    assert len(dm.status) > 0
    dut._log.info(f"M16 OK: {nrd} reads byte-exact against the compiled reference "
                  f"dummyMemory, {len(dm.status)} write statuses")

@cocotb.test()
async def test_datamover_status_one_per_command(dut):
    if not flat_only(dut):
        return
    m, chk, gold, rng = await setup(dut)
    dm = DataMover(m, chk)
    handler = ToeTxAppStatusHandler(WINDOW)
    events, ncmd, nwrapped = [], 0, 0
    for i in range(24):
        sess = rng.randrange(N_SESSIONS)
        wrapped = (i % 4 == 3)
        length = rng.randrange(64, 1024)
        if wrapped:
            off = WINDOW - length // 2                     # straddles the ring end
        else:
            off = rng.randrange(0, WINDOW - length)
        events.append((off, length))
        payload = bytes(rng.getrandbits(8) for _ in range(length))
        if wrapped:
            nwrapped += 1
            n1 = WINDOW - off
            await dm.write_cmd(sess * WINDOW + off, payload[:n1], awid=1)
            await dm.write_cmd(sess * WINDOW + 0, payload[n1:], awid=1)
            ncmd += 2
        else:
            await dm.write_cmd(sess * WINDOW + off, payload, awid=1)
            ncmd += 1
        await dm.read_cmd(sess * WINDOW + off, min(length, WINDOW - off), arid=1)
    assert len(dm.status) == ncmd, \
        f"M17: {len(dm.status)} statuses for {ncmd} commands"
    assert all(s == 1 for s in dm.status), "M17: every status must be okay=1"
    ev, st = list(events), list(dm.status)
    for _ in range(4000):
        handler.step(ev, st)
    assert handler.pushes == len(events), \
        f"M17: handler pushed {handler.pushes} of {len(events)} events"
    assert handler.stalled_cycles == 0, "M17: the handler must never stall on this trace"
    assert chk.ok(), chk.report()
    dut._log.info(f"M17 OK: {ncmd} cmds ({nwrapped} wrapped => 2 statuses each), "
                  f"{len(dm.status)} statuses, {handler.pushes} pushes")

@cocotb.test()
async def test_datamover_status_suppressed_stalls_session_forever(dut):
    if not flat_only(dut):
        return
    m, chk, gold, rng = await setup(dut)

    dm = DataMover(m, chk)
    handler = ToeTxAppStatusHandler(WINDOW)
    events = []
    for i in range(3):
        off, length = i * 4096, 256
        events.append((off, length))
        if i == 1:
            dm.drop_next_status = True          # the shim/datamover never reported
        await dm.write_cmd(off, bytes(rng.getrandbits(8) for _ in range(length)), awid=1)
    assert len(dm.status) == 2, f"M17neg: expected 2 statuses for 3 cmds, got {len(dm.status)}"
    ev, st = list(events), list(dm.status)
    for _ in range(5000):
        handler.step(ev, st)
    assert handler.pushes == 2, f"M17neg(a): pushes={handler.pushes}, expected 2"
    assert handler.state == handler.READ_STATUS_1, "M17neg(a): must be stuck awaiting status"
    assert handler.stalled_cycles > 4000, "M17neg(a): the stall must be unbounded"
    stall_a = handler.stalled_cycles

    dm2 = DataMover(m, chk)
    h2 = ToeTxAppStatusHandler(WINDOW)
    ev2 = [(0, 256), (4096, 256)]
    dm2.fail_next_status = True
    await dm2.write_cmd(0, bytes(256), awid=2)
    await dm2.write_cmd(4096, bytes(256), awid=2)
    assert dm2.status == [0, 1], f"M17neg(b): statuses {dm2.status}"
    st2 = list(dm2.status)
    for _ in range(5000):
        h2.step(ev2, st2)
    assert h2.pushes == 1, (f"M17neg(b): pushes={h2.pushes}, expected exactly 1 — the "
                            "failed command's pointer is released by the NEXT command's "
                            "status (tx_app_interface.cpp:96-112, no else)")
    assert h2.state == h2.READ_STATUS_1, \
        "M17neg(b): the second command must be left waiting for a status that never comes"
    assert h2.stalled_cycles > 4000, "M17neg(b): that wait must be unbounded"

    dut._log.info(f"M17neg OK: (a) suppressed status => stalled {stall_a} cycles after "
                  f"2/3 pushes; (b) okay=0 => 1 push (the WRONG one) and "
                  f"{h2.stalled_cycles} stalled cycles thereafter. Shim responses stayed "
                  f"OKAY throughout — which is exactly why M9 exists.")
    assert chk.ok(), chk.report()

@cocotb.test()
async def test_rdma_slot_address_compression(dut):
    if not slot_only(dut):
        return
    m, chk, gold, rng = await setup(dut)
    seen = {}
    for pid in range(1 << PID_BITS):
        for offs in range(1 << OST_BITS):
            a = slot_addr(pid, offs)
            pat = ((pid << 8) | offs) * 0x0001000100010001
            await m.write_burst(a, [(pat, (1 << DB) - 1)], awid=1)
            key = (pid, offs)
            assert key not in seen
            seen[key] = pat
    collisions = 0
    for (pid, offs), pat in seen.items():
        beats = await m.read_burst(slot_addr(pid, offs), 1, arid=1)
        if beats[0][0] != pat:
            collisions += 1
    assert collisions == 0, f"M18: {collisions} of {len(seen)} slots collided"
    for pid, offs in [(0, 0), (63, 15), (17, 9)]:
        beats = await m.read_burst(slot_addr(pid, offs), 1, arid=2)
        assert beats[0][0] == seen[(pid, offs)], "M18: mapping is not stable"
    assert int(dut.oob_cnt.value) == 0, "M18: all enumerated slots must be in-span"
    dut._log.info(f"M18 OK: {len(seen)} distinct (pid,offs) slots, 0 collisions, stable")

@cocotb.test()
async def test_rdma_slot_size_bound(dut):
    if not slot_only(dut):
        return
    m, chk, gold, rng = await setup(dut)
    NBL = PMTU // DB
    a = slot_addr(10, 3)
    nxt = slot_addr(10, 4)
    npat = rand_line(rng)
    await m.write_burst(nxt, [(npat, (1 << DB) - 1)], awid=0)
    pats = [rand_line(rng) for _ in range(NBL)]
    bid, bresp = await m.write_burst(a, [(p, (1 << DB) - 1) for p in pats], awid=1)
    assert bresp == 0
    rb = await m.read_burst(a, NBL, arid=1)
    for k in range(NBL):
        assert rb[k][0] == pats[k], f"M19: exact-PMTU burst beat {k} mismatch"
    assert int(dut.slot_ovf_cnt.value) == 0, "M19: an exact-PMTU burst is not an overflow"
    over = [(rand_line(rng), (1 << DB) - 1) for _ in range(NBL + 1)]
    await m.write_burst(a, over, awid=2)
    assert int(dut.slot_ovf_err.value) == 1, "M19: an over-length burst must be flagged"
    rn = await m.read_burst(nxt, 1, arid=3)
    assert rn[0][0] == npat, "M19: the adjacent slot was corrupted"
    dut._log.info(f"M19 OK: slot_ovf_cnt={int(dut.slot_ovf_cnt.value)}, neighbour intact")
