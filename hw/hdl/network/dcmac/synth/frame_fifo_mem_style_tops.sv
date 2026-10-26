// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module frame_fifo_block_ram_top #(
  parameter int DATA_W = 512, parameter int KEEP_W = 64, parameter int ADDR_W = 9
)(
  input  logic clk, rstn, abort,
  input  logic [DATA_W-1:0] s_axis_tdata, input logic [KEEP_W-1:0] s_axis_tkeep,
  input  logic s_axis_tvalid, output logic s_axis_tready,
  input  logic s_axis_tlast, input logic s_axis_tuser,
  output logic [DATA_W-1:0] m_axis_tdata, output logic [KEEP_W-1:0] m_axis_tkeep,
  output logic m_axis_tvalid, input logic m_axis_tready,
  output logic m_axis_tlast, output logic m_axis_tuser,
  output logic [31:0] drop_frames, output logic overflow
);
  dcmac_axis_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(KEEP_W), .ADDR_W(ADDR_W),
    .DROP_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1), .MEM_STYLE("block")
  ) u (.*);
endmodule

module frame_fifo_distributed_ram_top #(
  parameter int DATA_W = 512, parameter int KEEP_W = 64, parameter int ADDR_W = 9
)(
  input  logic clk, rstn, abort,
  input  logic [DATA_W-1:0] s_axis_tdata, input logic [KEEP_W-1:0] s_axis_tkeep,
  input  logic s_axis_tvalid, output logic s_axis_tready,
  input  logic s_axis_tlast, input logic s_axis_tuser,
  output logic [DATA_W-1:0] m_axis_tdata, output logic [KEEP_W-1:0] m_axis_tkeep,
  output logic m_axis_tvalid, input logic m_axis_tready,
  output logic m_axis_tlast, output logic m_axis_tuser,
  output logic [31:0] drop_frames, output logic overflow
);
  dcmac_axis_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(KEEP_W), .ADDR_W(ADDR_W),
    .DROP_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1), .MEM_STYLE("distributed")
  ) u (.*);
endmodule
