# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.queue import Queue

class SegmentedSource:
    def __init__(self, dut, clk, n_seg=2, seg_w=128):
        self.dut = dut
        self.clk = clk
        self.n_seg = n_seg
        self.seg_w = seg_w
        self.seg_b = seg_w // 8
        self.beat_b = self.seg_b * n_seg
        self._idle()

    def _idle(self):
        self.dut.rx_seg_valid.value = 0
        self.dut.rx_seg_dat.value = 0
        self.dut.rx_seg_ena.value = 0
        self.dut.rx_seg_sop.value = 0
        self.dut.rx_seg_eop.value = 0
        self.dut.rx_seg_err.value = 0
        self.dut.rx_seg_mty.value = 0

    async def send(self, frame: bytes, err: bool = False,
                   err_beat: int = None, err_seg: int = 0):
        n_seg, seg_b, beat_b = self.n_seg, self.seg_b, self.beat_b
        beats = [frame[i:i + beat_b] for i in range(0, len(frame), beat_b)] or [b""]
        if err_beat is not None and err_beat < 0:
            err_beat += len(beats)
        for i, beat in enumerate(beats):
            is_last = (i == len(beats) - 1)
            nbytes = len(beat)
            dat = 0
            for k, byte in enumerate(beat):
                dat |= byte << (k * 8)
            ena = 0
            for s in range(n_seg):
                seg_bytes = max(0, min(seg_b, nbytes - s * seg_b))
                if seg_bytes > 0:
                    ena |= (1 << s)
            sop = 1 if i == 0 else 0            # SOP on segment 0 of first beat
            eop = 0
            mty = 0
            errv = 0
            if is_last:
                last_idx = max(0, nbytes - 1)
                eop_seg = last_idx // seg_b
                eop = (1 << eop_seg)
                seg_bytes = nbytes - eop_seg * seg_b
                mty = (seg_b - seg_bytes) << (eop_seg * 4)
                if err:
                    errv = (1 << eop_seg)
            if err_beat is not None and i == err_beat and ((ena >> err_seg) & 1):
                errv |= (1 << err_seg)
            self.dut.rx_seg_valid.value = 1
            self.dut.rx_seg_dat.value = dat
            self.dut.rx_seg_ena.value = ena
            self.dut.rx_seg_sop.value = sop
            self.dut.rx_seg_eop.value = eop
            self.dut.rx_seg_err.value = errv
            self.dut.rx_seg_mty.value = mty
            await RisingEdge(self.clk)
        self._idle()

    async def idle_cycles(self, n=1):
        self._idle()
        for _ in range(n):
            await RisingEdge(self.clk)

class SegmentedSink:
    def __init__(self, dut, clk, n_seg=2, seg_w=128, ready_signal="tx_seg_ready"):
        self.dut = dut
        self.clk = clk
        self.n_seg = n_seg
        self.seg_w = seg_w
        self.seg_b = seg_w // 8
        self.queue = Queue()
        self._ready_sig = getattr(dut, ready_signal)
        self._cur = bytearray()
        self._err = 0
        cocotb.start_soon(self._run())

    async def _run(self):
        n_seg, seg_b, seg_w = self.n_seg, self.seg_b, self.seg_w
        while True:
            await RisingEdge(self.clk)
            if int(self.dut.tx_seg_valid.value) != 1:
                continue
            if int(self._ready_sig.value) != 1:
                continue
            dat = int(self.dut.tx_seg_dat.value)
            ena = int(self.dut.tx_seg_ena.value)
            eop = int(self.dut.tx_seg_eop.value)
            err = int(self.dut.tx_seg_err.value)
            mty = int(self.dut.tx_seg_mty.value)
            done = False
            for s in range(n_seg):
                if not ((ena >> s) & 1):
                    continue
                is_eop = (eop >> s) & 1
                mty_s = (mty >> (s * 4)) & 0xF
                nbytes = (seg_b - mty_s) if is_eop else seg_b
                base = s * seg_w
                for j in range(nbytes):
                    self._cur.append((dat >> (base + j * 8)) & 0xFF)
                if is_eop:
                    self._err |= (err >> s) & 1
                    done = True
            if done:
                await self.queue.put((bytes(self._cur), self._err))
                self._cur = bytearray()
                self._err = 0

    async def recv(self):
        return await self.queue.get()
