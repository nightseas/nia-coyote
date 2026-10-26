# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

DATA_BYTES = 64
SETTLE = Timer(100, "ps")

ETHERTYPE_IPV4 = 0x0800
ETHERTYPE_ARP = 0x0806
PROTO_UDP = 0x11
PROTO_TCP = 0x06
PORT_ROCE = 0x12B7
PORT_PLAIN = 0x1F90


def _ethernet_header(ethertype):
    frame = bytearray(14)
    frame[0:6] = bytes([0x00, 0x0A, 0x35, 0x02, 0x9D, 0xE5])
    frame[6:12] = bytes([0x00, 0x0A, 0x35, 0x02, 0x9D, 0xE6])
    frame[12] = (ethertype >> 8) & 0xFF
    frame[13] = ethertype & 0xFF
    return frame


def ipv4_udp_frame(dest_port, length=160, tag=0x00):
    frame = _ethernet_header(ETHERTYPE_IPV4)
    frame += bytearray(length - len(frame))
    frame[14] = 0x45
    frame[23] = PROTO_UDP
    frame[36] = (dest_port >> 8) & 0xFF
    frame[37] = dest_port & 0xFF
    for index in range(42, length):
        frame[index] = (tag + index) & 0xFF
    return bytes(frame)


def ipv4_tcp_frame(length=160, tag=0x40):
    frame = _ethernet_header(ETHERTYPE_IPV4)
    frame += bytearray(length - len(frame))
    frame[14] = 0x45
    frame[23] = PROTO_TCP
    for index in range(34, length):
        frame[index] = (tag + index) & 0xFF
    return bytes(frame)


def arp_frame():
    frame = _ethernet_header(ETHERTYPE_ARP)
    frame += bytearray(60 - len(frame))
    frame[14] = 0x00
    frame[15] = 0x01
    frame[20] = 0x00
    frame[21] = 0x01
    return bytes(frame)


def ipv4_udp_frame_with_arp_shaped_payload():
    frame = bytearray(ipv4_udp_frame(PORT_PLAIN, length=128, tag=0x80))
    frame[DATA_BYTES + 12] = 0x08
    frame[DATA_BYTES + 13] = 0x06
    return bytes(frame)


def to_beats(frame):
    beats = []
    for offset in range(0, len(frame), DATA_BYTES):
        chunk = frame[offset:offset + DATA_BYTES]
        data = int.from_bytes(chunk.ljust(DATA_BYTES, b"\x00"), "little")
        keep = (1 << len(chunk)) - 1
        beats.append((data, keep, offset + DATA_BYTES >= len(frame)))
    return beats


def from_beats(beats):
    frame = bytearray()
    for data, keep, _ in beats:
        chunk = data.to_bytes(DATA_BYTES, "little")
        frame += chunk[:bin(keep).count("1")]
    return bytes(frame)


class Bench:
    def __init__(self, dut):
        self.dut = dut
        self.host = []
        self.offloaded = []
        self.pending = []
        self.sent = []

    async def start(self):
        cocotb.start_soon(Clock(self.dut.nclk, 4, units="ns").start())
        self.dut.nresetn.value = 0
        self.dut.rx_tvalid.value = 0
        self.dut.rx_tdata.value = 0
        self.dut.rx_tkeep.value = 0
        self.dut.rx_tlast.value = 0
        self.dut.host_tready.value = 0
        self.dut.offloaded_tready.value = 0
        for _ in range(4):
            await RisingEdge(self.dut.nclk)
        self.dut.nresetn.value = 1
        await RisingEdge(self.dut.nclk)

    def queue(self, frame):
        self.pending += to_beats(frame)

    def set_ready(self, host, offloaded):
        self.dut.host_tready.value = 1 if host else 0
        self.dut.offloaded_tready.value = 1 if offloaded else 0

    async def cycle(self):
        await FallingEdge(self.dut.nclk)
        if self.pending:
            data, keep, last = self.pending[0]
            self.dut.rx_tdata.value = data
            self.dut.rx_tkeep.value = keep
            self.dut.rx_tlast.value = 1 if last else 0
            self.dut.rx_tvalid.value = 1
        else:
            self.dut.rx_tvalid.value = 0
        await SETTLE
        accepted = False
        if self.pending and self.dut.rx_tready.value == 1:
            accepted = True
        if self.dut.host_tvalid.value == 1 and self.dut.host_tready.value == 1:
            self.host.append((int(self.dut.host_tdata.value),
                              int(self.dut.host_tkeep.value),
                              int(self.dut.host_tlast.value)))
        if self.dut.offloaded_tvalid.value == 1 and self.dut.offloaded_tready.value == 1:
            self.offloaded.append((int(self.dut.offloaded_tdata.value),
                                   int(self.dut.offloaded_tkeep.value),
                                   int(self.dut.offloaded_tlast.value)))
        if accepted:
            self.sent.append(self.pending.pop(0))
        await RisingEdge(self.dut.nclk)
        return accepted

    async def run(self, cycles):
        for _ in range(cycles):
            await self.cycle()

    async def drain(self, cycles=400):
        for _ in range(cycles):
            if not self.pending:
                await self.run(2)
                return True
            await self.cycle()
        return False


@cocotb.test()
async def test_offloaded_frame_passes_while_the_host_path_is_stalled(dut):
    bench = Bench(dut)
    await bench.start()
    bench.set_ready(host=False, offloaded=True)
    bench.queue(ipv4_udp_frame(PORT_ROCE, length=160, tag=0x10))
    drained = await bench.drain()
    assert drained, (
        f"the RoCE frame stalled with the host path not ready: "
        f"{len(bench.pending)} beats of 3 never accepted"
    )
    assert from_beats(bench.offloaded) == ipv4_udp_frame(PORT_ROCE, length=160, tag=0x10), \
        "the offloaded path did not receive the RoCE frame byte exact"
    assert bench.host == [], "the RoCE frame reached the host path"
    dut._log.info(f"RoCE frame accepted in {len(bench.sent)} beats with host_tready held low")


@cocotb.test()
async def test_host_frame_passes_while_the_offloaded_path_is_stalled(dut):
    bench = Bench(dut)
    await bench.start()
    bench.set_ready(host=True, offloaded=False)
    frame = ipv4_udp_frame(PORT_PLAIN, length=160, tag=0x20)
    bench.queue(frame)
    drained = await bench.drain()
    assert drained, (
        f"the host frame stalled with the offloaded path not ready: "
        f"{len(bench.pending)} beats of 3 never accepted"
    )
    assert from_beats(bench.host) == frame, \
        "the host path did not receive the frame byte exact"
    assert bench.offloaded == [], "the host frame reached the offloaded path"
    dut._log.info(f"host frame accepted in {len(bench.sent)} beats with offloaded_tready held low")


@cocotb.test()
async def test_arp_frame_waits_for_both_consumers_and_is_duplicated(dut):
    bench = Bench(dut)
    await bench.start()
    bench.set_ready(host=True, offloaded=False)
    frame = arp_frame()
    bench.queue(frame)
    await bench.run(8)
    assert len(bench.pending) == 1, "the ARP frame was accepted with the offloaded path not ready"
    bench.set_ready(host=True, offloaded=True)
    drained = await bench.drain(40)
    assert drained, "the ARP frame stalled with both consumers ready"
    assert from_beats(bench.host) == frame, "the host path did not receive the ARP frame"
    assert from_beats(bench.offloaded) == frame, "the offloaded path did not receive the ARP frame"


@cocotb.test()
async def test_host_frame_payload_does_not_reach_the_offloaded_path(dut):
    bench = Bench(dut)
    await bench.start()
    bench.set_ready(host=True, offloaded=True)
    frame = ipv4_udp_frame_with_arp_shaped_payload()
    bench.queue(frame)
    drained = await bench.drain(60)
    assert drained, "the host frame stalled with both consumers ready"
    assert from_beats(bench.host) == frame, "the host path did not receive the frame byte exact"
    assert bench.offloaded == [], (
        f"{len(bench.offloaded)} payload beats of the host frame leaked into the offloaded path"
    )


@cocotb.test()
async def test_alternating_frames_are_classified_per_frame(dut):
    bench = Bench(dut)
    await bench.start()
    bench.set_ready(host=True, offloaded=True)
    host_frame = ipv4_udp_frame(PORT_PLAIN, length=160, tag=0x30)
    roce = ipv4_udp_frame(PORT_ROCE, length=160, tag=0x50)
    tcp = ipv4_tcp_frame()
    for frame in (host_frame, roce, host_frame, roce, tcp):
        bench.queue(frame)
    drained = await bench.drain(200)
    assert drained, "the alternating stream stalled with both consumers ready"
    assert from_beats(bench.host) == host_frame + host_frame + tcp, \
        "the host path did not receive exactly the two host frames and the TCP frame"
    assert from_beats(bench.offloaded) == roce + roce, \
        "the offloaded path did not receive exactly the two RoCE frames"
