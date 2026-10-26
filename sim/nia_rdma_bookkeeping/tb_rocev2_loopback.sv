// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

module tb_rocev2_loopback;

    localparam integer CLK_PERIOD = 2558;
    localparam integer OP_WRITE_FIRST = 32'h06;
    localparam integer OP_WRITE_MIDDLE = 32'h07;
    localparam integer OP_WRITE_LAST = 32'h08;
    localparam integer OP_WRITE_ONLY = 32'h0A;
    localparam integer PMTU_BYTES = 4096;
    localparam integer OP_READ_REQ = 32'h0C;
    localparam integer OP_READ_RESP_ONLY = 32'h10;
    localparam integer OP_ACK = 32'h11;
    localparam integer QPS_READY_RECV = 32'd2;
    localparam integer IDLE_LIMIT = 20000;

    integer messages = 12;
    integer pattern = 2;
    integer gap = 400;
    integer fixed_size = 0;

    logic ap_clk = 1'b0;
    logic ap_rst_n = 1'b0;

    always #(CLK_PERIOD/2) ap_clk = ~ap_clk;

    logic [511:0] tx_tdata, rx_tdata;
    logic [63:0]  tx_tkeep, rx_tkeep;
    logic         tx_tlast, rx_tlast;
    logic         tx_tvalid, rx_tvalid;
    logic         tx_tready, rx_tready;

    logic [247:0] sq_tdata;
    logic         sq_tvalid, sq_tready;

    logic [55:0]  ack_tdata;
    logic         ack_tvalid, ack_tready;

    logic [143:0] wr_cmd_tdata, rd_cmd_tdata;
    logic         wr_cmd_tvalid, wr_cmd_tready, rd_cmd_tvalid, rd_cmd_tready;

    logic [511:0] mwr_tdata;
    logic [63:0]  mwr_tkeep;
    logic         mwr_tlast, mwr_tvalid, mwr_tready;

    logic [511:0] mrd_tdata;
    logic [63:0]  mrd_tkeep;
    logic         mrd_tlast, mrd_tvalid, mrd_tready;

    logic [183:0] qp_tdata, conn_tdata;
    logic         qp_tvalid, qp_tready, conn_tvalid, conn_tready;

    logic [103:0] dbg0_tdata, dbg1_tdata, dbg2_tdata;
    logic         dbg0_tvalid, dbg0_tready, dbg1_tvalid, dbg1_tready, dbg2_tvalid, dbg2_tready;

    logic [31:0] regCrcDropPkgCount, regInvalidPsnDropCount, regRetransCount, regIbvCountRx, regIbvCountTx;
    logic        regCrcDropPkgCount_ap_vld, regInvalidPsnDropCount_ap_vld, regRetransCount_ap_vld;
    logic        regIbvCountRx_ap_vld, regIbvCountTx_ap_vld;

    rocev2_top dut (
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

        .m_axis_rx_ack_meta_TDATA(ack_tdata),
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
        .m_axis_dbg_0_TREADY(dbg0_tready),
        .m_axis_dbg_1_TDATA(dbg1_tdata),
        .m_axis_dbg_1_TVALID(dbg1_tvalid),
        .m_axis_dbg_1_TREADY(dbg1_tready),
        .m_axis_dbg_2_TDATA(dbg2_tdata),
        .m_axis_dbg_2_TVALID(dbg2_tvalid),
        .m_axis_dbg_2_TREADY(dbg2_tready),

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

        .ap_clk(ap_clk),
        .ap_rst_n(ap_rst_n)
    );

    assign rx_tdata = tx_tdata;
    assign rx_tkeep = tx_tkeep;
    assign rx_tlast = tx_tlast;
    assign rx_tvalid = tx_tvalid;
    assign tx_tready = rx_tready;

    assign dbg0_tready = 1'b1;
    assign dbg1_tready = 1'b1;
    assign dbg2_tready = 1'b1;
    assign wr_cmd_tready = 1'b1;
    assign mwr_tready = 1'b1;
    assign ack_tready = 1'b1;

    integer frames_looped = 0;
    integer mem_wr_cmds = 0;
    integer mem_rd_cmds = 0;
    integer ack_cnt_ack = 0;
    integer ack_cnt_rdresp = 0;
    integer ack_cnt_other = 0;
    integer sq_writes = 0;
    integer sq_reads = 0;
    integer idle = 0;
    integer moved = 0;

    always_ff @(posedge ap_clk) begin
        if (ap_rst_n) begin
            if (tx_tvalid && tx_tready && tx_tlast) frames_looped <= frames_looped + 1;
            if (wr_cmd_tvalid && wr_cmd_tready) mem_wr_cmds <= mem_wr_cmds + 1;
            if (ack_tvalid && ack_tready) begin
                if (ack_tdata[31:0] == OP_ACK) ack_cnt_ack <= ack_cnt_ack + 1;
                else if (ack_tdata[31:0] >= 32'h0D && ack_tdata[31:0] <= 32'h10)
                    ack_cnt_rdresp <= ack_cnt_rdresp + 1;
                else ack_cnt_other <= ack_cnt_other + 1;
                $display("ROCELB ACKMETA opcode=%02h qpn=%04h lst=%0b", ack_tdata[7:0], ack_tdata[47:32], ack_tdata[55]);
            end
        end
    end

    integer rd_beats_left = 0;

    assign rd_cmd_tready = (rd_beats_left == 0);
    assign mrd_tvalid = (rd_beats_left > 0);
    assign mrd_tdata = {8{64'h0123_4567_89ab_cdef}};
    assign mrd_tkeep = '1;
    assign mrd_tlast = (rd_beats_left == 1);

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            rd_beats_left <= 0;
        end
        else begin
            if (rd_cmd_tvalid && rd_cmd_tready) begin
                rd_beats_left <= (rd_cmd_tdata[130:103] + 63) / 64;
                mem_rd_cmds <= mem_rd_cmds + 1;
            end
            else if (mrd_tvalid && mrd_tready) begin
                rd_beats_left <= rd_beats_left - 1;
            end
        end
    end

    task automatic push_qp(input int qpn, input int rpsn, input int lpsn);
        qp_tdata = '0;
        qp_tdata[31:0]    = QPS_READY_RECV;
        qp_tdata[55:32]   = qpn[23:0];
        qp_tdata[79:56]   = rpsn[23:0];
        qp_tdata[103:80]  = lpsn[23:0];
        qp_tdata[135:104] = 32'h0;
        qp_tdata[183:136] = 48'h0;
        qp_tvalid = 1'b1;
        do @(posedge ap_clk); while (!qp_tready);
        qp_tvalid = 1'b0;
        @(posedge ap_clk);
    endtask

    task automatic push_conn(input int qpn, input int rqpn);
        conn_tdata = '0;
        conn_tdata[15:0]   = qpn[15:0];
        conn_tdata[39:16]  = rqpn[23:0];
        conn_tdata[167:40] = 128'hfe80_0000_0000_0000_92e2_baff_0b01_d4d2;
        conn_tdata[183:168] = 16'd5000;
        conn_tvalid = 1'b1;
        do @(posedge ap_clk); while (!conn_tready);
        conn_tvalid = 1'b0;
        @(posedge ap_clk);
    endtask

    task automatic push_sq(input int opcode, input int qpn, input int len, input int offs, output bit taken);
        int waited;
        taken = 1'b0;
        waited = 0;
        sq_tdata = '0;
        sq_tdata[31:0]    = opcode;
        sq_tdata[47:32]   = qpn[15:0];
        sq_tdata[48]      = 1'b1;
        sq_tdata[49]      = 1'b1;
        sq_tdata[55:50]   = 6'h0;
        sq_tdata[119:56]  = 64'h1000 + offs;
        sq_tdata[183:120] = 64'h2000 + offs;
        sq_tdata[215:184] = len;
        sq_tdata[247:216] = 32'h0;
        sq_tvalid = 1'b1;
        while (waited < 2000 && !taken) begin
            @(posedge ap_clk);
            if (sq_tready) taken = 1'b1;
            waited = waited + 1;
        end
        sq_tvalid = 1'b0;
        @(posedge ap_clk);
    endtask

    task automatic settle(input int cycles);
        repeat (cycles) @(posedge ap_clk);
    endtask

    task automatic report(input string tag);
        $display("ROCELB STATE %s sq_writes=%0d sq_reads=%0d ack=%0d rdresp=%0d other=%0d frames=%0d memrd=%0d memwr=%0d psn_drop=%0d retrans=%0d crc_drop=%0d ibv_rx=%0d ibv_tx=%0d",
                 tag, sq_writes, sq_reads, ack_cnt_ack, ack_cnt_rdresp, ack_cnt_other,
                 frames_looped, mem_rd_cmds, mem_wr_cmds,
                 regInvalidPsnDropCount, regRetransCount, regCrcDropPkgCount, regIbvCountRx, regIbvCountTx);
    endtask

    initial begin
        bit taken;
        int sizes [3];
        sizes[0] = 64; sizes[1] = 128; sizes[2] = 256;

        void'($value$plusargs("messages=%d", messages));
        void'($value$plusargs("pattern=%d", pattern));
        void'($value$plusargs("gap=%d", gap));
        void'($value$plusargs("size=%d", fixed_size));

        sq_tvalid = 1'b0;
        qp_tvalid = 1'b0;
        conn_tvalid = 1'b0;
        sq_tdata = '0;
        qp_tdata = '0;
        conn_tdata = '0;

        ap_rst_n = 1'b0;
        repeat (64) @(posedge ap_clk);
        ap_rst_n = 1'b1;
        settle(256);

        $display("ROCELB CONFIG messages=%0d pattern=%0d gap=%0d size=%0d", messages, pattern, gap, fixed_size);

        push_qp(0, 24'h2a19d6, 24'hac701e);
        push_qp(1, 24'hac701e, 24'h2a19d6);
        push_conn(0, 1);
        push_conn(1, 0);
        settle(256);
        report("after_bringup");

        for (int m = 0; m < messages; m++) begin
            int len;
            len = (fixed_size != 0) ? fixed_size : sizes[m % 3];
            if (pattern == 0 || ((pattern == 2) && (m % 2 == 0))) begin
                int remaining;
                int chunk;
                int packets;
                int opc;
                remaining = len;
                packets = 0;
                while (remaining > 0) begin
                    chunk = (remaining > PMTU_BYTES) ? PMTU_BYTES : remaining;
                    if (packets == 0 && chunk == remaining) opc = OP_WRITE_ONLY;
                    else if (packets == 0) opc = OP_WRITE_FIRST;
                    else if (chunk == remaining) opc = OP_WRITE_LAST;
                    else opc = OP_WRITE_MIDDLE;
                    push_sq(opc, 0, chunk, len - remaining, taken);
                    if (taken) sq_writes = sq_writes + 1;
                    else $display("ROCELB NOTE write refused at message %0d packet %0d", m, packets);
                    packets = packets + 1;
                    remaining = remaining - chunk;
                end
            end
            else begin
                push_sq(OP_READ_REQ, 0, len, 0, taken);
                if (taken) sq_reads = sq_reads + 1;
                else $display("ROCELB NOTE read refused at message %0d", m);
            end
            settle(gap);
        end

        settle(4000);
        report("after_traffic");

        $display("ROCELB DONE sq_total=%0d acks=%0d rdresps=%0d", sq_writes + sq_reads, ack_cnt_ack, ack_cnt_rdresp);
        if ((sq_writes + sq_reads) > 0 &&
            ((ack_cnt_ack + ack_cnt_rdresp) == (sq_writes + sq_reads))) begin
            $display("ROCELB RESULT PASS all cases");
        end
        else begin
            $display("ROCELB RESULT FAIL no traffic completed");
        end
        $finish;
    end

endmodule
