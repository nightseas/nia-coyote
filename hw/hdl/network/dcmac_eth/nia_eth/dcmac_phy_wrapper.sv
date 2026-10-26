// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module dcmac_phy #(

  parameter int         N_CLIENT               = 1,
  parameter int         N_SEG                  = 2,
  parameter int         SEG_W                  = 128,
  parameter int         PORT_MAX               = 6,

  parameter logic [2:0] LOOPBACK_MODE          = 3'b000,

  parameter int         ANCHOR_0               = 0,
  parameter int         ANCHOR_1               = 1,

  parameter int         RX_DP_RESET_MIN_CYCLES = 512,

  parameter int         EN_DPRST_SYNC          = 1,

  parameter int         TX_MAINCURSOR          = dcmac_ctl_pkg::TX_MAIN_DEFAULT,
  parameter int         TX_PRECURSOR           = dcmac_ctl_pkg::TX_PRE_DEFAULT,
  parameter int         TX_POSTCURSOR          = dcmac_ctl_pkg::TX_POST_DEFAULT,

  parameter logic [7:0] POLARITY_TX_Q0         = dcmac_ctl_pkg::QSFP0_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q0         = dcmac_ctl_pkg::QSFP0_RXPOLARITY,
  parameter logic [7:0] POLARITY_TX_Q1         = dcmac_ctl_pkg::QSFP1_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q1         = dcmac_ctl_pkg::QSFP1_RXPOLARITY
)(

  input  wire                              sys_reset,

  input  wire                              gt_ref_clk0_p,
  input  wire                              gt_ref_clk0_n,
  input  wire                              gt_ref_clk1_p,
  input  wire                              gt_ref_clk1_n,

  input  wire [4*N_CLIENT-1:0]             gt_rxp_in,
  input  wire [4*N_CLIENT-1:0]             gt_rxn_in,
  output wire [4*N_CLIENT-1:0]             gt_txn_out,
  output wire [4*N_CLIENT-1:0]             gt_txp_out,

  output wire                              seg_clk,

  output wire [N_CLIENT-1:0]                seg_rstn,
  output wire                               seg_rstn_ctl,
  output wire                              usr_clk,

  output wire [N_CLIENT-1:0]               rx_seg_valid,
  output wire [N_CLIENT*N_SEG*SEG_W-1:0]   rx_seg_dat,
  output wire [N_CLIENT*N_SEG-1:0]         rx_seg_ena,
  output wire [N_CLIENT*N_SEG-1:0]         rx_seg_sop,
  output wire [N_CLIENT*N_SEG-1:0]         rx_seg_eop,
  output wire [N_CLIENT*N_SEG-1:0]         rx_seg_err,
  output wire [N_CLIENT*N_SEG*4-1:0]       rx_seg_mty,

  output wire [N_CLIENT-1:0]               tx_seg_ready,
  input  wire [N_CLIENT-1:0]               tx_seg_valid,
  input  wire [N_CLIENT*N_SEG*SEG_W-1:0]   tx_seg_dat,
  input  wire [N_CLIENT*N_SEG-1:0]         tx_seg_ena,
  input  wire [N_CLIENT*N_SEG-1:0]         tx_seg_sop,
  input  wire [N_CLIENT*N_SEG-1:0]         tx_seg_eop,
  input  wire [N_CLIENT*N_SEG-1:0]         tx_seg_err,
  input  wire [N_CLIENT*N_SEG*4-1:0]       tx_seg_mty,

  input  wire [N_CLIENT-1:0]               ctl_rx_enable,
  input  wire [N_CLIENT-1:0]               ctl_rx_force_resync,
  input  wire [N_CLIENT-1:0]               ctl_tx_enable,
  input  wire [N_CLIENT-1:0]               ctl_tx_send_idle,
  input  wire [N_CLIENT-1:0]               ctl_tx_send_lfi,
  input  wire [N_CLIENT-1:0]               ctl_tx_send_rfi,

  input  wire [N_CLIENT-1:0]               rx_datapath_reset,
  input  wire [N_CLIENT-1:0]               rx_pll_datapath_reset,
  input  wire [N_CLIENT-1:0]               gt_all_reset,
  input  wire [N_CLIENT-1:0]               rx_serdes_reset_req,
  input  wire [N_CLIENT-1:0]               rx_flush_req,
  input  wire [N_CLIENT*PORT_MAX-1:0]      rx_datapath_reset_ports,
  input  wire [N_CLIENT-1:0]               tx_datapath_reset,

  input  wire                              axil_aclk,
  input  wire                              axil_aresetn,
  input  wire [19:0]                       s_axil_awaddr,
  input  wire                              s_axil_awvalid,
  output wire                              s_axil_awready,
  input  wire [31:0]                       s_axil_wdata,
  input  wire [3:0]                        s_axil_wstrb,
  input  wire                              s_axil_wvalid,
  output wire                              s_axil_wready,
  output wire [1:0]                        s_axil_bresp,
  output wire                              s_axil_bvalid,
  input  wire                              s_axil_bready,
  input  wire [19:0]                       s_axil_araddr,
  input  wire                              s_axil_arvalid,
  output wire                              s_axil_arready,
  output wire [31:0]                       s_axil_rdata,
  output wire [1:0]                        s_axil_rresp,
  output wire                              s_axil_rvalid,
  input  wire                              s_axil_rready,

  output wire [8*N_CLIENT-1:0]             gt_tx_reset_done,
  output wire [8*N_CLIENT-1:0]             gt_rx_reset_done,

  input  wire                              core_serdes_reset
);

  // synthesis translate_off
  initial begin
    if (!dcmac_ctl_pkg::cursor_legal(TX_MAINCURSOR, TX_PRECURSOR, TX_POSTCURSOR))
      $fatal(1, "dcmac_phy: cursor set main=%0d pre=%0d post=%0d is not AM017-legal",
             TX_MAINCURSOR, TX_PRECURSOR, TX_POSTCURSOR);
    if (N_CLIENT != 1 && N_CLIENT != 2)
      $fatal(1, "dcmac_phy: N_CLIENT=%0d unsupported - this file maps dcmac_0 for 1 or 2 clients only", N_CLIENT);
    if (N_SEG != 2 && N_SEG != 4)
      $fatal(1, "dcmac_phy: N_SEG=%0d - the 100GAUI-1 client is 2 segments and the 200GAUI-2 client is 4", N_SEG);
    if (N_CLIENT > 1 && ANCHOR_0 == ANCHOR_1)
      $fatal(1, "dcmac_phy: violated - both clients anchored at MAC slot %0d", ANCHOR_0);
    if (POLARITY_TX_Q0[1:0] != 2'b00 || POLARITY_RX_Q0[1:0] != 2'b00)
      $fatal(1, "dcmac_phy: violated - QSFP0/bank202 CH0 requires TX_INV=0 RX_INV=0 but POLARITY_TX_Q0=%b POLARITY_RX_Q0=%b",
             POLARITY_TX_Q0, POLARITY_RX_Q0);
    if (N_CLIENT > 1 && (POLARITY_TX_Q1[1:0] != 2'b11 || POLARITY_RX_Q1[1:0] != 2'b11))
      $fatal(1, "dcmac_phy: violated - QSFP1/bank204 CH0 requires TX_INV=1 RX_INV=1 (inversion REQUIRED) but POLARITY_TX_Q1=%b POLARITY_RX_Q1=%b. Building at 0 gives a link that never aligns and looks exactly like silicon.",
             POLARITY_TX_Q1, POLARITY_RX_Q1);
  end
  // synthesis translate_on

  wire QUAD0_GTREFCLK0;
  wire QUAD1_GTREFCLK0;
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
    .I     (gt_ref_clk0_p),
    .IB    (gt_ref_clk0_n),
    .CEB   (1'b0),
    .ODIV2 (bufds_odiv2_0),
    .O     (QUAD0_GTREFCLK0)
  );

  generate
  if (N_CLIENT > 1) begin : g_refclk1

    IBUFDS_GTME5 #(
      .REFCLK_EN_TX_PATH  (1'b0),
      .REFCLK_HROW_CK_SEL (0),
      .REFCLK_ICNTL_RX    (0)
    ) dcmac_IBUFDS_GTE5_REFCLK1_gt1 (

      .I     (gt_ref_clk1_p),
      .IB    (gt_ref_clk1_n),
      .CEB   (1'b0),
      .ODIV2 (),
      .O     (QUAD1_GTREFCLK0)
    );
  end else begin : g_no_refclk1
    assign QUAD1_GTREFCLK0 = 1'b0;
    wire _unused_rc1 = |{gt_ref_clk1_p, gt_ref_clk1_n};
  end
  endgenerate

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
  wire freerun_clk_i;
  wire usr_clk_locked;
  dcmac_usr_clk_wiz i_usr_clk_wiz (
    .reset    (sys_reset),
    .clk_in1  (clk_wiz_in),
    .locked   (usr_clk_locked),
    .clk_out1 (usr_clk_i),
    .clk_out2 (freerun_clk_i)
  );
  assign usr_clk = usr_clk_i;

  wire [5:0] rx_serdes_clk;
  wire [5:0] tx_serdes_clk;
  wire [5:0] rx_alt_serdes_clk;
  wire [5:0] tx_alt_serdes_clk;

  wire [N_CLIENT-1:0] gt_tx_usrclk,  gt_tx_usrclk2;
  wire [N_CLIENT-1:0] gt_rx_usrclk,  gt_rx_usrclk2;
  wire [N_CLIENT-1:0] gtpowergood_q;
  wire [N_CLIENT-1:0] rst_tx_done_q;
  wire [N_CLIENT-1:0] rst_rx_done_q;

  genvar q;
  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_done
    assign gt_tx_reset_done[8*q +: 8] = {6'd0, {2{rst_tx_done_q[q]}}};
    assign gt_rx_reset_done[8*q +: 8] = {6'd0, {2{rst_rx_done_q[q]}}};
  end
  endgenerate

  wire gt_rx_all_done = &rst_rx_done_q;
  wire gt_tx_all_done = &rst_tx_done_q;

  wire gt_rx_notdone_core_sync;
  wire gt_tx_notdone_core_sync;
  wire sys_reset_core_sync;

  rst_sync #(.STAGES(3)) i_sync_rx_core (
    .clk(core_clk), .arst_n(~gt_rx_all_done),
    .rst_n(gt_rx_notdone_core_sync));
  rst_sync #(.STAGES(3)) i_sync_tx_core (
    .clk(core_clk), .arst_n(~gt_tx_all_done),
    .rst_n(gt_tx_notdone_core_sync));
  rst_sync #(.STAGES(3)) i_sync_sysrst_core (
    .clk(core_clk), .arst_n(sys_reset),
    .rst_n(sys_reset_core_sync));

  logic core_rst_rx_hold_r = 1'b1;
  logic core_rst_tx_hold_r = 1'b1;
  always_ff @(posedge core_clk) begin
    if (sys_reset_core_sync) begin
      core_rst_rx_hold_r <= 1'b1;
      core_rst_tx_hold_r <= 1'b1;
    end else begin
      if (clk_wiz_locked && !gt_rx_notdone_core_sync) core_rst_rx_hold_r <= 1'b0;
      if (clk_wiz_locked && !gt_tx_notdone_core_sync) core_rst_tx_hold_r <= 1'b0;
    end
  end

  wire rx_core_reset_pin = core_rst_rx_hold_r;
  wire tx_core_reset_pin = core_rst_tx_hold_r;

  wire rx_core_clk = core_clk;
  wire tx_core_clk = core_clk;
  wire clk_rx_axi  = axis_clk;
  wire clk_tx_axi  = axis_clk;

  wire seg_rstn_locked;
  rst_sync #(.STAGES(4)) i_sync_seg_axis (
    .clk(axis_clk), .arst_n(clk_wiz_locked),
    .rst_n(seg_rstn_locked));

  assign seg_rstn_ctl = seg_rstn_locked;

  genvar qs;
  generate
  for (qs = 0; qs < N_CLIENT; qs++) begin : g_seg_rstn
    wire done_both = rst_rx_done_q[qs] & rst_tx_done_q[qs];
    (* ASYNC_REG = "TRUE" *) reg [2:0] done_sr = 3'b000;
    always_ff @(posedge axis_clk) done_sr <= {done_sr[1:0], done_both};
    assign seg_rstn[qs] = seg_rstn_locked & done_sr[2];
  end
  endgenerate

  wire [N_CLIENT-1:0]          rx_dp_reset_s;
  wire [N_CLIENT-1:0]          tx_dp_reset_s;
  wire [N_CLIENT*PORT_MAX-1:0] rx_dp_ports_s;

  generate
  if (EN_DPRST_SYNC != 0) begin : g_dprst_sync

    dcmac_sync2 #(.WIDTH(N_CLIENT), .STAGES(2), .INIT('0)) u_sync_rx_dp (
      .clk (axis_clk), .din (rx_datapath_reset), .dout (rx_dp_reset_s));

    dcmac_sync2 #(.WIDTH(N_CLIENT), .STAGES(2), .INIT('0)) u_sync_tx_dp (
      .clk (axis_clk), .din (tx_datapath_reset), .dout (tx_dp_reset_s));

    dcmac_sync2 #(.WIDTH(N_CLIENT*PORT_MAX), .STAGES(2), .INIT('0)) u_sync_rx_ports (
      .clk (axis_clk), .din (rx_datapath_reset_ports), .dout (rx_dp_ports_s));
  end else begin : g_dprst_raw

    assign rx_dp_reset_s = rx_datapath_reset;
    assign tx_dp_reset_s = tx_datapath_reset;
    assign rx_dp_ports_s = rx_datapath_reset_ports;
  end
  endgenerate

  localparam int SW = (RX_DP_RESET_MIN_CYCLES > 1) ? $clog2(RX_DP_RESET_MIN_CYCLES + 1) : 1;
  wire [N_CLIENT-1:0] rx_dp_reset_stretched;

  genvar c;
  generate
  for (c = 0; c < N_CLIENT; c++) begin : g_stretch
    reg [SW-1:0] rx_dp_cnt   = '0;
    reg          rx_dp_str_r = 1'b0;
    always_ff @(posedge axis_clk) begin
      if (!seg_rstn_locked) begin
        rx_dp_cnt   <= '0;
        rx_dp_str_r <= 1'b0;
      end else if (rx_dp_reset_s[c]) begin
        rx_dp_cnt   <= RX_DP_RESET_MIN_CYCLES[SW-1:0];
        rx_dp_str_r <= 1'b1;
      end else if (rx_dp_cnt != '0) begin
        rx_dp_cnt   <= rx_dp_cnt - 1'b1;
        rx_dp_str_r <= 1'b1;
      end else begin
        rx_dp_str_r <= 1'b0;
      end
    end
    assign rx_dp_reset_stretched[c] = rx_dp_str_r;
  end
  endgenerate

  wire [N_CLIENT-1:0] gt_all_reset_stretched;
  genvar ca;
  generate
  for (ca = 0; ca < N_CLIENT; ca++) begin : g_stretch_all
    reg [SW-1:0] all_cnt   = '0;
    reg          all_str_r = 1'b0;
    always_ff @(posedge axis_clk) begin
      if (!seg_rstn_locked) begin
        all_cnt   <= '0;
        all_str_r <= 1'b0;
      end else if (gt_all_reset[ca]) begin
        all_cnt   <= RX_DP_RESET_MIN_CYCLES[SW-1:0];
        all_str_r <= 1'b1;
      end else if (all_cnt != '0) begin
        all_cnt   <= all_cnt - 1'b1;
        all_str_r <= 1'b1;
      end else begin
        all_str_r <= 1'b0;
      end
    end
    assign gt_all_reset_stretched[ca] = all_str_r;
  end
  endgenerate

  wire [N_CLIENT-1:0] rx_pll_dp_reset_stretched;
  genvar cp;
  generate
  for (cp = 0; cp < N_CLIENT; cp++) begin : g_stretch_pll
    reg [SW-1:0] pll_cnt   = '0;
    reg          pll_str_r = 1'b0;
    always_ff @(posedge axis_clk) begin
      if (!seg_rstn_locked) begin
        pll_cnt   <= '0;
        pll_str_r <= 1'b0;
      end else if (rx_pll_datapath_reset[cp]) begin
        pll_cnt   <= RX_DP_RESET_MIN_CYCLES[SW-1:0];
        pll_str_r <= 1'b1;
      end else if (pll_cnt != '0) begin
        pll_cnt   <= pll_cnt - 1'b1;
        pll_str_r <= 1'b1;
      end else begin
        pll_str_r <= 1'b0;
      end
    end
    assign rx_pll_dp_reset_stretched[cp] = pll_str_r;
  end
  endgenerate

  logic [5:0] rx_channel_flush_i;
  always_comb begin
    rx_channel_flush_i = 6'b0;
    for (int cc = 0; cc < N_CLIENT; cc++)
      for (int p = 0; p < PORT_MAX && p < 6; p++)
        if (rx_dp_ports_s[cc*PORT_MAX + p]) rx_channel_flush_i[p] = 1'b1;
    if (rx_flush_req[0]) rx_channel_flush_i[ANCHOR_0] = 1'b1;
    if (N_CLIENT > 1) begin
      if (rx_flush_req[(N_CLIENT > 1) ? 1 : 0]) rx_channel_flush_i[ANCHOR_1] = 1'b1;
    end
  end

  wire _unused_ctl = |{ctl_rx_enable, ctl_rx_force_resync, ctl_tx_enable,
                       usr_clk_locked, gtpowergood_q, tx_dp_reset_s};

  wire [127:0] rx_axis_tdata   [0:N_SEG*N_CLIENT-1];
  wire         rx_axis_ena     [0:N_SEG*N_CLIENT-1];
  wire         rx_axis_sop     [0:N_SEG*N_CLIENT-1];
  wire         rx_axis_eop     [0:N_SEG*N_CLIENT-1];
  wire         rx_axis_err     [0:N_SEG*N_CLIENT-1];
  wire [3:0]   rx_axis_mty     [0:N_SEG*N_CLIENT-1];
  wire [N_CLIENT-1:0] rx_axis_tvalid;
  wire [N_CLIENT-1:0] tx_axis_tready;
  wire [N_CLIENT-1:0] tx_axis_taf;

  genvar sg;
  generate
  for (c = 0; c < N_CLIENT; c++) begin : g_segmap
    assign rx_seg_valid[c] = rx_axis_tvalid[c];
    assign tx_seg_ready[c] = tx_axis_tready[c];
    for (sg = 0; sg < N_SEG; sg++) begin : g_segslot
      localparam int SLOT = c*N_SEG + sg;
      assign rx_seg_dat[SLOT*SEG_W +: SEG_W] = rx_axis_tdata[SLOT];
      assign rx_seg_ena[SLOT]                = rx_axis_ena[SLOT];
      assign rx_seg_sop[SLOT]                = rx_axis_sop[SLOT];
      assign rx_seg_eop[SLOT]                = rx_axis_eop[SLOT];
      assign rx_seg_err[SLOT]                = rx_axis_err[SLOT];
      assign rx_seg_mty[SLOT*4 +: 4]         = rx_axis_mty[SLOT];
    end
  end
  endgenerate

  wire [127:0] txd [0:N_SEG*N_CLIENT-1];
  wire         txena[0:N_SEG*N_CLIENT-1], txsop[0:N_SEG*N_CLIENT-1];
  wire         txeop[0:N_SEG*N_CLIENT-1], txerr[0:N_SEG*N_CLIENT-1];
  wire [3:0]   txmty[0:N_SEG*N_CLIENT-1];
  generate
  for (c = 0; c < N_SEG*N_CLIENT; c++) begin : g_txview
    assign txd[c]   = tx_seg_dat[c*SEG_W +: SEG_W];
    assign txena[c] = tx_seg_ena[c];
    assign txsop[c] = tx_seg_sop[c];
    assign txeop[c] = tx_seg_eop[c];
    assign txerr[c] = tx_seg_err[c];
    assign txmty[c] = tx_seg_mty[c*4 +: 4];
  end
  endgenerate

  wire rx_all_channel_mac_pm_rdy;

  wire _unused_pm_rdy = rx_all_channel_mac_pm_rdy;

  wire [255:0] txdata_out [0:N_SEG*N_CLIENT-1];
  wire [255:0] rxdata_in  [0:N_SEG*N_CLIENT-1];

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

  wire [5:0] slot_send_idle, slot_send_lfi, slot_send_rfi;
  generate
  for (c = 0; c < 6; c++) begin : g_slotctl
    localparam int OWNER = (c == ANCHOR_0) ? 0 : ((N_CLIENT > 1 && c == ANCHOR_1) ? 1 : -1);
    if (OWNER >= 0) begin : g_owned
      assign slot_send_idle[c] = ctl_tx_send_idle[OWNER];
      assign slot_send_lfi[c]  = ctl_tx_send_lfi[OWNER];
      assign slot_send_rfi[c]  = ctl_tx_send_rfi[OWNER];
    end else begin : g_unowned
      assign slot_send_idle[c] = 1'b0;
      assign slot_send_lfi[c]  = 1'b0;
      assign slot_send_rfi[c]  = 1'b0;
    end
  end
  endgenerate

  localparam int LANES_PER_CLIENT = (N_CLIENT > 1 && ANCHOR_1 > ANCHOR_0)
                                  ? (ANCHOR_1 - ANCHOR_0) : 2;

  function automatic int client_of_lane(input int lane);
    int k;
    k = lane / LANES_PER_CLIENT;
    return (k >= N_CLIENT) ? (N_CLIENT - 1) : k;
  endfunction

  generate
  for (c = 0; c < 6; c++) begin : g_serdesclk
    if (c < 2*N_CLIENT) begin : g_live
      localparam int CL = client_of_lane(c);
      assign rx_alt_serdes_clk[c] = gt_rx_usrclk2[CL];
      assign tx_alt_serdes_clk[c] = gt_tx_usrclk2[CL];
      assign rx_serdes_clk[c]     = gt_rx_usrclk[CL];
      assign tx_serdes_clk[c]     = gt_tx_usrclk[CL];
    end else begin : g_tied
      assign rx_alt_serdes_clk[c] = 1'b0;
      assign tx_alt_serdes_clk[c] = 1'b0;
      assign rx_serdes_clk[c]     = 1'b0;
      assign tx_serdes_clk[c]     = 1'b0;
    end
  end
  endgenerate

  generate
  if (N_CLIENT == 1) begin : g_dcmac_1c

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
      .rx_axis_tdata0     (rx_axis_tdata[0]),
      .rx_axis_tdata1     (rx_axis_tdata[1]),
      .rx_axis_tuser_ena0 (rx_axis_ena[0]),
      .rx_axis_tuser_ena1 (rx_axis_ena[1]),
      .rx_axis_tuser_eop0 (rx_axis_eop[0]),
      .rx_axis_tuser_eop1 (rx_axis_eop[1]),
      .rx_axis_tuser_err0 (rx_axis_err[0]),
      .rx_axis_tuser_err1 (rx_axis_err[1]),
      .rx_axis_tuser_mty0 (rx_axis_mty[0]),
      .rx_axis_tuser_mty1 (rx_axis_mty[1]),
      .rx_axis_tuser_sop0 (rx_axis_sop[0]),
      .rx_axis_tuser_sop1 (rx_axis_sop[1]),
      .rx_axis_tvalid_0   (rx_axis_tvalid[0]),
`ifdef DCMAC_ETH_200G
      .rx_axis_tdata2     (rx_axis_tdata[2]),
      .rx_axis_tdata3     (rx_axis_tdata[3]),
      .rx_axis_tuser_ena2 (rx_axis_ena[2]),
      .rx_axis_tuser_ena3 (rx_axis_ena[3]),
      .rx_axis_tuser_eop2 (rx_axis_eop[2]),
      .rx_axis_tuser_eop3 (rx_axis_eop[3]),
      .rx_axis_tuser_err2 (rx_axis_err[2]),
      .rx_axis_tuser_err3 (rx_axis_err[3]),
      .rx_axis_tuser_mty2 (rx_axis_mty[2]),
      .rx_axis_tuser_mty3 (rx_axis_mty[3]),
      .rx_axis_tuser_sop2 (rx_axis_sop[2]),
      .rx_axis_tuser_sop3 (rx_axis_sop[3]),
`endif

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
      .tx_axis_taf_0     (tx_axis_taf[0]),
      .tx_axis_tready_0  (tx_axis_tready[0]),
      .tx_pcs_tdm_stats_data(), .tx_pcs_tdm_stats_start(), .tx_pcs_tdm_stats_valid(),
      .tx_port_pm_rdy(),
      .txdata_out_0 (txdata_out[0]),
      .txdata_out_1 (txdata_out[1]),
`ifdef DCMAC_ETH_200G
      .txdata_out_2 (txdata_out[2]),
      .txdata_out_3 (txdata_out[3]),
`endif
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
      .c0_ctl_tx_send_idle_pin(slot_send_idle[0]),
      .c0_ctl_tx_send_lfi_pin (slot_send_lfi[0]),
      .c0_ctl_tx_send_rfi_pin (slot_send_rfi[0]),
      .c1_ctl_tx_lane0_vlm_bip7_override(1'b0), .c1_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c1_ctl_tx_send_idle_pin(slot_send_idle[1]), .c1_ctl_tx_send_lfi_pin(slot_send_lfi[1]), .c1_ctl_tx_send_rfi_pin(slot_send_rfi[1]),
      .c2_ctl_tx_lane0_vlm_bip7_override(1'b0), .c2_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c2_ctl_tx_send_idle_pin(slot_send_idle[2]), .c2_ctl_tx_send_lfi_pin(slot_send_lfi[2]), .c2_ctl_tx_send_rfi_pin(slot_send_rfi[2]),
      .c3_ctl_tx_lane0_vlm_bip7_override(1'b0), .c3_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c3_ctl_tx_send_idle_pin(slot_send_idle[3]), .c3_ctl_tx_send_lfi_pin(slot_send_lfi[3]), .c3_ctl_tx_send_rfi_pin(slot_send_rfi[3]),
      .c4_ctl_tx_lane0_vlm_bip7_override(1'b0), .c4_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c4_ctl_tx_send_idle_pin(slot_send_idle[4]), .c4_ctl_tx_send_lfi_pin(slot_send_lfi[4]), .c4_ctl_tx_send_rfi_pin(slot_send_rfi[4]),
      .c5_ctl_tx_lane0_vlm_bip7_override(1'b0), .c5_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c5_ctl_tx_send_idle_pin(slot_send_idle[5]), .c5_ctl_tx_send_lfi_pin(slot_send_lfi[5]), .c5_ctl_tx_send_rfi_pin(slot_send_rfi[5]),

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
      .rx_core_reset(rx_core_reset_pin),
      .rx_flexif_clk(rx_flexif_clk),
      .rx_macif_clk(rx_macif_clk),
      .rx_serdes_clk(rx_serdes_clk),
      .rxdata_in_0(rxdata_in[0]),
      .rxdata_in_1(rxdata_in[1]),
`ifdef DCMAC_ETH_200G
      .rxdata_in_2(rxdata_in[2]),
      .rxdata_in_3(rxdata_in[3]),
`endif
      .rx_serdes_fifo_flagin_0(1'b0), .rx_serdes_fifo_flagin_1(1'b0), .rx_serdes_fifo_flagin_2(1'b0),
      .rx_serdes_fifo_flagin_3(1'b0), .rx_serdes_fifo_flagin_4(1'b0), .rx_serdes_fifo_flagin_5(1'b0),
      .rx_serdes_reset(rx_serdes_reset),
      .ts_clk({6{ts_clk}}),

      .tx_all_channel_mac_pm_tick(1'b0),
      .tx_alt_serdes_clk(tx_alt_serdes_clk),
      .tx_axis_tdata0(txd[0]),
      .tx_axis_tdata1(txd[1]),
      .tx_axis_tuser_ena0(txena[0]),
      .tx_axis_tuser_ena1(txena[1]),
      .tx_axis_tuser_eop0(txeop[0]),
      .tx_axis_tuser_eop1(txeop[1]),
      .tx_axis_tuser_err0(txerr[0]),
      .tx_axis_tuser_err1(txerr[1]),
      .tx_axis_tuser_mty0(txmty[0]),
      .tx_axis_tuser_mty1(txmty[1]),
      .tx_axis_tuser_sop0(txsop[0]),
      .tx_axis_tuser_sop1(txsop[1]),
`ifdef DCMAC_ETH_200G
      .tx_axis_tdata2(txd[2]),
      .tx_axis_tdata3(txd[3]),
      .tx_axis_tuser_ena2(txena[2]),
      .tx_axis_tuser_ena3(txena[3]),
      .tx_axis_tuser_eop2(txeop[2]),
      .tx_axis_tuser_eop3(txeop[3]),
      .tx_axis_tuser_err2(txerr[2]),
      .tx_axis_tuser_err3(txerr[3]),
      .tx_axis_tuser_mty2(txmty[2]),
      .tx_axis_tuser_mty3(txmty[3]),
      .tx_axis_tuser_sop2(txsop[2]),
      .tx_axis_tuser_sop3(txsop[3]),
`endif
      .tx_axis_tvalid_0(tx_seg_valid[0]),
      .tx_preamblein_0(56'd0),
      .tx_axi_clk(clk_tx_axi),
      .tx_channel_flush(6'd0),
      .tx_core_clk(tx_core_clk),
      .tx_core_reset(tx_core_reset_pin),
      .tx_flexif_clk(tx_flexif_clk),
      .tx_macif_clk(tx_macif_clk),
      .tx_port_pm_tick(pm_tick_core),
      .tx_serdes_clk(tx_serdes_clk),
      .tx_serdes_reset(tx_serdes_reset)
    );
  end else begin : g_dcmac_2c

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

      .rx_axis_tdata0     (rx_axis_tdata[0]),
      .rx_axis_tdata1     (rx_axis_tdata[1]),
      .rx_axis_tuser_ena0 (rx_axis_ena[0]),
      .rx_axis_tuser_ena1 (rx_axis_ena[1]),
      .rx_axis_tuser_eop0 (rx_axis_eop[0]),
      .rx_axis_tuser_eop1 (rx_axis_eop[1]),
      .rx_axis_tuser_err0 (rx_axis_err[0]),
      .rx_axis_tuser_err1 (rx_axis_err[1]),
      .rx_axis_tuser_mty0 (rx_axis_mty[0]),
      .rx_axis_tuser_mty1 (rx_axis_mty[1]),
      .rx_axis_tuser_sop0 (rx_axis_sop[0]),
      .rx_axis_tuser_sop1 (rx_axis_sop[1]),
      .rx_axis_tvalid_0   (rx_axis_tvalid[0]),
      .rx_preambleout_0(),

      .rx_axis_tdata2     (rx_axis_tdata[2]),
      .rx_axis_tdata3     (rx_axis_tdata[3]),
      .rx_axis_tuser_ena2 (rx_axis_ena[2]),
      .rx_axis_tuser_ena3 (rx_axis_ena[3]),
      .rx_axis_tuser_eop2 (rx_axis_eop[2]),
      .rx_axis_tuser_eop3 (rx_axis_eop[3]),
      .rx_axis_tuser_err2 (rx_axis_err[2]),
      .rx_axis_tuser_err3 (rx_axis_err[3]),
      .rx_axis_tuser_mty2 (rx_axis_mty[2]),
      .rx_axis_tuser_mty3 (rx_axis_mty[3]),
      .rx_axis_tuser_sop2 (rx_axis_sop[2]),
      .rx_axis_tuser_sop3 (rx_axis_sop[3]),
      .rx_axis_tvalid_1   (rx_axis_tvalid[1]),
      .rx_preambleout_1(),

      .rx_lane_aligner_fill(), .rx_lane_aligner_fill_start(), .rx_lane_aligner_fill_valid(),
      .rx_pcs_tdm_stats_data(), .rx_pcs_tdm_stats_start(), .rx_pcs_tdm_stats_valid(),
      .rx_port_pm_rdy(),

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
      .tx_axis_taf_0     (tx_axis_taf[0]),
      .tx_axis_tready_0  (tx_axis_tready[0]),
      .tx_axis_taf_1     (tx_axis_taf[1]),
      .tx_axis_tready_1  (tx_axis_tready[1]),
      .tx_pcs_tdm_stats_data(), .tx_pcs_tdm_stats_start(), .tx_pcs_tdm_stats_valid(),
      .tx_port_pm_rdy(),
      .txdata_out_0 (txdata_out[0]),
      .txdata_out_1 (txdata_out[1]),
      .txdata_out_2 (txdata_out[2]),
      .txdata_out_3 (txdata_out[3]),
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
      .c0_ctl_tx_send_idle_pin(slot_send_idle[0]), .c0_ctl_tx_send_lfi_pin(slot_send_lfi[0]), .c0_ctl_tx_send_rfi_pin(slot_send_rfi[0]),
      .c1_ctl_tx_lane0_vlm_bip7_override(1'b0), .c1_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c1_ctl_tx_send_idle_pin(slot_send_idle[1]), .c1_ctl_tx_send_lfi_pin(slot_send_lfi[1]), .c1_ctl_tx_send_rfi_pin(slot_send_rfi[1]),
      .c2_ctl_tx_lane0_vlm_bip7_override(1'b0), .c2_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c2_ctl_tx_send_idle_pin(slot_send_idle[2]), .c2_ctl_tx_send_lfi_pin(slot_send_lfi[2]), .c2_ctl_tx_send_rfi_pin(slot_send_rfi[2]),
      .c3_ctl_tx_lane0_vlm_bip7_override(1'b0), .c3_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c3_ctl_tx_send_idle_pin(slot_send_idle[3]), .c3_ctl_tx_send_lfi_pin(slot_send_lfi[3]), .c3_ctl_tx_send_rfi_pin(slot_send_rfi[3]),
      .c4_ctl_tx_lane0_vlm_bip7_override(1'b0), .c4_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c4_ctl_tx_send_idle_pin(slot_send_idle[4]), .c4_ctl_tx_send_lfi_pin(slot_send_lfi[4]), .c4_ctl_tx_send_rfi_pin(slot_send_rfi[4]),
      .c5_ctl_tx_lane0_vlm_bip7_override(1'b0), .c5_ctl_tx_lane0_vlm_bip7_override_value(8'd0),
      .c5_ctl_tx_send_idle_pin(slot_send_idle[5]), .c5_ctl_tx_send_lfi_pin(slot_send_lfi[5]), .c5_ctl_tx_send_rfi_pin(slot_send_rfi[5]),

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
      .rx_core_reset(rx_core_reset_pin),
      .rx_flexif_clk(rx_flexif_clk),
      .rx_macif_clk(rx_macif_clk),
      .rx_serdes_clk(rx_serdes_clk),
      .rxdata_in_0(rxdata_in[0]),
      .rxdata_in_1(rxdata_in[1]),
      .rxdata_in_2(rxdata_in[2]),
      .rxdata_in_3(rxdata_in[3]),
      .rx_serdes_fifo_flagin_0(1'b0), .rx_serdes_fifo_flagin_1(1'b0), .rx_serdes_fifo_flagin_2(1'b0),
      .rx_serdes_fifo_flagin_3(1'b0), .rx_serdes_fifo_flagin_4(1'b0), .rx_serdes_fifo_flagin_5(1'b0),
      .rx_serdes_reset(rx_serdes_reset),
      .ts_clk({6{ts_clk}}),

      .tx_all_channel_mac_pm_tick(1'b0),
      .tx_alt_serdes_clk(tx_alt_serdes_clk),

      .tx_axis_tdata0(txd[0]),        .tx_axis_tdata1(txd[1]),
      .tx_axis_tuser_ena0(txena[0]),  .tx_axis_tuser_ena1(txena[1]),
      .tx_axis_tuser_eop0(txeop[0]),  .tx_axis_tuser_eop1(txeop[1]),
      .tx_axis_tuser_err0(txerr[0]),  .tx_axis_tuser_err1(txerr[1]),
      .tx_axis_tuser_mty0(txmty[0]),  .tx_axis_tuser_mty1(txmty[1]),
      .tx_axis_tuser_sop0(txsop[0]),  .tx_axis_tuser_sop1(txsop[1]),
      .tx_axis_tvalid_0(tx_seg_valid[0]),
      .tx_preamblein_0(56'd0),

      .tx_axis_tdata2(txd[2]),        .tx_axis_tdata3(txd[3]),
      .tx_axis_tuser_ena2(txena[2]),  .tx_axis_tuser_ena3(txena[3]),
      .tx_axis_tuser_eop2(txeop[2]),  .tx_axis_tuser_eop3(txeop[3]),
      .tx_axis_tuser_err2(txerr[2]),  .tx_axis_tuser_err3(txerr[3]),
      .tx_axis_tuser_mty2(txmty[2]),  .tx_axis_tuser_mty3(txmty[3]),
      .tx_axis_tuser_sop2(txsop[2]),  .tx_axis_tuser_sop3(txsop[3]),
      .tx_axis_tvalid_1(tx_seg_valid[1]),
      .tx_preamblein_1(56'd0),

      .tx_axi_clk(clk_tx_axi),
      .tx_channel_flush(6'd0),
      .tx_core_clk(tx_core_clk),
      .tx_core_reset(tx_core_reset_pin),
      .tx_flexif_clk(tx_flexif_clk),
      .tx_macif_clk(tx_macif_clk),
      .tx_port_pm_tick(pm_tick_core),
      .tx_serdes_clk(tx_serdes_clk),
      .tx_serdes_reset(tx_serdes_reset)
    );
  end
  endgenerate

  wire [N_CLIENT-1:0] gt_ch0_txoutclk, gt_ch0_rxoutclk;
  wire [N_CLIENT-1:0] gt_tx_clr_out, gt_tx_clrb_leaf_out;
  wire [N_CLIENT-1:0] gt_rx_clr_out, gt_rx_clrb_leaf_out;

  dcmac_0_gtwiz_versal_0 i_gtwiz0 (
    .gtwiz_freerun_clk        (freerun_clk_i),
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

    .QUAD0_rxp                (gt_rxp_in[3:0]),
    .QUAD0_rxn                (gt_rxn_in[3:0]),
    .QUAD0_txp                (gt_txp_out[3:0]),
    .QUAD0_txn                (gt_txn_out[3:0]),

    .QUAD0_TX0_outclk         (gt_ch0_txoutclk[0]),
    .QUAD0_RX0_outclk         (gt_ch0_rxoutclk[0]),
    .QUAD0_TX0_usrclk         (gt_tx_usrclk2[0]),
    .QUAD0_RX0_usrclk         (gt_rx_usrclk2[0]),
    .QUAD0_TX1_usrclk         (gt_tx_usrclk2[0]),
    .QUAD0_RX1_usrclk         (gt_rx_usrclk2[0]),

    .QUAD0_ch0_loopback       (LOOPBACK_MODE),
    .QUAD0_ch1_loopback       (LOOPBACK_MODE),
    .QUAD0_gpi                (32'd0),
    .QUAD0_gpo                (),

    .INTF0_TX0_ch_txdata      (txdata_out[0]),
    .INTF0_RX0_ch_rxdata      (rxdata_in[0]),
    .INTF0_TX1_ch_txdata      (txdata_out[1]),
    .INTF0_RX1_ch_rxdata      (rxdata_in[1]),

    .INTF0_TX0_ch_txresetdone (), .INTF0_RX0_ch_rxresetdone (),
    .INTF0_TX1_ch_txresetdone (), .INTF0_RX1_ch_rxresetdone (),

    .INTF0_TX0_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX0_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX0_ch_txprecursor (6'(TX_PRECURSOR)),
    .INTF0_RX0_ch_rxcdrhold    (1'b0),
    .INTF0_TX1_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX1_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX1_ch_txprecursor (6'(TX_PRECURSOR)),
    .INTF0_RX1_ch_rxcdrhold    (1'b0),

    .INTF0_TX0_ch_txpolarity   (POLARITY_TX_Q0[0]),
    .INTF0_TX1_ch_txpolarity   (POLARITY_TX_Q0[1]),
    .INTF0_RX0_ch_rxpolarity   (POLARITY_RX_Q0[0]),
    .INTF0_RX1_ch_rxpolarity   (POLARITY_RX_Q0[1]),

    .INTF0_TX0_ch_txrate (8'd0), .INTF0_RX0_ch_rxrate (8'd0),
    .INTF0_TX1_ch_txrate (8'd0), .INTF0_RX1_ch_rxrate (8'd0),

    .INTF0_TX0_ch_txpmaresetdone (), .INTF0_TX0_ch_txprogdivresetdone (),
    .INTF0_RX0_ch_rxpmaresetdone (), .INTF0_RX0_ch_rxprogdivresetdone (),
    .INTF0_TX1_ch_txpmaresetdone (), .INTF0_TX1_ch_txprogdivresetdone (),
    .INTF0_RX1_ch_rxpmaresetdone (), .INTF0_RX1_ch_rxprogdivresetdone (),

`ifdef DCMAC_ETH_200G
    .QUAD0_TX2_usrclk          (gt_tx_usrclk2[0]),
    .QUAD0_RX2_usrclk          (gt_rx_usrclk2[0]),
    .QUAD0_TX3_usrclk          (gt_tx_usrclk2[0]),
    .QUAD0_RX3_usrclk          (gt_rx_usrclk2[0]),

    .QUAD0_ch2_loopback        (LOOPBACK_MODE),
    .QUAD0_ch3_loopback        (LOOPBACK_MODE),

    .INTF0_TX2_ch_txdata       (txdata_out[2]),
    .INTF0_RX2_ch_rxdata       (rxdata_in[2]),
    .INTF0_TX3_ch_txdata       (txdata_out[3]),
    .INTF0_RX3_ch_rxdata       (rxdata_in[3]),

    .INTF0_TX2_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX2_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX2_ch_txprecursor (6'(TX_PRECURSOR)),
    .INTF0_TX3_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX3_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX3_ch_txprecursor (6'(TX_PRECURSOR)),
    .INTF0_RX2_ch_rxcdrhold    (1'b0),
    .INTF0_RX3_ch_rxcdrhold    (1'b0),

    .INTF0_TX2_ch_txpolarity   (POLARITY_TX_Q0[2]),
    .INTF0_TX3_ch_txpolarity   (POLARITY_TX_Q0[3]),
    .INTF0_RX2_ch_rxpolarity   (POLARITY_RX_Q0[2]),
    .INTF0_RX3_ch_rxpolarity   (POLARITY_RX_Q0[3]),

    .INTF0_TX2_ch_txrate (8'd0), .INTF0_RX2_ch_rxrate (8'd0),
    .INTF0_TX3_ch_txrate (8'd0), .INTF0_RX3_ch_rxrate (8'd0),

    .INTF0_TX2_ch_txresetdone (), .INTF0_RX2_ch_rxresetdone (),
    .INTF0_TX3_ch_txresetdone (), .INTF0_RX3_ch_rxresetdone (),
    .INTF0_TX2_ch_txpmaresetdone (), .INTF0_TX2_ch_txprogdivresetdone (),
    .INTF0_RX2_ch_rxpmaresetdone (), .INTF0_RX2_ch_rxprogdivresetdone (),
    .INTF0_TX3_ch_txpmaresetdone (), .INTF0_TX3_ch_txprogdivresetdone (),
    .INTF0_RX3_ch_rxpmaresetdone (), .INTF0_RX3_ch_rxprogdivresetdone (),
`endif

    .INTF0_TX_clr_out                 (gt_tx_clr_out[0]),
    .INTF0_TX_clrb_leaf_out           (gt_tx_clrb_leaf_out[0]),
    .INTF0_RX_clr_out                 (gt_rx_clr_out[0]),
    .INTF0_RX_clrb_leaf_out           (gt_rx_clrb_leaf_out[0]),
    .INTF0_rst_all_in                 (sys_reset | gt_all_reset_stretched[0]),
    .INTF0_rst_tx_pll_and_datapath_in (1'b0),
    .INTF0_rst_rx_pll_and_datapath_in (rx_pll_dp_reset_stretched[0]),
    .INTF0_rst_tx_done_out            (rst_tx_done_q[0]),
    .INTF0_rst_rx_done_out            (rst_rx_done_q[0]),

    .INTF0_rst_tx_datapath_in         (tx_dp_reset_s[0]),
    .INTF0_rst_rx_datapath_in         (rx_dp_reset_stretched[0]),
    .gtpowergood                      (gtpowergood_q[0])
  );

  generate
  if (N_CLIENT > 1) begin : g_gtwiz1

    dcmac_0_gtwiz_versal_1 i_gtwiz1 (
      .gtwiz_freerun_clk        (freerun_clk_i),
      .QUAD0_GTREFCLK0          (QUAD1_GTREFCLK0),
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

      .QUAD0_rxp                (gt_rxp_in[7:4]),
      .QUAD0_rxn                (gt_rxn_in[7:4]),
      .QUAD0_txp                (gt_txp_out[7:4]),
      .QUAD0_txn                (gt_txn_out[7:4]),

      .QUAD0_TX0_outclk         (gt_ch0_txoutclk[1]),
      .QUAD0_RX0_outclk         (gt_ch0_rxoutclk[1]),
      .QUAD0_TX0_usrclk         (gt_tx_usrclk2[1]),
      .QUAD0_RX0_usrclk         (gt_rx_usrclk2[1]),
      .QUAD0_TX1_usrclk         (gt_tx_usrclk2[1]),
      .QUAD0_RX1_usrclk         (gt_rx_usrclk2[1]),

      .QUAD0_ch0_loopback       (LOOPBACK_MODE),
      .QUAD0_ch1_loopback       (LOOPBACK_MODE),
      .QUAD0_gpi                (32'd0),
      .QUAD0_gpo                (),

      .INTF0_TX0_ch_txdata      (txdata_out[2]),
      .INTF0_RX0_ch_rxdata      (rxdata_in[2]),
      .INTF0_TX1_ch_txdata      (txdata_out[3]),
      .INTF0_RX1_ch_rxdata      (rxdata_in[3]),

      .INTF0_TX0_ch_txresetdone (), .INTF0_RX0_ch_rxresetdone (),
      .INTF0_TX1_ch_txresetdone (), .INTF0_RX1_ch_rxresetdone (),

      .INTF0_TX0_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX0_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX0_ch_txprecursor (6'(TX_PRECURSOR)),
      .INTF0_RX0_ch_rxcdrhold    (1'b0),
      .INTF0_TX1_ch_txmaincursor (7'(TX_MAINCURSOR)), .INTF0_TX1_ch_txpostcursor (6'(TX_POSTCURSOR)), .INTF0_TX1_ch_txprecursor (6'(TX_PRECURSOR)),
      .INTF0_RX1_ch_rxcdrhold    (1'b0),

      .INTF0_TX0_ch_txpolarity   (POLARITY_TX_Q1[0]),
      .INTF0_TX1_ch_txpolarity   (POLARITY_TX_Q1[1]),
      .INTF0_RX0_ch_rxpolarity   (POLARITY_RX_Q1[0]),
      .INTF0_RX1_ch_rxpolarity   (POLARITY_RX_Q1[1]),

      .INTF0_TX0_ch_txrate (8'd0), .INTF0_RX0_ch_rxrate (8'd0),
      .INTF0_TX1_ch_txrate (8'd0), .INTF0_RX1_ch_rxrate (8'd0),

      .INTF0_TX0_ch_txpmaresetdone (), .INTF0_TX0_ch_txprogdivresetdone (),
      .INTF0_RX0_ch_rxpmaresetdone (), .INTF0_RX0_ch_rxprogdivresetdone (),
      .INTF0_TX1_ch_txpmaresetdone (), .INTF0_TX1_ch_txprogdivresetdone (),
      .INTF0_RX1_ch_rxpmaresetdone (), .INTF0_RX1_ch_rxprogdivresetdone (),

      .INTF0_TX_clr_out                 (gt_tx_clr_out[1]),
      .INTF0_TX_clrb_leaf_out           (gt_tx_clrb_leaf_out[1]),
      .INTF0_RX_clr_out                 (gt_rx_clr_out[1]),
      .INTF0_RX_clrb_leaf_out           (gt_rx_clrb_leaf_out[1]),
      .INTF0_rst_all_in                 (sys_reset | gt_all_reset_stretched[1]),
      .INTF0_rst_tx_pll_and_datapath_in (1'b0),
      .INTF0_rst_rx_pll_and_datapath_in (rx_pll_dp_reset_stretched[1]),
      .INTF0_rst_tx_done_out            (rst_tx_done_q[1]),
      .INTF0_rst_rx_done_out            (rst_rx_done_q[1]),

      .INTF0_rst_tx_datapath_in         (tx_dp_reset_s[1]),
      .INTF0_rst_rx_datapath_in         (rx_dp_reset_stretched[1]),
      .gtpowergood                      (gtpowergood_q[1])
    );
  end
  endgenerate

  generate
  for (c = 0; c < N_CLIENT; c++) begin : g_mbufg
    MBUFG_GT #(.MODE("PERFORMANCE")) i_mbufg_tx (
      .O1(gt_tx_usrclk[c]), .O2(gt_tx_usrclk2[c]), .O3(), .O4(),
      .CE(1'b1), .CEMASK(1'b0),
      .CLR(gt_tx_clr_out[c]), .CLRB_LEAF(gt_tx_clrb_leaf_out[c]), .CLRMASK(1'b0),
      .DIV(3'd0), .I(gt_ch0_txoutclk[c])
    );
    MBUFG_GT #(.MODE("PERFORMANCE")) i_mbufg_rx (
      .O1(gt_rx_usrclk[c]), .O2(gt_rx_usrclk2[c]), .O3(), .O4(),
      .CE(1'b1), .CEMASK(1'b0),
      .CLR(gt_rx_clr_out[c]), .CLRB_LEAF(gt_rx_clrb_leaf_out[c]), .CLRMASK(1'b0),
      .DIV(3'd0), .I(gt_ch0_rxoutclk[c])
    );
  end
  endgenerate

  logic [5:0] rx_serdes_reset_i, tx_serdes_reset_i;
  always_comb begin
    rx_serdes_reset_i = 6'b0;
    tx_serdes_reset_i = 6'b0;
    for (int p = 0; p < 6; p++) begin
      if (p == ANCHOR_0) begin
        rx_serdes_reset_i[p] = ~rst_rx_done_q[0] | rx_serdes_reset_req[0];
        tx_serdes_reset_i[p] = ~rst_tx_done_q[0];
      end else if (N_CLIENT > 1 && p == ANCHOR_1) begin
        rx_serdes_reset_i[p] = ~rst_rx_done_q[(N_CLIENT > 1) ? 1 : 0]
                             | rx_serdes_reset_req[(N_CLIENT > 1) ? 1 : 0];
        tx_serdes_reset_i[p] = ~rst_tx_done_q[(N_CLIENT > 1) ? 1 : 0];
      end else begin
        rx_serdes_reset_i[p] = 1'b1;
        tx_serdes_reset_i[p] = 1'b1;
      end
    end
  end

  assign tx_serdes_reset = tx_serdes_reset_i | {6{core_serdes_reset}};
  assign rx_serdes_reset = rx_serdes_reset_i | {6{core_serdes_reset}};

endmodule

`default_nettype wire
