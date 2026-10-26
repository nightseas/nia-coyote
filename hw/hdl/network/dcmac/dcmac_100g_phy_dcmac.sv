// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module dcmac_100g_phy #(
  parameter int         N_SEG                  = 2,
  parameter int         SEG_W                  = 128,
  parameter int         PORT_MAX               = 6,
  parameter logic [2:0] LOOPBACK_MODE          = 3'b000,
  parameter int         RX_DP_RESET_MIN_CYCLES = 512,
  parameter int         TX_MAINCURSOR          = dcmac_ctl_pkg::TX_MAIN_DEFAULT,
  parameter int         TX_PRECURSOR           = dcmac_ctl_pkg::TX_PRE_DEFAULT,
  parameter int         TX_POSTCURSOR          = dcmac_ctl_pkg::TX_POST_DEFAULT
)(
  input  wire                     init_clk,
  input  wire                     sys_reset,
  input  wire                     gt_ref_clk_p,
  input  wire                     gt_ref_clk_n,
  input  wire [3:0]               gt_rxp_in,
  input  wire [3:0]               gt_rxn_in,
  output wire [3:0]               gt_txn_out,
  output wire [3:0]               gt_txp_out,

  output logic                    seg_clk,
  output logic                    seg_rstn,
  output logic                    usr_clk,

  output logic                    rx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]  rx_seg_dat,
  output logic [N_SEG-1:0]        rx_seg_ena,
  output logic [N_SEG-1:0]        rx_seg_sop,
  output logic [N_SEG-1:0]        rx_seg_eop,
  output logic [N_SEG-1:0]        rx_seg_err,
  output logic [N_SEG*4-1:0]      rx_seg_mty,

  output logic                    tx_seg_ready,
  input  logic                    tx_seg_valid,
  input  logic [N_SEG*SEG_W-1:0]  tx_seg_dat,
  input  logic [N_SEG-1:0]        tx_seg_ena,
  input  logic [N_SEG-1:0]        tx_seg_sop,
  input  logic [N_SEG-1:0]        tx_seg_eop,
  input  logic [N_SEG-1:0]        tx_seg_err,
  input  logic [N_SEG*4-1:0]      tx_seg_mty,

  input  logic                    ctl_rx_enable,
  input  logic                    ctl_rx_force_resync,
  input  logic                    ctl_tx_enable,
  input  logic                    ctl_tx_send_idle,
  input  logic                    ctl_tx_send_lfi,
  input  logic                    ctl_tx_send_rfi,
  input  logic                    rx_datapath_reset,
  input  logic [PORT_MAX-1:0]     rx_datapath_reset_ports,
  input  logic                    tx_datapath_reset,

  input  wire                     axil_aclk,
  input  wire                     axil_aresetn,
  input  logic [19:0]             s_axil_awaddr,
  input  logic                    s_axil_awvalid,
  output logic                    s_axil_awready,
  input  logic [31:0]             s_axil_wdata,
  input  logic [3:0]              s_axil_wstrb,
  input  logic                    s_axil_wvalid,
  output logic                    s_axil_wready,
  output logic [1:0]              s_axil_bresp,
  output logic                    s_axil_bvalid,
  input  logic                    s_axil_bready,
  input  logic [19:0]             s_axil_araddr,
  input  logic                    s_axil_arvalid,
  output logic                    s_axil_arready,
  output logic [31:0]             s_axil_rdata,
  output logic [1:0]              s_axil_rresp,
  output logic                    s_axil_rvalid,
  input  logic                    s_axil_rready,

  output logic [7:0]              gt_tx_reset_done,
  output logic [7:0]              gt_rx_reset_done,

  input  logic                    core_serdes_reset
);

  // synthesis translate_off
  initial begin
    if (!dcmac_ctl_pkg::cursor_legal(TX_MAINCURSOR, TX_PRECURSOR, TX_POSTCURSOR))
      $fatal(1, "dcmac_100g_phy: G2 violated - cursor set main=%0d pre=%0d post=%0d is not AM017-legal",
             TX_MAINCURSOR, TX_PRECURSOR, TX_POSTCURSOR);
  end
  // synthesis translate_on

  wire QUAD0_GTREFCLK0;
  wire bufds_odiv2_0;
  wire clk_wiz_in;

  wire core_clk;
  wire axis_clk;
  wire ts_clk;
  wire clk_wiz_locked;
  wire clk_wiz_reset = 1'b0;

  IBUFDS_GTME5 #(
    .REFCLK_EN_TX_PATH  (1'b0),
    .REFCLK_HROW_CK_SEL (0),
    .REFCLK_ICNTL_RX    (0)
  ) dcmac_IBUFDS_GTE5_REFCLK0_gt0 (
    .I     (gt_ref_clk_p),
    .IB    (gt_ref_clk_n),
    .CEB   (1'b0),
    .ODIV2 (bufds_odiv2_0),
    .O     (QUAD0_GTREFCLK0)
  );

  BUFG_GT #(
    .SIM_DEVICE("VERSAL_PREMIUM")
  ) dcmac_BUFG_GT_inst (
    .O       (clk_wiz_in),
    .CE      (1'b1),
    .CEMASK  (1'b0),
    .CLR     (1'b0),
    .CLRMASK (1'b0),
    .DIV     (3'd0),
    .I       (bufds_odiv2_0)
  );

  dcmac_0_clk_wiz_0 i_dcmac_clk_wiz (
    .reset    (clk_wiz_reset),
    .clk_in1  (clk_wiz_in),
    .locked   (clk_wiz_locked),
    .clk_out1 (core_clk),
    .clk_out2 (axis_clk),
    .clk_out3 (ts_clk)
  );

  assign seg_clk = axis_clk;

  wire usr_clk_i;
  wire usr_clk_locked;
  dcmac_usr_clk_wiz i_usr_clk_wiz (
    .reset    (sys_reset),
    .clk_in1  (clk_wiz_in),
    .locked   (usr_clk_locked),
    .clk_out1 (usr_clk_i)
  );
  assign usr_clk = usr_clk_i;

  wire [5:0] rx_serdes_clk;
  wire [5:0] tx_serdes_clk;
  wire [5:0] rx_alt_serdes_clk;
  wire [5:0] tx_alt_serdes_clk;

  wire gt0_tx_usrclk_0,  gt0_tx_usrclk2_0;
  wire gt0_rx_usrclk_0,  gt0_rx_usrclk2_0;

  wire gtpowergood_0;
  wire INTF0_rst_tx_done_out;
  wire INTF0_rst_rx_done_out;

  wire [11:0] gt_tx_reset_done_int;
  wire [11:0] gt_rx_reset_done_int;
  assign gt_tx_reset_done_int[1:0]   = {2{INTF0_rst_tx_done_out}};
  assign gt_rx_reset_done_int[1:0]   = {2{INTF0_rst_rx_done_out}};
  assign gt_tx_reset_done_int[11:2]  = {10{1'b1}};
  assign gt_rx_reset_done_int[11:2]  = {10{1'b1}};

  assign rx_alt_serdes_clk[0] = gt0_rx_usrclk2_0;
  assign tx_alt_serdes_clk[0] = gt0_tx_usrclk2_0;
  assign rx_serdes_clk[0]     = gt0_rx_usrclk_0;
  assign tx_serdes_clk[0]     = gt0_tx_usrclk_0;
  assign rx_alt_serdes_clk[5:1] = 5'b0;
  assign tx_alt_serdes_clk[5:1] = 5'b0;
  assign rx_serdes_clk[5:1]     = 5'b0;
  assign tx_serdes_clk[5:1]     = 5'b0;

  wire gt_rx_reset_done_inv = ~(&gt_rx_reset_done_int[11:0]);
  wire gt_tx_reset_done_inv = ~(&gt_tx_reset_done_int[11:0]);

  wire gt_rx_reset_done_core_clk_sync;
  wire gt_tx_reset_done_core_clk_sync;
  wire gt_rx_reset_done_axis_clk_sync;
  wire gt_tx_reset_done_axis_clk_sync;

  dcmac_0_syncer_reset #(.RESET_PIPE_LEN(3)) i_sync_rx_core (
    .clk(core_clk), .reset_async(gt_rx_reset_done_inv),
    .reset(gt_rx_reset_done_core_clk_sync));
  dcmac_0_syncer_reset #(.RESET_PIPE_LEN(3)) i_sync_tx_core (
    .clk(core_clk), .reset_async(gt_tx_reset_done_inv),
    .reset(gt_tx_reset_done_core_clk_sync));
  dcmac_0_syncer_reset #(.RESET_PIPE_LEN(3)) i_sync_rx_axis (
    .clk(axis_clk), .reset_async(gt_rx_reset_done_inv),
    .reset(gt_rx_reset_done_axis_clk_sync));
  dcmac_0_syncer_reset #(.RESET_PIPE_LEN(3)) i_sync_tx_axis (
    .clk(axis_clk), .reset_async(gt_tx_reset_done_inv),
    .reset(gt_tx_reset_done_axis_clk_sync));

  wire rx_core_clk = core_clk;
  wire tx_core_clk = core_clk;
  wire clk_rx_axi  = axis_clk;
  wire clk_tx_axi  = axis_clk;

  wire rstn_rx_axi = clk_wiz_locked & ~gt_rx_reset_done_axis_clk_sync;
  wire rstn_tx_axi = clk_wiz_locked & ~gt_tx_reset_done_axis_clk_sync;
  assign seg_rstn = rstn_tx_axi & rstn_rx_axi;

  localparam int SW = (RX_DP_RESET_MIN_CYCLES > 1) ? $clog2(RX_DP_RESET_MIN_CYCLES + 1) : 1;
  logic [SW-1:0] rx_dp_cnt;
  logic          rx_dp_reset_stretched;
  always_ff @(posedge axis_clk) begin
    if (!rstn_tx_axi) begin
      rx_dp_cnt             <= '0;
      rx_dp_reset_stretched <= 1'b0;
    end else if (rx_datapath_reset) begin
      rx_dp_cnt             <= RX_DP_RESET_MIN_CYCLES[SW-1:0];
      rx_dp_reset_stretched <= 1'b1;
    end else if (rx_dp_cnt != '0) begin
      rx_dp_cnt             <= rx_dp_cnt - 1'b1;
      rx_dp_reset_stretched <= 1'b1;
    end else begin
      rx_dp_reset_stretched <= 1'b0;
    end
  end

  wire [127:0] rx_axis_tdata0, rx_axis_tdata1;
  wire         rx_axis_tuser_ena0,  rx_axis_tuser_ena1;
  wire         rx_axis_tuser_sop0,  rx_axis_tuser_sop1;
  wire         rx_axis_tuser_eop0,  rx_axis_tuser_eop1;
  wire         rx_axis_tuser_err0,  rx_axis_tuser_err1;
  wire [3:0]   rx_axis_tuser_mty0,  rx_axis_tuser_mty1;
  wire         rx_axis_tvalid_0;

  assign rx_seg_valid = rx_axis_tvalid_0;
  assign rx_seg_dat   = {rx_axis_tdata1, rx_axis_tdata0};
  assign rx_seg_ena   = {rx_axis_tuser_ena1, rx_axis_tuser_ena0};
  assign rx_seg_sop   = {rx_axis_tuser_sop1, rx_axis_tuser_sop0};
  assign rx_seg_eop   = {rx_axis_tuser_eop1, rx_axis_tuser_eop0};
  assign rx_seg_err   = {rx_axis_tuser_err1, rx_axis_tuser_err0};
  assign rx_seg_mty   = {rx_axis_tuser_mty1, rx_axis_tuser_mty0};

  wire [127:0] tx_axis_tdata0     = tx_seg_dat[127:0];
  wire [127:0] tx_axis_tdata1     = tx_seg_dat[255:128];
  wire         tx_axis_tuser_ena0 = tx_seg_ena[0];
  wire         tx_axis_tuser_ena1 = tx_seg_ena[1];
  wire         tx_axis_tuser_sop0 = tx_seg_sop[0];
  wire         tx_axis_tuser_sop1 = tx_seg_sop[1];
  wire         tx_axis_tuser_eop0 = tx_seg_eop[0];
  wire         tx_axis_tuser_eop1 = tx_seg_eop[1];
  wire         tx_axis_tuser_err0 = tx_seg_err[0];
  wire         tx_axis_tuser_err1 = tx_seg_err[1];
  wire [3:0]   tx_axis_tuser_mty0 = tx_seg_mty[3:0];
  wire [3:0]   tx_axis_tuser_mty1 = tx_seg_mty[7:4];
  wire         tx_axis_tvalid_0   = tx_seg_valid;
  wire         tx_axis_tready_0;
  wire         tx_axis_taf_0;
  assign tx_seg_ready = tx_axis_tready_0;

  wire rx_all_channel_mac_pm_rdy;
  wire _unused_pm_rdy = rx_all_channel_mac_pm_rdy;

  wire [255:0] txdata_out_0, txdata_out_1;
  wire [255:0] rxdata_in_0,  rxdata_in_1;

  wire tx_serdes_is_am_0, tx_serdes_is_am_1, tx_serdes_is_am_2;
  wire tx_serdes_is_am_3, tx_serdes_is_am_4, tx_serdes_is_am_5;
  wire tx_serdes_is_am_prefifo_0, tx_serdes_is_am_prefifo_1, tx_serdes_is_am_prefifo_2;
  wire tx_serdes_is_am_prefifo_3, tx_serdes_is_am_prefifo_4, tx_serdes_is_am_prefifo_5;

  wire [5:0] pm_tick_core  = 6'b0;
  wire [5:0] tx_flexif_clk = 6'b0;
  wire [5:0] rx_flexif_clk = 6'b0;
  wire       tx_macif_clk  = 1'b0;
  wire       rx_macif_clk  = 1'b0;
  wire [5:0] rx_serdes_reset;
  wire [5:0] tx_serdes_reset;

  wire [15:0] default_vl_length_100GE = 16'd255;

  wire [63:0] ctl_vl0  = 64'hc16821003e97de00, ctl_vl1  = 64'h9d718e00628e7100;
  wire [63:0] ctl_vl2  = 64'h594be800a6b41700, ctl_vl3  = 64'h4d957b00b26a8400;
  wire [63:0] ctl_vl4  = 64'hf50709000af8f600, ctl_vl5  = 64'hdd14c20022eb3d00;
  wire [63:0] ctl_vl6  = 64'h9a4a260065b5d900, ctl_vl7  = 64'h7b45660084ba9900;
  wire [63:0] ctl_vl8  = 64'ha02476005fdb8900, ctl_vl9  = 64'h68c9fb0097360400;
  wire [63:0] ctl_vl10 = 64'hfd6c990002936600, ctl_vl11 = 64'hb9915500466eaa00;
  wire [63:0] ctl_vl12 = 64'h5cb9b200a3464d00, ctl_vl13 = 64'h1af8bd00e5074200;
  wire [63:0] ctl_vl14 = 64'h83c7ca007c383500, ctl_vl15 = 64'h3536cd00cac93200;
  wire [63:0] ctl_vl16 = 64'hc4314c003bceb300, ctl_vl17 = 64'hadd6b70052294800;
  wire [63:0] ctl_vl18 = 64'h5f662a00a099d500, ctl_vl19 = 64'hc0f0e5003f0f1a00;

  logic [5:0] rx_channel_flush_i;
  always_comb begin
    rx_channel_flush_i = 6'b0;
    for (int p = 0; p < PORT_MAX && p < 6; p++)
      rx_channel_flush_i[p] = rx_datapath_reset_ports[p];
  end

  wire _unused_ctl = |{ctl_rx_enable, ctl_rx_force_resync, ctl_tx_enable,
                       usr_clk_locked, gtpowergood_0, tx_axis_taf_0};

  dcmac_0 i_dcmac_0 (
    .s_axi_aclk           (axil_aclk),
    .s_axi_aresetn        (axil_aresetn),
    .s_axi_awaddr         ({12'd0, s_axil_awaddr}),
    .s_axi_awvalid        (s_axil_awvalid),
    .s_axi_awready        (s_axil_awready),
    .s_axi_wdata          (s_axil_wdata),
    .s_axi_wvalid         (s_axil_wvalid),
    .s_axi_wready         (s_axil_wready),
    .s_axi_bresp          (s_axil_bresp),
    .s_axi_bvalid         (s_axil_bvalid),
    .s_axi_bready         (s_axil_bready),
    .s_axi_araddr         ({12'd0, s_axil_araddr}),
    .s_axi_arvalid        (s_axil_arvalid),
    .s_axi_arready        (s_axil_arready),
    .s_axi_rdata          (s_axil_rdata),
    .s_axi_rresp          (s_axil_rresp),
    .s_axi_rvalid         (s_axil_rvalid),
    .s_axi_rready         (s_axil_rready),

    .fec_tx_dout_start_0(), .fec_tx_dout_start_0_bh(),
    .fec_tx_dout_start_1(), .fec_tx_dout_start_1_bh(),
    .fec_tx_dout_start_2(), .fec_tx_dout_start_2_bh(),
    .fec_tx_dout_start_3(), .fec_tx_dout_start_3_bh(),
    .fec_tx_dout_start_4(), .fec_tx_dout_start_4_bh(),
    .fec_tx_dout_start_5(), .fec_tx_dout_start_5_bh(),

    .rsvd_out(), .rsvd_out_rx_mac(), .rsvd_out_rx_phy(),
    .rsvd_out_tx_mac(), .rsvd_out_tx_phy(),

    .rx_all_channel_mac_pm_rdy (rx_all_channel_mac_pm_rdy),
    .rx_axis_tdata0     (rx_axis_tdata0),
    .rx_axis_tdata1     (rx_axis_tdata1),
    .rx_axis_tuser_ena0 (rx_axis_tuser_ena0),
    .rx_axis_tuser_ena1 (rx_axis_tuser_ena1),
    .rx_axis_tuser_eop0 (rx_axis_tuser_eop0),
    .rx_axis_tuser_eop1 (rx_axis_tuser_eop1),
    .rx_axis_tuser_err0 (rx_axis_tuser_err0),
    .rx_axis_tuser_err1 (rx_axis_tuser_err1),
    .rx_axis_tuser_mty0 (rx_axis_tuser_mty0),
    .rx_axis_tuser_mty1 (rx_axis_tuser_mty1),
    .rx_axis_tuser_sop0 (rx_axis_tuser_sop0),
    .rx_axis_tuser_sop1 (rx_axis_tuser_sop1),
    .rx_axis_tvalid_0   (rx_axis_tvalid_0),

    .rx_lane_aligner_fill(), .rx_lane_aligner_fill_start(), .rx_lane_aligner_fill_valid(),
    .rx_pcs_tdm_stats_data(), .rx_pcs_tdm_stats_start(), .rx_pcs_tdm_stats_valid(),
    .rx_port_pm_rdy(),
    .rx_preambleout_0(),

    .rx_serdes_albuf_restart_0(), .rx_serdes_albuf_restart_1(), .rx_serdes_albuf_restart_2(),
    .rx_serdes_albuf_restart_3(), .rx_serdes_albuf_restart_4(), .rx_serdes_albuf_restart_5(),
    .rx_serdes_albuf_slip_0(),  .rx_serdes_albuf_slip_1(),  .rx_serdes_albuf_slip_2(),
    .rx_serdes_albuf_slip_3(),  .rx_serdes_albuf_slip_4(),  .rx_serdes_albuf_slip_5(),
    .rx_serdes_albuf_slip_6(),  .rx_serdes_albuf_slip_7(),  .rx_serdes_albuf_slip_8(),
    .rx_serdes_albuf_slip_9(),  .rx_serdes_albuf_slip_10(), .rx_serdes_albuf_slip_11(),
    .rx_serdes_albuf_slip_12(), .rx_serdes_albuf_slip_13(), .rx_serdes_albuf_slip_14(),
    .rx_serdes_albuf_slip_15(), .rx_serdes_albuf_slip_16(), .rx_serdes_albuf_slip_17(),
    .rx_serdes_albuf_slip_18(), .rx_serdes_albuf_slip_19(), .rx_serdes_albuf_slip_20(),
    .rx_serdes_albuf_slip_21(), .rx_serdes_albuf_slip_22(), .rx_serdes_albuf_slip_23(),
    .rx_serdes_fifo_flagout_0(), .rx_serdes_fifo_flagout_1(), .rx_serdes_fifo_flagout_2(),
    .rx_serdes_fifo_flagout_3(), .rx_serdes_fifo_flagout_4(), .rx_serdes_fifo_flagout_5(),

    .rx_tsmac_tdm_stats_data(), .rx_tsmac_tdm_stats_id(), .rx_tsmac_tdm_stats_valid(),

    .c0_stat_rx_corrected_lane_delay_0(), .c0_stat_rx_corrected_lane_delay_1(),
    .c0_stat_rx_corrected_lane_delay_2(), .c0_stat_rx_corrected_lane_delay_3(),
    .c0_stat_rx_corrected_lane_delay_valid(),
    .c1_stat_rx_corrected_lane_delay_0(), .c1_stat_rx_corrected_lane_delay_1(),
    .c1_stat_rx_corrected_lane_delay_2(), .c1_stat_rx_corrected_lane_delay_3(),
    .c1_stat_rx_corrected_lane_delay_valid(),
    .c2_stat_rx_corrected_lane_delay_0(), .c2_stat_rx_corrected_lane_delay_1(),
    .c2_stat_rx_corrected_lane_delay_2(), .c2_stat_rx_corrected_lane_delay_3(),
    .c2_stat_rx_corrected_lane_delay_valid(),
    .c3_stat_rx_corrected_lane_delay_0(), .c3_stat_rx_corrected_lane_delay_1(),
    .c3_stat_rx_corrected_lane_delay_2(), .c3_stat_rx_corrected_lane_delay_3(),
    .c3_stat_rx_corrected_lane_delay_valid(),
    .c4_stat_rx_corrected_lane_delay_0(), .c4_stat_rx_corrected_lane_delay_1(),
    .c4_stat_rx_corrected_lane_delay_2(), .c4_stat_rx_corrected_lane_delay_3(),
    .c4_stat_rx_corrected_lane_delay_valid(),
    .c5_stat_rx_corrected_lane_delay_0(), .c5_stat_rx_corrected_lane_delay_1(),
    .c5_stat_rx_corrected_lane_delay_2(), .c5_stat_rx_corrected_lane_delay_3(),
    .c5_stat_rx_corrected_lane_delay_valid(),

    .tx_all_channel_mac_pm_rdy(),
    .tx_axis_taf_0     (tx_axis_taf_0),
    .tx_axis_tready_0  (tx_axis_tready_0),
    .tx_pcs_tdm_stats_data(), .tx_pcs_tdm_stats_start(), .tx_pcs_tdm_stats_valid(),
    .tx_port_pm_rdy(),
    .txdata_out_0 (txdata_out_0),
    .txdata_out_1 (txdata_out_1),
    .tx_serdes_is_am_0(tx_serdes_is_am_0), .tx_serdes_is_am_1(tx_serdes_is_am_1),
    .tx_serdes_is_am_2(tx_serdes_is_am_2), .tx_serdes_is_am_3(tx_serdes_is_am_3),
    .tx_serdes_is_am_4(tx_serdes_is_am_4), .tx_serdes_is_am_5(tx_serdes_is_am_5),
    .tx_serdes_is_am_prefifo_0(tx_serdes_is_am_prefifo_0),
    .tx_serdes_is_am_prefifo_1(tx_serdes_is_am_prefifo_1),
    .tx_serdes_is_am_prefifo_2(tx_serdes_is_am_prefifo_2),
    .tx_serdes_is_am_prefifo_3(tx_serdes_is_am_prefifo_3),
    .tx_serdes_is_am_prefifo_4(tx_serdes_is_am_prefifo_4),
    .tx_serdes_is_am_prefifo_5(tx_serdes_is_am_prefifo_5),
    .tx_tsmac_tdm_stats_data(), .tx_tsmac_tdm_stats_id(), .tx_tsmac_tdm_stats_valid(),

    .c0_ctl_tx_lane0_vlm_bip7_override(1'b0), .c0_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
    .c0_ctl_tx_send_idle_pin(ctl_tx_send_idle),
    .c0_ctl_tx_send_lfi_pin (ctl_tx_send_lfi),
    .c0_ctl_tx_send_rfi_pin (ctl_tx_send_rfi),
    .c1_ctl_tx_lane0_vlm_bip7_override(1'b0), .c1_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
    .c1_ctl_tx_send_idle_pin(1'b0), .c1_ctl_tx_send_lfi_pin(1'b0), .c1_ctl_tx_send_rfi_pin(1'b0),
    .c2_ctl_tx_lane0_vlm_bip7_override(1'b0), .c2_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
    .c2_ctl_tx_send_idle_pin(1'b0), .c2_ctl_tx_send_lfi_pin(1'b0), .c2_ctl_tx_send_rfi_pin(1'b0),
    .c3_ctl_tx_lane0_vlm_bip7_override(1'b0), .c3_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
    .c3_ctl_tx_send_idle_pin(1'b0), .c3_ctl_tx_send_lfi_pin(1'b0), .c3_ctl_tx_send_rfi_pin(1'b0),
    .c4_ctl_tx_lane0_vlm_bip7_override(1'b0), .c4_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
    .c4_ctl_tx_send_idle_pin(1'b0), .c4_ctl_tx_send_lfi_pin(1'b0), .c4_ctl_tx_send_rfi_pin(1'b0),
    .c5_ctl_tx_lane0_vlm_bip7_override(1'b0), .c5_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
    .c5_ctl_tx_send_idle_pin(1'b0), .c5_ctl_tx_send_lfi_pin(1'b0), .c5_ctl_tx_send_rfi_pin(1'b0),

    .ctl_rx_custom_vl_length_minus1(default_vl_length_100GE),
    .ctl_tx_custom_vl_length_minus1(default_vl_length_100GE),
    .ctl_vl_marker_id0(ctl_vl0),   .ctl_vl_marker_id1(ctl_vl1),
    .ctl_vl_marker_id2(ctl_vl2),   .ctl_vl_marker_id3(ctl_vl3),
    .ctl_vl_marker_id4(ctl_vl4),   .ctl_vl_marker_id5(ctl_vl5),
    .ctl_vl_marker_id6(ctl_vl6),   .ctl_vl_marker_id7(ctl_vl7),
    .ctl_vl_marker_id8(ctl_vl8),   .ctl_vl_marker_id9(ctl_vl9),
    .ctl_vl_marker_id10(ctl_vl10), .ctl_vl_marker_id11(ctl_vl11),
    .ctl_vl_marker_id12(ctl_vl12), .ctl_vl_marker_id13(ctl_vl13),
    .ctl_vl_marker_id14(ctl_vl14), .ctl_vl_marker_id15(ctl_vl15),
    .ctl_vl_marker_id16(ctl_vl16), .ctl_vl_marker_id17(ctl_vl17),
    .ctl_vl_marker_id18(ctl_vl18), .ctl_vl_marker_id19(ctl_vl19),
    .ctl_rsvd_in(120'd0),
    .rsvd_in_rx_mac(8'd0),
    .rsvd_in_rx_phy(8'd0),

    .rx_all_channel_mac_pm_tick(1'b0),
    .rx_alt_serdes_clk(rx_alt_serdes_clk),
    .rx_axi_clk(clk_rx_axi),
    .rx_port_pm_tick(pm_tick_core),
    .rx_channel_flush(rx_channel_flush_i),
    .rx_core_clk(rx_core_clk),
    .rx_core_reset(gt_rx_reset_done_core_clk_sync),
    .rx_flexif_clk(rx_flexif_clk),
    .rx_macif_clk(rx_macif_clk),
    .rx_serdes_clk(rx_serdes_clk),
    .rxdata_in_0(rxdata_in_0),
    .rxdata_in_1(rxdata_in_1),
    .rx_serdes_fifo_flagin_0(1'b0), .rx_serdes_fifo_flagin_1(1'b0), .rx_serdes_fifo_flagin_2(1'b0),
    .rx_serdes_fifo_flagin_3(1'b0), .rx_serdes_fifo_flagin_4(1'b0), .rx_serdes_fifo_flagin_5(1'b0),
    .rx_serdes_reset(rx_serdes_reset),
    .ts_clk({6{ts_clk}}),

    .tx_all_channel_mac_pm_tick(1'b0),
    .tx_alt_serdes_clk(tx_alt_serdes_clk),
    .tx_axis_tdata0(tx_axis_tdata0),
    .tx_axis_tdata1(tx_axis_tdata1),
    .tx_axis_tuser_ena0(tx_axis_tuser_ena0),
    .tx_axis_tuser_ena1(tx_axis_tuser_ena1),
    .tx_axis_tuser_eop0(tx_axis_tuser_eop0),
    .tx_axis_tuser_eop1(tx_axis_tuser_eop1),
    .tx_axis_tuser_err0(tx_axis_tuser_err0),
    .tx_axis_tuser_err1(tx_axis_tuser_err1),
    .tx_axis_tuser_mty0(tx_axis_tuser_mty0),
    .tx_axis_tuser_mty1(tx_axis_tuser_mty1),
    .tx_axis_tuser_sop0(tx_axis_tuser_sop0),
    .tx_axis_tuser_sop1(tx_axis_tuser_sop1),
    .tx_axis_tvalid_0(tx_axis_tvalid_0),
    .tx_preamblein_0(56'd0),
    .tx_axi_clk(clk_tx_axi),
    .tx_channel_flush(6'd0),
    .tx_core_clk(tx_core_clk),
    .tx_core_reset(gt_tx_reset_done_core_clk_sync),
    .tx_flexif_clk(tx_flexif_clk),
    .tx_macif_clk(tx_macif_clk),
    .tx_port_pm_tick(pm_tick_core),
    .tx_serdes_clk(tx_serdes_clk),
    .tx_serdes_reset(tx_serdes_reset)
  );

  wire gt0_ch0_txoutclk, gt0_ch0_rxoutclk;
  wire gt0_tx_clr_out_0, gt0_tx_clrb_leaf_out_0;
  wire gt0_rx_clr_out_0, gt0_rx_clrb_leaf_out_0;
  wire [31:0] gt_gpo_unused;

  dcmac_0_gtwiz_versal_0 i_gtwiz (
    .gtwiz_freerun_clk        (init_clk),
    .QUAD0_GTREFCLK0          (QUAD0_GTREFCLK0),

    .QUAD0_s_axi_lite_resetn  (~sys_reset),
    .QUAD0_s_axi_lite_araddr  (18'd0),
    .QUAD0_s_axi_lite_arvalid (1'b0),
    .QUAD0_s_axi_lite_arready (),
    .QUAD0_s_axi_lite_rdata   (),
    .QUAD0_s_axi_lite_rvalid  (),
    .QUAD0_s_axi_lite_rready  (1'b1),
    .QUAD0_s_axi_lite_awaddr  (18'd0),
    .QUAD0_s_axi_lite_awvalid (1'b0),
    .QUAD0_s_axi_lite_awready (),
    .QUAD0_s_axi_lite_wdata   (32'd0),
    .QUAD0_s_axi_lite_wvalid  (1'b0),
    .QUAD0_s_axi_lite_wready  (),
    .QUAD0_s_axi_lite_rresp   (),
    .QUAD0_s_axi_lite_bresp   (),
    .QUAD0_s_axi_lite_bvalid  (),
    .QUAD0_s_axi_lite_bready  (1'b1),

    .QUAD0_rxp                (gt_rxp_in),
    .QUAD0_rxn                (gt_rxn_in),
    .QUAD0_txp                (gt_txp_out),
    .QUAD0_txn                (gt_txn_out),

    .QUAD0_TX0_outclk         (gt0_ch0_txoutclk),
    .QUAD0_RX0_outclk         (gt0_ch0_rxoutclk),
    .QUAD0_TX0_usrclk         (gt0_tx_usrclk2_0),
    .QUAD0_RX0_usrclk         (gt0_rx_usrclk2_0),
    .QUAD0_TX1_usrclk         (gt0_tx_usrclk2_0),
    .QUAD0_RX1_usrclk         (gt0_rx_usrclk2_0),

    .QUAD0_ch0_loopback       (LOOPBACK_MODE),
    .QUAD0_ch1_loopback       (LOOPBACK_MODE),
    .QUAD0_gpi                (32'd0),
    .QUAD0_gpo                (gt_gpo_unused),

    .INTF0_TX0_ch_txdata      (txdata_out_0),
    .INTF0_RX0_ch_rxdata      (rxdata_in_0),
    .INTF0_TX1_ch_txdata      (txdata_out_1),
    .INTF0_RX1_ch_rxdata      (rxdata_in_1),

    .INTF0_TX0_ch_txresetdone (), .INTF0_RX0_ch_rxresetdone (),
    .INTF0_TX1_ch_txresetdone (), .INTF0_RX1_ch_rxresetdone (),

    .INTF0_TX0_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX0_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX0_ch_txprecursor (6'(TX_PRECURSOR)),
    .INTF0_RX0_ch_rxcdrhold    (1'b0),
    .INTF0_TX1_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX1_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX1_ch_txprecursor (6'(TX_PRECURSOR)),
    .INTF0_RX1_ch_rxcdrhold    (1'b0),

    .INTF0_TX0_ch_txrate (8'd0), .INTF0_RX0_ch_rxrate (8'd0),
    .INTF0_TX1_ch_txrate (8'd0), .INTF0_RX1_ch_rxrate (8'd0),

    .INTF0_TX0_ch_txpmaresetdone (), .INTF0_TX0_ch_txprogdivresetdone (),
    .INTF0_RX0_ch_rxpmaresetdone (), .INTF0_RX0_ch_rxprogdivresetdone (),
    .INTF0_TX1_ch_txpmaresetdone (), .INTF0_TX1_ch_txprogdivresetdone (),
    .INTF0_RX1_ch_rxpmaresetdone (), .INTF0_RX1_ch_rxprogdivresetdone (),

    .INTF0_TX_clr_out                 (gt0_tx_clr_out_0),
    .INTF0_TX_clrb_leaf_out           (gt0_tx_clrb_leaf_out_0),
    .INTF0_RX_clr_out                 (gt0_rx_clr_out_0),
    .INTF0_RX_clrb_leaf_out           (gt0_rx_clrb_leaf_out_0),
    .INTF0_rst_all_in                 (sys_reset),
    .INTF0_rst_tx_pll_and_datapath_in (1'b0),
    .INTF0_rst_rx_pll_and_datapath_in (1'b0),
    .INTF0_rst_tx_done_out            (INTF0_rst_tx_done_out),
    .INTF0_rst_rx_done_out            (INTF0_rst_rx_done_out),
    .INTF0_rst_tx_datapath_in         (tx_datapath_reset),
    .INTF0_rst_rx_datapath_in         (rx_dp_reset_stretched),
    .gtpowergood                      (gtpowergood_0)
  );

  MBUFG_GT #(.MODE("PERFORMANCE")) i_mbufg_tx0 (
    .O1(gt0_tx_usrclk_0), .O2(gt0_tx_usrclk2_0), .O3(), .O4(),
    .CE(1'b1), .CEMASK(1'b0),
    .CLR(gt0_tx_clr_out_0), .CLRB_LEAF(gt0_tx_clrb_leaf_out_0), .CLRMASK(1'b0),
    .DIV(3'd0), .I(gt0_ch0_txoutclk)
  );
  MBUFG_GT #(.MODE("PERFORMANCE")) i_mbufg_rx0 (
    .O1(gt0_rx_usrclk_0), .O2(gt0_rx_usrclk2_0), .O3(), .O4(),
    .CE(1'b1), .CEMASK(1'b0),
    .CLR(gt0_rx_clr_out_0), .CLRB_LEAF(gt0_rx_clrb_leaf_out_0), .CLRMASK(1'b0),
    .DIV(3'd0), .I(gt0_ch0_rxoutclk)
  );

  assign tx_serdes_reset = {6{gt_tx_reset_done_inv | core_serdes_reset}};
  assign rx_serdes_reset = {6{gt_rx_reset_done_inv | core_serdes_reset}};

  assign gt_tx_reset_done = {6'd0, gt_tx_reset_done_int[1:0]};
  assign gt_rx_reset_done = {6'd0, gt_rx_reset_done_int[1:0]};

endmodule

`default_nettype wire
