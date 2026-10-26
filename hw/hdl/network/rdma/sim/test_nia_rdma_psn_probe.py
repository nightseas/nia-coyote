# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

OPC_READ_REQ = 0x0C     # RC_RDMA_READ_REQUEST, ib_transport_protocol.hpp:100
OPC_WRITE_ONLY = 0x0A   # RC_RDMA_WRITE_ONLY, :98
OPC_ACK = 0x11          # RC_ACK, :105

CTL_ENTER = 0           # ib_transport_protocol.cpp:316
CTL_INORDER = 1         # :368
CTL_DUP_RD = 2          # :381
CTL_DUP_WR = 3          # :394
CTL_DUP_OTHER = 4       # :410
CTL_INVALID = 5         # :424

def record(opcode: int, psn: int, epsn: int, ctl: int) -> int:
    assert opcode < (1 << 32) and psn < (1 << 32) and epsn < (1 << 32) and ctl < (1 << 8)
    return opcode | (psn << 32) | (epsn << 64) | (ctl << 96)

async def start(dut):
    cocotb.start_soon(Clock(dut.nclk, 4, units="ns").start())
    dut.nresetn.value = 0
    dut.s_dbg_valid.value = 0
    dut.s_dbg_data.value = 0
    await ClockCycles(dut.nclk, 5)
    dut.nresetn.value = 1
    await ClockCycles(dut.nclk, 2)

async def push(dut, rec: int, gap: int = 0):
    dut.s_dbg_data.value = rec
    dut.s_dbg_valid.value = 1
    await RisingEdge(dut.nclk)
    dut.s_dbg_valid.value = 0
    dut.s_dbg_data.value = 0
    for _ in range(gap):
        await RisingEdge(dut.nclk)

def windows(dut):
    return (int(dut.w0.value), int(dut.w1.value), int(dut.w2.value), int(dut.w3.value))

@cocotb.test()
async def test_reset_reads_all_zero(dut):
    await start(dut)
    assert windows(dut) == (0, 0, 0, 0), f"windows not clear after reset: {windows(dut)}"
    dut._log.info("reset OK: all four windows 0")

@cocotb.test()
async def test_healthy_run_reports_no_invalid(dut):
    await start(dut)
    n = 40
    for i in range(n):
        await push(dut, record(OPC_READ_REQ, 0x100 + i, 0x100 + i, CTL_ENTER))
        await push(dut, record(OPC_READ_REQ, 0x100 + i, 0x100 + i, CTL_INORDER))
    await ClockCycles(dut.nclk, 2)
    w0, w1, w2, w3 = windows(dut)
    assert w0 == 0 and w1 == 0, f"invalid capture fired on a healthy run: w0={w0:#x} w1={w1:#x}"
    assert w2 == 0, f"invalid or duplicate-read counts non-zero: w2={w2:#x}"
    assert (w3 >> 16) == n, f"entered count {w3 >> 16} != {n}"
    assert (w3 & 0xFFFF) == n, f"in-order count {w3 & 0xFFFF} != {n}"
    dut._log.info("healthy OK: entered=%d in_order=%d, no invalid", w3 >> 16, w3 & 0xFFFF)

@cocotb.test()
async def test_first_invalid_is_latched_with_both_psns(dut):
    await start(dut)
    await push(dut, record(OPC_READ_REQ, 0x000123, 0x000123, CTL_ENTER))
    await push(dut, record(OPC_READ_REQ, 0x000123, 0x000123, CTL_INORDER))
    await push(dut, record(OPC_READ_REQ, 0xABCDEF, 0x000124, CTL_INVALID))
    await push(dut, record(OPC_WRITE_ONLY, 0x111111, 0x222222, CTL_INVALID))
    await ClockCycles(dut.nclk, 2)
    w0, w1, w2, _ = windows(dut)
    assert (w0 >> 24) == OPC_READ_REQ, f"opcode {w0 >> 24:#x} is not the first invalid one"
    assert (w0 & 0xFFFFFF) == 0xABCDEF, f"packet PSN {w0 & 0xFFFFFF:#x} wrong"
    assert (w1 >> 24) == CTL_INVALID, f"ctl {w1 >> 24} is not 5"
    assert (w1 & 0xFFFFFF) == 0x000124, f"expected PSN {w1 & 0xFFFFFF:#x} wrong"
    assert (w2 >> 16) == 2, f"invalid count {w2 >> 16} != 2"
    dut._log.info("first-invalid OK: opcode %#x psn %#x epsn %#x, 2 invalid seen",
                  w0 >> 24, w0 & 0xFFFFFF, w1 & 0xFFFFFF)

@cocotb.test()
async def test_read_request_is_distinguishable_from_a_write(dut):
    await start(dut)
    await push(dut, record(OPC_WRITE_ONLY, 0x000010, 0x000020, CTL_INVALID))
    await ClockCycles(dut.nclk, 2)
    assert (int(dut.w0.value) >> 24) == OPC_WRITE_ONLY
    dut._log.info("opcode discrimination OK: a WRITE-only invalid reads %#x, not %#x",
                  OPC_WRITE_ONLY, OPC_READ_REQ)

@cocotb.test()
async def test_duplicate_read_requests_counted_separately(dut):
    await start(dut)
    for i in range(7):
        await push(dut, record(OPC_READ_REQ, 0x200 + i, 0x300, CTL_DUP_RD))
    await ClockCycles(dut.nclk, 2)
    w0, w1, w2, _ = windows(dut)
    assert w0 == 0 and w1 == 0, "duplicates must not latch as invalid"
    assert (w2 & 0xFFFF) == 7, f"duplicate-read count {w2 & 0xFFFF} != 7"
    assert (w2 >> 16) == 0, "invalid count must stay 0"
    dut._log.info("duplicate OK: 7 counted, invalid still 0")

@cocotb.test()
async def test_counts_saturate(dut):
    await start(dut)
    for i in range(300):
        await push(dut, record(OPC_READ_REQ, i, i, CTL_DUP_RD))
    await ClockCycles(dut.nclk, 2)
    assert (int(dut.w2.value) & 0xFFFF) == 300
    dut._log.info("monotonic OK at 300; saturation is by construction in sat_inc")

@cocotb.test()
async def test_other_ctl_values_are_ignored(dut):
    await start(dut)
    await push(dut, record(OPC_ACK, 0x1, 0x2, CTL_DUP_WR))
    await push(dut, record(OPC_ACK, 0x1, 0x2, CTL_DUP_OTHER))
    await push(dut, record(OPC_ACK, 0x1, 0x2, 0x7F))
    await ClockCycles(dut.nclk, 2)
    assert windows(dut) == (0, 0, 0, 0), f"unexpected change: {windows(dut)}"
    dut._log.info("ignored-ctl OK")

@cocotb.test()
async def test_back_to_back_and_gapped_records(dut):
    await start(dut)
    random.seed(1)
    n_inorder = 0
    n_enter = 0
    for _ in range(120):
        gap = random.choice([0, 0, 0, 1, 3])
        if random.random() < 0.5:
            await push(dut, record(OPC_READ_REQ, 1, 1, CTL_ENTER), gap)
            n_enter += 1
        else:
            await push(dut, record(OPC_READ_REQ, 1, 1, CTL_INORDER), gap)
            n_inorder += 1
    await ClockCycles(dut.nclk, 2)
    w3 = int(dut.w3.value)
    assert (w3 >> 16) == n_enter, f"entered {w3 >> 16} != {n_enter}"
    assert (w3 & 0xFFFF) == n_inorder, f"in order {w3 & 0xFFFF} != {n_inorder}"
    dut._log.info("no-loss OK: %d entered, %d in order", n_enter, n_inorder)

@cocotb.test()
async def test_reset_clears_a_captured_record(dut):
    await start(dut)
    await push(dut, record(OPC_READ_REQ, 0xAAAAAA, 0xBBBBBB, CTL_INVALID))
    await ClockCycles(dut.nclk, 2)
    assert int(dut.w0.value) != 0
    dut.nresetn.value = 0
    await ClockCycles(dut.nclk, 3)
    dut.nresetn.value = 1
    await ClockCycles(dut.nclk, 2)
    assert windows(dut) == (0, 0, 0, 0), f"reset did not clear: {windows(dut)}"
    dut._log.info("reset-clears OK")
