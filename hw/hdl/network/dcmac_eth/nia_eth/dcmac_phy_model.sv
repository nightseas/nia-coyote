// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

`default_nettype none

module dcmac_phy #(

  parameter int         N_CLIENT      = 1,
  parameter int         N_SEG         = 2,
  parameter int         SEG_W         = 128,
  parameter int         PORT_MAX      = 6,
  parameter logic [2:0] LOOPBACK_MODE = 3'b000,

  parameter int         ANCHOR_0      = 0,
  parameter int         ANCHOR_1      = 1,

  parameter int         RX_DP_RESET_MIN_CYCLES = 512,
  parameter int         EN_DPRST_SYNC = 1,
  parameter int         TX_MAINCURSOR = dcmac_ctl_pkg::TX_MAIN_DEFAULT,
  parameter int         TX_PRECURSOR  = dcmac_ctl_pkg::TX_PRE_DEFAULT,
  parameter int         TX_POSTCURSOR = dcmac_ctl_pkg::TX_POST_DEFAULT,

  parameter logic [7:0] POLARITY_TX_Q0 = dcmac_ctl_pkg::QSFP0_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q0 = dcmac_ctl_pkg::QSFP0_RXPOLARITY,
  parameter logic [7:0] POLARITY_TX_Q1 = dcmac_ctl_pkg::QSFP1_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q1 = dcmac_ctl_pkg::QSFP1_RXPOLARITY
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
  wire stub_clk = gt_ref_clk0_p;
  assign seg_clk = stub_clk;
  assign usr_clk = stub_clk;

  reg rstn_r = 1'b0, rstn_rr = 1'b0;
  always_ff @(posedge stub_clk) begin
    rstn_r  <= ~sys_reset;
    rstn_rr <= rstn_r;
  end
  assign seg_rstn = {N_CLIENT{rstn_rr}};
  assign seg_rstn_ctl = rstn_rr;

  wire _unused = |{gt_ref_clk0_n, gt_ref_clk1_p, gt_ref_clk1_n, gt_rxp_in, gt_rxn_in,
                   LOOPBACK_MODE, ANCHOR_0[0], ANCHOR_1[0], RX_DP_RESET_MIN_CYCLES[0],
                   EN_DPRST_SYNC[0], TX_MAINCURSOR[0], TX_PRECURSOR[0], TX_POSTCURSOR[0],
                   POLARITY_TX_Q0[0], POLARITY_RX_Q0[0], POLARITY_TX_Q1[0], POLARITY_RX_Q1[0],
                   ctl_rx_force_resync, ctl_tx_send_idle, ctl_tx_send_lfi, ctl_tx_send_rfi,
                   tx_datapath_reset};
  assign gt_txn_out = {(4*N_CLIENT){1'b0}};
  assign gt_txp_out = {(4*N_CLIENT){1'b0}};

  wire [N_CLIENT-1:0] phy_align_scripted;

  function automatic int axil_rd_client(input [19:0] a);
    int prt;
    prt = int'(a[14:12]) - 1;
    axil_rd_client = 0;
    if (N_CLIENT > 1 && prt >= ANCHOR_1) axil_rd_client = 1;
  endfunction

  reg axil_aw_seen = 1'b0, axil_w_seen = 1'b0, axil_bvalid_r = 1'b0, axil_rvalid_r = 1'b0;
  reg [31:0] axil_rdata_r = 32'd0;

  always_ff @(posedge axil_aclk) begin
    if (!axil_aresetn) begin
      axil_aw_seen  <= 1'b0;
      axil_w_seen   <= 1'b0;
      axil_bvalid_r <= 1'b0;
      axil_rvalid_r <= 1'b0;
      axil_rdata_r  <= 32'd0;
    end else begin

      if (s_axil_awvalid && !axil_bvalid_r) axil_aw_seen <= 1'b1;
      if (s_axil_wvalid  && !axil_bvalid_r) axil_w_seen  <= 1'b1;
      if ((axil_aw_seen || s_axil_awvalid) && (axil_w_seen || s_axil_wvalid) &&
          !axil_bvalid_r) begin
        axil_bvalid_r <= 1'b1;
        axil_aw_seen  <= 1'b0;
        axil_w_seen   <= 1'b0;
      end else if (axil_bvalid_r && s_axil_bready) begin
        axil_bvalid_r <= 1'b0;
      end

      if (s_axil_arvalid && !axil_rvalid_r) begin
        axil_rvalid_r <= 1'b1;

        axil_rdata_r  <= phy_align_scripted[axil_rd_client(s_axil_araddr)]
                           ? 32'h0000_0005 : 32'h0000_0000;
      end else if (axil_rvalid_r && s_axil_rready) begin
        axil_rvalid_r <= 1'b0;
      end
    end
  end

  assign s_axil_awready = !axil_bvalid_r;
  assign s_axil_wready  = !axil_bvalid_r;
  assign s_axil_bvalid  = axil_bvalid_r;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_arready = !axil_rvalid_r;
  assign s_axil_rvalid  = axil_rvalid_r;
  assign s_axil_rdata   = axil_rdata_r;
  assign s_axil_rresp   = 2'b00;

  reg gt_done_r = 1'b0;
  always_ff @(posedge axil_aclk) gt_done_r <= axil_aresetn;

  reg [N_CLIENT-1:0] rx_dp_d = '0;
  reg [N_CLIENT-1:0] tx_dp_d = '0;
  always_ff @(posedge axil_aclk) begin
    rx_dp_d <= rx_datapath_reset;
    tx_dp_d <= tx_datapath_reset;
  end

  genvar gd;
  generate
  for (gd = 0; gd < N_CLIENT; gd++) begin : g_gt_done
    assign gt_rx_reset_done[8*gd +: 8] = (gt_done_r && !rx_dp_d[gd]) ? 8'h03 : 8'h00;
    assign gt_tx_reset_done[8*gd +: 8] = (gt_done_r && !tx_dp_d[gd]) ? 8'h03 : 8'h00;
  end
  endgenerate

  wire _unused_axil = |{s_axil_awaddr, s_axil_wdata, s_axil_wstrb, s_axil_araddr,
                        core_serdes_reset};

generate
if (LOOPBACK_MODE == 3'b000) begin : g_tieoff
  assign phy_align_scripted = '0;
  assign rx_seg_valid = {N_CLIENT{1'b0}};
  assign rx_seg_dat   = {(N_CLIENT*N_SEG*SEG_W){1'b0}};
  assign rx_seg_ena   = {(N_CLIENT*N_SEG){1'b0}};
  assign rx_seg_sop   = {(N_CLIENT*N_SEG){1'b0}};
  assign rx_seg_eop   = {(N_CLIENT*N_SEG){1'b0}};
  assign rx_seg_err   = {(N_CLIENT*N_SEG){1'b0}};
  assign rx_seg_mty   = {(N_CLIENT*N_SEG*4){1'b0}};
  assign tx_seg_ready = {N_CLIENT{1'b0}};
  wire _unused_lb = |{tx_seg_valid, tx_seg_dat, tx_seg_ena, tx_seg_sop, tx_seg_eop,
                      tx_seg_err, tx_seg_mty, ctl_rx_enable, ctl_tx_enable,
                      rx_datapath_reset, rx_datapath_reset_ports, rx_flush_req,
                      rx_pll_datapath_reset, gt_all_reset};
end else begin : g_loopback

  wire [N_CLIENT-1:0] rx_kill_v;
  for (genvar k = 0; k < N_CLIENT; k++) begin : g_kill
    wire [PORT_MAX-1:0] kports = rx_datapath_reset_ports[k*PORT_MAX +: PORT_MAX];
    assign rx_kill_v[k] = rx_datapath_reset[k] | rx_serdes_reset_req[k]
                        | ((|kports) & ~ctl_rx_enable[k]);
  end

  localparam int ALIGN_CYCLES = 256;

  reg [$clog2(ALIGN_CYCLES+1)-1:0] align_cnt [N_CLIENT];
  reg [N_CLIENT-1:0]               aligned_r;
  initial begin
    for (int i = 0; i < N_CLIENT; i++) align_cnt[i] = '0;
    aligned_r = '0;
  end
  for (genvar c = 0; c < N_CLIENT; c++) begin : g_align
    always_ff @(posedge stub_clk) begin
      if (!rstn_rr || rx_kill_v[c]) begin
        align_cnt[c] <= '0;
        aligned_r[c] <= 1'b0;
      end else if (align_cnt[c] != ALIGN_CYCLES[$clog2(ALIGN_CYCLES+1)-1:0]) begin
        align_cnt[c] <= align_cnt[c] + 1'b1;
      end else begin
        aligned_r[c] <= 1'b1;
      end
    end
  end
  assign phy_align_scripted = aligned_r;

  for (genvar c = 0; c < N_CLIENT; c++) begin : g_client

    assign tx_seg_ready[c] = ctl_tx_enable[c];

    reg                    rx_valid_r = 1'b0;
    reg [N_SEG*SEG_W-1:0]  rx_dat_r   = '0;
    reg [N_SEG-1:0]        rx_ena_r = '0, rx_sop_r = '0, rx_eop_r = '0, rx_err_r = '0;
    reg [N_SEG*4-1:0]      rx_mty_r = '0;

    wire rx_kill = rx_kill_v[c];

    wire [N_SEG-1:0] tena = tx_seg_ena[c*N_SEG +: N_SEG];
    wire [N_SEG-1:0] tsop = tx_seg_sop[c*N_SEG +: N_SEG];
    wire [N_SEG-1:0] teop = tx_seg_eop[c*N_SEG +: N_SEG];

    wire acc      = tx_seg_valid[c] & tx_seg_ready[c];
    wire beat_dat = |tena;
    wire beat_sop = |(tsop & tena);
    wire beat_eop = |(teop & tena);

    reg in_frame = 1'b0;
    reg hunting  = 1'b1;

    wire fwd_ok = beat_dat & (in_frame ? ~beat_sop : beat_sop);
    wire fwd    = acc & fwd_ok & ctl_rx_enable[c];
    wire viol   = acc & ~fwd_ok & ~hunting;

    always_ff @(posedge stub_clk) begin
      if (!rstn_rr || rx_kill) begin
        in_frame <= 1'b0;
        hunting  <= 1'b1;
      end else if (acc && fwd_ok) begin
        in_frame <= ~beat_eop;
        hunting  <= 1'b0;
      end
    end

    always_ff @(posedge stub_clk) begin
      if (!rstn_rr || rx_kill) begin
        rx_valid_r <= 1'b0;
        rx_ena_r   <= '0;
        rx_sop_r   <= '0;
        rx_eop_r   <= '0;
        rx_err_r   <= '0;
        rx_mty_r   <= '0;
        rx_dat_r   <= '0;
      end else begin
        rx_valid_r <= fwd;
        if (fwd) begin
          rx_dat_r <= tx_seg_dat[c*N_SEG*SEG_W +: N_SEG*SEG_W];
          rx_ena_r <= tena;
          rx_sop_r <= tsop & tena;
          rx_eop_r <= teop & tena;
          rx_err_r <= tx_seg_err[c*N_SEG +: N_SEG] & tena;
          rx_mty_r <= tx_seg_mty[c*N_SEG*4 +: N_SEG*4];
        end else begin

          rx_dat_r <= '0;
          rx_ena_r <= '0;
          rx_sop_r <= '0;
          rx_eop_r <= '0;
          rx_err_r <= '0;
          rx_mty_r <= '0;
        end
      end
    end

    integer viol_cnt = 0;
    always_ff @(posedge stub_clk) begin
      if (!rstn_rr) begin
        viol_cnt <= 0;
      end else if (viol) begin
        viol_cnt <= viol_cnt + 1;
        if (viol_cnt < 8)
          $display("NIA_PHY_STUB VIOLATION c%0d t=%0t #%0d: TX re-offered or malformed beat -- acc=1 ena=%b sop=%b eop=%b in_frame=%b. DISCARDED, not looped back. >=1 of these means the TX chain offered a beat it had already handed over (a DUT-side AXIS violation); ZERO of these with the loopback set passing means the old 1016-frame signature was this stub amplifying its own stale sideband.",
                   c, $time, viol_cnt + 1, tena, tsop, teop, in_frame);
        else if (viol_cnt == 8)
          $display("NIA_PHY_STUB VIOLATION c%0d t=%0t: 9th violation -- further per-beat lines suppressed. The test-side runaway detector reports the total.",
                   c, $time);
      end
    end

    assign rx_seg_valid[c]                        = rx_valid_r;
    assign rx_seg_dat[c*N_SEG*SEG_W +: N_SEG*SEG_W] = rx_dat_r;
    assign rx_seg_ena[c*N_SEG +: N_SEG]           = rx_ena_r;
    assign rx_seg_sop[c*N_SEG +: N_SEG]           = rx_sop_r;
    assign rx_seg_eop[c*N_SEG +: N_SEG]           = rx_eop_r;
    assign rx_seg_err[c*N_SEG +: N_SEG]           = rx_err_r;
    assign rx_seg_mty[c*N_SEG*4 +: N_SEG*4]       = rx_mty_r;
  end
end
endgenerate
endmodule

`default_nettype wire
