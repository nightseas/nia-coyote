// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps

module nia_rdma_psn_probe #(
    parameter int DATA_BITS = 104,
    parameter int CTL_LSB   = 96,
    parameter int VAL1_LSB  = 32,
    parameter int VAL2_LSB  = 64,
    parameter int OPC_LSB   = 0
) (
    input  logic                        nclk,
    input  logic                        nresetn,

    input  logic                        s_dbg_valid,
    input  logic [DATA_BITS-1:0]        s_dbg_data,

    output logic [31:0]                 w0,
    output logic [31:0]                 w1,
    output logic [31:0]                 w2,
    output logic [31:0]                 w3
);

    localparam logic [7:0] CTL_ENTER   = 8'd0;
    localparam logic [7:0] CTL_INORDER = 8'd1;
    localparam logic [7:0] CTL_DUP_RD  = 8'd2;
    localparam logic [7:0] CTL_INVALID = 8'd5;

    localparam logic [3:0] TAG_FIRST_INVALID_PACKET   = 4'h8;
    localparam logic [3:0] TAG_FIRST_INVALID_EXPECTED = 4'h9;
    localparam logic [3:0] TAG_INVALID_AND_DUP_READ   = 4'hA;
    localparam logic [3:0] TAG_ENTERED_AND_INORDER    = 4'hB;

    logic [7:0]  ctl;
    logic [23:0] packet_psn, expected_psn;
    logic [7:0]  opcode;

    always_comb begin
        ctl          = s_dbg_data[CTL_LSB  +: 8];
        packet_psn   = s_dbg_data[VAL1_LSB +: 24];
        expected_psn = s_dbg_data[VAL2_LSB +: 24];
        opcode       = s_dbg_data[OPC_LSB  +: 8];
    end

    logic        invalid_seen;
    logic [4:0]  invalid_opcode, invalid_ctl;
    logic [22:0] invalid_packet_psn, invalid_expected_psn;
    logic [13:0] entered_count, inorder_count, dup_read_count, invalid_count;

    function automatic logic [13:0] saturating_increment(input logic [13:0] count);
        saturating_increment = (count == 14'h3FFF) ? count : count + 14'd1;
    endfunction

    always_ff @(posedge nclk) begin
        if (!nresetn) begin
            invalid_seen <= 1'b0;
            invalid_opcode <= '0;
            invalid_ctl <= '0;
            invalid_packet_psn <= '0;
            invalid_expected_psn <= '0;
            entered_count <= '0;
            inorder_count <= '0;
            dup_read_count <= '0;
            invalid_count <= '0;
        end
        else if (s_dbg_valid) begin
            case (ctl)
                CTL_ENTER:   entered_count  <= saturating_increment(entered_count);
                CTL_INORDER: inorder_count  <= saturating_increment(inorder_count);
                CTL_DUP_RD:  dup_read_count <= saturating_increment(dup_read_count);
                CTL_INVALID: begin
                    invalid_count <= saturating_increment(invalid_count);
                    if (!invalid_seen) begin
                        invalid_seen <= 1'b1;
                        invalid_opcode <= opcode[4:0];
                        invalid_ctl <= ctl[4:0];
                        invalid_packet_psn <= packet_psn[22:0];
                        invalid_expected_psn <= expected_psn[22:0];
                    end
                end
                default: ;
            endcase
        end
    end

    assign w0 = {TAG_FIRST_INVALID_PACKET,   invalid_opcode, invalid_packet_psn};
    assign w1 = {TAG_FIRST_INVALID_EXPECTED, invalid_ctl,    invalid_expected_psn};
    assign w2 = {TAG_INVALID_AND_DUP_READ,   invalid_count,  dup_read_count};
    assign w3 = {TAG_ENTERED_AND_INORDER,    entered_count,  inorder_count};

endmodule
