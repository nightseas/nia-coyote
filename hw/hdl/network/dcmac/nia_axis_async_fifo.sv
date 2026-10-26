// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module nia_axis_async_fifo #(
  parameter int DATA_W = 256,
  parameter int KEEP_W = DATA_W/8,
  parameter int ADDR_W = 9,
  parameter bit DROP_ON_FULL = 1'b1
)(
  input  logic               s_clk,
  input  logic               s_rstn,
  input  logic [DATA_W-1:0]  s_axis_tdata,
  input  logic [KEEP_W-1:0]  s_axis_tkeep,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  input  logic               s_axis_tlast,
  input  logic               s_axis_tuser,

  input  logic               m_clk,
  input  logic               m_rstn,
  output logic [DATA_W-1:0]  m_axis_tdata,
  output logic [KEEP_W-1:0]  m_axis_tkeep,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready,
  output logic               m_axis_tlast,
  output logic               m_axis_tuser,

  output logic               overflow
);
  localparam int DEPTH = 1 << ADDR_W;
  localparam int W     = DATA_W + KEEP_W + 2;

  logic [W-1:0] mem [DEPTH];

  logic [ADDR_W:0] wbin, wgray;
  logic [ADDR_W:0] rgray_s1, rgray_s2;
  logic            wfull;

  wire             wr_en   = s_axis_tvalid & s_axis_tready;
  wire [ADDR_W:0]  wbin_nx = wbin + {{ADDR_W{1'b0}}, wr_en};
  wire [ADDR_W:0]  wgry_nx = (wbin_nx >> 1) ^ wbin_nx;

  assign s_axis_tready = DROP_ON_FULL ? 1'b1 : ~wfull;

  always_ff @(posedge s_clk) begin
    if (!s_rstn) begin
      wbin <= '0; wgray <= '0; wfull <= 1'b0;
      rgray_s1 <= '0; rgray_s2 <= '0;
      overflow <= 1'b0;
    end else begin
      rgray_s1 <= rgray;
      rgray_s2 <= rgray_s1;
      if (s_axis_tvalid && wfull) overflow <= 1'b1;
      if (wr_en && !wfull) begin
        mem[wbin[ADDR_W-1:0]] <= {s_axis_tuser, s_axis_tlast, s_axis_tkeep, s_axis_tdata};
        wbin  <= wbin_nx;
        wgray <= wgry_nx;
      end
      wfull <= ((wr_en && !wfull) ? wgry_nx : wgray)
               == {~rgray_s2[ADDR_W:ADDR_W-1], rgray_s2[ADDR_W-2:0]};
    end
  end

  logic [ADDR_W:0] rbin, rgray;
  logic [ADDR_W:0] wgray_s1, wgray_s2;
  logic            rempty;

  wire            rd_en   = m_axis_tvalid & m_axis_tready;
  wire [ADDR_W:0] rbin_nx = rbin + {{ADDR_W{1'b0}}, rd_en};
  wire [ADDR_W:0] rgry_nx = (rbin_nx >> 1) ^ rbin_nx;

  always_ff @(posedge m_clk) begin
    if (!m_rstn) begin
      rbin <= '0; rgray <= '0; rempty <= 1'b1;
      wgray_s1 <= '0; wgray_s2 <= '0;
    end else begin
      wgray_s1 <= wgray;
      wgray_s2 <= wgray_s1;
      rbin   <= rbin_nx;
      rgray  <= rgry_nx;
      rempty <= (rgry_nx == wgray_s2);
    end
  end

  wire [W-1:0] rdata = mem[rbin[ADDR_W-1:0]];
  assign m_axis_tvalid = ~rempty;
  assign m_axis_tdata  = rdata[DATA_W-1:0];
  assign m_axis_tkeep  = rdata[DATA_W+KEEP_W-1:DATA_W];
  assign m_axis_tlast  = rdata[DATA_W+KEEP_W];
  assign m_axis_tuser  = rdata[DATA_W+KEEP_W+1];
endmodule
