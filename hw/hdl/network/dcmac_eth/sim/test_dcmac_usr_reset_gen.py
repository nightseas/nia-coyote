# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

MODE = int(os.environ.get("MODE", "1"))
HOLD_CYCLES = int(os.environ.get("HOLD_CYCLES", "16"))
USR_MHZ = float(os.environ.get("USR_MHZ", "250"))
CLK_NS = 1000.0 / USR_MHZ


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())


async def apply_sys_reset(dut, cycles=8):
    dut.sys_reset.value = 1
    dut.mac_link_up.value = 0
    dut.mac_tx_rst.value = 1
    await ClockCycles(dut.clk, cycles)


async def release_sys_reset(dut):
    dut.sys_reset.value = 0
    await RisingEdge(dut.clk)


async def wait_release(dut, limit):
    for _ in range(limit):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.tx_rst.value) == 0:
            return True
    return False


@cocotb.test()
async def test_r1_asserted_out_of_reset(dut):
    await start_clock(dut)
    await apply_sys_reset(dut)
    await Timer(1, units="ns")
    assert int(dut.tx_rst.value) == 1, "tx_rst must be asserted while sys_reset is held"
    await ClockCycles(dut.clk, 32)
    await Timer(1, units="ns")
    assert int(dut.tx_rst.value) == 1, "tx_rst must stay asserted while sys_reset is held"


@cocotb.test()
async def test_r1_hold_cycles_are_respected(dut):
    if MODE == 2:
        return
    await start_clock(dut)
    await apply_sys_reset(dut)
    dut.mac_link_up.value = 1
    await release_sys_reset(dut)
    for i in range(HOLD_CYCLES - 1):
        await Timer(1, units="ns")
        assert int(dut.tx_rst.value) == 1, f"tx_rst released {i} cycles into a {HOLD_CYCLES} cycle hold"
        await RisingEdge(dut.clk)
    assert await wait_release(dut, HOLD_CYCLES + 16), "tx_rst never released after the hold"


@cocotb.test()
async def test_r1_mode1_holds_until_first_link_up(dut):
    if MODE != 1:
        return
    await start_clock(dut)
    await apply_sys_reset(dut)
    await release_sys_reset(dut)
    dut.mac_link_up.value = 0
    await ClockCycles(dut.clk, HOLD_CYCLES + 64)
    await Timer(1, units="ns")
    assert int(dut.tx_rst.value) == 1, "MODE 1 released tx_rst before the link came up"
    dut.mac_link_up.value = 1
    assert await wait_release(dut, 16), "MODE 1 never released tx_rst after the link came up"


@cocotb.test()
async def test_r1_mode0_ignores_the_link(dut):
    if MODE != 0:
        return
    await start_clock(dut)
    await apply_sys_reset(dut)
    await release_sys_reset(dut)
    dut.mac_link_up.value = 0
    assert await wait_release(dut, HOLD_CYCLES + 32), "MODE 0 must release tx_rst without a link"


@cocotb.test()
async def test_r1_alignment_dip_does_not_reassert(dut):
    await start_clock(dut)
    await apply_sys_reset(dut)
    await release_sys_reset(dut)
    dut.mac_link_up.value = 1
    dut.mac_tx_rst.value = 0
    assert await wait_release(dut, HOLD_CYCLES + 64), "tx_rst never released"

    for dip in range(4):
        dut.mac_link_up.value = 0
        dut.mac_tx_rst.value = 1
        for _ in range(24):
            await RisingEdge(dut.clk)
            await Timer(1, units="ns")
            if MODE == 2:
                continue
            assert int(dut.tx_rst.value) == 0, f"tx_rst re-asserted on alignment dip {dip}"
        dut.mac_link_up.value = 1
        dut.mac_tx_rst.value = 0
        await ClockCycles(dut.clk, 8)

    await Timer(1, units="ns")
    if MODE != 2:
        assert int(dut.tx_rst.value) == 0, "tx_rst did not stay released across the dips"


@cocotb.test()
async def test_r1_mode2_is_the_control(dut):
    if MODE != 2:
        return
    await start_clock(dut)
    await apply_sys_reset(dut)
    await release_sys_reset(dut)
    dut.mac_link_up.value = 1
    dut.mac_tx_rst.value = 0
    assert await wait_release(dut, 32), "MODE 2 never released tx_rst"
    dut.mac_tx_rst.value = 1
    seen = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        if int(dut.tx_rst.value) == 1:
            seen = 1
    assert seen == 1, "MODE 2 must follow mac_tx_rst, otherwise the control arm is vacuous"


@cocotb.test()
async def test_r1_only_sys_reset_reasserts(dut):
    await start_clock(dut)
    await apply_sys_reset(dut)
    await release_sys_reset(dut)
    dut.mac_link_up.value = 1
    dut.mac_tx_rst.value = 0
    assert await wait_release(dut, HOLD_CYCLES + 64), "tx_rst never released"
    dut.sys_reset.value = 1
    await ClockCycles(dut.clk, 4)
    await Timer(1, units="ns")
    assert int(dut.tx_rst.value) == 1, "sys_reset must re-assert tx_rst"
    dut.sys_reset.value = 0
    assert await wait_release(dut, HOLD_CYCLES + 64), "tx_rst never released after the second sys_reset"


@cocotb.test()
async def test_r1_link_loss_before_release_is_not_a_release(dut):
    if MODE != 1:
        return
    await start_clock(dut)
    await apply_sys_reset(dut)
    await release_sys_reset(dut)
    await ClockCycles(dut.clk, 4)
    dut.mac_link_up.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.mac_link_up.value = 0
    assert await wait_release(dut, HOLD_CYCLES + 64), "a single link_up pulse must satisfy MODE 1"
    for _ in range(32):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        assert int(dut.tx_rst.value) == 0, "tx_rst re-asserted after the link went away again"


@cocotb.test()
async def test_r1_link_up_during_sys_reset_is_not_remembered(dut):
    if MODE != 1:
        return
    await start_clock(dut)
    dut.sys_reset.value = 1
    dut.mac_link_up.value = 1
    dut.mac_tx_rst.value = 1
    await ClockCycles(dut.clk, 16)
    dut.mac_link_up.value = 0
    dut.sys_reset.value = 0
    await ClockCycles(dut.clk, HOLD_CYCLES + 64)
    await Timer(1, units="ns")
    assert int(dut.tx_rst.value) == 1, \
        "a link_up seen while sys_reset was held must not release tx_rst afterwards"
