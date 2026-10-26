// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_rdma_chain;

    localparam integer CLK_PERIOD = 2558;
    localparam integer QPS_READY_RECV = 32'd2;
    localparam integer TEST_PID = 0;
    localparam integer TEST_VFID = 0;
    localparam integer MAX_WR = 4096;
    localparam integer SETTLE_LIMIT = 60000;

    integer messages = 24;
    integer pattern = 2;
    integer gap = 400;
    integer fixed_size = 0;
    integer reap_delay = 0;
    integer stop_reaping_class = 2;
    integer seed = 1;
    integer expect_all_reaped = 1;
    integer settle_cycles = 4000;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    metaIntf #(.STYPE(dreq_t)) sq_in (aclk, aresetn);
    metaIntf #(.STYPE(dreq_t)) sq_out (aclk, aresetn);
    metaIntf #(.STYPE(dack_t)) ack_in (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) cq_net (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) cq_user [N_REGIONS] (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) cq_host (aclk, aresetn);

    rdma_flow inst_rdma_flow (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_req(sq_in),
        .m_req(sq_out),
        .s_ack(ack_in),
        .m_ack(cq_net)
    );

    logic [N_REGIONS_BITS-1:0] rx_vfid;

    rdma_meta_rx_arbiter inst_rx_arbiter (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_meta(cq_net),
        .m_meta_user(cq_user),
        .m_meta_host(cq_host),
        .vfid(rx_vfid)
    );

    for (genvar gi = 0; gi < N_REGIONS; gi++) begin
        assign cq_user[gi].ready = 1'b1;
    end

    logic clear_rd = 1'b0;
    logic clear_wr = 1'b0;
    logic [PID_BITS-1:0] clear_addr = TEST_PID;
    logic [31:0] stat_cnt_rd;
    logic [31:0] stat_cnt_wr;
    logic cnt_rd_hit, cnt_wr_hit;
    logic [PID_BITS-1:0] cnt_rd_pid, cnt_wr_pid;
    logic [31:0] cnt_rd_next, cnt_wr_next;

    rdma_cq_count #(
        .QDEPTH(8)
    ) inst_cq_count (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_rdma_done(cq_host),
        .clear_rd(clear_rd),
        .clear_addr_rd(clear_addr),
        .clear_wr(clear_wr),
        .clear_addr_wr(clear_addr),
        .stat_pid(TEST_PID[PID_BITS-1:0]),
        .stat_cnt_rd(stat_cnt_rd),
        .stat_cnt_wr(stat_cnt_wr),
        .cnt_rd_hit(cnt_rd_hit),
        .cnt_rd_pid(cnt_rd_pid),
        .cnt_rd_next(cnt_rd_next),
        .cnt_wr_hit(cnt_wr_hit),
        .cnt_wr_pid(cnt_wr_pid),
        .cnt_wr_next(cnt_wr_next)
    );

    logic [RDMA_REQ_BITS-1:0] sq_tdata;
    logic sq_tvalid, sq_tready;

    always_comb begin
        sq_tdata = 0;
        sq_tdata[0+:RDMA_OPCODE_BITS] = sq_out.data.req_1.opcode;
        sq_tdata[32+:RDMA_QPN_BITS] = {{RDMA_QPN_BITS-DEST_BITS-PID_BITS{1'b0}},
                                       sq_out.data.req_1.vfid, sq_out.data.req_1.pid};
        sq_tdata[32+RDMA_QPN_BITS+0+:1] = sq_out.data.req_1.host;
        sq_tdata[32+RDMA_QPN_BITS+1+:1] = sq_out.data.req_1.last;
        sq_tdata[32+RDMA_QPN_BITS+2+:OFFS_BITS] = sq_out.data.req_1.offs;
        sq_tdata[32+RDMA_QPN_BITS+2+OFFS_BITS+:RDMA_VADDR_BITS] = {16'h0000, sq_out.data.req_1.vaddr};
        sq_tdata[32+RDMA_QPN_BITS+2+OFFS_BITS+RDMA_VADDR_BITS+:RDMA_VADDR_BITS] =
            {10'h000, sq_out.data.req_2.strm, sq_out.data.req_1.dest, sq_out.data.req_2.vaddr};
        sq_tdata[32+RDMA_QPN_BITS+2+OFFS_BITS+2*RDMA_VADDR_BITS+:RDMA_LEN_BITS] = sq_out.data.req_1.len;
        sq_tdata[32+RDMA_QPN_BITS+2+OFFS_BITS+2*RDMA_VADDR_BITS+RDMA_LEN_BITS+:RDMA_IMM_BITS] =
            {sq_out.data.req_2.offs[3:0], sq_out.data.req_2.len};
    end

    assign sq_tvalid = sq_out.valid;
    assign sq_out.ready = sq_tready;

    logic [RDMA_ACK_BITS-1:0] ack_meta_data;
    logic ack_tvalid, ack_tready;

    assign ack_in.data.ack.opcode = ack_meta_data[0+:OPCODE_BITS];
    assign ack_in.data.ack.remote = 1'b1;
    assign ack_in.data.ack.pid  = ack_meta_data[32+:PID_BITS];
    assign ack_in.data.ack.vfid = ack_meta_data[32+PID_BITS+:DEST_BITS];
    assign ack_in.data.ack.host = ack_meta_data[32+RDMA_QPN_BITS+:1];
    assign ack_in.data.ack.dest = ack_meta_data[32+RDMA_QPN_BITS+1+:DEST_BITS];
    assign ack_in.data.ack.strm = ack_meta_data[32+RDMA_QPN_BITS+1+DEST_BITS+:STRM_BITS];
    assign ack_in.data.ack.rsrvd = 0;
    assign ack_in.data.last = ack_meta_data[32+RDMA_QPN_BITS+1+DEST_BITS+STRM_BITS+:1];
    assign ack_in.valid = ack_tvalid;
    assign ack_tready = ack_in.ready;

    logic [511:0] tx_tdata, rx_tdata;
    logic [63:0]  tx_tkeep, rx_tkeep;
    logic         tx_tlast, rx_tlast, tx_tvalid, rx_tvalid, tx_tready, rx_tready;

    logic [143:0] wr_cmd_tdata, rd_cmd_tdata;
    logic wr_cmd_tvalid, wr_cmd_tready, rd_cmd_tvalid, rd_cmd_tready;

    logic [511:0] mwr_tdata, mrd_tdata;
    logic [63:0]  mwr_tkeep, mrd_tkeep;
    logic mwr_tlast, mwr_tvalid, mwr_tready, mrd_tlast, mrd_tvalid, mrd_tready;

    logic [183:0] qp_tdata, conn_tdata;
    logic qp_tvalid, qp_tready, conn_tvalid, conn_tready;

    logic [103:0] dbg0_tdata, dbg1_tdata, dbg2_tdata;
    logic dbg0_tvalid, dbg1_tvalid, dbg2_tvalid;

    logic [31:0] regCrcDropPkgCount, regInvalidPsnDropCount, regRetransCount, regIbvCountRx, regIbvCountTx;
    logic regCrcDropPkgCount_ap_vld, regInvalidPsnDropCount_ap_vld, regRetransCount_ap_vld;
    logic regIbvCountRx_ap_vld, regIbvCountTx_ap_vld;

    rocev2_top inst_roce (
        .s_axis_rx_data_TDATA(rx_tdata),
        .s_axis_rx_data_TKEEP(rx_tkeep),
        .s_axis_rx_data_TSTRB(64'h0),
        .s_axis_rx_data_TLAST({1'b0, rx_tlast}),
        .s_axis_rx_data_TVALID(rx_tvalid),
        .s_axis_rx_data_TREADY(rx_tready),

        .m_axis_tx_data_TDATA(tx_tdata),
        .m_axis_tx_data_TKEEP(tx_tkeep),
        .m_axis_tx_data_TSTRB(),
        .m_axis_tx_data_TLAST(tx_tlast),
        .m_axis_tx_data_TVALID(tx_tvalid),
        .m_axis_tx_data_TREADY(tx_tready),

        .s_axis_sq_meta_TDATA(sq_tdata),
        .s_axis_sq_meta_TVALID(sq_tvalid),
        .s_axis_sq_meta_TREADY(sq_tready),

        .m_axis_rx_ack_meta_TDATA(ack_meta_data[55:0]),
        .m_axis_rx_ack_meta_TVALID(ack_tvalid),
        .m_axis_rx_ack_meta_TREADY(ack_tready),

        .m_axis_mem_write_cmd_TDATA(wr_cmd_tdata),
        .m_axis_mem_write_cmd_TVALID(wr_cmd_tvalid),
        .m_axis_mem_write_cmd_TREADY(wr_cmd_tready),

        .m_axis_mem_read_cmd_TDATA(rd_cmd_tdata),
        .m_axis_mem_read_cmd_TVALID(rd_cmd_tvalid),
        .m_axis_mem_read_cmd_TREADY(rd_cmd_tready),

        .m_axis_mem_write_data_TDATA(mwr_tdata),
        .m_axis_mem_write_data_TKEEP(mwr_tkeep),
        .m_axis_mem_write_data_TSTRB(),
        .m_axis_mem_write_data_TLAST(mwr_tlast),
        .m_axis_mem_write_data_TVALID(mwr_tvalid),
        .m_axis_mem_write_data_TREADY(mwr_tready),

        .s_axis_mem_read_data_TDATA(mrd_tdata),
        .s_axis_mem_read_data_TKEEP(mrd_tkeep),
        .s_axis_mem_read_data_TSTRB(64'h0),
        .s_axis_mem_read_data_TLAST({1'b0, mrd_tlast}),
        .s_axis_mem_read_data_TVALID(mrd_tvalid),
        .s_axis_mem_read_data_TREADY(mrd_tready),

        .s_axis_qp_interface_TDATA(qp_tdata),
        .s_axis_qp_interface_TVALID(qp_tvalid),
        .s_axis_qp_interface_TREADY(qp_tready),

        .s_axis_qp_conn_interface_TDATA(conn_tdata),
        .s_axis_qp_conn_interface_TVALID(conn_tvalid),
        .s_axis_qp_conn_interface_TREADY(conn_tready),

        .local_ip_address(128'hfe80_0000_0000_0000_92e2_baff_0b01_d4d2),

        .m_axis_dbg_0_TDATA(dbg0_tdata),
        .m_axis_dbg_0_TVALID(dbg0_tvalid),
        .m_axis_dbg_0_TREADY(1'b1),
        .m_axis_dbg_1_TDATA(dbg1_tdata),
        .m_axis_dbg_1_TVALID(dbg1_tvalid),
        .m_axis_dbg_1_TREADY(1'b1),
        .m_axis_dbg_2_TDATA(dbg2_tdata),
        .m_axis_dbg_2_TVALID(dbg2_tvalid),
        .m_axis_dbg_2_TREADY(1'b1),

        .regCrcDropPkgCount(regCrcDropPkgCount),
        .regCrcDropPkgCount_ap_vld(regCrcDropPkgCount_ap_vld),
        .regInvalidPsnDropCount(regInvalidPsnDropCount),
        .regInvalidPsnDropCount_ap_vld(regInvalidPsnDropCount_ap_vld),
        .regRetransCount(regRetransCount),
        .regRetransCount_ap_vld(regRetransCount_ap_vld),
        .regIbvCountRx(regIbvCountRx),
        .regIbvCountRx_ap_vld(regIbvCountRx_ap_vld),
        .regIbvCountTx(regIbvCountTx),
        .regIbvCountTx_ap_vld(regIbvCountTx_ap_vld),

        .ap_clk(aclk),
        .ap_rst_n(aresetn)
    );

    assign ack_meta_data[63:56] = 8'h00;

    assign rx_tdata = tx_tdata;
    assign rx_tkeep = tx_tkeep;
    assign rx_tlast = tx_tlast;
    assign rx_tvalid = tx_tvalid;
    assign tx_tready = rx_tready;

    assign wr_cmd_tready = 1'b1;
    assign mwr_tready = 1'b1;

    localparam integer RD_CMD_DEPTH = 16;

    integer rd_cmd_len [RD_CMD_DEPTH];
    integer rd_pushes = 0;
    integer rd_pops = 0;
    integer rd_bytes_left = 0;
    integer mem_rd_cmds = 0;
    integer mem_wr_cmds = 0;

    logic rd_cmd_avail;
    logic rd_start_next;

    assign rd_cmd_avail = (rd_pushes != rd_pops);
    assign rd_cmd_tready = ((rd_pushes - rd_pops) < RD_CMD_DEPTH);
    assign mrd_tvalid = (rd_bytes_left > 0);
    assign mrd_tdata = {8{64'h0123_4567_89ab_cdef}};
    assign mrd_tkeep = (rd_bytes_left >= 64) ? {64{1'b1}}
                                             : ({64{1'b1}} >> (64 - rd_bytes_left));
    assign mrd_tlast = (rd_bytes_left > 0) && (rd_bytes_left <= 64);
    assign rd_start_next = rd_cmd_avail &&
                           ((rd_bytes_left == 0) ||
                            (mrd_tvalid && mrd_tready && (rd_bytes_left <= 64)));

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            rd_pushes <= 0;
            rd_pops <= 0;
            rd_bytes_left <= 0;
        end
        else begin
            if (wr_cmd_tvalid && wr_cmd_tready) mem_wr_cmds <= mem_wr_cmds + 1;

            if (rd_cmd_tvalid && rd_cmd_tready) begin
                rd_cmd_len[rd_pushes % RD_CMD_DEPTH] <= rd_cmd_tdata[130:103];
                rd_pushes <= rd_pushes + 1;
                mem_rd_cmds <= mem_rd_cmds + 1;
            end

            if (mrd_tvalid && mrd_tready) begin
                rd_bytes_left <= (rd_bytes_left > 64) ? (rd_bytes_left - 64) : 0;
            end

            if (rd_start_next) begin
                rd_bytes_left <= rd_cmd_len[rd_pops % RD_CMD_DEPTH];
                rd_pops <= rd_pops + 1;
            end
        end
    end

    integer frames_looped = 0;
    always_ff @(posedge aclk) begin
        if (aresetn && tx_tvalid && tx_tready && tx_tlast) frames_looped <= frames_looped + 1;
    end

    integer sq_offered = 0;
    integer sq_taken = 0;
    integer sq_refused = 0;

    integer completions_offered = 0;
    integer completions_ack = 0;
    integer completions_rdresp = 0;
    integer cq_host_offered = 0;
    integer cq_host_taken = 0;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (ack_tvalid && ack_tready) begin
                completions_offered <= completions_offered + 1;
                if (is_opcode_rd_resp(ack_meta_data[0+:OPCODE_BITS]))
                    completions_rdresp <= completions_rdresp + 1;
                else
                    completions_ack <= completions_ack + 1;
            end
            if (cq_host.valid && !cq_host.ready) cq_host_offered <= cq_host_offered + 1;
            if (cq_host.valid && cq_host.ready) cq_host_taken <= cq_host_taken + 1;
        end
    end

    integer failures = 0;
    integer decr_read = 0;
    integer decr_write = 0;
    integer polled_rd = 0;
    integer polled_wr = 0;
    integer posted_rd = 0;
    integer posted_wr = 0;

    bit wr_is_read [MAX_WR];
    integer wr_posted = 0;
    integer wr_head = 0;

    task automatic clear_counters();
        clear_rd = 1'b1;
        clear_wr = 1'b1;
        @(posedge aclk);
        clear_rd = 1'b0;
        clear_wr = 1'b0;
        repeat (4) @(posedge aclk);
    endtask

    task automatic push_qp(input int qpn, input int rpsn, input int lpsn);
        qp_tdata = '0;
        qp_tdata[31:0]    = QPS_READY_RECV;
        qp_tdata[55:32]   = qpn[23:0];
        qp_tdata[79:56]   = rpsn[23:0];
        qp_tdata[103:80]  = lpsn[23:0];
        qp_tvalid = 1'b1;
        do @(posedge aclk); while (!qp_tready);
        qp_tvalid = 1'b0;
        @(posedge aclk);
    endtask

    task automatic push_conn(input int qpn, input int rqpn);
        conn_tdata = '0;
        conn_tdata[15:0]    = qpn[15:0];
        conn_tdata[39:16]   = rqpn[23:0];
        conn_tdata[167:40]  = 128'hfe80_0000_0000_0000_92e2_baff_0b01_d4d2;
        conn_tdata[183:168] = 16'd5000;
        conn_tvalid = 1'b1;
        do @(posedge aclk); while (!conn_tready);
        conn_tvalid = 1'b0;
        @(posedge aclk);
    endtask

    task automatic post_sq(input int opcode, input int len, input int offs, output bit taken);
        int waited;
        taken = 1'b0;
        waited = 0;
        sq_in.data = '0;
        sq_in.data.req_1.opcode = opcode[OPCODE_BITS-1:0];
        sq_in.data.req_1.strm = STRM_RDMA;
        sq_in.data.req_1.remote = 1'b1;
        sq_in.data.req_1.rdma = 1'b1;
        sq_in.data.req_1.host = 1'b1;
        sq_in.data.req_1.last = 1'b1;
        sq_in.data.req_1.actv = 1'b1;
        sq_in.data.req_1.vfid = TEST_VFID;
        sq_in.data.req_1.pid = TEST_PID;
        sq_in.data.req_1.dest = 0;
        sq_in.data.req_1.len = len;
        sq_in.data.req_1.vaddr = 48'h1000 + offs;
        sq_in.data.req_2 = sq_in.data.req_1;
        sq_in.data.req_2.vaddr = 48'h2000 + offs;
        sq_in.valid = 1'b1;
        while (waited < 4000 && !taken) begin
            @(posedge aclk);
            if (sq_in.ready) taken = 1'b1;
            waited = waited + 1;
        end
        sq_in.valid = 1'b0;
        sq_offered = sq_offered + 1;
        if (taken) sq_taken = sq_taken + 1;
        else sq_refused = sq_refused + 1;
        @(posedge aclk);
    endtask

    task automatic post_wr(input bit is_read);
        if (wr_posted < MAX_WR) begin
            wr_is_read[wr_posted] = is_read;
            wr_posted = wr_posted + 1;
        end
        if (is_read) posted_rd = posted_rd + 1;
        else posted_wr = posted_wr + 1;
    endtask

    task automatic poll_cq(input bit reap_read, input bit reap_write, output int fulfilled);
        int avail_rd;
        int avail_wr;
        fulfilled = 0;
        @(posedge aclk);
        avail_wr = stat_cnt_wr - decr_write;
        avail_rd = stat_cnt_rd - decr_read;
        while (wr_head < wr_posted) begin
            if (wr_is_read[wr_head]) begin
                if (reap_read && avail_rd >= 1) begin
                    avail_rd = avail_rd - 1;
                    decr_read = decr_read + 1;
                    polled_rd = polled_rd + 1;
                    wr_head = wr_head + 1;
                    fulfilled = fulfilled + 1;
                end
                else break;
            end
            else begin
                if (reap_write && avail_wr >= 1) begin
                    avail_wr = avail_wr - 1;
                    decr_write = decr_write + 1;
                    polled_wr = polled_wr + 1;
                    wr_head = wr_head + 1;
                    fulfilled = fulfilled + 1;
                end
                else break;
            end
        end
    endtask

    task automatic drain_cq(input bit reap_read, input bit reap_write, input int budget);
        int got;
        int spent;
        spent = 0;
        while (wr_head < wr_posted && spent < budget) begin
            poll_cq(reap_read, reap_write, got);
            if (got == 0) spent = spent + 1;
        end
    endtask

    task automatic census(input string tag);
        $display("CHAIN CENSUS %s sq_in(v=%0b r=%0b) sq_out(v=%0b r=%0b) ack_in(v=%0b r=%0b) cq_net(v=%0b r=%0b) cq_host(v=%0b r=%0b) tx(v=%0b r=%0b) rx(v=%0b r=%0b) sq_meta(v=%0b r=%0b) rdcmd(v=%0b r=%0b) wrcmd(v=%0b r=%0b) memrd(v=%0b r=%0b) memwr(v=%0b r=%0b)",
                 tag,
                 sq_in.valid, sq_in.ready, sq_out.valid, sq_out.ready,
                 ack_in.valid, ack_in.ready, cq_net.valid, cq_net.ready,
                 cq_host.valid, cq_host.ready, tx_tvalid, tx_tready, rx_tvalid, rx_tready,
                 sq_tvalid, sq_tready, rd_cmd_tvalid, rd_cmd_tready,
                 wr_cmd_tvalid, wr_cmd_tready, mrd_tvalid, mrd_tready, mwr_tvalid, mwr_tready);
        $display("CHAIN FLOW %s state_C=%0d addr_C=%0h head=%0d tail=%0d issued=%0b rd_bytes_left=%0d cmds_queued=%0d sq_offered=%0d sq_taken=%0d sq_refused=%0d",
                 tag, inst_rdma_flow.state_C, inst_rdma_flow.addr_C,
                 inst_rdma_flow.head, inst_rdma_flow.tail, inst_rdma_flow.issued,
                 rd_bytes_left, rd_pushes - rd_pops, sq_offered, sq_taken, sq_refused);
    endtask

    task automatic report(input string tag);
        $display("CHAIN STATE %s posted_wr=%0d posted_rd=%0d sq_frames=%0d completions=%0d ack=%0d rdresp=%0d cnt_wr=%0d cnt_rd=%0d polled_wr=%0d polled_rd=%0d outstanding=%0d cqhost_offered=%0d cqhost_taken=%0d memrd=%0d memwr=%0d psn_drop=%0d retrans=%0d ibv_rx=%0d ibv_tx=%0d deadlock=%0b",
                 tag, posted_wr, posted_rd, frames_looped, completions_offered,
                 completions_ack, completions_rdresp, stat_cnt_wr, stat_cnt_rd,
                 polled_wr, polled_rd, wr_posted - wr_head, cq_host_offered, cq_host_taken,
                 mem_rd_cmds, mem_wr_cmds, regInvalidPsnDropCount, regRetransCount,
                 regIbvCountRx, regIbvCountTx, inst_roce.find_df_deadlock);
    endtask

    task automatic check(input string name, input bit got, input bit want);
        if (got === want) begin
            $display("CHAIN RESULT PASS %s", name);
        end
        else begin
            $display("CHAIN RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    task automatic send_message(input bit is_read, input int len);
        bit taken;
        int remaining;
        int chunk;
        int packets;
        int opc;
        post_wr(is_read);
        if (is_read) begin
            post_sq(RC_RDMA_READ_REQUEST, len, 0, taken);
            if (!taken) $display("CHAIN NOTE read request refused len=%0d", len);
        end
        else begin
            remaining = len;
            packets = 0;
            while (remaining > 0) begin
                chunk = (remaining > PMTU_BYTES) ? PMTU_BYTES : remaining;
                if (packets == 0 && chunk == remaining) opc = RC_RDMA_WRITE_ONLY;
                else if (packets == 0) opc = RC_RDMA_WRITE_FIRST;
                else if (chunk == remaining) opc = RC_RDMA_WRITE_LAST;
                else opc = RC_RDMA_WRITE_MIDDLE;
                post_sq(opc, chunk, len - remaining, taken);
                if (!taken) $display("CHAIN NOTE write refused len=%0d packet=%0d", len, packets);
                packets = packets + 1;
                remaining = remaining - chunk;
            end
        end
    endtask

    integer rng_state = 1;

    function automatic int rnd_next();
        integer x;
        x = rng_state;
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        if (x == 0) x = 1;
        rng_state = x;
        rnd_next = x;
    endfunction

    function automatic int rnd_range(input int n);
        integer v;
        v = rnd_next();
        if (v < 0) v = -v;
        rnd_range = (n <= 0) ? 0 : (v % n);
    endfunction

    function automatic int pick_size();
        int tbl [8];
        tbl[0] = 64; tbl[1] = 128; tbl[2] = 256; tbl[3] = 1024;
        tbl[4] = 4088; tbl[5] = 4096; tbl[6] = 6144; tbl[7] = 8192;
        pick_size = tbl[rnd_range(8)];
    endfunction

    initial begin
        int runs;
        bit reap_rd;
        bit reap_wr;
        bit is_read;
        int len;

        void'($value$plusargs("messages=%d", messages));
        void'($value$plusargs("pattern=%d", pattern));
        void'($value$plusargs("gap=%d", gap));
        void'($value$plusargs("size=%d", fixed_size));
        void'($value$plusargs("reap_delay=%d", reap_delay));
        void'($value$plusargs("stop_reaping_class=%d", stop_reaping_class));
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("expect_all_reaped=%d", expect_all_reaped));
        void'($value$plusargs("settle=%d", settle_cycles));

        rng_state = (seed == 0) ? 1 : seed;

        sq_in.valid = 1'b0;
        sq_in.data = '0;
        qp_tvalid = 1'b0;
        conn_tvalid = 1'b0;
        qp_tdata = '0;
        conn_tdata = '0;

        aresetn = 1'b0;
        repeat (64) @(posedge aclk);
        aresetn = 1'b1;
        repeat (256) @(posedge aclk);

        $display("CHAIN CONFIG messages=%0d pattern=%0d gap=%0d size=%0d reap_delay=%0d stop_reaping_class=%0d seed=%0d",
                 messages, pattern, gap, fixed_size, reap_delay, stop_reaping_class, seed);

        clear_counters();
        push_qp(0, 24'h2a19d6, 24'hac701e);
        push_qp(1, 24'hac701e, 24'h2a19d6);
        push_conn(0, 1);
        push_conn(1, 0);
        repeat (256) @(posedge aclk);
        report("after_bringup");

        for (int m = 0; m < messages; m++) begin
            case (pattern)
                0: is_read = 1'b0;
                1: is_read = 1'b1;
                2: is_read = (m % 2 == 1);
                default: is_read = (rnd_range(2) == 1);
            endcase
            len = (fixed_size != 0) ? fixed_size : ((pattern == 3) ? pick_size() : 0);
            if (len == 0) len = pick_size();

            send_message(is_read, len);

            reap_rd = (stop_reaping_class != 0);
            reap_wr = (stop_reaping_class != 1);
            if (stop_reaping_class == 3) begin
                reap_rd = !is_read;
                reap_wr = is_read;
            end

            if (reap_delay == 0 || (m % (reap_delay + 1) == reap_delay)) begin
                drain_cq(reap_rd, reap_wr, 8);
            end
            repeat ((pattern == 3) ? rnd_range(gap + 1) : gap) @(posedge aclk);
        end

        repeat (settle_cycles) @(posedge aclk);
        drain_cq(1'b1, 1'b1, 64);
        report("after_traffic");
        census("after_traffic");

        check("the transport reports no invalid packet sequence number drop", (regInvalidPsnDropCount == 0), 1'b1);
        check("the transport reports no retransmission", (regRetransCount == 0), 1'b1);
        check("the generated deadlock detector did not fire", (inst_roce.find_df_deadlock === 1'b0), 1'b1);
        check("one completion reaches the host accounting per completion the flow module emitted",
              (cq_host_taken == completions_offered), 1'b1);
        check("the two counters together account for every completion",
              ((stat_cnt_rd + stat_cnt_wr) == completions_offered), 1'b1);

        if (expect_all_reaped) begin
            check("every work request is fulfilled", (wr_head == wr_posted), 1'b1);
        end
        else begin
            check("work requests are left outstanding", (wr_head < wr_posted), 1'b1);
        end

        if (failures == 0) begin
            $display("CHAIN RESULT PASS all cases");
        end
        else begin
            $display("CHAIN RESULT FAIL %0d cases", failures);
        end
        $finish;
    end

    initial begin
        #(CLK_PERIOD * SETTLE_LIMIT);
        $display("CHAIN STATE watchdog_expired");
        report("watchdog");
        census("watchdog");
        $display("CHAIN RESULT FAIL watchdog expired at %0d cycles", SETTLE_LIMIT);
        $finish;
    end

endmodule
