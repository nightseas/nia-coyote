# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

import os
import random
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer, with_timeout

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamSink, AxiStreamFrame

from seg_bfm import SegmentedSource, SegmentedSink

N_SEG = int(os.environ.get("N_SEG", "2"))
SEG_W = int(os.environ.get("SEG_W", "128"))
NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))

USR_MHZ = float(os.environ.get("USR_MHZ", "250"))
SEG_PERIOD_NS = 2.56                        # 390.625 MHz — DCMAC 100GAUI-1 client
USR_PERIOD_NS = round(1000.0 / USR_MHZ * 500) / 500

S_IDLE, S_GT_LOCKED, S_WAIT_ALIGN, S_XFER, S_RX_RESET = 0, 1, 2, 3, 4

EDGE_SIZES = [1, 2, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129,
              511, 512, 513, 1500, 1518]

def _rand_frame(n):
    return bytes(random.randint(0, 255) for _ in range(n))

def _start_clocks(dut):
    cocotb.start_soon(Clock(dut.seg_clk, SEG_PERIOD_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.usr_clk, USR_PERIOD_NS, units="ns").start())

async def _reset(dut, aligned=0):
    dut.seg_rstn.value = 0
    dut.usr_rstn.value = 0
    dut.stat_rx_aligned.value = aligned
    dut.rx_datapath_reset_req.value = 0
    dut.tx_datapath_reset_req.value = 0
    dut.m_rx_axis_tready.value = 1
    dut.tx_seg_ready.value = 1
    dut.s_tx_axis_tdata.value = 0
    dut.s_tx_axis_tkeep.value = 0
    dut.s_tx_axis_tvalid.value = 0
    dut.s_tx_axis_tlast.value = 0
    dut.rx_seg_valid.value = 0
    dut.rx_seg_dat.value = 0
    dut.rx_seg_ena.value = 0
    dut.rx_seg_sop.value = 0
    dut.rx_seg_eop.value = 0
    dut.rx_seg_err.value = 0
    dut.rx_seg_mty.value = 0
    await ClockCycles(dut.seg_clk, 8)
    await ClockCycles(dut.usr_clk, 8)
    dut.seg_rstn.value = 1
    dut.usr_rstn.value = 1
    await ClockCycles(dut.seg_clk, 4)

async def _bringup(dut):
    dut.stat_rx_aligned.value = 1
    for _ in range(200):
        await RisingEdge(dut.seg_clk)
        if int(dut.ctl_tx_enable.value) == 1:
            break
    assert int(dut.ctl_tx_enable.value) == 1, \
        f"FSM never reached XFER: state={int(dut.fsm_state.value)}"
    await ClockCycles(dut.usr_clk, 8)

def _sink_frame_bytes(rx):
    if rx.tkeep is None:
        return bytes(rx.tdata)
    return bytes(b for b, k in zip(rx.tdata, rx.tkeep) if k)

@cocotb.test()
async def test_rx_byte_exact(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)
    await src.idle_cycles(8)

    sizes = EDGE_SIZES + [random.randint(1, 1518) for _ in range(40)]
    frames = [_rand_frame(n) for n in sizes]

    for f in frames:
        await src.send(f)
        await src.idle_cycles(random.randint(1, 4))     # >= 1 idle beat = IPG

    await ClockCycles(dut.usr_clk, 400)

    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))

    assert int(dut.rx_overflow.value) == 0, "W5: rx_overflow raised with a ready sink"
    assert len(got) == len(frames), (
        f"W3: RX frame count {len(got)} != {len(frames)}; "
        f"sent={[len(f) for f in frames][:12]}... got={[len(g) for g in got][:12]}...")
    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act, (f"W3: RX frame {i} (len exp {len(exp)} / act {len(act)}) mismatch\n"
                            f"  exp={exp.hex()}\n  act={act.hex()}")
    dut._log.info(f"W3/W5/W11 RX byte-exact PASS over {len(frames)} frames "
                  f"(seg {1000/SEG_PERIOD_NS:.3f} MHz -> usr {1000/USR_PERIOD_NS:.3f} MHz)")

@cocotb.test()
async def test_tx_byte_exact(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    source = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_tx_axis"), dut.usr_clk,
                             dut.usr_rstn, reset_active_level=False)
    source.log.setLevel(logging.WARNING)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    sizes = EDGE_SIZES + [random.randint(1, 1518) for _ in range(40)]
    frames = [_rand_frame(n) for n in sizes]

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f))
        await source.wait()
    cocotb.start_soon(drive())

    got = []
    for _ in range(len(frames)):
        data, err = await with_timeout(sink.recv(), 200, "us")
        got.append(data)

    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act, (f"W4: TX frame {i} (len exp {len(exp)} / act {len(act)}) mismatch\n"
                            f"  exp={exp.hex()}\n  act={act.hex()}")
    dut._log.info(f"W4/W11 TX byte-exact PASS over {len(frames)} frames "
                  f"(usr {1000/USR_PERIOD_NS:.3f} MHz -> seg {1000/SEG_PERIOD_NS:.3f} MHz)")

@cocotb.test()
async def test_tx_backpressure(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    source = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_tx_axis"), dut.usr_clk,
                             dut.usr_rstn, reset_active_level=False)
    source.log.setLevel(logging.WARNING)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    async def backpressure():
        while True:
            dut.tx_seg_ready.value = 1 if random.random() < 0.6 else 0
            await RisingEdge(dut.seg_clk)
    cocotb.start_soon(backpressure())

    frames = [_rand_frame(n) for n in ([1, 16, 32, 33, 64, 65, 1518]
                                       + [random.randint(1, 600) for _ in range(25)])]

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f))
        await source.wait()
    cocotb.start_soon(drive())

    got = []
    for _ in range(len(frames)):
        data, err = await with_timeout(sink.recv(), 500, "us")
        got.append(data)

    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act, f"W6: TX(bp) frame {i} mismatch exp={exp.hex()} act={act.hex()}"
    dut._log.info(f"W6 TX back-pressure byte-exact PASS over {len(frames)} frames")

@cocotb.test()
async def test_tx_gated_before_enable(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)          # link NOT aligned -> FSM must not enable TX

    source = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_tx_axis"), dut.usr_clk,
                             dut.usr_rstn, reset_active_level=False)
    source.log.setLevel(logging.WARNING)

    async def drive():
        for _ in range(6):
            await source.send(AxiStreamFrame(tdata=_rand_frame(128)))
    cocotb.start_soon(drive())

    beats = 0
    for _ in range(400):
        await RisingEdge(dut.seg_clk)
        if int(dut.tx_seg_valid.value) and int(dut.tx_seg_ena.value):
            beats += 1
    assert int(dut.ctl_tx_enable.value) == 0, "W10: ctl_tx_enable set while unaligned"
    assert beats == 0, f"W10: {beats} segmented TX beats emitted before ctl_tx_enable"

    await _bringup(dut)
    seen = 0
    for _ in range(600):
        await RisingEdge(dut.seg_clk)
        if int(dut.tx_seg_valid.value) and int(dut.tx_seg_ready.value):
            seen += 1
            if seen > 4:
                break
    assert seen > 4, "W10: TX did not resume after alignment (gate dropped data?)"
    dut._log.info("W10 TX gating PASS (0 beats before enable, flows after)")

@cocotb.test()
async def test_rx_gated_before_align(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)

    for _ in range(4):
        await src.send(_rand_frame(200))          # garbage arriving while unaligned
        await src.idle_cycles(2)
    await ClockCycles(dut.usr_clk, 200)
    assert sink.empty(), "W16: RX data forwarded to the stack before alignment"

    await _bringup(dut)
    good = _rand_frame(300)
    await src.send(good)
    await src.idle_cycles(4)
    await ClockCycles(dut.usr_clk, 200)
    assert not sink.empty(), "W16: RX stopped forwarding after alignment"
    assert _sink_frame_bytes(sink.recv_nowait()) == good, "W16: first post-align frame corrupt"
    dut._log.info("W16 RX gating PASS (pre-align dropped, post-align byte-exact)")

@cocotb.test()
async def test_bringup_sequence(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    assert int(dut.tx_rst.value) == 1, "W7: tx_rst not asserted out of reset"

    await ClockCycles(dut.seg_clk, 20)
    assert int(dut.ctl_tx_send_lfi.value) == 1 and int(dut.ctl_tx_send_rfi.value) == 1, \
        "W9: LFI/RFI not signalled while unaligned"
    assert int(dut.ctl_tx_enable.value) == 0, "W9: TX enabled while unaligned"
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN, \
        f"W8: FSM should wait for alignment, state={int(dut.fsm_state.value)}"
    assert int(dut.ctl_rx_enable.value) == 1, "W8: ctl_rx_enable not set in WAIT_ALIGN"
    assert int(dut.ctl_rx_force_resync.value) == 0, "W8: force_resync set unrequested"
    assert int(dut.tx_rst.value) == 1, "W7: tx_rst deasserted before alignment"

    await _bringup(dut)
    assert int(dut.fsm_state.value) == S_XFER
    assert int(dut.ctl_tx_send_lfi.value) == 0 and int(dut.ctl_tx_send_rfi.value) == 0, \
        "W9: LFI/RFI still asserted after alignment"
    assert int(dut.tx_rst.value) == 0, "W7: tx_rst not released after alignment"
    dut._log.info("W7/W8/W9 bring-up sequence PASS")

@cocotb.test()
async def test_align_loss_recovery(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)

    f0 = _rand_frame(256)
    await src.send(f0)
    await src.idle_cycles(4)

    dut.stat_rx_aligned.value = 0
    rx_rst_pulses = 0
    tx_rst_req_seen = 0
    saw_lfi = 0
    for _ in range(120):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value):
            rx_rst_pulses += 1
        if int(dut.tx_datapath_reset.value):
            tx_rst_req_seen += 1
        if int(dut.ctl_tx_send_lfi.value):
            saw_lfi += 1

    assert rx_rst_pulses > 0, "W14: no RX-only datapath reset requested on re-align"
    assert tx_rst_req_seen == 0, \
        "W14: TX datapath reset asserted by an RX re-align (the vendor exdes defect)"
    assert saw_lfi > 0, "W9: LFI not re-asserted after alignment loss"
    assert int(dut.ctl_tx_enable.value) == 0, "W9: TX still enabled after alignment loss"
    assert int(dut.tx_rst.value) == 1, "W7: tx_rst not re-asserted after alignment loss"

    await _bringup(dut)
    f1 = _rand_frame(512)
    await src.send(f1)
    await src.idle_cycles(4)
    await ClockCycles(dut.usr_clk, 300)
    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))
    assert f1 in got, f"W8/W9: no byte-exact frame after re-align (got {[len(g) for g in got]})"
    dut._log.info(f"W8/W9/W14 re-align PASS (rx-only reset pulses={rx_rst_pulses}, "
                  f"tx reset requests={tx_rst_req_seen})")

@cocotb.test()
async def test_reset_midframe(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)

    dut.rx_seg_valid.value = 1
    dut.rx_seg_dat.value = int.from_bytes(_rand_frame(32), "little")
    dut.rx_seg_ena.value = (1 << N_SEG) - 1
    dut.rx_seg_sop.value = 1
    dut.rx_seg_eop.value = 0
    dut.rx_seg_mty.value = 0
    await RisingEdge(dut.seg_clk)
    dut.rx_seg_valid.value = 0
    dut.rx_seg_sop.value = 0
    await ClockCycles(dut.seg_clk, 4)

    dut.seg_rstn.value = 0
    dut.usr_rstn.value = 0
    await ClockCycles(dut.seg_clk, 6)
    await ClockCycles(dut.usr_clk, 6)
    dut.seg_rstn.value = 1
    dut.usr_rstn.value = 1
    await ClockCycles(dut.seg_clk, 4)
    await _bringup(dut)

    frames = [_rand_frame(n) for n in (64, 100, 1518)]
    for f in frames:
        await src.send(f)
        await src.idle_cycles(3)
    await ClockCycles(dut.usr_clk, 400)

    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))
    assert got == frames, (f"W12: post-reset traffic not byte-exact / fused frame present: "
                           f"sent={[len(f) for f in frames]} got={[len(g) for g in got]}")
    dut._log.info("W12 mid-frame reset PASS (partial frame discarded, recovery byte-exact)")

@cocotb.test()
async def test_short_frames_no_pad(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    source = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_tx_axis"), dut.usr_clk,
                             dut.usr_rstn, reset_active_level=False)
    source.log.setLevel(logging.WARNING)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    shorts = [1, 2, 7, 14, 32, 59, 60, 61]
    frames = [_rand_frame(n) for n in shorts]

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f))
        await source.wait()
    cocotb.start_soon(drive())

    for i, exp in enumerate(frames):
        data, err = await with_timeout(sink.recv(), 200, "us")
        assert len(data) == len(exp), \
            f"W13: frame {i} length changed {len(exp)} -> {len(data)} (wrapper padded/truncated)"
        assert data == exp, f"W13: frame {i} not byte-exact"
    dut._log.info(f"W13 no-pad PASS for lengths {shorts}")

@cocotb.test()
async def test_rx_overflow_sticky(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    dut.m_rx_axis_tready.value = 0          # stall the whole usr side

    assert int(dut.rx_overflow.value) == 0, "W5: rx_overflow sticky before any traffic"
    for _ in range(80):                      # >> FIFO depth
        await src.send(_rand_frame(1518))
    await ClockCycles(dut.seg_clk, 20)

    assert int(dut.rx_overflow.value) == 1, \
        "W5: RX data was lost without raising rx_overflow (silent loss)"
    dut._log.info("W5 overflow flag PASS (loss is flagged, not silent)")

@cocotb.test()
async def test_tx_gapless(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    source = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_tx_axis"), dut.usr_clk,
                             dut.usr_rstn, reset_active_level=False)
    source.log.setLevel(logging.WARNING)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    violations = []

    async def monitor():
        in_frame = False
        cyc = 0
        legal_ena = {(1 << (k + 1)) - 1 for k in range(N_SEG)}      # 0b01, 0b11, ...
        while True:
            await RisingEdge(dut.seg_clk)
            cyc += 1
            v = int(dut.tx_seg_valid.value)
            r = int(dut.tx_seg_ready.value)
            ena = int(dut.tx_seg_ena.value)
            eop = int(dut.tx_seg_eop.value)
            if in_frame and not v:
                violations.append(f"cycle {cyc}: tvalid dropped mid-frame")
                in_frame = False
            if v and ena not in legal_ena:
                violations.append(f"cycle {cyc}: interior ena gap, ena={ena:#b}")
            if v and r:
                if eop:
                    in_frame = False
                elif ena:
                    in_frame = True

    cocotb.start_soon(monitor())

    async def backpressure():
        while True:
            if random.random() < 0.25:
                dut.tx_seg_ready.value = 0
                await ClockCycles(dut.seg_clk, random.randint(1, 6))
            dut.tx_seg_ready.value = 1
            await ClockCycles(dut.seg_clk, random.randint(1, 8))
    cocotb.start_soon(backpressure())

    frames = [_rand_frame(n) for n in ([64, 65, 128, 200, 512, 513, 1518]
                                       + [random.randint(64, 1518) for _ in range(15)])]

    def pause_gen():
        while True:
            for _ in range(random.randint(1, 6)):
                yield False
            for _ in range(random.randint(1, 16)):
                yield True
    source.set_pause_generator(pause_gen())

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f))
            await ClockCycles(dut.usr_clk, random.randint(1, 16))
        await source.wait()
    cocotb.start_soon(drive())

    got = []
    for _ in range(len(frames)):
        data, err = await with_timeout(sink.recv(), 1000, "us")
        got.append(data)

    assert not violations, f"W7 violated ({len(violations)}): {violations[:6]}"
    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act, f"W7: frame {i} not byte-exact under gaps"
    dut._log.info(f"W7 gapless TX PASS over {len(frames)} frames, 0 violations "
                  f"(usr {USR_MHZ} MHz)")

@cocotb.test()
async def test_rx_err_frame_dropped(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)
    await src.idle_cycles(8)

    good = [_rand_frame(n) for n in (64, 300, 1518, 65)]
    bad = [_rand_frame(n) for n in (128, 700)]

    order = [(good[0], False), (bad[0], True), (good[1], False),
             (bad[1], True), (good[2], False), (good[3], False)]
    for f, err in order:
        await src.send(f, err=err)
        await src.idle_cycles(2)
    await ClockCycles(dut.usr_clk, 600)

    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))

    expect = [f for f, err in order if not err]
    assert got == expect, (f"W8: errored frames not dropped whole / good frames disturbed. "
                           f"expect lens={[len(f) for f in expect]} got={[len(g) for g in got]}")
    assert int(dut.rx_err_frames.value) == len(bad), \
        f"W8: rx_err_frames={int(dut.rx_err_frames.value)}, expected {len(bad)}"
    assert int(dut.rx_drop_frames.value) >= len(bad), \
        f"W8: rx_drop_frames={int(dut.rx_drop_frames.value)} < {len(bad)}"
    dut._log.info(f"W8 errored-frame drop PASS ({len(bad)} dropped, "
                  f"{len(expect)} good byte-exact, rx_err_frames={int(dut.rx_err_frames.value)})")

@cocotb.test()
async def test_w8_drop_with_selected_frame_fifo_storage(dut):
    want_bram = os.environ.get("FF_BRAM", "0") == "1"

    ff = dut.u_rx_frame_fifo
    have_bram = hasattr(ff, "g_bram_read")
    assert have_bram == want_bram, (
        f"FF_BRAM={os.environ.get('FF_BRAM')} but g_bram_read "
        f"{'exists' if have_bram else 'does not exist'} — MEM_STYLE plumbing is broken, or "
        f"this RTL predates S20 and has no block-RAM storage mode at all")
    if have_bram:
        assert hasattr(ff.g_bram_read, "rd_word_valid"), \
            "g_bram_read has no rd_word_valid: this is not a registered-read FIFO"

    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)
    sink.pause = True                      # hold the sink off so the FIFO fills
    await src.idle_cycles(8)

    lens = [64, 128, 200, 64, 512, 97, 1518, 64]
    errs = [False, True, False, True, False, False, True, False]
    frames = [_rand_frame(n) for n in lens]
    for f, e in zip(frames, errs):
        await src.send(f, err=e)
    await ClockCycles(dut.usr_clk, 200)
    sink.pause = False                     # release; drain with a stuttering sink
    for _ in range(24):
        await ClockCycles(dut.usr_clk, 40)
        sink.pause = True
        await ClockCycles(dut.usr_clk, 7)
        sink.pause = False
    await ClockCycles(dut.usr_clk, 800)

    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))
    expect = [f for f, e in zip(frames, errs) if not e]
    assert got == expect, (
        f"W8 under {'block' if have_bram else 'distributed'} storage: "
        f"expect lens={[len(f) for f in expect]} got={[len(g) for g in got]}")
    n_bad = sum(errs)
    assert int(dut.rx_err_frames.value) == n_bad, \
        f"rx_err_frames={int(dut.rx_err_frames.value)} expected {n_bad}"
    assert int(dut.rx_drop_frames.value) >= n_bad, \
        f"rx_drop_frames={int(dut.rx_drop_frames.value)} < {n_bad}"
    dut._log.info(f"S20 W8 PASS with storage={'block' if have_bram else 'distributed'}: "
                  f"{n_bad} dropped whole, {len(expect)} good byte-exact under back-pressure")

@cocotb.test()
async def test_rx_tready_ignored(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    dut.m_rx_axis_tready.value = 0

    await src.send(_rand_frame(1518))
    await src.idle_cycles(4)
    await ClockCycles(dut.usr_clk, 60)
    assert int(dut.m_rx_axis_tvalid.value) == 1, \
        "W6(RX): tvalid never asserted while tready was held low"

    for _ in range(80):
        await src.send(_rand_frame(1518))
    await ClockCycles(dut.seg_clk, 20)
    assert int(dut.rx_overflow.value) == 1, "W6(RX)/D5: loss not recorded"
    dropped = int(dut.rx_drop_frames.value)
    assert dropped > 0, "W6(RX): frames lost but rx_drop_frames == 0"

    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)
    dut.m_rx_axis_tready.value = 1
    await ClockCycles(dut.usr_clk, 4000)
    while not sink.empty():
        sink.recv_nowait()
    f = _rand_frame(512)
    await src.send(f)
    await src.idle_cycles(4)
    await ClockCycles(dut.usr_clk, 400)
    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))
    assert f in got, f"W6(RX): deadlock — no byte-exact frame after tready released ({got=})"
    dut._log.info(f"W6(RX) PASS (tvalid asserted, {dropped} frames dropped and counted, "
                  f"no deadlock)")

@cocotb.test()
async def test_txrst_latency(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    edges = 0
    for _ in range(12):
        await RisingEdge(dut.usr_clk)
        assert int(dut.tx_rst.value) == 1, "W2: tx_rst deasserted while unaligned"
        edges += 1
    assert edges >= 8, "W3: fewer than 8 usr_clk edges observed while tx_rst was asserted"

    await _bringup(dut)
    assert int(dut.tx_rst.value) == 0, "W2: tx_rst not released after alignment"

    dut.stat_rx_aligned.value = 0
    n = 0
    for _ in range(8):
        await RisingEdge(dut.usr_clk)
        n += 1
        if int(dut.tx_rst.value) == 1:
            break
    assert int(dut.tx_rst.value) == 1 and n <= 4, \
        f"W2: tx_rst took {n} usr_clk cycles to re-assert (limit 4)"
    dut._log.info(f"W2/W3 PASS (>=8 usr_clk edges before release; re-assert in {n} cycles "
                  f"at {USR_MHZ} MHz)")

@cocotb.test()
async def test_port_group_reset(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    expect = sum(1 << p for p in range(ANCHOR, ANCHOR + NPORTS))

    dut.stat_rx_aligned.value = 0
    seen = None
    for _ in range(120):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value):
            seen = int(dut.rx_datapath_reset_ports.value)
            break
    assert seen is not None, "W16: no RX datapath reset observed on re-align"
    assert seen == expect, (f"W16: reset vector {seen:#08b} != expected {expect:#08b} "
                            f"(ANCHOR={ANCHOR}, NPORTS={NPORTS})")

    await _bringup(dut)
    await ClockCycles(dut.seg_clk, 4)
    assert int(dut.rx_datapath_reset_ports.value) == 0, \
        "W16: reset vector non-zero while no reset requested"
    dut._log.info(f"W16 PASS (ANCHOR={ANCHOR}, NPORTS={NPORTS}, vector={seen:#08b})")

@cocotb.test()
async def test_rx_err_midframe_dropped(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)
    await src.idle_cycles(8)

    good0, good1, good2 = _rand_frame(64), _rand_frame(300), _rand_frame(1518)
    bad_first = _rand_frame(256)    # 8 seg beats / 4 AXIS beats; error on the FIRST
    bad_mid = _rand_frame(512)      # 16 seg beats / 8 AXIS beats; error in the MIDDLE
    bad_seg1 = _rand_frame(128)     # error on segment 1 rather than segment 0

    order = [(good0, None, 0), (bad_first, 0, 0), (good1, None, 0),
             (bad_mid, 5, 0), (good2, None, 0), (bad_seg1, 1, 1)]
    for f, eb, es in order:
        await src.send(f, err_beat=eb, err_seg=es)
        await src.idle_cycles(2)
    await ClockCycles(dut.usr_clk, 1200)

    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))
    expect = [f for f, eb, _ in order if eb is None]

    assert got == expect, (
        "X5 (DEFECT-N5-1): an RX error flagged before the final 512-bit beat did not drop "
        "the frame whole. rx_seg_err is only honoured when it coincides with tlast.\n"
        f"  expect lens={[len(f) for f in expect]}\n"
        f"  got    lens={[len(g) for g in got]}")
    dut._log.info(f"X5 PASS — {len(order) - len(expect)} mid-frame-errored frames dropped "
                  f"whole, {len(expect)} good frames byte-exact")

@cocotb.test()
async def test_rx_err_midframe_counted(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)
    await src.idle_cycles(8)

    assert int(dut.rx_err_frames.value) == 0, "X6: rx_err_frames non-zero before traffic"

    n_bad = 4
    for _ in range(n_bad):
        await src.send(_rand_frame(256), err_beat=0)     # error on the first beat
        await src.idle_cycles(2)
    await ClockCycles(dut.usr_clk, 900)

    err_cnt = int(dut.rx_err_frames.value)
    assert err_cnt == n_bad, (
        "X6 (DEFECT-N5-1): a mid-frame RX error was not counted. "
        f"rx_err_frames={err_cnt}, expected {n_bad} — the counter samples tuser only when "
        "rxa_tlast is high (dcmac_axis_core.sv:261-263).")
    drop_cnt = int(dut.rx_drop_frames.value)
    assert drop_cnt >= n_bad, f"X6/X7: rx_drop_frames={drop_cnt} < {n_bad} errored frames"
    assert int(dut.rx_overflow.value) == 1, "X8: frames discarded without raising rx_overflow"
    dut._log.info(f"X6 PASS — rx_err_frames={err_cnt}, rx_drop_frames={drop_cnt}")

@cocotb.test()
async def test_rx_frames_whole_under_backpressure(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_rx_axis"), dut.usr_clk,
                         dut.usr_rstn, reset_active_level=False)
    sink.log.setLevel(logging.WARNING)
    await src.idle_cycles(8)

    lens = [64, 65, 63, 128, 129, 1518, 97, 512, 511, 66, 1500, 64,
            333, 1024, 127, 200, 65, 999, 64, 1518]
    REPS = 8
    frames = [_rand_frame(n) for _ in range(REPS) for n in lens]

    stop = False

    async def stutter():
        while not stop:
            sink.pause = True
            await ClockCycles(dut.usr_clk, 200)
            sink.pause = False
            await ClockCycles(dut.usr_clk, 4)

    sink.pause = True
    cocotb.start_soon(stutter())

    for f in frames:                     # no idle: offer at full segmented line rate
        await src.send(f)
    await src.idle_cycles(4)
    await ClockCycles(dut.usr_clk, 2000)

    stop = True
    sink.pause = False                   # drain
    await ClockCycles(dut.usr_clk, 20000)

    got = []
    while not sink.empty():
        got.append(_sink_frame_bytes(sink.recv_nowait()))

    sent_set = set(frames)
    for i, g in enumerate(got):
        assert g in sent_set, (
            f"X1/X2: delivered frame #{i} (len {len(g)}) is not any frame that was sent — "
            "it is a truncation, a fusion of two frames, or corrupt. "
            f"sent lens={lens}, got lens={[len(x) for x in got]}")

    it = iter(frames)
    assert all(any(g == s for s in it) for g in got), (
        f"X9: delivered frames are not an order-preserving subsequence of the sent frames. "
        f"sent {len(frames)} frames, got lens={[len(x) for x in got]}")

    dropped = int(dut.rx_drop_frames.value)
    assert dropped > 0, (
        "X3: no frame was dropped — the sink was not back-pressured hard enough for this "
        "test to be meaningful (it would pass trivially on a truncating design too)")
    assert int(dut.rx_overflow.value) == 1, "X8: frames dropped without rx_overflow sticky"
    assert len(got) + dropped == len(frames), (
        f"X7/X8: accounting — delivered {len(got)} + rx_drop_frames {dropped} != "
        f"{len(frames)} sent. A frame vanished without being counted, or was double-counted.")

    dut._log.info(f"X1/X2/X3/X7/X8/X9 PASS — {len(got)} of {len(frames)} frames delivered "
                  f"whole and in order, {dropped} dropped whole and counted, "
                  f"0 partial, 0 fused")
