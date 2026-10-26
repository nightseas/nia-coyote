// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module eth_axis_dwidth_down #(
  parameter int IN_W   = 512,
  parameter int OUT_W  = 256,
  parameter int USER_W = 1
)(
  input  logic                clk,
  input  logic                rstn,
  input  logic [IN_W-1:0]     s_axis_tdata,
  input  logic [IN_W/8-1:0]   s_axis_tkeep,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  input  logic                s_axis_tlast,
  input  logic [USER_W-1:0]   s_axis_tuser,
  output logic [OUT_W-1:0]    m_axis_tdata,
  output logic [OUT_W/8-1:0]  m_axis_tkeep,
  output logic                m_axis_tvalid,
  input  logic                m_axis_tready,
  output logic                m_axis_tlast,
  output logic [USER_W-1:0]   m_axis_tuser
);
  localparam int R      = IN_W / OUT_W;
  localparam int OUT_KW = OUT_W / 8;
  localparam int IDXW   = (R > 1) ? $clog2(R) : 1;

  logic [IDXW-1:0] idx;
  logic [IDXW-1:0] last_idx;

  always_comb begin
    last_idx = '0;
    for (int i = 0; i < R; i++)
      if (|s_axis_tkeep[i*OUT_KW +: OUT_KW]) last_idx = i[IDXW-1:0];
  end

  wire at_last = (idx == last_idx);

  always_comb begin
    m_axis_tdata  = s_axis_tdata[idx*OUT_W  +: OUT_W];
    m_axis_tkeep  = s_axis_tkeep[idx*OUT_KW +: OUT_KW];
    m_axis_tvalid = s_axis_tvalid;
    m_axis_tlast  = s_axis_tlast & at_last;
  end

  wire user_e = s_axis_tuser[0] & s_axis_tlast & at_last;
  generate
  if (USER_W > 1) begin : g_user_wide
    assign m_axis_tuser = {s_axis_tuser[USER_W-1:1], user_e};
  end else begin : g_user_narrow
    assign m_axis_tuser = user_e;
  end
  endgenerate

  assign s_axis_tready = m_axis_tready & at_last;

  always_ff @(posedge clk) begin
    if (!rstn) idx <= '0;
    else if (s_axis_tvalid && m_axis_tready) idx <= at_last ? '0 : (idx + 1'b1);
  end
endmodule

module eth_axis_dwidth_up #(
  parameter int IN_W   = 256,
  parameter int OUT_W  = 512,
  parameter int USER_W = 1
)(
  input  logic                clk,
  input  logic                rstn,
  input  logic [IN_W-1:0]     s_axis_tdata,
  input  logic [IN_W/8-1:0]   s_axis_tkeep,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  input  logic                s_axis_tlast,
  input  logic [USER_W-1:0]   s_axis_tuser,
  output logic [OUT_W-1:0]    m_axis_tdata,
  output logic [OUT_W/8-1:0]  m_axis_tkeep,
  output logic                m_axis_tvalid,
  input  logic                m_axis_tready,
  output logic                m_axis_tlast,
  output logic [USER_W-1:0]   m_axis_tuser
);
  localparam int R      = OUT_W / IN_W;
  localparam int IN_KW  = IN_W / 8;
  localparam int OUT_KW = OUT_W / 8;
  localparam int IDXW   = (R > 1) ? $clog2(R) : 1;
  localparam int SBW    = (USER_W > 1) ? (USER_W - 1) : 1;

  logic [OUT_W-1:0]  acc_d;
  logic [OUT_KW-1:0] acc_k;
  logic              acc_u;
  logic [IDXW-1:0]   idx;

  logic [OUT_W-1:0]  out_d;
  logic [OUT_KW-1:0] out_k;
  logic              out_v, out_l, out_u;
  logic [SBW-1:0]    out_sb;

  logic [OUT_W-1:0]  nxt_d;
  logic [OUT_KW-1:0] nxt_k;
  always_comb begin
    nxt_d = acc_d;
    nxt_k = acc_k;
    nxt_d[idx*IN_W  +: IN_W ] = s_axis_tdata;
    nxt_k[idx*IN_KW +: IN_KW] = s_axis_tkeep;
  end

  logic [OUT_W-1:0] nxt_d_masked;
  always_comb
    for (int b = 0; b < OUT_KW; b++)
      nxt_d_masked[b*8 +: 8] = nxt_k[b] ? nxt_d[b*8 +: 8] : 8'h00;

  logic [SBW-1:0] sb_in;
  generate
  if (USER_W > 1) begin : g_sb_in
    assign sb_in = s_axis_tuser[USER_W-1:1];
  end else begin : g_sb_in_none
    assign sb_in = {SBW{1'b0}};
  end
  endgenerate

  assign s_axis_tready = ~out_v | m_axis_tready;

  wire accept = s_axis_tvalid & s_axis_tready;
  wire flush  = accept & (s_axis_tlast | (idx == (R-1)));

  always_ff @(posedge clk) begin
    if (!rstn) begin
      acc_d <= '0; acc_k <= '0; acc_u <= 1'b0; idx <= '0;
      out_d <= '0; out_k <= '0; out_v <= 1'b0; out_l <= 1'b0; out_u <= 1'b0;
      out_sb <= '0;
    end else begin
      if (out_v && m_axis_tready) out_v <= 1'b0;
      if (accept) begin
        if (flush) begin
          out_d  <= nxt_d_masked;
          out_k  <= nxt_k;
          out_v  <= 1'b1;
          out_l  <= s_axis_tlast;
          out_u  <= acc_u | s_axis_tuser[0];
          out_sb <= sb_in;
          acc_d <= '0; acc_k <= '0; acc_u <= 1'b0; idx <= '0;
        end else begin
          acc_d <= nxt_d;
          acc_k <= nxt_k;
          acc_u <= acc_u | s_axis_tuser[0];
          idx   <= idx + 1'b1;
        end
      end
    end
  end

  assign m_axis_tdata  = out_d;
  assign m_axis_tkeep  = out_k;
  assign m_axis_tvalid = out_v;
  assign m_axis_tlast  = out_l;
  generate
  if (USER_W > 1) begin : g_user_wide
    assign m_axis_tuser = {out_sb, out_u};
  end else begin : g_user_narrow
    assign m_axis_tuser = out_u;
  end
  endgenerate
endmodule
