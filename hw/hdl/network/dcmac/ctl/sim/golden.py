# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

O_CONFIG_REV = 0x000
O_GLOBAL_MODE = 0x004
O_CHCTL_RX = 0x030
O_CHCTL_TX = 0x038
O_TX_MODE = 0x040
O_RX_MODE = 0x044
O_PCTL_RX = 0x0F0
O_TICK_RX = 0x0F4
O_PCTL_TX = 0x0F8
O_TICK_TX = 0x0FC
O_RX_PHY_STATUS = 0xC00
STAT_OFFS = [0x200, 0x208, 0x210, 0x218, 0x400, 0x408, 0x410, 0x418,
             0xE48, 0xE50, 0xE58]

W_GLOBAL_MODE = 0x07550000
W_PORT_MODE = 0x25800062
W_PORT_REV = 0x00000C01
ALIGN_ARM = 0xFFFFFFFF
ALIGN_MASK = 0x5
AXI_BAD = 0x0BAD0BAD

PORT_MAX = 6

def pp(p, off, base=0):
    return base + off + ((p + 1) << 12)

def _mode_words(rate, field):
    wtx = (rate & 0x3) | (1 << 4) | (1 << 10)
    wrx = (rate & 0x3) | (1 << 11) | (1 << 13)
    wtx = (wtx & 0xFFE0FFFF) | (field << 16)
    wrx = (wrx & 0xFFE0FFFF) | (field << 16)
    return wtx, wrx

def config_phase(nports=1, anchor=0, rate=0, field=0x04, base=0,
                 nonanchor_field=0x04):
    g = lambda off: base + off                                    # noqa: E731
    P = lambda p, off: pp(p, off, base)                            # noqa: E731
    group = list(range(anchor, anchor + nports))
    t = []

    t.append(("W", g(O_PCTL_RX), 0x7))
    t.append(("W", g(O_PCTL_TX), 0x7))
    for p in range(PORT_MAX):
        t.append(("W", P(p, O_PCTL_RX), 0x3))
        t.append(("W", P(p, O_PCTL_TX), 0x3))
    for p in group:
        t.append(("W", P(p, O_CHCTL_RX), 0x1))
        t.append(("W", P(p, O_CHCTL_TX), 0x1))
        t.append(("W", P(p, O_PCTL_RX), 0x3))
        t.append(("W", P(p, O_PCTL_TX), 0x3))

    t.append(("W", g(O_GLOBAL_MODE), W_GLOBAL_MODE))

    for i in range(PORT_MAX):
        t.append(("W", P(i, O_GLOBAL_MODE), W_PORT_MODE))
    for i in range(PORT_MAX):
        t.append(("W", P(i, O_CONFIG_REV), W_PORT_REV))

    for p in range(PORT_MAX):
        r = rate if p == anchor else 0
        f = field if p == anchor else nonanchor_field
        wtx, wrx = _mode_words(r, f)
        t.append(("W", P(p, O_TX_MODE), wtx))
        t.append(("W", P(p, O_RX_MODE), wrx))

    t.append(("W", g(O_PCTL_TX), 0x0))
    t.append(("W", g(O_PCTL_RX), 0x0))
    for p in range(PORT_MAX):
        t.append(("W", P(p, O_PCTL_TX), 0x0))
        t.append(("W", P(p, O_PCTL_RX), 0x0))
    for p in group:
        t.append(("W", P(p, O_PCTL_RX), 0x0))
        t.append(("W", P(p, O_PCTL_TX), 0x0))

    for p in group:
        t.append(("W", P(p, O_CHCTL_TX), 0x0))
        t.append(("W", P(p, O_CHCTL_RX), 0x0))
    return t

def poll_pair(anchor=0, base=0):
    a = pp(anchor, O_RX_PHY_STATUS, base)
    return [("W", a, ALIGN_ARM), ("R", a, None)]

def group_realign(nports=1, anchor=0, base=0):
    group = list(range(anchor, anchor + nports))
    t = [("W", pp(p, O_PCTL_RX, base), 0x2) for p in group]
    t += [("W", pp(p, O_PCTL_RX, base), 0x0) for p in group]
    return t

def pmtick(nports=1, anchor=0, base=0):
    t = []
    for p in range(anchor, anchor + nports):
        t.append(("W", pp(p, O_TICK_RX, base), 0x1))
        t.append(("W", pp(p, O_TICK_TX, base), 0x1))
    return t

def stats_reads(nports=1, anchor=0, base=0):
    t = []
    for p in range(anchor, anchor + nports):
        for off in STAT_OFFS:
            t.append(("R", pp(p, off, base), None))
            t.append(("R", pp(p, off + 4, base), None))
    return t

def closed_address_set(base=0):
    offs = [O_CONFIG_REV, O_GLOBAL_MODE, O_CHCTL_RX, O_CHCTL_TX, O_TX_MODE,
            O_RX_MODE, O_PCTL_RX, O_TICK_RX, O_PCTL_TX, O_TICK_TX,
            O_RX_PHY_STATUS]
    for s in STAT_OFFS:
        offs += [s, s + 4]
    s = set(base + o for o in offs)
    for p in range(PORT_MAX):
        for o in offs:
            s.add(pp(p, o, base))
    return s
