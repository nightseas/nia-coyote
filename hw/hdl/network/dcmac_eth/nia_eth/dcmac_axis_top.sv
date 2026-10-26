// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module dcmac_axis_top #(

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

  parameter integer SEG_CYC_PER_MS = 390930,
  parameter integer T_RXDP_MS      = 100,
  parameter integer T_SERDES_MS    = 100,
  parameter integer LINK_WDT_MS    = 750,
  parameter integer PORT_MAX   = 6,
  parameter integer NPORTS     = 1,
  parameter integer ANCHOR     = 0,
  parameter [2:0]   LOOPBACK_MODE = 3'b000,

  parameter integer EN_CTL_SEQ = 1,

  parameter integer CTL_CYC_PER_MS = 250000,

  parameter integer RX_USER_W = (PTP_TS_EN != 0) ? (PTP_TS_W + 1) : 1,
  parameter integer TX_USER_W = TX_TAG_W + 1,
  parameter integer TX_TAG_WP = (TX_TAG_W > 0) ? TX_TAG_W : 1
)(

  input  wire                    sys_reset,
  input  wire                    gt_ref_clk_p,
  input  wire                    gt_ref_clk_n,
  input  wire [3:0]              gt_rxp_in,
  input  wire [3:0]              gt_rxn_in,
  output wire [3:0]              gt_txp_out,
  output wire [3:0]              gt_txn_out,

  output wire                    tx_clk,
  output wire                    tx_rst,
  output wire                    rx_clk,
  output wire                    rx_rst,

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
  output wire                    seg_clk,

  output wire                    tx_status,
  output wire                    rx_status,
  output wire                    link_up,
  output wire                    rx_overflow,
  output wire                    rx_trunc,
  output wire [31:0]             rx_err_frames,
  output wire [31:0]             rx_align_stat,
  output wire [31:0]             rx_drop_frames,
  output wire                    tx_cpl_overflow,
  output wire [2:0]              mac_fsm_state,

  input  wire                    ctl_bringup_restart_req,
  input  wire                    ctl_stats_req,
  input  wire                    ctl_rx_force_resync_req,
  input  wire                    ctl_rx_datapath_reset_req,
  input  wire                    ctl_tx_datapath_reset_req,
  output wire                    ctl_link_fault,
  output wire                    ctl_access_fault,
  output wire                    ctl_seq_busy,
  output wire [31:0]             ctl_rx_phy_status,
  output wire [7:0]              ctl_retry_cnt,
  output wire [4:0]              ctl_seq_state,
  output wire [15:0]             ctl_seq_pc,
  input  wire [7:0]              ctl_stat_rd_idx,
  output wire [31:0]             ctl_stat_rd_data,

  input  wire [19:0]             s_axil_awaddr,
  input  wire                    s_axil_awvalid,
  output wire                    s_axil_awready,
  input  wire [31:0]             s_axil_wdata,
  input  wire [3:0]              s_axil_wstrb,
  input  wire                    s_axil_wvalid,
  output wire                    s_axil_wready,
  output wire [1:0]              s_axil_bresp,
  output wire                    s_axil_bvalid,
  input  wire                    s_axil_bready,
  input  wire [19:0]             s_axil_araddr,
  input  wire                    s_axil_arvalid,
  output wire                    s_axil_arready,
  output wire [31:0]             s_axil_rdata,
  output wire [1:0]              s_axil_rresp,
  output wire                    s_axil_rvalid,
  input  wire                    s_axil_rready
);

  wire seg_clk_i, usr_clk_i, usr_rstn_i;
  wire [0:0] seg_rstn_i;
  assign seg_clk = seg_clk_i;

  initial begin
    if (EN_CTL_SEQ != 1) begin
      $error("Error: dcmac_axis_top EN_CTL_SEQ=%0d is not supported. This seam always instantiates dcmac_link_ctl, which owns the DCMAC s_axi, and its own s_axil_* slave port is tied off for that reason. The EN_CTL_SEQ=0 arm that passes s_axil_* through to the MAC exists in app/pcie_versal and was not imported, so 0 would give a seam whose MAC cannot be reached (instance %m)", EN_CTL_SEQ);
      $finish;
    end
  end

  wire                   rx_seg_valid;
  wire [N_SEG*SEG_W-1:0] rx_seg_dat;
  wire [N_SEG-1:0]       rx_seg_ena, rx_seg_sop, rx_seg_eop, rx_seg_err;
  wire [N_SEG*4-1:0]     rx_seg_mty;

  wire                   tx_seg_ready, tx_seg_valid;
  wire [N_SEG*SEG_W-1:0] tx_seg_dat;
  wire [N_SEG-1:0]       tx_seg_ena, tx_seg_sop, tx_seg_eop, tx_seg_err;
  wire [N_SEG*4-1:0]     tx_seg_mty;

  wire ctl_rx_enable, ctl_rx_force_resync_core, ctl_tx_enable;
  wire ctl_tx_send_idle, ctl_tx_send_lfi, ctl_tx_send_rfi;

  wire                port_rx_dp_reset, port_tx_dp_reset, port_core_serdes_reset;
  wire [PORT_MAX-1:0] port_rx_dp_reset_ports;

  wire                seq_rx_dp_reset;
  wire [PORT_MAX-1:0] seq_rx_dp_ports;
  wire                port_rx_pll_dp_reset;
  wire                port_gt_all_reset;
  wire                port_rx_serdes_reset;
  wire                port_rx_flush;
  wire                gt_rx_done_seg;
  wire                seg_rstn_ctl_i;

  wire fsm_link_up_seam, fsm_tx_rst_seg_seam, rx_pcs_aligned_top;

  wire [7:0] gt_tx_reset_done_raw, gt_rx_reset_done_raw;

  dcmac_sync2 #(.WIDTH(1), .STAGES(2), .INIT('0)) u_sync_gt_rx_done_seg (
    .clk  (seg_clk_i),
    .din  (|gt_rx_reset_done_raw),
    .dout (gt_rx_done_seg));
  wire [7:0] gt_tx_reset_done, gt_rx_reset_done;

  dcmac_sync2 #(.WIDTH(8), .STAGES(2), .INIT(8'h00)) u_sync_gt_tx_done (
    .clk  (usr_clk_i),
    .din  (gt_tx_reset_done_raw),
    .dout (gt_tx_reset_done));

  dcmac_sync2 #(.WIDTH(8), .STAGES(2), .INIT(8'h00)) u_sync_gt_rx_done (
    .clk  (usr_clk_i),
    .din  (gt_rx_reset_done_raw),
    .dout (gt_rx_reset_done));

  wire [19:0] seq_awaddr, seq_araddr;
  wire [31:0] seq_wdata, seq_rdata;
  wire [3:0]  seq_wstrb;
  wire [1:0]  seq_bresp, seq_rresp;
  wire        seq_awvalid, seq_awready, seq_wvalid, seq_wready;
  wire        seq_bvalid, seq_bready, seq_arvalid, seq_arready;
  wire        seq_rvalid, seq_rready;

  wire host_rx_req_gated;
  gt_rst_req_gate #(
    .EN_GATE   (1),
    .SYNC_DONE (1)
  ) u_gate_rx_seam (
    .clk           (usr_clk_i),
    .rstn          (usr_rstn_i),
    .req_level     (ctl_rx_datapath_reset_req),

    .gt_reset_done ((|gt_tx_reset_done) && (|gt_rx_reset_done)),
    .seq_busy      (ctl_seq_busy),
    .req_pulse     (host_rx_req_gated),

    .sts_state      (),
    .sts_stuck      (),
    .sts_refused    (),
    .sts_refuse_cnt (),
    .clr_status     (1'b0)
  );

  dcmac_port #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
    .PTP_TS_EN(PTP_TS_EN), .PTP_TS_W(PTP_TS_W), .TX_TAG_W(TX_TAG_W),
    .RX_FIFO_AW(RX_FIFO_AW), .RX_CDC_AW(RX_CDC_AW),
    .TX_FIFO_AW(TX_FIFO_AW), .TX_CDC_AW(TX_CDC_AW), .TX_CPL_AW(TX_CPL_AW)
  ) u_port (

    .sys_reset               (sys_reset),
    .seg_clk                 (seg_clk_i),
    .seg_rstn                (seg_rstn_ctl_i),
    .usr_clk                 (usr_clk_i),

    .tx_clk                  (tx_clk),
    .tx_rst                  (tx_rst),
    .rx_clk                  (rx_clk),
    .rx_rst                  (rx_rst),
    .usr_rstn                (usr_rstn_i),

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

    .tx_status               (tx_status),
    .rx_status               (rx_status),
    .rx_overflow             (rx_overflow),
    .rx_trunc                (rx_trunc),
    .rx_err_frames           (rx_err_frames),
    .rx_align_stat           (rx_align_stat),
    .rx_drop_frames          (rx_drop_frames),
    .tx_cpl_overflow         (tx_cpl_overflow),

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

    .stat_rx_aligned         (rx_pcs_aligned_top),
    .link_up                 (fsm_link_up_seam),
    .tx_rst_seg              (fsm_tx_rst_seg_seam),
    .ctl_tx_enable           (ctl_tx_enable)
  );

  assign s_axil_awready = 1'b0;
  assign s_axil_wready  = 1'b0;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_bvalid  = 1'b0;
  assign s_axil_arready = 1'b0;
  assign s_axil_rdata   = 32'd0;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_rvalid  = 1'b0;

  dcmac_link_ctl #(
    .PORT_MAX   (PORT_MAX),
    .NPORTS     (NPORTS),
    .ANCHOR     (ANCHOR),
    .N_GROUP    (1),
    .ANCHOR_1   (ANCHOR),
    .CYC_PER_MS (CTL_CYC_PER_MS),

    .LINK_WDT_MS     (LINK_WDT_MS),
    .SEG_CYC_PER_MS  (SEG_CYC_PER_MS),
    .T_RXDP_MS       (T_RXDP_MS),
    .T_SERDES_MS     (T_SERDES_MS),
    .ALIGN_EXPORT_MODE (1)
  ) u_ctl (
    .aclk                    (usr_clk_i),
    .aresetn                 (usr_rstn_i),

    .seg_clk                 (seg_clk_i),
    .seg_rstn                (seg_rstn_i[0]),

    .link_up                     (fsm_link_up_seam),
    .tx_rst_seg                  (fsm_tx_rst_seg_seam),
    .carrier                     (link_up),
    .mac_fsm_state               (mac_fsm_state),
    .ctl_rx_enable               (ctl_rx_enable),
    .ctl_rx_force_resync         (ctl_rx_force_resync_core),
    .ctl_tx_enable               (ctl_tx_enable),
    .ctl_tx_send_idle            (ctl_tx_send_idle),
    .ctl_tx_send_lfi             (ctl_tx_send_lfi),
    .ctl_tx_send_rfi             (ctl_tx_send_rfi),
    .fsm_rx_datapath_reset       (port_rx_dp_reset),
    .fsm_rx_pll_datapath_reset   (port_rx_pll_dp_reset),
    .fsm_gt_all_reset            (port_gt_all_reset),
    .fsm_rx_serdes_reset         (port_rx_serdes_reset),
    .fsm_rx_flush                (port_rx_flush),
    .fsm_gt_rx_done              (gt_rx_done_seg),
    .fsm_repair_count            (),
    .fsm_repair_tmo_count        (),
    .fsm_rx_datapath_reset_ports (port_rx_dp_reset_ports),
    .host_link_reset_req         (host_rx_req_gated),
    .host_rx_force_resync_req    (ctl_rx_force_resync_req),

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

    .gt_tx_reset_done        (gt_tx_reset_done),
    .gt_rx_reset_done        (gt_rx_reset_done),
    .rx_datapath_reset       (seq_rx_dp_reset),
    .rx_datapath_reset_ports (seq_rx_dp_ports),
    .core_serdes_reset       (port_core_serdes_reset),
    .tx_datapath_reset       (),

    .bringup_restart_req     (ctl_bringup_restart_req),
    .stats_req               (ctl_stats_req),
    .rx_force_resync_req     (1'b0),
    .rx_datapath_reset_req   (1'b0),
    .tx_datapath_reset_req   (ctl_tx_datapath_reset_req),
    .rx_force_resync         (),

    .link_wdt_ms             (16'(LINK_WDT_MS)),

    .rx_pcs_aligned          (rx_pcs_aligned_top),
    .link_fault              (ctl_link_fault),
    .access_fault            (ctl_access_fault),
    .seq_busy                (ctl_seq_busy),
    .bringup_done            (),
    .rx_phy_status           (ctl_rx_phy_status),
    .retry_cnt               (ctl_retry_cnt),
    .seq_state               (ctl_seq_state),
    .seq_pc                  (ctl_seq_pc),
    .stat_rd_idx             (ctl_stat_rd_idx),
    .stat_rd_data            (ctl_stat_rd_data),

    .link_reset_req          (),
    .link_remote_fault       (),
    .link_bus_stuck          (),
    .link_ever_aligned       (),
    .link_fault_nibble       (),
    .sup_esc_count           (),
    .link_sample_count       (),
    .link_valid              (),
    .link_window_running     (),
    .link_last_was_fault     (),
    .link_bus_err_count      (),
    .link_window_remaining   (),
    .exec_tmo_count          ()
  );

  assign port_tx_dp_reset = ctl_tx_datapath_reset_req;

  localparam logic [PORT_MAX-1:0] GROUP_MASK = ((PORT_MAX)'((1 << NPORTS) - 1)) << ANCHOR;
  wire [PORT_MAX-1:0] seq_rx_hit      = seq_rx_dp_ports & GROUP_MASK;
  wire                phy_rx_dp_reset = port_rx_dp_reset | (seq_rx_dp_reset & (|seq_rx_hit));
  wire [PORT_MAX-1:0] phy_rx_dp_ports = port_rx_dp_reset_ports | seq_rx_hit;

  dcmac_phy #(
    .N_CLIENT(1),
    .N_SEG(N_SEG), .SEG_W(SEG_W), .PORT_MAX(PORT_MAX),
    .LOOPBACK_MODE(LOOPBACK_MODE),
    .ANCHOR_0(ANCHOR), .ANCHOR_1(ANCHOR + NPORTS)
  ) u_phy (
    .sys_reset               (sys_reset),
    .gt_ref_clk0_p           (gt_ref_clk_p),
    .gt_ref_clk0_n           (gt_ref_clk_n),
    .gt_ref_clk1_p           (1'b0),
    .gt_ref_clk1_n           (1'b0),
    .gt_rxp_in               (gt_rxp_in),
    .gt_rxn_in               (gt_rxn_in),
    .gt_txn_out              (gt_txn_out),
    .gt_txp_out              (gt_txp_out),

    .seg_clk                 (seg_clk_i),
    .seg_rstn                (seg_rstn_i),
    .seg_rstn_ctl            (seg_rstn_ctl_i),
    .usr_clk                 (usr_clk_i),

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

    .ctl_rx_enable           (ctl_rx_enable),
    .ctl_rx_force_resync     (ctl_rx_force_resync_core),
    .ctl_tx_enable           (ctl_tx_enable),
    .ctl_tx_send_idle        (ctl_tx_send_idle),
    .ctl_tx_send_lfi         (ctl_tx_send_lfi),
    .ctl_tx_send_rfi         (ctl_tx_send_rfi),

    .rx_datapath_reset       (phy_rx_dp_reset),
    .rx_pll_datapath_reset   (port_rx_pll_dp_reset),
    .gt_all_reset            (port_gt_all_reset),
    .rx_serdes_reset_req     (port_rx_serdes_reset),
    .rx_flush_req            (port_rx_flush),
    .rx_datapath_reset_ports (phy_rx_dp_ports),
    .tx_datapath_reset       (port_tx_dp_reset),

    .axil_aclk               (usr_clk_i),
    .axil_aresetn            (usr_rstn_i),

    .s_axil_awaddr           (seq_awaddr),
    .s_axil_awvalid          (seq_awvalid),
    .s_axil_awready          (seq_awready),
    .s_axil_wdata            (seq_wdata),
    .s_axil_wstrb            (seq_wstrb),
    .s_axil_wvalid           (seq_wvalid),
    .s_axil_wready           (seq_wready),
    .s_axil_bresp            (seq_bresp),
    .s_axil_bvalid           (seq_bvalid),
    .s_axil_bready           (seq_bready),
    .s_axil_araddr           (seq_araddr),
    .s_axil_arvalid          (seq_arvalid),
    .s_axil_arready          (seq_arready),
    .s_axil_rdata            (seq_rdata),
    .s_axil_rresp            (seq_rresp),
    .s_axil_rvalid           (seq_rvalid),
    .s_axil_rready           (seq_rready),

    .gt_tx_reset_done        (gt_tx_reset_done_raw),
    .gt_rx_reset_done        (gt_rx_reset_done_raw),
    .core_serdes_reset       (port_core_serdes_reset)
  );

endmodule
