/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2021-2025, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

`timescale 1ns / 1ps

import lynxTypes::*;

module rdma_cq_count #(
    parameter integer           QDEPTH = 8
) (
    input  logic                aclk,
    input  logic                aresetn,

    metaIntf.s                  s_rdma_done,

    input  logic                clear_rd,
    input  logic [PID_BITS-1:0] clear_addr_rd,
    input  logic                clear_wr,
    input  logic [PID_BITS-1:0] clear_addr_wr,

    input  logic [PID_BITS-1:0] stat_pid,
    output logic [31:0]         stat_cnt_rd,
    output logic [31:0]         stat_cnt_wr,

    output logic                cnt_rd_hit,
    output logic [PID_BITS-1:0] cnt_rd_pid,
    output logic [31:0]         cnt_rd_next,
    output logic                cnt_wr_hit,
    output logic [PID_BITS-1:0] cnt_wr_pid,
    output logic [31:0]         cnt_wr_next
);

metaIntf #(.STYPE(ack_t)) done (.*);
metaIntf #(.STYPE(ack_t)) done_rd (.*);
metaIntf #(.STYPE(ack_t)) done_wr (.*);

logic cyc_rd;
logic [3:0] a_we_rd;
logic [PID_BITS-1:0] a_addr_rd;
logic [31:0] a_data_in_rd;
logic [31:0] a_data_out_rd;

logic cyc_wr;
logic [3:0] a_we_wr;
logic [PID_BITS-1:0] a_addr_wr;
logic [31:0] a_data_in_wr;
logic [31:0] a_data_out_wr;

queue_stream #(
    .QTYPE(ack_t),
    .QDEPTH(QDEPTH)
) inst_cmplt_q (
    .aclk(aclk),
    .aresetn(aresetn),
    .val_snk (s_rdma_done.valid),
    .rdy_snk (),
    .data_snk(s_rdma_done.data),
    .val_src (done.valid),
    .rdy_src (done.ready),
    .data_src(done.data)
);

assign s_rdma_done.ready = 1'b1;

assign done_rd.data  = done.data;
assign done_rd.valid = is_opcode_rd_resp(done.data.opcode) ? done.valid : 1'b0;
assign done_wr.data  = done.data;
assign done_wr.valid = is_opcode_rd_resp(done.data.opcode) ? 1'b0 : done.valid;
assign done.ready    = is_opcode_rd_resp(done.data.opcode) ? done_rd.ready : done_wr.ready;

always_ff @(posedge aclk) begin
    if(aresetn == 1'b0) begin
        cyc_rd <= 1'b0;
        cyc_wr <= 1'b0;
    end
    else begin
        cyc_rd <= cyc_rd ? 1'b0 : (done_rd.valid ? 1'b1 : cyc_rd);
        cyc_wr <= cyc_wr ? 1'b0 : (done_wr.valid ? 1'b1 : cyc_wr);
    end
end

assign done_rd.ready = (cyc_rd && done_rd.valid);
assign done_wr.ready = (cyc_wr && done_wr.valid);

assign a_we_rd      = (clear_rd || cyc_rd) ? ~0 : 0;
assign a_data_in_rd = clear_rd ? 0 : a_data_out_wr + 1;
assign a_addr_rd    = clear_rd ? clear_addr_rd : done_rd.data.pid;

assign a_we_wr      = (clear_wr || cyc_wr) ? ~0 : 0;
assign a_data_in_wr = clear_wr ? 0 : a_data_out_wr + 1;
assign a_addr_wr    = clear_wr ? clear_addr_wr : done_wr.data.pid;

assign cnt_rd_hit  = cyc_rd;
assign cnt_rd_pid  = done_rd.data.pid;
assign cnt_rd_next = a_data_out_rd + 1;
assign cnt_wr_hit  = cyc_wr;
assign cnt_wr_pid  = done_wr.data.pid;
assign cnt_wr_next = a_data_out_wr + 1;

ram_tp_nc #(
    .ADDR_BITS(PID_BITS),
    .DATA_BITS(32),
    .DISTRIBUTED(1)
) inst_cnt_rd (
    .clk(aclk),
    .a_en(1'b1),
    .a_we(a_we_rd),
    .a_addr(a_addr_rd),
    .b_en(1'b1),
    .b_addr(stat_pid),
    .a_data_in(a_data_in_rd),
    .a_data_out(a_data_out_rd),
    .b_data_out(stat_cnt_rd)
);

ram_tp_nc #(
    .ADDR_BITS(PID_BITS),
    .DATA_BITS(32),
    .DISTRIBUTED(1)
) inst_cnt_wr (
    .clk(aclk),
    .a_en(1'b1),
    .a_we(a_we_wr),
    .a_addr(a_addr_wr),
    .b_en(1'b1),
    .b_addr(stat_pid),
    .a_data_in(a_data_in_wr),
    .a_data_out(a_data_out_wr),
    .b_data_out(stat_cnt_wr)
);

endmodule
