// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

#include <iostream>
#include <vector>
#include <string>
#include <cstdlib>

#include "../ib_transport_protocol/ib_transport_protocol.cpp"
#include "../ib_transport_protocol/ib_utils.cpp"
#include "../axi_utils.cpp"
#include "newFakeDram.hpp"
#include "simSwitch.hpp"

using namespace hls;

#define IBTPORT(ninst)                                                   \
    static stream<txMeta> s_axis_sq_meta_n##ninst;                       \
    static stream<ackMeta> m_axis_rx_ack_meta_n##ninst;                  \
    static stream<qpContext> s_axis_qp_interface_n##ninst;               \
    static stream<ifConnReq> s_axis_qp_conn_interface_n##ninst;          \
    static stream<memCmd> m_axis_mem_write_cmd_n##ninst;                 \
    static stream<memCmd> m_axis_mem_read_cmd_n##ninst;                  \
    static stream<net_axis<DATA_WIDTH> > m_axis_mem_write_data_n##ninst; \
    static stream<net_axis<DATA_WIDTH> > s_axis_mem_read_data_n##ninst;  \
    static stream<psnPkg> m_axis_dbg_0_n##ninst;                         \
    static stream<psnPkg> m_axis_dbg_1_n##ninst;                         \
    static stream<psnPkg> m_axis_dbg_2_n##ninst;                         \
    ap_uint<32> regInvalidPsnDropCount_n##ninst;                         \
    ap_uint<32> regRetransCount_n##ninst;                                \
    ap_uint<32> regValidIbvCountRx_n##ninst;                             \
    ap_uint<32> regValidIbvCountTx_n##ninst;

#define IBTRUN(ninst)                               \
    ib_transport_protocol<DATA_WIDTH, ninst>(       \
        s_axis_rx_meta_n##ninst,                    \
        s_axis_rx_data_n##ninst,                    \
        m_axis_tx_meta_n##ninst,                    \
        m_axis_tx_data_n##ninst,                    \
        s_axis_sq_meta_n##ninst,                    \
        m_axis_rx_ack_meta_n##ninst,                \
        m_axis_mem_write_cmd_n##ninst,              \
        m_axis_mem_read_cmd_n##ninst,               \
        m_axis_mem_write_data_n##ninst,             \
        s_axis_mem_read_data_n##ninst,              \
        s_axis_qp_interface_n##ninst,               \
        s_axis_qp_conn_interface_n##ninst,          \
        m_axis_dbg_0_n##ninst,                      \
        m_axis_dbg_1_n##ninst,                      \
        m_axis_dbg_2_n##ninst,                      \
        regInvalidPsnDropCount_n##ninst,            \
        regRetransCount_n##ninst,                   \
        regValidIbvCountRx_n##ninst,                \
        regValidIbvCountTx_n##ninst                 \
    );

#define SWITCHPORT(port)                                    \
    static stream<ipUdpMeta> s_axis_rx_meta_n##port;        \
    static stream<net_axis<DATA_WIDTH> > s_axis_rx_data_n##port;   \
    static stream<ipUdpMeta> m_axis_tx_meta_n##port;        \
    static stream<net_axis<DATA_WIDTH> > m_axis_tx_data_n##port;

#define SWITCHRUN_LOCAL()                           \
    simSwitch<DATA_WIDTH>(                          \
        s_axis_rx_meta_n0,                          \
        s_axis_rx_data_n0,                          \
        m_axis_tx_meta_n0,                          \
        m_axis_tx_data_n0,                          \
        s_axis_rx_meta_n1,                          \
        s_axis_rx_data_n1,                          \
        m_axis_tx_meta_n1,                          \
        m_axis_tx_data_n1,                          \
        ipAddrN0,                                   \
        ipAddrN1,                                   \
        drop_every                                  \
    );

#define DRAIN(ninst)                                                                      \
if (!m_axis_mem_write_cmd_n##ninst.empty() && !writeCmdReady[ninst]) {                     \
    m_axis_mem_write_cmd_n##ninst.read(writeCmd[ninst]);                                   \
    writeCmdReady[ninst] = true;                                                           \
    writeRemainLen[ninst] = writeCmd[ninst].len;                                           \
    tally[ninst].mem_write_cmd++;                                                          \
    moved = true;                                                                          \
}                                                                                          \
if (writeCmdReady[ninst] && !m_axis_mem_write_data_n##ninst.empty()) {                      \
    net_axis<DATA_WIDTH> currWord;                                                         \
    m_axis_mem_write_data_n##ninst.read(currWord);                                         \
    writeRemainLen[ninst] -= (DATA_WIDTH/8);                                               \
    writeCmdReady[ninst] = (writeRemainLen[ninst] <= 0) ? false : true;                    \
    moved = true;                                                                          \
}                                                                                          \
if (!m_axis_mem_read_cmd_n##ninst.empty()) {                                               \
    m_axis_mem_read_cmd_n##ninst.read(readCmd[ninst]);                                     \
    memoryN##ninst.processRead(readCmd[ninst], s_axis_mem_read_data_n##ninst);             \
    tally[ninst].mem_read_cmd++;                                                           \
    moved = true;                                                                          \
}                                                                                          \
if (!m_axis_rx_ack_meta_n##ninst.empty()) {                                                \
    ackMeta am;                                                                            \
    m_axis_rx_ack_meta_n##ninst.read(am);                                                  \
    if (am.op_code == RC_ACK) tally[ninst].ack_meta_ack++;                                 \
    else if (is_read_response(am.op_code)) tally[ninst].ack_meta_rd_resp++;                \
    else tally[ninst].ack_meta_other++;                                                    \
    std::cout << std::dec << "CONSERVE ACKMETA endpoint=" << ninst << " opcode="            \
              << opcode_name(am.op_code) << " qpn=" << std::hex << am.qpn << std::dec      \
              << " lst=" << am.lst << std::endl;                                           \
    moved = true;                                                                          \
}

struct Tally {
    long sq_write;
    long sq_read;
    long ack_meta_ack;
    long ack_meta_rd_resp;
    long ack_meta_other;
    long mem_write_cmd;
    long mem_read_cmd;
};

static bool is_read_response(ibOpCode op) {
    return op == RC_RDMA_READ_RESP_FIRST || op == RC_RDMA_READ_RESP_MIDDLE ||
           op == RC_RDMA_READ_RESP_LAST || op == RC_RDMA_READ_RESP_ONLY;
}

static const char *opcode_name(ibOpCode op) {
    switch (op) {
    case RC_RDMA_WRITE_FIRST: return "WRITE_FIRST";
    case RC_RDMA_WRITE_MIDDLE: return "WRITE_MIDDLE";
    case RC_RDMA_WRITE_LAST: return "WRITE_LAST";
    case RC_RDMA_WRITE_ONLY: return "WRITE_ONLY";
    case RC_RDMA_READ_REQUEST: return "READ_REQUEST";
    case RC_RDMA_READ_RESP_FIRST: return "READ_RESP_FIRST";
    case RC_RDMA_READ_RESP_MIDDLE: return "READ_RESP_MIDDLE";
    case RC_RDMA_READ_RESP_LAST: return "READ_RESP_LAST";
    case RC_RDMA_READ_RESP_ONLY: return "READ_RESP_ONLY";
    case RC_ACK: return "ACK";
    default: return "OTHER";
    }
}

int main(int argc, char *argv[]) {
    SWITCHPORT(0);
    SWITCHPORT(1);
    IBTPORT(0);
    IBTPORT(1);

    newFakeDRAM<DATA_WIDTH> memoryN0;
    newFakeDRAM<DATA_WIDTH> memoryN1;
    std::vector<bool> writeCmdReady {false, false};
    std::vector<memCmd> writeCmd(2);
    std::vector<memCmd> readCmd(2);
    std::vector<int> writeRemainLen(2);

    Tally tally[2] = {};

    ap_uint<128> ipAddrN0, ipAddrN1;
    ipAddrN0(127, 64) = 0xfe80000000000000;
    ipAddrN0(63, 0)   = 0x92e2baff0b01d4d2;
    ipAddrN1(127, 64) = 0xfe80000000000000;
    ipAddrN1(63, 0)   = 0x92e2baff0b01d4d3;

    qpContext ctxN00 = qpContext(READY_RECV, 0x00, 0xac701e, 0x2a19d6, 0, 0x00);
    qpContext ctxN01 = qpContext(READY_RECV, 0x01, 0xbc701e, 0x3a19d6, 0, 0x00);
    qpContext ctxN10 = qpContext(READY_RECV, 0x00, 0x3a19d6, 0xbc701e, 0, 0x00);
    qpContext ctxN11 = qpContext(READY_RECV, 0x01, 0x2a19d6, 0xac701e, 0, 0x00);
    ifConnReq connInfoN0 = ifConnReq(1, 0, ipAddrN1, 5000);
    ifConnReq connInfoN1 = ifConnReq(0, 1, ipAddrN0, 5000);

    s_axis_qp_interface_n0.write(ctxN00);
    s_axis_qp_interface_n0.write(ctxN01);
    s_axis_qp_interface_n1.write(ctxN10);
    s_axis_qp_interface_n1.write(ctxN11);
    s_axis_qp_conn_interface_n0.write(connInfoN0);
    s_axis_qp_conn_interface_n1.write(connInfoN1);

    long settle = 0;
    while (settle < 32) {
        IBTRUN(0);
        IBTRUN(1);
        settle++;
    }

    std::vector<unsigned> sizes;
    bool alternate = true;
    bool read_only = false;
    bool write_only = false;
    long messages = 6;
    long idle_budget = 20000;
    int drop_every = 0;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--sizes" && i + 1 < argc) {
            std::string v = argv[++i];
            size_t p = 0;
            while (p < v.size()) {
                size_t q = v.find(',', p);
                if (q == std::string::npos) q = v.size();
                sizes.push_back((unsigned)atol(v.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
        else if (a == "--messages" && i + 1 < argc) messages = atol(argv[++i]);
        else if (a == "--read-only") { read_only = true; alternate = false; }
        else if (a == "--write-only") { write_only = true; alternate = false; }
        else if (a == "--idle-budget" && i + 1 < argc) idle_budget = atol(argv[++i]);
        else if (a == "--drop" && i + 1 < argc) drop_every = atoi(argv[++i]);
    }
    if (sizes.empty()) { sizes.push_back(6144); sizes.push_back(20480); }

    std::cout << std::dec << "CONSERVE CONFIG pmtu=" << PMTU << " data_width=" << DATA_WIDTH
              << " messages=" << messages << " pattern="
              << (read_only ? "read_only" : (write_only ? "write_only" : "alternating"))
              << " drop_every=" << drop_every
              << " sizes=";
    for (size_t i = 0; i < sizes.size(); i++) std::cout << sizes[i] << (i + 1 < sizes.size() ? "," : "");
    std::cout << std::endl;

    ap_uint<64> laddr = 0x400;
    ap_uint<64> raddr = 0x500;

    for (long m = 0; m < messages; m++) {
        unsigned len = sizes[m % sizes.size()];
        bool do_read = read_only ? true : (write_only ? false : ((m % 2) == 0));

        if (do_read) {
            s_axis_sq_meta_n0.write(txMeta(RC_RDMA_READ_REQUEST, 0x01, 0, 1, 0, laddr, raddr, len, 0));
            tally[0].sq_read++;
            std::cout << std::dec << "CONSERVE OFFER message=" << m << " read len=" << len
                      << " sq_entries=1" << std::endl;
        }
        else {
            unsigned remaining = len;
            unsigned packets = 0;
            ap_uint<64> la = laddr;
            ap_uint<64> ra = raddr;
            while (remaining > 0) {
                unsigned chunk = remaining > PMTU ? PMTU : remaining;
                ibOpCode op;
                if (packets == 0 && chunk == remaining) op = RC_RDMA_WRITE_ONLY;
                else if (packets == 0) op = RC_RDMA_WRITE_FIRST;
                else if (chunk == remaining) op = RC_RDMA_WRITE_LAST;
                else op = RC_RDMA_WRITE_MIDDLE;
                ap_uint<1> lst = (chunk == remaining) ? 1 : 0;
                s_axis_sq_meta_n0.write(txMeta(op, 0x01, 0, lst, 0, la, ra, chunk, 0));
                tally[0].sq_write++;
                packets++;
                la += chunk;
                ra += chunk;
                remaining -= chunk;
            }
            std::cout << std::dec << "CONSERVE OFFER message=" << m << " write len=" << len
                      << " sq_entries=" << packets << std::endl;
        }

        long quiet = 0;
        while (quiet < idle_budget) {
            bool moved = false;
            IBTRUN(0);
            IBTRUN(1);
            SWITCHRUN_LOCAL();
            DRAIN(0);
            DRAIN(1);
            if (!moved) quiet++; else quiet = 0;
        }
    }

    for (int n = 0; n < 2; n++) {
        std::cout << std::dec << "CONSERVE TALLY endpoint=" << n
                  << " sq_write=" << tally[n].sq_write
                  << " sq_read=" << tally[n].sq_read
                  << " ack_meta_ack=" << tally[n].ack_meta_ack
                  << " ack_meta_rd_resp=" << tally[n].ack_meta_rd_resp
                  << " ack_meta_other=" << tally[n].ack_meta_other
                  << " mem_write_cmd=" << tally[n].mem_write_cmd
                  << " mem_read_cmd=" << tally[n].mem_read_cmd
                  << std::endl;
    }

    long head_write = tally[0].sq_write;
    long tail_write = tally[0].ack_meta_ack;
    long head_read = tally[0].sq_read;
    long tail_read = tally[0].ack_meta_rd_resp;

    std::cout << std::dec << "CONSERVE WINDOW write_entry head=" << head_write << " tail=" << tail_write
              << " drift=" << (tail_write - head_write) << std::endl;
    std::cout << std::dec << "CONSERVE WINDOW read_entry head=" << head_read << " tail=" << tail_read
              << " drift=" << (tail_read - head_read) << std::endl;

    bool conserved = (tail_write == head_write) && (tail_read == head_read);
    std::cout << (conserved ? "CONSERVE RESULT PASS conserved" : "CONSERVE RESULT FAIL not conserved")
              << std::endl;

    std::cout << std::dec << "CONSERVE COUNTERS n0 psn_drop=" << regInvalidPsnDropCount_n0
              << " retrans=" << regRetransCount_n0
              << " ibv_rx=" << regValidIbvCountRx_n0
              << " ibv_tx=" << regValidIbvCountTx_n0 << std::endl;
    std::cout << std::dec << "CONSERVE COUNTERS n1 psn_drop=" << regInvalidPsnDropCount_n1
              << " retrans=" << regRetransCount_n1
              << " ibv_rx=" << regValidIbvCountRx_n1
              << " ibv_tx=" << regValidIbvCountTx_n1 << std::endl;

    return conserved ? 0 : 1;
}
