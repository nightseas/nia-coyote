// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module dcmac_100g_phy #(
  parameter int         N_SEG         = 2,
  parameter int         SEG_W         = 128,
  parameter int         PORT_MAX      = 6,
  parameter logic [2:0] LOOPBACK_MODE = 3'b000
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
  assign seg_clk = init_clk;
  assign usr_clk = init_clk;

  logic rstn_r, rstn_rr;
  always_ff @(posedge init_clk) begin
    rstn_r  <= ~sys_reset;
    rstn_rr <= rstn_r;
  end
  assign seg_rstn        = rstn_rr;

  wire _unused = |{gt_ref_clk_p, gt_ref_clk_n, gt_rxp_in, gt_rxn_in, LOOPBACK_MODE,
                   ctl_rx_force_resync, ctl_tx_send_idle, ctl_tx_send_lfi, ctl_tx_send_rfi,
                   tx_datapath_reset};
  assign gt_txn_out = {4{1'b0}};
  assign gt_txp_out = {4{1'b0}};

  logic phy_align_scripted;

  logic axil_aw_seen, axil_w_seen, axil_bvalid_r, axil_rvalid_r;
  logic [31:0] axil_rdata_r;

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
        axil_rdata_r  <= phy_align_scripted ? 32'h0000_0005 : 32'h0000_0000;
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

  logic gt_done_r;
  always_ff @(posedge axil_aclk) gt_done_r <= axil_aresetn;
  assign gt_tx_reset_done = gt_done_r ? 8'h03 : 8'h00;
  assign gt_rx_reset_done = gt_done_r ? 8'h03 : 8'h00;

  wire _unused_axil = |{s_axil_awaddr, s_axil_wdata, s_axil_wstrb, s_axil_araddr,
                        core_serdes_reset};

generate
if (LOOPBACK_MODE == 3'b000) begin : g_tieoff
  assign phy_align_scripted = 1'b0;
  assign rx_seg_valid    = 1'b0;
  assign rx_seg_dat      = '0;
  assign rx_seg_ena      = '0;
  assign rx_seg_sop      = '0;
  assign rx_seg_eop      = '0;
  assign rx_seg_err      = '0;
  assign rx_seg_mty      = '0;
  assign tx_seg_ready    = 1'b0;
  wire _unused_lb = |{tx_seg_valid, tx_seg_dat, tx_seg_ena, tx_seg_sop, tx_seg_eop,
                      tx_seg_err, tx_seg_mty, ctl_rx_enable, ctl_tx_enable,
                      rx_datapath_reset, rx_datapath_reset_ports};
end else begin : g_loopback
  localparam int ALIGN_CYCLES = 256;

  logic [$clog2(ALIGN_CYCLES+1)-1:0] align_cnt;
  logic                              aligned_r;
  always_ff @(posedge init_clk) begin
    if (!rstn_rr) begin
      align_cnt <= '0;
      aligned_r <= 1'b0;
    end else if (align_cnt != ALIGN_CYCLES[$clog2(ALIGN_CYCLES+1)-1:0]) begin
      align_cnt <= align_cnt + 1'b1;
    end else begin
      aligned_r <= 1'b1;
    end
  end
  assign phy_align_scripted = aligned_r;

  assign tx_seg_ready = ctl_tx_enable;

  logic                    rx_valid_r;
  logic [N_SEG*SEG_W-1:0]  rx_dat_r;
  logic [N_SEG-1:0]        rx_ena_r, rx_sop_r, rx_eop_r, rx_err_r;
  logic [N_SEG*4-1:0]      rx_mty_r;

  wire rx_kill = rx_datapath_reset | (|rx_datapath_reset_ports & ~ctl_rx_enable);

  always_ff @(posedge init_clk) begin
    if (!rstn_rr || rx_kill) begin
      rx_valid_r <= 1'b0;
      rx_ena_r   <= '0;
      rx_sop_r   <= '0;
      rx_eop_r   <= '0;
      rx_err_r   <= '0;
      rx_mty_r   <= '0;
      rx_dat_r   <= '0;
    end else begin
      rx_valid_r <= tx_seg_valid & tx_seg_ready & ctl_rx_enable;
      rx_dat_r   <= tx_seg_dat;
      rx_ena_r   <= tx_seg_ena;
      rx_sop_r   <= tx_seg_sop;
      rx_eop_r   <= tx_seg_eop;
      rx_err_r   <= tx_seg_err;
      rx_mty_r   <= tx_seg_mty;
    end
  end

  assign rx_seg_valid = rx_valid_r;
  assign rx_seg_dat   = rx_dat_r;
  assign rx_seg_ena   = rx_ena_r;
  assign rx_seg_sop   = rx_sop_r;
  assign rx_seg_eop   = rx_eop_r;
  assign rx_seg_err   = rx_err_r;
  assign rx_seg_mty   = rx_mty_r;
end
endgenerate
endmodule
