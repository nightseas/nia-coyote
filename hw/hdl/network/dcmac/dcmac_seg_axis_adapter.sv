// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module dcmac_seg_axis_rx #(
  parameter int N_SEG = 2,
  parameter int SEG_W = 128
)(
  input  logic                       clk,
  input  logic                       rstn,
  input  logic                       rx_seg_valid,
  input  logic [N_SEG*SEG_W-1:0]     rx_seg_dat,
  input  logic [N_SEG-1:0]           rx_seg_ena,
  input  logic [N_SEG-1:0]           rx_seg_sop,
  input  logic [N_SEG-1:0]           rx_seg_eop,
  input  logic [N_SEG-1:0]           rx_seg_err,
  input  logic [N_SEG*4-1:0]         rx_seg_mty,
  output logic [N_SEG*SEG_W-1:0]     m_axis_tdata,
  output logic [N_SEG*SEG_W/8-1:0]   m_axis_tkeep,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       m_axis_tlast,
  output logic                       m_axis_tuser
);
  localparam int SEG_B = SEG_W/8;
  logic [N_SEG*SEG_W-1:0]   d;
  logic [N_SEG*SEG_B-1:0]   k;
  logic                     v, l, u;

  always_comb begin
    d = rx_seg_dat;
    k = '0;
    for (int s = 0; s < N_SEG; s++) begin
      logic [3:0] mty_s;
      int         nbytes;
      mty_s  = rx_seg_mty[s*4 +: 4];
      nbytes = rx_seg_eop[s] ? (SEG_B - int'(mty_s)) : SEG_B;
      if (rx_seg_ena[s])
        k[s*SEG_B +: SEG_B] = ({SEG_B{1'b1}} >> (SEG_B - nbytes));
    end
    v = rx_seg_valid & (|rx_seg_ena);
    l = |(rx_seg_eop & rx_seg_ena);
    u = |(rx_seg_err & rx_seg_ena);
  end

  assign m_axis_tdata  = d;
  assign m_axis_tkeep  = k;
  assign m_axis_tvalid = v;
  assign m_axis_tlast  = l;
  assign m_axis_tuser  = u;
endmodule

module dcmac_seg_axis_tx #(
  parameter int N_SEG = 2,
  parameter int SEG_W = 128
)(
  input  logic                       clk,
  input  logic                       rstn,
  input  logic [N_SEG*SEG_W-1:0]     s_axis_tdata,
  input  logic [N_SEG*SEG_W/8-1:0]   s_axis_tkeep,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tuser,
  input  logic                       tx_seg_ready,
  output logic                       tx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]     tx_seg_dat,
  output logic [N_SEG-1:0]           tx_seg_ena,
  output logic [N_SEG-1:0]           tx_seg_sop,
  output logic [N_SEG-1:0]           tx_seg_eop,
  output logic [N_SEG-1:0]           tx_seg_err,
  output logic [N_SEG*4-1:0]         tx_seg_mty
);
  localparam int SEG_B = SEG_W/8;

  logic first_beat;
  always_ff @(posedge clk) begin
    if (!rstn)                              first_beat <= 1'b1;
    else if (s_axis_tvalid && s_axis_tready) first_beat <= s_axis_tlast;
  end

  logic [$clog2(N_SEG+1)-1:0] last_ena;
  always_comb begin
    last_ena = '0;
    for (int s = 0; s < N_SEG; s++)
      if (|s_axis_tkeep[s*SEG_B +: SEG_B]) last_ena = s[$clog2(N_SEG+1)-1:0];
  end

  always_comb begin
    tx_seg_valid = s_axis_tvalid;
    tx_seg_dat   = s_axis_tdata;
    tx_seg_ena   = '0;
    tx_seg_sop   = '0;
    tx_seg_eop   = '0;
    tx_seg_err   = '0;
    tx_seg_mty   = '0;
    for (int s = 0; s < N_SEG; s++) begin
      logic [SEG_B-1:0] keepseg;
      logic             ena_s, eop_s;
      keepseg      = s_axis_tkeep[s*SEG_B +: SEG_B];
      ena_s        = |keepseg;
      eop_s        = s_axis_tlast & ena_s & (s == int'(last_ena));
      tx_seg_ena[s] = ena_s;
      tx_seg_eop[s] = eop_s;
      tx_seg_sop[s] = first_beat & (s == 0) & ena_s;
      tx_seg_err[s] = s_axis_tuser & eop_s;
      tx_seg_mty[s*4 +: 4] = eop_s ? (SEG_B[3:0] - $countones(keepseg)) : 4'd0;
    end
  end

  assign s_axis_tready = tx_seg_ready;
endmodule

module dcmac_seg_axis_adapter #(
  parameter int N_SEG = 2,
  parameter int SEG_W = 128
)(
  input  logic                       clk,
  input  logic                       rstn,

  input  logic                       rx_seg_valid,
  input  logic [N_SEG*SEG_W-1:0]     rx_seg_dat,
  input  logic [N_SEG-1:0]           rx_seg_ena,
  input  logic [N_SEG-1:0]           rx_seg_sop,
  input  logic [N_SEG-1:0]           rx_seg_eop,
  input  logic [N_SEG-1:0]           rx_seg_err,
  input  logic [N_SEG*4-1:0]         rx_seg_mty,
  output logic [N_SEG*SEG_W-1:0]     m_axis_tdata,
  output logic [N_SEG*SEG_W/8-1:0]   m_axis_tkeep,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       m_axis_tlast,
  output logic                       m_axis_tuser,

  input  logic [N_SEG*SEG_W-1:0]     s_axis_tdata,
  input  logic [N_SEG*SEG_W/8-1:0]   s_axis_tkeep,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tuser,
  input  logic                       tx_seg_ready,
  output logic                       tx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]     tx_seg_dat,
  output logic [N_SEG-1:0]           tx_seg_ena,
  output logic [N_SEG-1:0]           tx_seg_sop,
  output logic [N_SEG-1:0]           tx_seg_eop,
  output logic [N_SEG-1:0]           tx_seg_err,
  output logic [N_SEG*4-1:0]         tx_seg_mty
);
  dcmac_seg_axis_rx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_rx (
    .clk, .rstn,
    .rx_seg_valid, .rx_seg_dat, .rx_seg_ena, .rx_seg_sop, .rx_seg_eop, .rx_seg_err, .rx_seg_mty,
    .m_axis_tdata, .m_axis_tkeep, .m_axis_tvalid, .m_axis_tready, .m_axis_tlast, .m_axis_tuser
  );

  dcmac_seg_axis_tx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_tx (
    .clk, .rstn,
    .s_axis_tdata, .s_axis_tkeep, .s_axis_tvalid, .s_axis_tready, .s_axis_tlast, .s_axis_tuser,
    .tx_seg_ready, .tx_seg_valid, .tx_seg_dat, .tx_seg_ena, .tx_seg_sop, .tx_seg_eop, .tx_seg_err, .tx_seg_mty
  );
endmodule
