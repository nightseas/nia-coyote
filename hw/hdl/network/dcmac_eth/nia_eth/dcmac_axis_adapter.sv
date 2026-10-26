// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

`ifdef DCMAC_FRAME_FIFO_BRAM
  `define NIA_RX_FF_MEM_STYLE "block"
`else
  `define NIA_RX_FF_MEM_STYLE "distributed"
`endif

module dcmac_axis_adapter #(

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

  input  wire                         seg_clk,
  input  wire                         seg_rstn,

  input  wire                         tx_clk,
  input  wire                         tx_rstn,
  input  wire                         rx_clk,
  input  wire                         rx_rstn,

  output wire                         tx_rst,
  output wire                         rx_rst,

  input  wire [DATA_W-1:0]            s_axis_tx_tdata,
  input  wire [DATA_W/8-1:0]          s_axis_tx_tkeep,
  input  wire                         s_axis_tx_tvalid,
  output wire                         s_axis_tx_tready,
  input  wire                         s_axis_tx_tlast,
  input  wire [TX_USER_W-1:0]         s_axis_tx_tuser,

  output wire                         m_axis_tx_cpl_valid,
  input  wire                         m_axis_tx_cpl_ready,
  output wire [PTP_TS_W-1:0]          m_axis_tx_cpl_ts,
  output wire [TX_TAG_WP-1:0]         m_axis_tx_cpl_tag,

  output wire [DATA_W-1:0]            m_axis_rx_tdata,
  output wire [DATA_W/8-1:0]          m_axis_rx_tkeep,
  output wire                         m_axis_rx_tvalid,
  output wire                         m_axis_rx_tlast,
  output wire [RX_USER_W-1:0]         m_axis_rx_tuser,

  input  wire [PTP_TS_W-1:0]          seg_ptp_time,

  input  wire                         rx_seg_valid,
  input  wire [N_SEG*SEG_W-1:0]       rx_seg_dat,
  input  wire [N_SEG-1:0]             rx_seg_ena,
  input  wire [N_SEG-1:0]             rx_seg_sop,
  input  wire [N_SEG-1:0]             rx_seg_eop,
  input  wire [N_SEG-1:0]             rx_seg_err,
  input  wire [N_SEG*4-1:0]           rx_seg_mty,

  input  wire                         tx_seg_ready,
  output wire                         tx_seg_valid,
  output wire [N_SEG*SEG_W-1:0]       tx_seg_dat,
  output wire [N_SEG-1:0]             tx_seg_ena,
  output wire [N_SEG-1:0]             tx_seg_sop,
  output wire [N_SEG-1:0]             tx_seg_eop,
  output wire [N_SEG-1:0]             tx_seg_err,
  output wire [N_SEG*4-1:0]           tx_seg_mty,

  input  wire                         stat_rx_aligned,

  input  wire                         link_up,
  input  wire                         tx_rst_seg,
  input  wire                         ctl_tx_enable,

  output wire                         rx_status,
  output wire                         tx_status,
  output wire                         rx_overflow,
  output wire                         rx_trunc,
  output wire [31:0]                  rx_err_frames,
  output wire [31:0]                  rx_drop_frames,
  output wire [31:0]                  rx_align_stat,
  output wire                         tx_cpl_overflow
);
  localparam int SEG_BITS  = N_SEG*SEG_W;
  localparam int SEG_KEEP  = SEG_BITS/8;
  localparam int NET_KEEP  = DATA_W/8;

  localparam int CPL_W     = PTP_TS_W + TX_TAG_WP;
  localparam bit TX_CPL_EN = (PTP_TS_EN != 0) || (TX_TAG_W > 0);

  (* ASYNC_REG = "TRUE" *) logic rx_algn_s0 = 1'b0, rx_algn_s1 = 1'b0;
  always_ff @(posedge seg_clk) begin
    rx_algn_s0 <= stat_rx_aligned;
    rx_algn_s1 <= rx_algn_s0;
  end
  wire stat_rx_aligned_seg = rx_algn_s1;

  wire link_up_i = link_up;

  logic rx_rst_seg;
  always_ff @(posedge seg_clk) begin
    rx_rst_seg <= ~seg_rstn | ~link_up_i | ~stat_rx_aligned_seg;
  end

  (* ASYNC_REG = "TRUE" *) logic tx_rst_s0 = 1'b1, tx_rst_s1 = 1'b1;
  (* ASYNC_REG = "TRUE" *) logic tx_sts_s0 = 1'b0, tx_sts_s1 = 1'b0;
  always_ff @(posedge tx_clk) begin
    tx_rst_s0 <= tx_rst_seg;
    tx_rst_s1 <= tx_rst_s0;
    tx_sts_s0 <= link_up_i & ctl_tx_enable;
    tx_sts_s1 <= tx_sts_s0;
  end
  assign tx_rst    = tx_rst_s1;
  assign tx_status = tx_sts_s1;

  (* ASYNC_REG = "TRUE" *) logic rx_rst_s0 = 1'b1, rx_rst_s1 = 1'b1;
  (* ASYNC_REG = "TRUE" *) logic rx_sts_s0 = 1'b0, rx_sts_s1 = 1'b0;
  always_ff @(posedge rx_clk) begin
    rx_rst_s0 <= rx_rst_seg;
    rx_rst_s1 <= rx_rst_s0;
    rx_sts_s0 <= link_up_i;
    rx_sts_s1 <= rx_sts_s0;
  end
  assign rx_rst    = rx_rst_s1;
  assign rx_status = rx_sts_s1;

  wire rx_gated_valid = rx_seg_valid & link_up_i;

  logic [SEG_BITS-1:0] rxa_tdata;
  logic [SEG_KEEP-1:0] rxa_tkeep;
  logic                rxa_tvalid, rxa_tready, rxa_tlast, rxa_tuser;
  logic                rx_align_drop;

  dcmac_seg_axis_rx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_seg_rx (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .rx_seg_valid  (rx_gated_valid),
    .rx_seg_dat    (rx_seg_dat),
    .rx_seg_ena    (rx_seg_ena),
    .rx_seg_sop    (rx_seg_sop),
    .rx_seg_eop    (rx_seg_eop),
    .rx_seg_err    (rx_seg_err),
    .rx_seg_mty    (rx_seg_mty),
    .m_axis_tdata  (rxa_tdata),
    .m_axis_tkeep  (rxa_tkeep),
    .m_axis_tvalid (rxa_tvalid),
    .m_axis_tready (rxa_tready),
    .m_axis_tlast  (rxa_tlast),
    .m_axis_tuser  (rxa_tuser),
    .rx_align_drop (rx_align_drop),
    .rx_align_stat (rx_align_stat)
  );

  logic rx_in_frame;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)         rx_in_frame <= 1'b0;
    else if (rxa_tvalid)   rx_in_frame <= ~rxa_tlast;
  end

  logic        rxa_err_seen;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                    rxa_err_seen <= 1'b0;
    else if (rxa_tvalid && rxa_tlast) rxa_err_seen <= 1'b0;
    else if (rxa_tvalid)              rxa_err_seen <= rxa_err_seen | rxa_tuser;
  end

  logic [31:0] rx_err_cnt;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                                  rx_err_cnt <= '0;
    else if (rxa_tvalid && rxa_tlast && (rxa_tuser | rxa_err_seen) &&
             rx_err_cnt != 32'hFFFF_FFFF)           rx_err_cnt <= rx_err_cnt + 1'b1;
  end
  assign rx_err_frames = rx_err_cnt;

  wire rx_sop = rxa_tvalid & ~rx_in_frame;
  logic [PTP_TS_W-1:0] rx_ts_hold;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)   rx_ts_hold <= '0;
    else if (rx_sop) rx_ts_hold <= seg_ptp_time;
  end
  wire [PTP_TS_W-1:0] rx_ts_cur = rx_sop ? seg_ptp_time : rx_ts_hold;

  logic        link_up_1d;
  logic        rx_abort;
  logic [2:0]  rx_flush_cnt;
  logic        rx_trunc_r;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      link_up_1d   <= 1'b0;
      rx_flush_cnt <= '0;
      rx_trunc_r   <= 1'b0;
    end else begin
      link_up_1d <= link_up_i;
      if (rx_abort) begin
        rx_flush_cnt <= 3'd4;
        rx_trunc_r   <= 1'b1;
      end else if (rx_flush_cnt != '0) begin
        rx_flush_cnt <= rx_flush_cnt - 1'b1;
      end
    end
  end
  assign rx_abort = link_up_1d & ~link_up_i & rx_in_frame;
  assign rx_trunc = rx_trunc_r;

  wire rx_up_rstn = seg_rstn & ~(rx_abort | (rx_flush_cnt != 3'd0));

  logic [DATA_W-1:0]    rxu_tdata;
  logic [NET_KEEP-1:0]  rxu_tkeep;
  logic                 rxu_tvalid, rxu_tready, rxu_tlast;
  logic [RX_USER_W-1:0] rxu_tuser;

  wire [RX_USER_W-1:0] rxa_user_vec;
  generate
  if (RX_USER_W > 1) begin : g_rx_user_wide
    assign rxa_user_vec = {rx_ts_cur, rxa_tuser};
  end else begin : g_rx_user_narrow
    assign rxa_user_vec = rxa_tuser;
  end
  endgenerate

  eth_axis_dwidth_up #(.IN_W(SEG_BITS), .OUT_W(DATA_W), .USER_W(RX_USER_W)) u_rx_up (
    .clk           (seg_clk),
    .rstn          (rx_up_rstn),
    .s_axis_tdata  (rxa_tdata),
    .s_axis_tkeep  (rxa_tkeep),
    .s_axis_tvalid (rxa_tvalid),
    .s_axis_tready (rxa_tready),
    .s_axis_tlast  (rxa_tlast),
    .s_axis_tuser  (rxa_user_vec),
    .m_axis_tdata  (rxu_tdata),
    .m_axis_tkeep  (rxu_tkeep),
    .m_axis_tvalid (rxu_tvalid),
    .m_axis_tready (rxu_tready),
    .m_axis_tlast  (rxu_tlast),
    .m_axis_tuser  (rxu_tuser)
  );

  logic rx_fifo_overflow;
  logic rx_cdc_overflow;

  logic [DATA_W-1:0]    rxq_tdata;
  logic [NET_KEEP-1:0]  rxq_tkeep;
  logic                 rxq_tvalid, rxq_tready, rxq_tlast;
  logic [RX_USER_W-1:0] rxq_tuser;
  logic [31:0]          rx_drop_cnt;

  dcmac_axis_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(RX_USER_W), .ADDR_W(RX_FIFO_AW),
    .DROP_BAD_FRAME(1'b0), .FLAG_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1),
    .MEM_STYLE(`NIA_RX_FF_MEM_STYLE)
  ) u_rx_frame_fifo (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .abort         (rx_abort),
    .s_axis_tdata  (rxu_tdata),
    .s_axis_tkeep  (rxu_tkeep),
    .s_axis_tvalid (rxu_tvalid),
    .s_axis_tready (rxu_tready),
    .s_axis_tlast  (rxu_tlast),
    .s_axis_tuser  (rxu_tuser),
    .m_axis_tdata  (rxq_tdata),
    .m_axis_tkeep  (rxq_tkeep),
    .m_axis_tvalid (rxq_tvalid),
    .m_axis_tready (rxq_tready),
    .m_axis_tlast  (rxq_tlast),
    .m_axis_tuser  (rxq_tuser),
    .drop_frames   (rx_drop_cnt),
    .overflow      (rx_fifo_overflow)
  );
  assign rx_drop_frames = rx_drop_cnt;

  eth_axis_async_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(RX_USER_W), .ADDR_W(RX_CDC_AW),
    .DROP_ON_FULL(1'b0)
  ) u_rx_cdc (
    .s_clk         (seg_clk),
    .s_rstn        (seg_rstn),
    .s_axis_tdata  (rxq_tdata),
    .s_axis_tkeep  (rxq_tkeep),
    .s_axis_tvalid (rxq_tvalid),
    .s_axis_tready (rxq_tready),
    .s_axis_tlast  (rxq_tlast),
    .s_axis_tuser  (rxq_tuser),
    .m_clk         (rx_clk),
    .m_rstn        (rx_rstn),
    .m_axis_tdata  (m_axis_rx_tdata),
    .m_axis_tkeep  (m_axis_rx_tkeep),
    .m_axis_tvalid (m_axis_rx_tvalid),
    .m_axis_tready (1'b1),
    .m_axis_tlast  (m_axis_rx_tlast),
    .m_axis_tuser  (m_axis_rx_tuser),
    .overflow      (rx_cdc_overflow)
  );

  assign rx_overflow = rx_fifo_overflow | rx_cdc_overflow | rx_align_drop;

  logic [DATA_W-1:0]    txf_tdata;
  logic [NET_KEEP-1:0]  txf_tkeep;
  logic                 txf_tvalid, txf_tready, txf_tlast;
  logic [TX_USER_W-1:0] txf_tuser;

  eth_axis_async_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(TX_USER_W), .ADDR_W(TX_CDC_AW),
    .DROP_ON_FULL(1'b0)
  ) u_tx_cdc (
    .s_clk         (tx_clk),
    .s_rstn        (tx_rstn),
    .s_axis_tdata  (s_axis_tx_tdata),
    .s_axis_tkeep  (s_axis_tx_tkeep),
    .s_axis_tvalid (s_axis_tx_tvalid),
    .s_axis_tready (s_axis_tx_tready),
    .s_axis_tlast  (s_axis_tx_tlast),
    .s_axis_tuser  (s_axis_tx_tuser),
    .m_clk         (seg_clk),
    .m_rstn        (seg_rstn),
    .m_axis_tdata  (txf_tdata),
    .m_axis_tkeep  (txf_tkeep),
    .m_axis_tvalid (txf_tvalid),
    .m_axis_tready (txf_tready),
    .m_axis_tlast  (txf_tlast),
    .m_axis_tuser  (txf_tuser),
    .overflow      ()
  );

  logic [DATA_W-1:0]    txp_tdata;
  logic [NET_KEEP-1:0]  txp_tkeep;
  logic                 txp_tvalid, txp_tready, txp_tlast;
  logic [TX_USER_W-1:0] txp_tuser;

  tx_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(TX_USER_W), .ADDR_W(TX_FIFO_AW)
  ) u_tx_frame_fifo (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .s_axis_tdata  (txf_tdata),
    .s_axis_tkeep  (txf_tkeep),
    .s_axis_tvalid (txf_tvalid),
    .s_axis_tready (txf_tready),
    .s_axis_tlast  (txf_tlast),
    .s_axis_tuser  (txf_tuser),
    .m_axis_tdata  (txp_tdata),
    .m_axis_tkeep  (txp_tkeep),
    .m_axis_tvalid (txp_tvalid),
    .m_axis_tready (txp_tready),
    .m_axis_tlast  (txp_tlast),
    .m_axis_tuser  (txp_tuser)
  );

  logic                 tx_in_frame;
  logic [DATA_W-1:0]    txg_tdata;
  logic [NET_KEEP-1:0]  txg_tkeep;
  logic                 txg_tvalid, txg_tready, txg_tlast;
  logic [TX_USER_W-1:0] txg_tuser;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                     tx_in_frame <= 1'b0;
    else if (txg_tvalid && txg_tready) tx_in_frame <= ~txg_tlast;
  end

  wire tx_gate = ctl_tx_enable | tx_in_frame;
  assign txg_tdata  = txp_tdata;
  assign txg_tkeep  = txp_tkeep;
  assign txg_tlast  = txp_tlast;
  assign txg_tuser  = txp_tuser;
  assign txg_tvalid = txp_tvalid & tx_gate;
  assign txp_tready = txg_tready & tx_gate;

  logic [SEG_BITS-1:0]  txd_tdata;
  logic [SEG_KEEP-1:0]  txd_tkeep;
  logic                 txd_tvalid, txd_tready, txd_tlast;
  logic [TX_USER_W-1:0] txd_tuser;

  eth_axis_dwidth_down #(.IN_W(DATA_W), .OUT_W(SEG_BITS), .USER_W(TX_USER_W)) u_tx_dn (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .s_axis_tdata  (txg_tdata),
    .s_axis_tkeep  (txg_tkeep),
    .s_axis_tvalid (txg_tvalid),
    .s_axis_tready (txg_tready),
    .s_axis_tlast  (txg_tlast),
    .s_axis_tuser  (txg_tuser),
    .m_axis_tdata  (txd_tdata),
    .m_axis_tkeep  (txd_tkeep),
    .m_axis_tvalid (txd_tvalid),
    .m_axis_tready (txd_tready),
    .m_axis_tlast  (txd_tlast),
    .m_axis_tuser  (txd_tuser)
  );

  dcmac_seg_axis_tx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_seg_tx (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .s_axis_tdata  (txd_tdata),
    .s_axis_tkeep  (txd_tkeep),
    .s_axis_tvalid (txd_tvalid),
    .s_axis_tready (txd_tready),
    .s_axis_tlast  (txd_tlast),
    .s_axis_tuser  (txd_tuser[0]),
    .tx_seg_ready  (tx_seg_ready),
    .tx_seg_valid  (tx_seg_valid),
    .tx_seg_dat    (tx_seg_dat),
    .tx_seg_ena    (tx_seg_ena),
    .tx_seg_sop    (tx_seg_sop),
    .tx_seg_eop    (tx_seg_eop),
    .tx_seg_err    (tx_seg_err),
    .tx_seg_mty    (tx_seg_mty)
  );

  generate
  if (TX_CPL_EN) begin : g_tx_cpl
    wire tx_eop_accepted = txd_tvalid & txd_tready & txd_tlast;

    wire [PTP_TS_W-1:0]  cpl_ts_in  = seg_ptp_time;

    wire [TX_TAG_WP-1:0] cpl_tag_in;
    if (TX_TAG_W > 0) begin : g_tag
      assign cpl_tag_in = txd_tuser[TX_TAG_W:1];
    end else begin : g_no_tag
      assign cpl_tag_in = {TX_TAG_WP{1'b0}};
    end

    wire [CPL_W-1:0] cpl_word;
    assign cpl_word = {cpl_ts_in, cpl_tag_in};

    wire [CPL_W-1:0] cpl_word_out;

    eth_axis_async_fifo #(
      .DATA_W(CPL_W), .KEEP_W(1), .USER_W(1), .ADDR_W(TX_CPL_AW), .DROP_ON_FULL(1'b0)
    ) u_tx_cpl_cdc (
      .s_clk         (seg_clk),
      .s_rstn        (seg_rstn),
      .s_axis_tdata  (cpl_word),
      .s_axis_tkeep  (1'b1),
      .s_axis_tvalid (tx_eop_accepted),
      .s_axis_tready (),
      .s_axis_tlast  (1'b1),
      .s_axis_tuser  (1'b0),
      .m_clk         (tx_clk),
      .m_rstn        (tx_rstn),
      .m_axis_tdata  (cpl_word_out),
      .m_axis_tkeep  (),
      .m_axis_tvalid (m_axis_tx_cpl_valid),
      .m_axis_tready (m_axis_tx_cpl_ready),
      .m_axis_tlast  (),
      .m_axis_tuser  (),
      .overflow      (tx_cpl_overflow)
    );

    assign m_axis_tx_cpl_tag = cpl_word_out[TX_TAG_WP-1:0];
    assign m_axis_tx_cpl_ts  = cpl_word_out[CPL_W-1:TX_TAG_WP];
  end else begin : g_no_tx_cpl
    assign m_axis_tx_cpl_valid = 1'b0;
    assign m_axis_tx_cpl_tag   = {TX_TAG_WP{1'b0}};
    assign m_axis_tx_cpl_ts    = {PTP_TS_W{1'b0}};
    assign tx_cpl_overflow     = 1'b0;
  end
  endgenerate
endmodule
