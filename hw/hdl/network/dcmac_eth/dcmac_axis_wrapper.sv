// Copyright (c) 2022-2025 Systems Group, ETH Zurich
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

import lynxTypes::*;

`ifndef DCMAC_ETH_LOOPBACK_MODE
`define DCMAC_ETH_LOOPBACK_MODE 3'b000
`endif

module dcmac_axis_wrapper #(
`ifdef DCMAC_ETH_200G
    parameter int               N_SEG = 4
`else
    parameter int               N_SEG = 2
`endif
) (
    input wire                  init_clk,
    input wire                  sys_reset,

    input wire                  gt_ref_clk_p,
    input wire                  gt_ref_clk_n,
    input wire [3:0]            gt_rxp_in,
    input wire [3:0]            gt_rxn_in,
    output wire [3:0]           gt_txn_out,
    output wire [3:0]           gt_txp_out,

    AXI4S.m                     m_rx_axis,
    AXI4S.s                     s_tx_axis,

    output logic                usr_clk,
    output logic                tx_rst
);

  localparam int SEG_W          = 128;
  localparam int DATA_W         = AXI_NET_BITS;
  localparam int PTP_TS_EN      = 0;
  localparam int PTP_TS_W       = 80;
  localparam int TX_TAG_W       = 0;
  localparam int RX_FIFO_AW     = 9;
  localparam int RX_CDC_AW      = 9;
  localparam int TX_FIFO_AW     = 8;
  localparam int TX_CDC_AW      = 9;
  localparam int TX_CPL_AW      = 4;
  localparam int PORT_MAX       = 6;
  localparam int NPORTS         = 1;
  localparam int ANCHOR         = 0;
  localparam int EN_CTL_SEQ     = 1;
  localparam int SEG_CYC_PER_MS = 391000;
`ifndef DCMAC_ETH_USR_KCYC_PER_MS
  `define DCMAC_ETH_USR_KCYC_PER_MS 250
`endif
  localparam int CTL_CYC_PER_MS = `DCMAC_ETH_USR_KCYC_PER_MS * 1000;
  localparam int T_RXDP_MS      = 100;
  localparam int T_SERDES_MS    = 100;
  localparam int LINK_WDT_MS    = 750;

`ifndef DCMAC_ETH_USR_RESET_MODE
  `define DCMAC_ETH_USR_RESET_MODE 1
`endif
`ifndef DCMAC_ETH_USR_RESET_HOLD
  `define DCMAC_ETH_USR_RESET_HOLD 1024
`endif

  wire         mac_tx_clk;
  wire         mac_rx_clk;
  wire         mac_tx_rst;
  wire         mac_rx_rst;
  wire         mac_seg_clk;

  wire [DATA_W-1:0]   rx_tdata;
  wire [DATA_W/8-1:0] rx_tkeep;
  wire                rx_tvalid;
  wire                rx_tlast;
  wire                rx_tuser;

  wire                tx_cpl_valid;
  wire [PTP_TS_W-1:0] tx_cpl_ts;
  wire                tx_cpl_tag;

  wire        mac_tx_status;
  wire        mac_rx_status;
  wire        mac_link_up;
  wire        mac_rx_overflow;
  wire        mac_rx_trunc;
  wire [31:0] mac_rx_err_frames;
  wire [31:0] mac_rx_align_stat;
  wire [31:0] mac_rx_drop_frames;
  wire        mac_tx_cpl_overflow;
  wire [2:0]  mac_fsm_state;

  wire        ctl_link_fault;
  wire        ctl_access_fault;
  wire        ctl_seq_busy;
  wire [31:0] ctl_rx_phy_status;
  wire [7:0]  ctl_retry_cnt;
  wire [4:0]  ctl_seq_state;
  wire [15:0] ctl_seq_pc;
  wire [31:0] ctl_stat_rd_data;

  assign usr_clk = mac_tx_clk;

  assign m_rx_axis.tdata  = rx_tdata;
  assign m_rx_axis.tkeep  = rx_tkeep;
  assign m_rx_axis.tvalid = rx_tvalid;
  assign m_rx_axis.tlast  = rx_tlast;

  dcmac_axis_top #(
    .N_SEG          (N_SEG),
    .SEG_W          (SEG_W),
    .DATA_W         (DATA_W),
    .PTP_TS_EN      (PTP_TS_EN),
    .PTP_TS_W       (PTP_TS_W),
    .TX_TAG_W       (TX_TAG_W),
    .RX_FIFO_AW     (RX_FIFO_AW),
    .RX_CDC_AW      (RX_CDC_AW),
    .TX_FIFO_AW     (TX_FIFO_AW),
    .TX_CDC_AW      (TX_CDC_AW),
    .TX_CPL_AW      (TX_CPL_AW),
    .SEG_CYC_PER_MS (SEG_CYC_PER_MS),
    .T_RXDP_MS      (T_RXDP_MS),
    .T_SERDES_MS    (T_SERDES_MS),
    .LINK_WDT_MS    (LINK_WDT_MS),
    .PORT_MAX       (PORT_MAX),
    .NPORTS         (NPORTS),
    .ANCHOR         (ANCHOR),
    .LOOPBACK_MODE  (`DCMAC_ETH_LOOPBACK_MODE),
    .EN_CTL_SEQ     (EN_CTL_SEQ),
    .CTL_CYC_PER_MS (CTL_CYC_PER_MS)
  ) u_mac (
    .sys_reset                 (sys_reset),
    .gt_ref_clk_p              (gt_ref_clk_p),
    .gt_ref_clk_n              (gt_ref_clk_n),
    .gt_rxp_in                 (gt_rxp_in),
    .gt_rxn_in                 (gt_rxn_in),
    .gt_txp_out                (gt_txp_out),
    .gt_txn_out                (gt_txn_out),

    .tx_clk                    (mac_tx_clk),
    .tx_rst                    (mac_tx_rst),
    .rx_clk                    (mac_rx_clk),
    .rx_rst                    (mac_rx_rst),

    .s_axis_tx_tdata           (s_tx_axis.tdata),
    .s_axis_tx_tkeep           (s_tx_axis.tkeep),
    .s_axis_tx_tvalid          (s_tx_axis.tvalid),
    .s_axis_tx_tready          (s_tx_axis.tready),
    .s_axis_tx_tlast           (s_tx_axis.tlast),
    .s_axis_tx_tuser           (1'b0),

    .m_axis_tx_cpl_valid       (tx_cpl_valid),
    .m_axis_tx_cpl_ready       (1'b1),
    .m_axis_tx_cpl_ts          (tx_cpl_ts),
    .m_axis_tx_cpl_tag         (tx_cpl_tag),

    .m_axis_rx_tdata           (rx_tdata),
    .m_axis_rx_tkeep           (rx_tkeep),
    .m_axis_rx_tvalid          (rx_tvalid),
    .m_axis_rx_tlast           (rx_tlast),
    .m_axis_rx_tuser           (rx_tuser),

    .seg_ptp_time              ({PTP_TS_W{1'b0}}),
    .seg_clk                   (mac_seg_clk),

    .tx_status                 (mac_tx_status),
    .rx_status                 (mac_rx_status),
    .link_up                   (mac_link_up),
    .rx_overflow               (mac_rx_overflow),
    .rx_trunc                  (mac_rx_trunc),
    .rx_err_frames             (mac_rx_err_frames),
    .rx_align_stat             (mac_rx_align_stat),
    .rx_drop_frames            (mac_rx_drop_frames),
    .tx_cpl_overflow           (mac_tx_cpl_overflow),
    .mac_fsm_state             (mac_fsm_state),

    .ctl_bringup_restart_req   (1'b0),
    .ctl_stats_req             (1'b0),
    .ctl_rx_force_resync_req   (1'b0),
    .ctl_rx_datapath_reset_req (1'b0),
    .ctl_tx_datapath_reset_req (1'b0),
    .ctl_link_fault            (ctl_link_fault),
    .ctl_access_fault          (ctl_access_fault),
    .ctl_seq_busy              (ctl_seq_busy),
    .ctl_rx_phy_status         (ctl_rx_phy_status),
    .ctl_retry_cnt             (ctl_retry_cnt),
    .ctl_seq_state             (ctl_seq_state),
    .ctl_seq_pc                (ctl_seq_pc),
    .ctl_stat_rd_idx           (8'd0),
    .ctl_stat_rd_data          (ctl_stat_rd_data),

    .s_axil_awaddr             (20'd0),
    .s_axil_awvalid            (1'b0),
    .s_axil_awready            (),
    .s_axil_wdata              (32'd0),
    .s_axil_wstrb              (4'd0),
    .s_axil_wvalid             (1'b0),
    .s_axil_wready             (),
    .s_axil_bresp              (),
    .s_axil_bvalid             (),
    .s_axil_bready             (1'b0),
    .s_axil_araddr             (20'd0),
    .s_axil_arvalid            (1'b0),
    .s_axil_arready            (),
    .s_axil_rdata              (),
    .s_axil_rresp              (),
    .s_axil_rvalid             (),
    .s_axil_rready             (1'b0)
  );

  dcmac_usr_reset_gen #(
    .MODE        (`DCMAC_ETH_USR_RESET_MODE),
    .HOLD_CYCLES (`DCMAC_ETH_USR_RESET_HOLD)
  ) u_usr_reset (
    .clk         (mac_tx_clk),
    .sys_reset   (sys_reset),
    .mac_link_up (mac_link_up),
    .mac_tx_rst  (mac_tx_rst),
    .tx_rst      (tx_rst)
  );

  wire unused_seam = |{init_clk,
                       m_rx_axis.tready,
                       mac_rx_clk, mac_rx_rst, mac_seg_clk,
                       rx_tuser,
                       tx_cpl_valid, tx_cpl_ts, tx_cpl_tag,
                       mac_tx_status, mac_rx_status,
                       mac_rx_overflow, mac_rx_trunc,
                       mac_rx_err_frames, mac_rx_align_stat, mac_rx_drop_frames,
                       mac_tx_cpl_overflow, mac_fsm_state,
                       ctl_link_fault, ctl_access_fault, ctl_seq_busy,
                       ctl_rx_phy_status, ctl_retry_cnt,
                       ctl_seq_state, ctl_seq_pc, ctl_stat_rd_data};

endmodule
