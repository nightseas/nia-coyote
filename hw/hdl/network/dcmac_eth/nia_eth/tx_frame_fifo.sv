// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

`ifdef DCMAC_TX_FRAME_FIFO_BRAM
  `define NIA_TXFF_MEM_STYLE "block"
`else
  `define NIA_TXFF_MEM_STYLE "distributed"
`endif

module tx_frame_fifo #(
  parameter int DATA_W = 512,
  parameter int KEEP_W = DATA_W/8,
  parameter int USER_W = 1,
  parameter int ADDR_W = 8,
  parameter int MAX_FRAME_B = 9018
)(
  input  logic               clk,
  input  logic               rstn,

  input  logic [DATA_W-1:0]  s_axis_tdata,
  input  logic [KEEP_W-1:0]  s_axis_tkeep,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  input  logic               s_axis_tlast,
  input  logic [USER_W-1:0]  s_axis_tuser,

  output logic [DATA_W-1:0]  m_axis_tdata,
  output logic [KEEP_W-1:0]  m_axis_tkeep,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready,
  output logic               m_axis_tlast,
  output logic [USER_W-1:0]  m_axis_tuser
);
  dcmac_axis_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(KEEP_W), .USER_W(USER_W), .ADDR_W(ADDR_W),
    .DROP_BAD_FRAME(1'b0), .FLAG_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b0),
    .MAX_FRAME_BEATS((MAX_FRAME_B + DATA_W/8 - 1) / (DATA_W/8)),
    .MEM_STYLE(`NIA_TXFF_MEM_STYLE)
  ) u_ff (
    .clk           (clk),
    .rstn          (rstn),
    .abort         (1'b0),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    .s_axis_tlast  (s_axis_tlast),
    .s_axis_tuser  (s_axis_tuser),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tkeep  (m_axis_tkeep),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tlast  (m_axis_tlast),
    .m_axis_tuser  (m_axis_tuser),
    .drop_frames   (),
    .overflow      ()
  );
endmodule
