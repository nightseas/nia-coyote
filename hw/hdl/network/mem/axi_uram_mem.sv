// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT

`timescale 1ns / 1ps

module axi_uram_mem #(
    parameter int    DATA_BITS     = 512,
    parameter int    ADDR_BITS     = 64,
    parameter int    ID_BITS       = 6,
    parameter int    N_SESSIONS    = 16,
    parameter int    WINDOW_BITS   = 18,
    parameter        ADDR_MAP      = "flat",
    parameter int    PMTU_BYTES    = 4096,
    parameter int    RDMA_SHIFT    = 27,
    parameter int    RDMA_OST_BITS = 4,
    parameter int    PID_BITS      = 6,
    parameter int    VFID_BITS     = 0,
    parameter int    BANKS         = 1,
    parameter int    RD_LAT        = 2,
    parameter int    OSTD          = 8
) (
    input  logic                        aclk,
    input  logic                        aresetn,

    input  logic [ADDR_BITS-1:0]        s_axi_awaddr,
    input  logic [1:0]                  s_axi_awburst,
    input  logic [ID_BITS-1:0]          s_axi_awid,
    input  logic [7:0]                  s_axi_awlen,
    input  logic [2:0]                  s_axi_awsize,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,

    input  logic [DATA_BITS-1:0]        s_axi_wdata,
    input  logic [DATA_BITS/8-1:0]      s_axi_wstrb,
    input  logic                        s_axi_wlast,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,

    output logic [ID_BITS-1:0]          s_axi_bid,
    output logic [1:0]                  s_axi_bresp,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,

    input  logic [ADDR_BITS-1:0]        s_axi_araddr,
    input  logic [1:0]                  s_axi_arburst,
    input  logic [ID_BITS-1:0]          s_axi_arid,
    input  logic [7:0]                  s_axi_arlen,
    input  logic [2:0]                  s_axi_arsize,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,

    output logic [DATA_BITS-1:0]        s_axi_rdata,
    output logic [ID_BITS-1:0]          s_axi_rid,
    output logic                        s_axi_rlast,
    output logic [1:0]                  s_axi_rresp,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready,

    output logic                        oob_err,
    output logic [31:0]                 oob_cnt,
    output logic                        proto_err,
    output logic [31:0]                 proto_cnt,
    output logic                        xsess_err,
    output logic [31:0]                 xsess_cnt,
    output logic                        slot_ovf_err,
    output logic [31:0]                 slot_ovf_cnt
);

    localparam int LANE_BITS = $clog2(DATA_BITS/8);
    localparam int STRB_BITS = DATA_BITS/8;
    localparam int PMTU_AB   = $clog2(PMTU_BYTES);

    localparam int OFFS_LSB  = RDMA_SHIFT + PMTU_AB;
    localparam int PID_LSB   = OFFS_LSB + RDMA_OST_BITS;
    localparam int VFID_LSB  = PID_LSB  + PID_BITS;
    localparam int SLOT_AB   = VFID_BITS + PID_BITS + RDMA_OST_BITS;

    localparam longint FLAT_BYTES = longint'(N_SESSIONS) * (longint'(1) << WINDOW_BITS);
    localparam longint SLOT_BYTES = (longint'(1) << SLOT_AB) * longint'(PMTU_BYTES);
    localparam longint SPAN_BYTES = (ADDR_MAP == "rdma_slot") ? SLOT_BYTES : FLAT_BYTES;

    localparam int LINES   = int'(SPAN_BYTES / STRB_BITS);
    localparam int LINE_AB = $clog2(LINES);

    // synthesis translate_off
    initial begin
        if (WINDOW_BITS != 16 && WINDOW_BITS != 18)
            $fatal(1, "axi_uram_mem: WINDOW_BITS must be 16 (WINDOW_SCALE=0) or 18 (=1), got %0d", WINDOW_BITS);
        if (N_SESSIONS > (1 << (30 - WINDOW_BITS)))
            $fatal(1, "axi_uram_mem: N_SESSIONS=%0d exceeds the addressable %0d (S9 claim 4: toe's address space is 30 b)",
                   N_SESSIONS, (1 << (30 - WINDOW_BITS)));
        if (DATA_BITS != 512)
            $fatal(1, "axi_uram_mem: DATA_BITS must be 512 (AXI_DDR_BITS)");
        if (OSTD < RD_LAT + 2)
            $fatal(1, "axi_uram_mem: OSTD must be >= RD_LAT+2");
        if (ADDR_MAP != "flat" && ADDR_MAP != "rdma_slot")
            $fatal(1, "axi_uram_mem: ADDR_MAP must be \"flat\" or \"rdma_slot\"");
    end
    // synthesis translate_on

    function automatic logic [63:0] byte_off_of(input logic [ADDR_BITS-1:0] addr);
        logic [SLOT_AB-1:0] slot;
        if (ADDR_MAP == "rdma_slot") begin
            if (VFID_BITS > 0)
                slot = { addr[VFID_LSB +: (VFID_BITS > 0 ? VFID_BITS : 1)],
                         addr[PID_LSB  +: PID_BITS],
                         addr[OFFS_LSB +: RDMA_OST_BITS] };
            else
                slot = { addr[PID_LSB  +: PID_BITS],
                         addr[OFFS_LSB +: RDMA_OST_BITS] };
            byte_off_of = (64'(slot) << PMTU_AB) | {{(64-PMTU_AB){1'b0}}, addr[PMTU_AB-1:0]};
        end else begin
            byte_off_of = 64'(addr);
        end
    endfunction

    function automatic logic oob_of(input logic [ADDR_BITS-1:0] addr);
        logic [63:0] bo;
        bo = byte_off_of(addr);
        if (ADDR_MAP == "rdma_slot")
            oob_of = (|addr[OFFS_LSB-1:PMTU_AB]) || (bo >= 64'(SPAN_BYTES));
        else
            oob_of = (bo >= 64'(SPAN_BYTES));
    endfunction

    function automatic logic [LINE_AB-1:0] line_of(input logic [ADDR_BITS-1:0] addr);
        logic [63:0] bo;
        bo = byte_off_of(addr);
        line_of = bo[LANE_BITS +: LINE_AB];
    endfunction

    function automatic logic [ADDR_BITS-1:0] next_beat_addr(
        input logic [ADDR_BITS-1:0] a, input logic [2:0] sz, input logic [1:0] burst);
        logic [ADDR_BITS-1:0] step, mask;
        step = ADDR_BITS'(1) << sz;
        mask = ~(step - ADDR_BITS'(1));
        next_beat_addr = (burst == 2'b00) ? a : ((a & mask) + step);
    endfunction

    logic bump_oob_w, bump_oob_r, bump_proto_w, bump_proto_r, bump_xsess, bump_slot;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            oob_err <= 1'b0; oob_cnt <= '0;
            proto_err <= 1'b0; proto_cnt <= '0;
            xsess_err <= 1'b0; xsess_cnt <= '0;
            slot_ovf_err <= 1'b0; slot_ovf_cnt <= '0;
        end else begin
            if (bump_oob_w || bump_oob_r) begin
                oob_err <= 1'b1;
                if (oob_cnt != '1) oob_cnt <= oob_cnt + 32'(bump_oob_w) + 32'(bump_oob_r);
            end
            if (bump_proto_w || bump_proto_r) begin
                proto_err <= 1'b1;
                if (proto_cnt != '1) proto_cnt <= proto_cnt + 32'(bump_proto_w) + 32'(bump_proto_r);
            end
            if (bump_xsess) begin xsess_err    <= 1'b1; if (xsess_cnt    != '1) xsess_cnt    <= xsess_cnt + 1;    end
            if (bump_slot)  begin slot_ovf_err <= 1'b1; if (slot_ovf_cnt != '1) slot_ovf_cnt <= slot_ovf_cnt + 1; end
        end
    end

    logic [ADDR_BITS-1:0] wr_addr,  awq_addr;
    logic [ID_BITS-1:0]   wr_id,    awq_id;
    logic [7:0]           wr_len,   awq_len;
    logic [2:0]           wr_size,  awq_size;
    logic [1:0]           wr_burst, awq_burst;
    logic                 wr_act,   awq_val;
    logic [7:0]           wr_beat;
    logic [ADDR_BITS-1:0] wr_base;
    logic                 wr_oob_seen, wr_x_seen, wr_slot_seen;

    localparam int BQ_D  = 4;
    localparam int BQ_AB = $clog2(BQ_D);
    logic [ID_BITS-1:0]  bq_d [BQ_D];
    logic [BQ_AB-1:0]    bq_wp, bq_rp;
    logic [BQ_AB:0]      bq_n;
    logic                bq_full, b_fire;

    assign bq_full = (bq_n == BQ_D);
    assign b_fire  = s_axi_bvalid && s_axi_bready;

    assign s_axi_bvalid = (bq_n != 0);
    assign s_axi_bid    = bq_d[bq_rp];
    assign s_axi_bresp  = 2'b00;

    logic wr_fire, wr_last_fire, aw_fire;
    assign s_axi_wready = wr_act && !(bq_full && s_axi_wlast);
    assign wr_fire      = s_axi_wvalid && s_axi_wready;
    assign wr_last_fire = wr_fire && s_axi_wlast;
    assign s_axi_awready = !awq_val;
    assign aw_fire       = s_axi_awvalid && s_axi_awready;

    logic                 mw_en;
    logic [LINE_AB-1:0]   mw_line;
    logic                 cur_oob;

    always_comb begin
        cur_oob = oob_of(wr_addr);
        mw_line = line_of(wr_addr);
        mw_en   = wr_fire && !cur_oob;
    end

    logic [ADDR_BITS-1:0] wr_next;
    logic                 wr_xsess_now, wr_slot_now;
    always_comb begin
        wr_next      = next_beat_addr(wr_addr, wr_size, wr_burst);
        wr_xsess_now = (wr_next[ADDR_BITS-1:WINDOW_BITS] != wr_base[ADDR_BITS-1:WINDOW_BITS]);
        wr_slot_now  = (wr_next[PMTU_AB-1:0] < wr_addr[PMTU_AB-1:0]);
    end

    always_ff @(posedge aclk) begin
        bump_oob_w   <= 1'b0;
        bump_proto_w <= 1'b0;
        bump_xsess   <= 1'b0;
        bump_slot    <= 1'b0;

        if (!aresetn) begin
            wr_act <= 1'b0; awq_val <= 1'b0; wr_beat <= '0;
            bq_wp <= '0; bq_rp <= '0; bq_n <= '0;
            wr_oob_seen <= 1'b0; wr_x_seen <= 1'b0; wr_slot_seen <= 1'b0;
        end else begin
            if (wr_fire) begin
                if (cur_oob && !wr_oob_seen) begin wr_oob_seen <= 1'b1; bump_oob_w <= 1'b1; end

                if (s_axi_wlast) begin
                    if (wr_beat != wr_len) bump_proto_w <= 1'b1;
                    if (awq_val) begin
                        wr_addr <= awq_addr; wr_id <= awq_id; wr_len <= awq_len;
                        wr_size <= awq_size; wr_burst <= awq_burst;
                        wr_base <= awq_addr; wr_beat <= '0; awq_val <= 1'b0;
                        wr_oob_seen <= 1'b0; wr_x_seen <= 1'b0; wr_slot_seen <= 1'b0;
                    end else if (aw_fire) begin
                        wr_addr <= s_axi_awaddr; wr_id <= s_axi_awid; wr_len <= s_axi_awlen;
                        wr_size <= s_axi_awsize; wr_burst <= s_axi_awburst;
                        wr_base <= s_axi_awaddr; wr_beat <= '0;
                        wr_oob_seen <= 1'b0; wr_x_seen <= 1'b0; wr_slot_seen <= 1'b0;
                    end else begin
                        wr_act <= 1'b0;
                    end
                end else if (wr_beat == wr_len) begin
                    bump_proto_w <= 1'b1;
                end else begin
                    if (ADDR_MAP == "flat" && wr_xsess_now && !wr_x_seen) begin
                        wr_x_seen <= 1'b1; bump_xsess <= 1'b1;
                    end
                    if (ADDR_MAP == "rdma_slot" && wr_slot_now && !wr_slot_seen) begin
                        wr_slot_seen <= 1'b1; bump_slot <= 1'b1;
                    end
                    wr_addr <= wr_next;
                    wr_beat <= wr_beat + 8'd1;
                end
            end

            if (aw_fire && !(wr_fire && s_axi_wlast && !awq_val)) begin
                if (!wr_act) begin
                    wr_addr <= s_axi_awaddr; wr_id <= s_axi_awid; wr_len <= s_axi_awlen;
                    wr_size <= s_axi_awsize; wr_burst <= s_axi_awburst;
                    wr_base <= s_axi_awaddr; wr_beat <= '0; wr_act <= 1'b1;
                    wr_oob_seen <= 1'b0; wr_x_seen <= 1'b0; wr_slot_seen <= 1'b0;
                end else begin
                    awq_addr <= s_axi_awaddr; awq_id <= s_axi_awid; awq_len <= s_axi_awlen;
                    awq_size <= s_axi_awsize; awq_burst <= s_axi_awburst;
                    awq_val <= 1'b1;
                end
            end
            if (aw_fire && s_axi_awburst[1]) bump_proto_w <= 1'b1;

            if (wr_last_fire) begin
                bq_d[bq_wp] <= wr_id;
                bq_wp       <= (bq_wp == BQ_AB'(BQ_D-1)) ? '0 : bq_wp + 1;
            end
            if (b_fire) bq_rp <= (bq_rp == BQ_AB'(BQ_D-1)) ? '0 : bq_rp + 1;
            case ({wr_last_fire, b_fire})
                2'b10:   bq_n <= bq_n + 1;
                2'b01:   bq_n <= bq_n - 1;
                default: ;
            endcase
        end
    end

    logic [ADDR_BITS-1:0] rd_addr,  arq_addr;
    logic [ID_BITS-1:0]   rd_id,    arq_id;
    logic [7:0]           rd_len,   arq_len;
    logic [2:0]           rd_size,  arq_size;
    logic [1:0]           rd_burst, arq_burst;
    logic                 rd_act,   arq_val;
    logic [7:0]           rd_beat;
    logic                 rd_oob_seen;

    localparam int OF_AB = $clog2(OSTD);

    logic                 rd_oob;
    logic [LINE_AB-1:0]   mr_line;
    logic                 mr_en, ar_fire, r_fire;
    logic [OF_AB:0]       rd_credit;

    assign s_axi_arready = !arq_val;
    assign ar_fire       = s_axi_arvalid && s_axi_arready;

    always_comb begin
        rd_oob  = oob_of(rd_addr);
        mr_line = line_of(rd_addr);
        mr_en   = rd_act && (rd_credit != 0);
    end

    logic [DATA_BITS-1:0] mem_rd_data;

    logic [ID_BITS-1:0] pl_id  [RD_LAT];
    logic               pl_lst [RD_LAT];
    logic               pl_oob [RD_LAT];
    logic               pl_val [RD_LAT];

    logic [DATA_BITS-1:0] of_d  [OSTD];
    logic [ID_BITS-1:0]   of_id [OSTD];
    logic                 of_l  [OSTD];
    logic [OF_AB-1:0]     of_wp, of_rp;
    logic [OF_AB:0]       of_n;

    assign s_axi_rvalid = (of_n != 0);
    assign s_axi_rdata  = of_d [of_rp];
    assign s_axi_rid    = of_id[of_rp];
    assign s_axi_rlast  = of_l [of_rp];
    assign s_axi_rresp  = 2'b00;
    assign r_fire       = s_axi_rvalid && s_axi_rready;

    logic [ADDR_BITS-1:0] rd_next;
    always_comb rd_next = next_beat_addr(rd_addr, rd_size, rd_burst);

    always_ff @(posedge aclk) begin
        bump_oob_r   <= 1'b0;
        bump_proto_r <= 1'b0;

        if (!aresetn) begin
            rd_act <= 1'b0; arq_val <= 1'b0; rd_beat <= '0;
            rd_credit <= (OF_AB+1)'(OSTD);
            of_wp <= '0; of_rp <= '0; of_n <= '0;
            rd_oob_seen <= 1'b0;
            for (int i = 0; i < RD_LAT; i++) pl_val[i] <= 1'b0;
        end else begin
            if (mr_en) begin
                if (rd_oob && !rd_oob_seen) begin rd_oob_seen <= 1'b1; bump_oob_r <= 1'b1; end
                if (rd_beat == rd_len) begin
                    if (arq_val) begin
                        rd_addr <= arq_addr; rd_id <= arq_id; rd_len <= arq_len;
                        rd_size <= arq_size; rd_burst <= arq_burst;
                        rd_beat <= '0; arq_val <= 1'b0; rd_oob_seen <= 1'b0;
                    end else if (ar_fire) begin
                        rd_addr <= s_axi_araddr; rd_id <= s_axi_arid; rd_len <= s_axi_arlen;
                        rd_size <= s_axi_arsize; rd_burst <= s_axi_arburst;
                        rd_beat <= '0; rd_oob_seen <= 1'b0;
                    end else begin
                        rd_act <= 1'b0;
                    end
                end else begin
                    rd_addr <= rd_next;
                    rd_beat <= rd_beat + 8'd1;
                end
            end

            if (ar_fire && !(mr_en && (rd_beat == rd_len) && !arq_val)) begin
                if (!rd_act) begin
                    rd_addr <= s_axi_araddr; rd_id <= s_axi_arid; rd_len <= s_axi_arlen;
                    rd_size <= s_axi_arsize; rd_burst <= s_axi_arburst;
                    rd_beat <= '0; rd_act <= 1'b1; rd_oob_seen <= 1'b0;
                end else begin
                    arq_addr <= s_axi_araddr; arq_id <= s_axi_arid; arq_len <= s_axi_arlen;
                    arq_size <= s_axi_arsize; arq_burst <= s_axi_arburst;
                    arq_val <= 1'b1;
                end
            end
            if (ar_fire && s_axi_arburst[1]) bump_proto_r <= 1'b1;

            pl_val[0] <= mr_en;
            pl_id [0] <= rd_id;
            pl_lst[0] <= (rd_beat == rd_len);
            pl_oob[0] <= rd_oob;
            for (int i = 1; i < RD_LAT; i++) begin
                pl_val[i] <= pl_val[i-1];
                pl_id [i] <= pl_id [i-1];
                pl_lst[i] <= pl_lst[i-1];
                pl_oob[i] <= pl_oob[i-1];
            end

            if (pl_val[RD_LAT-1]) begin
                of_d [of_wp] <= pl_oob[RD_LAT-1] ? '0 : mem_rd_data;
                of_id[of_wp] <= pl_id [RD_LAT-1];
                of_l [of_wp] <= pl_lst[RD_LAT-1];
                of_wp        <= (of_wp == OF_AB'(OSTD-1)) ? '0 : of_wp + 1;
            end
            if (r_fire) of_rp <= (of_rp == OF_AB'(OSTD-1)) ? '0 : of_rp + 1;
            case ({pl_val[RD_LAT-1], r_fire})
                2'b10:   of_n <= of_n + 1;
                2'b01:   of_n <= of_n - 1;
                default: ;
            endcase

            case ({mr_en, r_fire})
                2'b10:   rd_credit <= rd_credit - 1;
                2'b01:   rd_credit <= rd_credit + 1;
                default: ;
            endcase
        end
    end

    nia_uram_sdp #(
        .DATA_BITS (DATA_BITS),
        .DEPTH     (LINES),
        .BANKS     (BANKS),
        .RD_LAT    (RD_LAT)
    ) inst_mem (
        .clk       (aclk),
        .wr_en     (mw_en),
        .wr_addr   (mw_line),
        .wr_data   (s_axi_wdata),
        .wr_strb   (s_axi_wstrb),
        .rd_en     (mr_en),
        .rd_addr   (mr_line),
        .rd_data   (mem_rd_data)
    );

endmodule
