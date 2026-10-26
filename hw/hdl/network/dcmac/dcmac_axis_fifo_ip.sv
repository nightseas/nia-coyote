// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module nia_axis_async_fifo_ip #(
  parameter int  DATA_W       = 512,
  parameter int  KEEP_W       = 64,
  parameter int  ADDR_W       = 9,
  parameter bit  DROP_ON_FULL = 1'b0
)(
  input  logic                s_clk,
  input  logic                s_rstn,
  input  logic [DATA_W-1:0]   s_axis_tdata,
  input  logic [KEEP_W-1:0]   s_axis_tkeep,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  input  logic                s_axis_tlast,
  input  logic                s_axis_tuser,

  input  logic                m_clk,
  input  logic                m_rstn,
  output logic [DATA_W-1:0]   m_axis_tdata,
  output logic [KEEP_W-1:0]   m_axis_tkeep,
  output logic                m_axis_tvalid,
  input  logic                m_axis_tready,
  output logic                m_axis_tlast,
  output logic                m_axis_tuser,

  output logic                overflow
);
  wire _unused = |{m_rstn, DROP_ON_FULL, ADDR_W[0]};

  axis_data_fifo_512_dcmac_cdc u_fifo (
    .s_axis_aresetn (s_rstn),
    .s_axis_aclk    (s_clk),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tready  (s_axis_tready),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tkeep   (s_axis_tkeep),
    .s_axis_tlast   (s_axis_tlast),
    .s_axis_tuser   (s_axis_tuser),
    .m_axis_aclk    (m_clk),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tready  (m_axis_tready),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tkeep   (m_axis_tkeep),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tuser   (m_axis_tuser)
  );

  assign overflow = 1'b0;
endmodule

module dcmac_axis_frame_fifo_ip #(
  parameter int  DATA_W         = 512,
  parameter int  KEEP_W         = 64,
  parameter int  ADDR_W         = 9,
  parameter bit  DROP_BAD_FRAME = 1'b0,
  parameter bit  DROP_WHEN_FULL = 1'b0,
  parameter      MEM_STYLE      = "distributed"
)(
  input  logic                clk,
  input  logic                rstn,
  input  logic                abort,
  input  logic [DATA_W-1:0]   s_axis_tdata,
  input  logic [KEEP_W-1:0]   s_axis_tkeep,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  input  logic                s_axis_tlast,
  input  logic                s_axis_tuser,

  output logic [DATA_W-1:0]   m_axis_tdata,
  output logic [KEEP_W-1:0]   m_axis_tkeep,
  output logic                m_axis_tvalid,
  input  logic                m_axis_tready,
  output logic                m_axis_tlast,
  output logic                m_axis_tuser,

  output logic [31:0]         drop_frames,
  output logic                overflow
);
  wire _unused = |{abort, DROP_BAD_FRAME, DROP_WHEN_FULL, ADDR_W[0]};

  axis_data_fifo_512_dcmac_pkt u_fifo (
    .s_axis_aresetn (rstn),
    .s_axis_aclk    (clk),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tready  (s_axis_tready),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tkeep   (s_axis_tkeep),
    .s_axis_tlast   (s_axis_tlast),
    .s_axis_tuser   (s_axis_tuser),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tready  (m_axis_tready),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tkeep   (m_axis_tkeep),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tuser   (m_axis_tuser)
  );

  assign drop_frames = 32'd0;
  assign overflow    = 1'b0;
endmodule
