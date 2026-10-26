// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ps / 1ps

module ethernet_frame_padding_512_ip (
    input  wire          ap_clk,
    input  wire          ap_rst_n,

    input  wire          s_axis_TVALID,
    output wire          s_axis_TREADY,
    input  wire [511:0]  s_axis_TDATA,
    input  wire [63:0]   s_axis_TKEEP,
    input  wire          s_axis_TLAST,

    output wire          m_axis_TVALID,
    input  wire          m_axis_TREADY,
    output wire [511:0]  m_axis_TDATA,
    output wire [63:0]   m_axis_TKEEP,
    output wire          m_axis_TLAST
);

wire unused = ap_clk | ap_rst_n;

assign m_axis_TVALID = s_axis_TVALID;
assign s_axis_TREADY = m_axis_TREADY;
assign m_axis_TDATA  = s_axis_TDATA;
assign m_axis_TKEEP  = s_axis_TKEEP;
assign m_axis_TLAST  = s_axis_TLAST;

endmodule
