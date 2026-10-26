# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

import random

from cocotb.triggers import RisingEdge

class AxiMaster:

    def __init__(self, dut, data_bits=512, id_bits=6, addr_bits=64):
        self.dut = dut
        self.DW = data_bits
        self.DB = data_bits // 8
        self.IDW = id_bits
        self.AW = addr_bits
        self.rng = random.Random(0)

    def _idle_w(self):
        self.dut.s_axi_awvalid.value = 0
        self.dut.s_axi_wvalid.value = 0

    def _idle_r(self):
        self.dut.s_axi_arvalid.value = 0

    async def send_aw(self, addr, length, size=6, burst=1, awid=0):
        d = self.dut
        d.s_axi_awaddr.value = addr
        d.s_axi_awlen.value = length
        d.s_axi_awsize.value = size
        d.s_axi_awburst.value = burst
        d.s_axi_awid.value = awid
        d.s_axi_awvalid.value = 1
        while True:
            await RisingEdge(d.aclk)
            if d.s_axi_awready.value:
                break
        d.s_axi_awvalid.value = 0

    async def send_w(self, data, strb, last, gap=0):
        d = self.dut
        for _ in range(gap):
            d.s_axi_wvalid.value = 0
            await RisingEdge(d.aclk)
        d.s_axi_wdata.value = data
        d.s_axi_wstrb.value = strb
        d.s_axi_wlast.value = 1 if last else 0
        d.s_axi_wvalid.value = 1
        while True:
            await RisingEdge(d.aclk)
            if d.s_axi_wready.value:
                break
        d.s_axi_wvalid.value = 0
        d.s_axi_wlast.value = 0

    async def send_ar(self, addr, length, size=6, burst=1, arid=0):
        d = self.dut
        d.s_axi_araddr.value = addr
        d.s_axi_arlen.value = length
        d.s_axi_arsize.value = size
        d.s_axi_arburst.value = burst
        d.s_axi_arid.value = arid
        d.s_axi_arvalid.value = 1
        while True:
            await RisingEdge(d.aclk)
            if d.s_axi_arready.value:
                break
        d.s_axi_arvalid.value = 0

    async def recv_b(self, delay=0):
        d = self.dut
        for _ in range(delay):
            d.s_axi_bready.value = 0
            await RisingEdge(d.aclk)
        d.s_axi_bready.value = 1
        while True:
            await RisingEdge(d.aclk)
            if d.s_axi_bvalid.value:
                bid = int(d.s_axi_bid.value)
                bresp = int(d.s_axi_bresp.value)
                break
        d.s_axi_bready.value = 0
        return bid, bresp

    async def recv_r(self, nbeats, delay=0):
        d = self.dut
        out = []
        got = 0
        while got < nbeats:
            for _ in range(delay):
                d.s_axi_rready.value = 0
                await RisingEdge(d.aclk)
            d.s_axi_rready.value = 1
            await RisingEdge(d.aclk)
            if d.s_axi_rvalid.value:
                out.append((int(d.s_axi_rdata.value),
                            int(d.s_axi_rid.value),
                            int(d.s_axi_rlast.value),
                            int(d.s_axi_rresp.value)))
                got += 1
        d.s_axi_rready.value = 0
        return out

    async def write_burst(self, addr, beats, size=6, burst=1, awid=0,
                          wgap=0, bdelay=0, force_last_at=None):
        n = len(beats)
        await self.send_aw(addr, n - 1, size, burst, awid)
        for i, (data, strb) in enumerate(beats):
            last = (i == n - 1) if force_last_at is None else (i == force_last_at)
            await self.send_w(data, strb, last, gap=wgap)
            if force_last_at is not None and i == force_last_at:
                break
        return await self.recv_b(delay=bdelay)

    async def read_burst(self, addr, nbeats, size=6, burst=1, arid=0, rdelay=0):
        await self.send_ar(addr, nbeats - 1, size, burst, arid)
        return await self.recv_r(nbeats, delay=rdelay)

class AxiChecker:

    def __init__(self):
        self.violations = []

    def check_read_resp(self, beats, expect_id, expect_n, tag=""):
        if len(beats) != expect_n:
            self.violations.append(f"{tag}: got {len(beats)} R beats, expected {expect_n}")
            return
        for i, (_d, rid, rlast, rresp) in enumerate(beats):
            if rid != expect_id:
                self.violations.append(f"{tag}: beat {i} rid={rid} != arid={expect_id}")
            if rresp != 0:
                self.violations.append(f"{tag}: beat {i} rresp={rresp} != OKAY")
            want_last = 1 if i == expect_n - 1 else 0
            if rlast != want_last:
                self.violations.append(f"{tag}: beat {i} rlast={rlast}, expected {want_last}")

    def check_write_resp(self, bid, bresp, expect_id, tag=""):
        if bid != expect_id:
            self.violations.append(f"{tag}: bid={bid} != awid={expect_id}")
        if bresp != 0:
            self.violations.append(f"{tag}: bresp={bresp} != OKAY")

    def ok(self):
        return not self.violations

    def report(self):
        return "\n".join(self.violations[:40])

class GoldenMem:

    def __init__(self, span_bytes, db=64):
        self.span = span_bytes
        self.db = db
        self.m = {}
        self.oob_txn = 0

    def write_beat(self, byte_addr, data_int, strb):
        line = (byte_addr // self.db) * self.db
        if line >= self.span:
            return False                      # M3: suppressed, not aliased
        for b in range(self.db):
            if (strb >> b) & 1:
                self.m[line + b] = (data_int >> (8 * b)) & 0xFF
        return True

    def read_beat(self, byte_addr):
        line = (byte_addr // self.db) * self.db
        if line >= self.span:
            return 0                          # M3: zeros, never another session's bytes
        v = 0
        for b in range(self.db):
            v |= self.m.get(line + b, 0) << (8 * b)
        return v

    def write_bytes(self, addr, payload):
        for i, byte in enumerate(payload):
            if addr + i < self.span:
                self.m[addr + i] = byte

    def read_bytes(self, addr, n):
        return bytes(self.m.get(addr + i, 0) if addr + i < self.span else 0
                     for i in range(n))

class DataMover:
    MAX_BEATS = 64          # c_*_burst_size 64
    BOUNDARY = 4096         # AXI4: a burst may not cross a 4 KiB boundary

    def __init__(self, master, checker, db=64, dre=True):
        self.m = master
        self.chk = checker
        self.db = db
        self.dre = dre
        self.status = []            # the mmStatus stream this model emits
        self.drop_next_status = False
        self.fail_next_status = False

    def _split(self, addr, nbytes):
        out = []
        a, rem = addr, nbytes
        while rem > 0:
            line = (a // self.db) * self.db
            to_boundary = self.BOUNDARY - (a % self.BOUNDARY)
            chunk = min(rem, to_boundary)
            end = a + chunk
            first_line = line
            last_line = ((end - 1) // self.db) * self.db
            nbeats = (last_line - first_line) // self.db + 1
            if nbeats > self.MAX_BEATS:
                nbeats = self.MAX_BEATS
                end = first_line + nbeats * self.db
                chunk = end - a
            out.append((a, chunk, nbeats))
            a += chunk
            rem -= chunk
        return out

    async def write_cmd(self, saddr, payload, wgap=0, bdelay=0, awid=0):
        off = 0
        for a, chunk, nbeats in self._split(saddr, len(payload)):
            beats = []
            for k in range(nbeats):
                line = ((a // self.db) * self.db) + k * self.db
                data, strb = 0, 0
                for b in range(self.db):
                    ba = line + b
                    if a <= ba < a + chunk:
                        data |= payload[off + (ba - a)] << (8 * b)
                        strb |= 1 << b
                beats.append((data, strb))
            bid, bresp = await self.m.write_burst(a, beats, awid=awid,
                                                 wgap=wgap, bdelay=bdelay)
            self.chk.check_write_resp(bid, bresp, awid, tag=f"dm_wr@{a:#x}")
            off += chunk
        if self.drop_next_status:
            self.drop_next_status = False
        elif self.fail_next_status:
            self.fail_next_status = False
            self.status.append(0)                       # okay = 0
        else:
            self.status.append(1)

    async def read_cmd(self, saddr, nbytes, rdelay=0, arid=0):
        out = bytearray()
        for a, chunk, nbeats in self._split(saddr, nbytes):
            beats = await self.m.read_burst(a, nbeats, arid=arid, rdelay=rdelay)
            self.chk.check_read_resp(beats, arid, nbeats, tag=f"dm_rd@{a:#x}")
            for k, (data, _id, _l, _r) in enumerate(beats):
                line = ((a // self.db) * self.db) + k * self.db
                for b in range(self.db):
                    ba = line + b
                    if a <= ba < a + chunk:
                        out.append((data >> (8 * b)) & 0xFF)
        return bytes(out)

class ToeTxAppStatusHandler:

    READ_EV, READ_STATUS_1, READ_STATUS_2 = 0, 1, 2

    def __init__(self, buffer_size):
        self.state = self.READ_EV
        self.buffer_size = buffer_size
        self.ev = None
        self.pushes = 0            # txApp2txSar_app_push firings
        self.stalled_cycles = 0

    def step(self, events, statuses):
        if self.state == self.READ_EV:
            if events:
                self.ev = events.pop(0)
                self.state = self.READ_STATUS_1
            else:
                return
        elif self.state == self.READ_STATUS_1:
            if not statuses:
                self.stalled_cycles += 1
                return
            okay = statuses.pop(0)
            if okay:                                        # <-- no else in the reference
                addr, length = self.ev
                if addr + length > self.buffer_size:
                    self.state = self.READ_STATUS_2         # wrapped write => 2nd status
                else:
                    self.pushes += 1
                    self.state = self.READ_EV
            else:
                self.stalled_cycles += 1                    # stuck in READ_STATUS_1
        elif self.state == self.READ_STATUS_2:
            if not statuses:
                self.stalled_cycles += 1
                return
            okay = statuses.pop(0)
            if okay:
                self.pushes += 1
                self.state = self.READ_EV
            else:
                self.stalled_cycles += 1
