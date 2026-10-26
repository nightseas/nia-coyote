// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module dcmac_port #(

  parameter integer N_SEG      = 2,
  parameter integer SEG_W      = 128,
  parameter integer DATA_W     = 512,

  parameter integer PTP_TS_EN  = 0,
  parameter integer PTP_TS_W   = 80,
  parameter integer TX_TAG_W   = 0,

  parameter integer RX_FIFO_AW = 9,
  parameter integer RX_CDC_AW  = 9,
  parameter integer TX_FIFO_AW = 8,
  parameter integer TX_CDC_AW  = 9,
  parameter integer TX_CPL_AW  = 4,

  parameter integer RX_USER_W = (PTP_TS_EN != 0) ? (PTP_TS_W + 1) : 1,
  parameter integer TX_USER_W = TX_TAG_W + 1,
  parameter integer TX_TAG_WP = (TX_TAG_W > 0) ? TX_TAG_W : 1
)(

  input  wire                    sys_reset,
  input  wire                    seg_clk,
  input  wire                    seg_rstn,
  input  wire                    usr_clk,

  output wire                    tx_clk,
  output wire                    tx_rst,
  output wire                    rx_clk,
  output wire                    rx_rst,

  output wire                    usr_rstn,

  input  wire [DATA_W-1:0]       s_axis_tx_tdata,
  input  wire [DATA_W/8-1:0]     s_axis_tx_tkeep,
  input  wire                    s_axis_tx_tvalid,
  output wire                    s_axis_tx_tready,
  input  wire                    s_axis_tx_tlast,
  input  wire [TX_USER_W-1:0]    s_axis_tx_tuser,

  output wire                    m_axis_tx_cpl_valid,
  input  wire                    m_axis_tx_cpl_ready,
  output wire [PTP_TS_W-1:0]     m_axis_tx_cpl_ts,
  output wire [TX_TAG_WP-1:0]    m_axis_tx_cpl_tag,

  output wire [DATA_W-1:0]       m_axis_rx_tdata,
  output wire [DATA_W/8-1:0]     m_axis_rx_tkeep,
  output wire                    m_axis_rx_tvalid,
  output wire                    m_axis_rx_tlast,
  output wire [RX_USER_W-1:0]    m_axis_rx_tuser,

  input  wire [PTP_TS_W-1:0]     seg_ptp_time,

  output wire                    tx_status,
  output wire                    rx_status,

  output wire                    rx_overflow,
  output wire                    rx_trunc,
  output wire [31:0]             rx_err_frames,
  output wire [31:0]             rx_align_stat,
  output wire [31:0]             rx_drop_frames,
  output wire                    tx_cpl_overflow,

  input  wire                    rx_seg_valid,
  input  wire [N_SEG*SEG_W-1:0]  rx_seg_dat,
  input  wire [N_SEG-1:0]        rx_seg_ena,
  input  wire [N_SEG-1:0]        rx_seg_sop,
  input  wire [N_SEG-1:0]        rx_seg_eop,
  input  wire [N_SEG-1:0]        rx_seg_err,
  input  wire [N_SEG*4-1:0]      rx_seg_mty,

  input  wire                    tx_seg_ready,
  output wire                    tx_seg_valid,
  output wire [N_SEG*SEG_W-1:0]  tx_seg_dat,
  output wire [N_SEG-1:0]        tx_seg_ena,
  output wire [N_SEG-1:0]        tx_seg_sop,
  output wire [N_SEG-1:0]        tx_seg_eop,
  output wire [N_SEG-1:0]        tx_seg_err,
  output wire [N_SEG*4-1:0]      tx_seg_mty,

  input  wire                    stat_rx_aligned,
  input  wire                    link_up,
  input  wire                    tx_rst_seg,
  input  wire                    ctl_tx_enable
);

  assign tx_clk = usr_clk;
  assign rx_clk = usr_clk;

  (* ASYNC_REG = "TRUE" *) reg [2:0] tx_rstn_sr = 3'b000;
  (* ASYNC_REG = "TRUE" *) reg [2:0] rx_rstn_sr = 3'b000;
  always_ff @(posedge tx_clk) tx_rstn_sr <= {tx_rstn_sr[1:0], ~sys_reset};
  always_ff @(posedge rx_clk) rx_rstn_sr <= {rx_rstn_sr[1:0], ~sys_reset};
  wire tx_rstn_i = tx_rstn_sr[2];
  wire rx_rstn_i = rx_rstn_sr[2];
  assign usr_rstn = tx_rstn_i;

  dcmac_axis_adapter #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
    .PTP_TS_EN(PTP_TS_EN), .PTP_TS_W(PTP_TS_W), .TX_TAG_W(TX_TAG_W),
    .RX_FIFO_AW(RX_FIFO_AW), .RX_CDC_AW(RX_CDC_AW),
    .TX_FIFO_AW(TX_FIFO_AW), .TX_CDC_AW(TX_CDC_AW), .TX_CPL_AW(TX_CPL_AW)
  ) u_adapter (
    .seg_clk                 (seg_clk),
    .seg_rstn                (seg_rstn),
    .tx_clk                  (tx_clk),
    .tx_rstn                 (tx_rstn_i),
    .rx_clk                  (rx_clk),
    .rx_rstn                 (rx_rstn_i),
    .tx_rst                  (tx_rst),
    .rx_rst                  (rx_rst),

    .s_axis_tx_tdata         (s_axis_tx_tdata),
    .s_axis_tx_tkeep         (s_axis_tx_tkeep),
    .s_axis_tx_tvalid        (s_axis_tx_tvalid),
    .s_axis_tx_tready        (s_axis_tx_tready),
    .s_axis_tx_tlast         (s_axis_tx_tlast),
    .s_axis_tx_tuser         (s_axis_tx_tuser),
    .m_axis_tx_cpl_valid     (m_axis_tx_cpl_valid),
    .m_axis_tx_cpl_ready     (m_axis_tx_cpl_ready),
    .m_axis_tx_cpl_ts        (m_axis_tx_cpl_ts),
    .m_axis_tx_cpl_tag       (m_axis_tx_cpl_tag),

    .m_axis_rx_tdata         (m_axis_rx_tdata),
    .m_axis_rx_tkeep         (m_axis_rx_tkeep),
    .m_axis_rx_tvalid        (m_axis_rx_tvalid),
    .m_axis_rx_tlast         (m_axis_rx_tlast),
    .m_axis_rx_tuser         (m_axis_rx_tuser),
    .seg_ptp_time            (seg_ptp_time),

    .rx_seg_valid            (rx_seg_valid),
    .rx_seg_dat              (rx_seg_dat),
    .rx_seg_ena              (rx_seg_ena),
    .rx_seg_sop              (rx_seg_sop),
    .rx_seg_eop              (rx_seg_eop),
    .rx_seg_err              (rx_seg_err),
    .rx_seg_mty              (rx_seg_mty),

    .tx_seg_ready            (tx_seg_ready),
    .tx_seg_valid            (tx_seg_valid),
    .tx_seg_dat              (tx_seg_dat),
    .tx_seg_ena              (tx_seg_ena),
    .tx_seg_sop              (tx_seg_sop),
    .tx_seg_eop              (tx_seg_eop),
    .tx_seg_err              (tx_seg_err),
    .tx_seg_mty              (tx_seg_mty),

    .stat_rx_aligned         (stat_rx_aligned),
    .link_up                 (link_up),
    .tx_rst_seg              (tx_rst_seg),
    .ctl_tx_enable           (ctl_tx_enable),

    .rx_status               (rx_status),
    .tx_status               (tx_status),
    .rx_overflow             (rx_overflow),
    .rx_trunc                (rx_trunc),
    .rx_err_frames           (rx_err_frames),
    .rx_align_stat           (rx_align_stat),
    .rx_drop_frames          (rx_drop_frames),
    .tx_cpl_overflow         (tx_cpl_overflow)
  );

endmodule
