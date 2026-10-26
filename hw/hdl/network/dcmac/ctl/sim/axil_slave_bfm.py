# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

import cocotb
from cocotb.triggers import RisingEdge

class Xact:

    __slots__ = ("kind", "addr", "data", "cycle")

    def __init__(self, kind, addr, data, cycle):
        self.kind = kind          # 'W' or 'R'
        self.addr = addr
        self.data = data
        self.cycle = cycle

    def __repr__(self):
        return f"{self.kind} 0x{self.addr:05x} 0x{self.data:08x} @{self.cycle}"

    def as_tuple(self):
        return (self.kind, self.addr, self.data)

class AxiLiteSlaveBFM:

    def __init__(self, dut, clk, rnd=None, rd_cb=None, max_delay=3):
        self.dut = dut
        self.clk = clk
        self.rnd = rnd
        self.rd_cb = rd_cb
        self.max_delay = max_delay
        self.mem = {}
        self.trace = []            # list[Xact] — the golden trace
        self.rd_count = {}
        self.cycle = 0
        self._stop = False
        self._idle()

    def _idle(self):
        self.dut.m_axil_awready.value = 0
        self.dut.m_axil_wready.value = 0
        self.dut.m_axil_bvalid.value = 0
        self.dut.m_axil_bresp.value = 0
        self.dut.m_axil_arready.value = 0
        self.dut.m_axil_rvalid.value = 0
        self.dut.m_axil_rdata.value = 0
        self.dut.m_axil_rresp.value = 0

    def _delay(self):
        if self.rnd is None or self.max_delay <= 0:
            return 0
        return self.rnd.randint(0, self.max_delay)

    def writes(self):
        return [x for x in self.trace if x.kind == "W"]

    def reads(self):
        return [x for x in self.trace if x.kind == "R"]

    def tuples(self):
        return [x.as_tuple() for x in self.trace]

    def clear(self):
        self.trace = []
        self.rd_count = {}

    def stop(self):
        self._stop = True

    async def start(self):
        cocotb.start_soon(self._tick())
        cocotb.start_soon(self._write_engine())
        cocotb.start_soon(self._read_engine())

    async def _tick(self):
        while not self._stop:
            await RisingEdge(self.clk)
            self.cycle += 1

    async def _write_engine(self):
        while not self._stop:
            aw_d, w_d = self._delay(), self._delay()
            got_aw = got_w = False
            addr = data = 0
            n = 0
            while not (got_aw and got_w):
                self.dut.m_axil_awready.value = 0 if (not got_aw and n < aw_d) else int(not got_aw)
                self.dut.m_axil_wready.value = 0 if (not got_w and n < w_d) else int(not got_w)
                await RisingEdge(self.clk)
                if (not got_aw) and self.dut.m_axil_awready.value == 1 \
                        and self.dut.m_axil_awvalid.value == 1:
                    addr = int(self.dut.m_axil_awaddr.value)
                    got_aw = True
                if (not got_w) and self.dut.m_axil_wready.value == 1 \
                        and self.dut.m_axil_wvalid.value == 1:
                    data = int(self.dut.m_axil_wdata.value)
                    got_w = True
                n += 1
                if self._stop:
                    return
            self.dut.m_axil_awready.value = 0
            self.dut.m_axil_wready.value = 0
            self.mem[addr] = data
            self.trace.append(Xact("W", addr, data, self.cycle))
            for _ in range(self._delay()):
                await RisingEdge(self.clk)
            self.dut.m_axil_bresp.value = 0
            self.dut.m_axil_bvalid.value = 1
            while True:
                await RisingEdge(self.clk)
                if self.dut.m_axil_bready.value == 1:
                    break
            self.dut.m_axil_bvalid.value = 0

    async def _read_engine(self):
        while not self._stop:
            for _ in range(self._delay()):
                await RisingEdge(self.clk)
            self.dut.m_axil_arready.value = 1
            addr = None
            while addr is None:
                await RisingEdge(self.clk)
                if self.dut.m_axil_arvalid.value == 1:
                    addr = int(self.dut.m_axil_araddr.value)
                if self._stop:
                    return
            self.dut.m_axil_arready.value = 0
            n = self.rd_count.get(addr, 0)
            self.rd_count[addr] = n + 1
            if self.rd_cb is not None:
                val = self.rd_cb(addr, n)
            else:
                val = self.mem.get(addr, 0)
            val &= 0xFFFFFFFF
            for _ in range(self._delay()):
                await RisingEdge(self.clk)
            self.dut.m_axil_rdata.value = val
            self.dut.m_axil_rresp.value = 0
            self.dut.m_axil_rvalid.value = 1
            while True:
                await RisingEdge(self.clk)
                if self.dut.m_axil_rready.value == 1:
                    break
            self.dut.m_axil_rvalid.value = 0
            self.trace.append(Xact("R", addr, val, self.cycle))
