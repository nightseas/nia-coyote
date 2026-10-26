// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT

`timescale 1ns / 1ps

module nia_uram_sdp #(
    parameter int DATA_BITS = 512,
    parameter int DEPTH     = 65536,
    parameter int BANKS     = 1,
    parameter int RD_LAT    = 2,
    parameter int STRB_BITS = DATA_BITS/8,
    parameter int ADDR_BITS = $clog2(DEPTH)
) (
    input  logic                    clk,

    input  logic                    wr_en,
    input  logic [ADDR_BITS-1:0]    wr_addr,
    input  logic [DATA_BITS-1:0]    wr_data,
    input  logic [STRB_BITS-1:0]    wr_strb,

    input  logic                    rd_en,
    input  logic [ADDR_BITS-1:0]    rd_addr,
    output logic [DATA_BITS-1:0]    rd_data
);

    // synthesis translate_off
    initial begin
        if (RD_LAT < 2)                 $fatal(1, "nia_uram_sdp: RD_LAT must be >= 2");
        if (2**$clog2(BANKS) != BANKS)  $fatal(1, "nia_uram_sdp: BANKS must be a power of 2");
        if (DEPTH % BANKS != 0)         $fatal(1, "nia_uram_sdp: DEPTH must divide by BANKS");
    end
    // synthesis translate_on

    localparam int BANK_DEPTH = DEPTH / BANKS;
    localparam int BANK_AB    = $clog2(BANK_DEPTH);
    localparam int SEL_BITS   = (BANKS > 1) ? $clog2(BANKS) : 1;

    logic [DATA_BITS-1:0] bank_q   [BANKS];
    logic [SEL_BITS-1:0]  rd_sel_r;

    for (genvar b = 0; b < BANKS; b++) begin : g_bank
        (* ram_style = "ultra" *)
        logic [DATA_BITS-1:0] mem [BANK_DEPTH];

        logic bank_wr, bank_rd;
        if (BANKS > 1) begin : g_dec
            assign bank_wr = wr_en && (wr_addr[ADDR_BITS-1 -: SEL_BITS] == b[SEL_BITS-1:0]);
            assign bank_rd = rd_en && (rd_addr[ADDR_BITS-1 -: SEL_BITS] == b[SEL_BITS-1:0]);
        end else begin : g_nodec
            assign bank_wr = wr_en;
            assign bank_rd = rd_en;
        end

        always_ff @(posedge clk) begin
            if (bank_wr) begin
                for (int s = 0; s < STRB_BITS; s++) begin
                    if (wr_strb[s]) mem[wr_addr[BANK_AB-1:0]][s*8 +: 8] <= wr_data[s*8 +: 8];
                end
            end
            if (bank_rd) begin
                bank_q[b] <= mem[rd_addr[BANK_AB-1:0]];
            end
        end
    end

    if (BANKS > 1) begin : g_sel
        always_ff @(posedge clk) if (rd_en) rd_sel_r <= rd_addr[ADDR_BITS-1 -: SEL_BITS];
    end else begin : g_nosel
        assign rd_sel_r = '0;
    end

    logic [DATA_BITS-1:0] pipe [RD_LAT-1];
    always_ff @(posedge clk) begin
        pipe[0] <= bank_q[rd_sel_r];
        for (int i = 1; i < RD_LAT-1; i++) pipe[i] <= pipe[i-1];
    end

    assign rd_data = pipe[RD_LAT-2];

endmodule
