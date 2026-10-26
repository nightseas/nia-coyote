// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

import lynxTypes::*;

module dcmac_axis_wrapper (
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
  localparam int N_SEG    = 2;
  localparam int SEG_W    = 128;
  localparam int PORT_MAX = 6;
  localparam int NPORTS   = 1;
  localparam int ANCHOR   = 0;

  logic                    seg_clk, seg_rstn;
  logic                    usr_clk_i, usr_rstn;
  logic                    stat_rx_aligned;

  logic                    rx_seg_valid;
  logic [N_SEG*SEG_W-1:0]  rx_seg_dat;
  logic [N_SEG-1:0]        rx_seg_ena, rx_seg_sop, rx_seg_eop, rx_seg_err;
  logic [N_SEG*4-1:0]      rx_seg_mty;

  logic                    tx_seg_ready, tx_seg_valid;
  logic [N_SEG*SEG_W-1:0]  tx_seg_dat;
  logic [N_SEG-1:0]        tx_seg_ena, tx_seg_sop, tx_seg_eop, tx_seg_err;
  logic [N_SEG*4-1:0]      tx_seg_mty;

  logic ctl_rx_enable, ctl_rx_force_resync;
  logic ctl_tx_enable, ctl_tx_send_idle, ctl_tx_send_lfi, ctl_tx_send_rfi;
  logic rx_datapath_reset, tx_datapath_reset;
  logic [PORT_MAX-1:0] rx_datapath_reset_ports;
  logic [2:0] fsm_state;
  logic link_up, rx_overflow, rx_trunc;
  logic [31:0] rx_err_frames, rx_drop_frames;

  assign usr_clk = usr_clk_i;

  assign usr_rstn = ~tx_rst;

  logic seq_rstn_r0, seq_rstn_r1;
  always_ff @(posedge usr_clk_i) begin
    seq_rstn_r0 <= ~sys_reset;
    seq_rstn_r1 <= seq_rstn_r0;
  end
  wire seq_aresetn = seq_rstn_r1;

  logic [19:0] seq_awaddr, seq_araddr;
  logic [31:0] seq_wdata, seq_rdata;
  logic [3:0]  seq_wstrb;
  logic [1:0]  seq_bresp, seq_rresp;
  logic seq_awvalid, seq_awready, seq_wvalid, seq_wready, seq_bvalid, seq_bready;
  logic seq_arvalid, seq_arready, seq_rvalid, seq_rready;

  logic [7:0] phy_gt_tx_done, phy_gt_rx_done;
  (* ASYNC_REG = "TRUE" *) logic [7:0] gt_tx_done_s0, gt_tx_done_s1;
  (* ASYNC_REG = "TRUE" *) logic [7:0] gt_rx_done_s0, gt_rx_done_s1;
  always_ff @(posedge usr_clk_i) begin
    gt_tx_done_s0 <= phy_gt_tx_done;
    gt_tx_done_s1 <= gt_tx_done_s0;
    gt_rx_done_s0 <= phy_gt_rx_done;
    gt_rx_done_s1 <= gt_rx_done_s0;
  end

  logic                seq_rx_dp_reset, seq_core_serdes_reset, seq_tx_dp_reset;
  logic [PORT_MAX-1:0] seq_rx_dp_reset_ports;
  logic                seq_link_up, seq_link_fault, seq_access_fault, seq_busy;
  logic                seq_rx_force_resync;
  logic [31:0]         seq_rx_phy_status, seq_stat_rd_data;
  logic [7:0]          seq_retry_cnt;
  logic [4:0]          seq_state;
  logic [15:0]         seq_pc;

`ifndef DCMAC_CTL_CYC_PER_MS
  `define DCMAC_CTL_CYC_PER_MS 250000
`endif

  dcmac_ctl_seq #(
    .PORT_MAX     (PORT_MAX),
    .NPORTS       (NPORTS),
    .ANCHOR       (ANCHOR),
    .CYC_PER_MS   (`DCMAC_CTL_CYC_PER_MS)
  ) u_ctl (
    .aclk                    (usr_clk_i),
    .aresetn                 (seq_aresetn),

    .m_axil_awaddr           (seq_awaddr),
    .m_axil_awvalid          (seq_awvalid),
    .m_axil_awready          (seq_awready),
    .m_axil_wdata            (seq_wdata),
    .m_axil_wstrb            (seq_wstrb),
    .m_axil_wvalid           (seq_wvalid),
    .m_axil_wready           (seq_wready),
    .m_axil_bresp            (seq_bresp),
    .m_axil_bvalid           (seq_bvalid),
    .m_axil_bready           (seq_bready),
    .m_axil_araddr           (seq_araddr),
    .m_axil_arvalid          (seq_arvalid),
    .m_axil_arready          (seq_arready),
    .m_axil_rdata            (seq_rdata),
    .m_axil_rresp            (seq_rresp),
    .m_axil_rvalid           (seq_rvalid),
    .m_axil_rready           (seq_rready),

    .gt_tx_reset_done        (gt_tx_done_s1),
    .gt_rx_reset_done        (gt_rx_done_s1),
    .rx_datapath_reset       (seq_rx_dp_reset),
    .rx_datapath_reset_ports (seq_rx_dp_reset_ports),
    .core_serdes_reset       (seq_core_serdes_reset),
    .tx_datapath_reset       (seq_tx_dp_reset),

    .bringup_restart_req     (1'b0),
    .stats_req               (1'b0),
    .rx_force_resync_req     (1'b0),
    .rx_datapath_reset_req   (1'b0),
    .tx_datapath_reset_req   (1'b0),
    .rx_force_resync         (seq_rx_force_resync),

    .link_up                 (seq_link_up),
    .link_fault              (seq_link_fault),
    .access_fault            (seq_access_fault),
    .seq_busy                (seq_busy),
    .rx_phy_status           (seq_rx_phy_status),
    .retry_cnt               (seq_retry_cnt),
    .seq_state               (seq_state),
    .seq_pc                  (seq_pc),
    .stat_rd_idx             (8'd0),
    .stat_rd_data            (seq_stat_rd_data)
  );

  (* ASYNC_REG = "TRUE" *) logic align_s0, align_s1;
  always_ff @(posedge seg_clk) begin
    align_s0 <= seq_link_up;
    align_s1 <= align_s0;
  end
  assign stat_rx_aligned = align_s1;

  (* ASYNC_REG = "TRUE" *) logic seq_rxdp_s0, seq_rxdp_s1;
  (* ASYNC_REG = "TRUE" *) logic [PORT_MAX-1:0] seq_rxdpp_s0, seq_rxdpp_s1;
  always_ff @(posedge seg_clk) begin
    seq_rxdp_s0  <= seq_rx_dp_reset;
    seq_rxdp_s1  <= seq_rxdp_s0;
    seq_rxdpp_s0 <= seq_rx_dp_reset_ports;
    seq_rxdpp_s1 <= seq_rxdpp_s0;
  end
  wire                phy_rx_dp_reset       = rx_datapath_reset | seq_rxdp_s1;
  wire [PORT_MAX-1:0] phy_rx_dp_reset_ports = rx_datapath_reset_ports | seq_rxdpp_s1;
  wire phy_tx_dp_reset = tx_datapath_reset | seq_tx_dp_reset;

  wire _unused_seq_status = |{seq_link_fault, seq_access_fault, seq_busy,
                              seq_rx_force_resync, seq_rx_phy_status, seq_retry_cnt,
                              seq_state, seq_pc, seq_stat_rd_data};

  dcmac_axis_core #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .AXI_NET_BITS(AXI_NET_BITS),
    .PORT_MAX(PORT_MAX), .NPORTS(NPORTS), .ANCHOR(ANCHOR)
  ) u_core (
    .seg_clk               (seg_clk),
    .seg_rstn              (seg_rstn),
    .usr_clk               (usr_clk_i),
    .usr_rstn              (usr_rstn),

    .m_rx_axis_tdata       (m_rx_axis.tdata),
    .m_rx_axis_tkeep       (m_rx_axis.tkeep),
    .m_rx_axis_tvalid      (m_rx_axis.tvalid),
    .m_rx_axis_tready      (m_rx_axis.tready),
    .m_rx_axis_tlast       (m_rx_axis.tlast),

    .s_tx_axis_tdata       (s_tx_axis.tdata),
    .s_tx_axis_tkeep       (s_tx_axis.tkeep),
    .s_tx_axis_tvalid      (s_tx_axis.tvalid),
    .s_tx_axis_tready      (s_tx_axis.tready),
    .s_tx_axis_tlast       (s_tx_axis.tlast),

    .rx_seg_valid          (rx_seg_valid),
    .rx_seg_dat            (rx_seg_dat),
    .rx_seg_ena            (rx_seg_ena),
    .rx_seg_sop            (rx_seg_sop),
    .rx_seg_eop            (rx_seg_eop),
    .rx_seg_err            (rx_seg_err),
    .rx_seg_mty            (rx_seg_mty),

    .tx_seg_ready          (tx_seg_ready),
    .tx_seg_valid          (tx_seg_valid),
    .tx_seg_dat            (tx_seg_dat),
    .tx_seg_ena            (tx_seg_ena),
    .tx_seg_sop            (tx_seg_sop),
    .tx_seg_eop            (tx_seg_eop),
    .tx_seg_err            (tx_seg_err),
    .tx_seg_mty            (tx_seg_mty),

    .stat_rx_aligned       (stat_rx_aligned),
    .rx_datapath_reset_req (1'b0),
    .tx_datapath_reset_req (1'b0),
    .rx_force_resync_req   (1'b0),
    .ctl_rx_enable         (ctl_rx_enable),
    .ctl_rx_force_resync   (ctl_rx_force_resync),
    .ctl_tx_enable         (ctl_tx_enable),
    .ctl_tx_send_idle      (ctl_tx_send_idle),
    .ctl_tx_send_lfi       (ctl_tx_send_lfi),
    .ctl_tx_send_rfi       (ctl_tx_send_rfi),
    .rx_datapath_reset     (rx_datapath_reset),
    .tx_datapath_reset     (tx_datapath_reset),
    .rx_datapath_reset_ports(rx_datapath_reset_ports),
    .tx_rst                (tx_rst),
    .fsm_state             (fsm_state),
    .link_up               (link_up),
    .rx_overflow           (rx_overflow),
    .rx_trunc              (rx_trunc),
    .rx_err_frames         (rx_err_frames),
    .rx_drop_frames        (rx_drop_frames)
  );

`ifndef DCMAC_LOOPBACK_MODE
  `define DCMAC_LOOPBACK_MODE 3'b000
`endif
  dcmac_100g_phy #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .PORT_MAX(PORT_MAX),
    .LOOPBACK_MODE(`DCMAC_LOOPBACK_MODE)
  ) u_phy (
    .init_clk              (init_clk),
    .sys_reset             (sys_reset),
    .gt_ref_clk_p          (gt_ref_clk_p),
    .gt_ref_clk_n          (gt_ref_clk_n),
    .gt_rxp_in             (gt_rxp_in),
    .gt_rxn_in             (gt_rxn_in),
    .gt_txn_out            (gt_txn_out),
    .gt_txp_out            (gt_txp_out),

    .seg_clk               (seg_clk),
    .seg_rstn              (seg_rstn),
    .usr_clk               (usr_clk_i),

    .rx_seg_valid          (rx_seg_valid),
    .rx_seg_dat            (rx_seg_dat),
    .rx_seg_ena            (rx_seg_ena),
    .rx_seg_sop            (rx_seg_sop),
    .rx_seg_eop            (rx_seg_eop),
    .rx_seg_err            (rx_seg_err),
    .rx_seg_mty            (rx_seg_mty),

    .tx_seg_ready          (tx_seg_ready),
    .tx_seg_valid          (tx_seg_valid),
    .tx_seg_dat            (tx_seg_dat),
    .tx_seg_ena            (tx_seg_ena),
    .tx_seg_sop            (tx_seg_sop),
    .tx_seg_eop            (tx_seg_eop),
    .tx_seg_err            (tx_seg_err),
    .tx_seg_mty            (tx_seg_mty),

    .ctl_rx_enable         (ctl_rx_enable),
    .ctl_rx_force_resync   (ctl_rx_force_resync),
    .ctl_tx_enable         (ctl_tx_enable),
    .ctl_tx_send_idle      (ctl_tx_send_idle),
    .ctl_tx_send_lfi       (ctl_tx_send_lfi),
    .ctl_tx_send_rfi       (ctl_tx_send_rfi),
    .rx_datapath_reset     (phy_rx_dp_reset),
    .rx_datapath_reset_ports(phy_rx_dp_reset_ports),
    .tx_datapath_reset     (phy_tx_dp_reset),

    .axil_aclk             (usr_clk_i),
    .axil_aresetn          (seq_aresetn),
    .s_axil_awaddr         (seq_awaddr),
    .s_axil_awvalid        (seq_awvalid),
    .s_axil_awready        (seq_awready),
    .s_axil_wdata          (seq_wdata),
    .s_axil_wstrb          (seq_wstrb),
    .s_axil_wvalid         (seq_wvalid),
    .s_axil_wready         (seq_wready),
    .s_axil_bresp          (seq_bresp),
    .s_axil_bvalid         (seq_bvalid),
    .s_axil_bready         (seq_bready),
    .s_axil_araddr         (seq_araddr),
    .s_axil_arvalid        (seq_arvalid),
    .s_axil_arready        (seq_arready),
    .s_axil_rdata          (seq_rdata),
    .s_axil_rresp          (seq_rresp),
    .s_axil_rvalid         (seq_rvalid),
    .s_axil_rready         (seq_rready),
    .gt_tx_reset_done      (phy_gt_tx_done),
    .gt_rx_reset_done      (phy_gt_rx_done),
    .core_serdes_reset     (seq_core_serdes_reset)
  );

endmodule

`default_nettype wire
