// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
package dcmac_ctl_pkg;

  localparam logic [19:0] O_CONFIG_REV   = 20'h00000;
  localparam logic [19:0] O_GLOBAL_MODE  = 20'h00004;
  localparam logic [19:0] O_CHCTL_RX     = 20'h00030;
  localparam logic [19:0] O_CHCTL_TX     = 20'h00038;
  localparam logic [19:0] O_TX_MODE      = 20'h00040;
  localparam logic [19:0] O_RX_MODE      = 20'h00044;
  localparam logic [19:0] O_PCTL_RX      = 20'h000f0;
  localparam logic [19:0] O_TICK_RX      = 20'h000f4;
  localparam logic [19:0] O_PCTL_TX      = 20'h000f8;
  localparam logic [19:0] O_TICK_TX      = 20'h000fc;
  localparam logic [19:0] O_STX_BYTES    = 20'h00200;
  localparam logic [19:0] O_STX_GBYTES   = 20'h00208;
  localparam logic [19:0] O_STX_PKTS     = 20'h00210;
  localparam logic [19:0] O_STX_GPKTS    = 20'h00218;
  localparam logic [19:0] O_SRX_BYTES    = 20'h00400;
  localparam logic [19:0] O_SRX_GBYTES   = 20'h00408;
  localparam logic [19:0] O_SRX_PKTS     = 20'h00410;
  localparam logic [19:0] O_SRX_GPKTS    = 20'h00418;
  localparam logic [19:0] O_RX_PHY_STATUS= 20'h00C00;
  localparam logic [19:0] O_FEC_CW       = 20'h00E48;
  localparam logic [19:0] O_FEC_CORR     = 20'h00E50;
  localparam logic [19:0] O_FEC_UNCORR   = 20'h00E58;

  localparam int PORT_SHIFT = 12;

  localparam logic [31:0] W_GLOBAL_MODE  = 32'h0755_0000;
  localparam logic [31:0] W_PORT_MODE    = 32'h2580_0062;
  localparam logic [31:0] W_PORT_REV     = 32'h0000_0C01;

  localparam logic [31:0] ALIGN_MASK     = 32'h0000_0005;
  localparam logic [31:0] ALIGN_ARM      = 32'hFFFF_FFFF;
  localparam logic [31:0] AXI_BAD_MAGIC  = 32'h0BAD_0BAD;

  localparam int TX_MAIN_DEFAULT = 87;
  localparam int TX_PRE_DEFAULT  = 17;
  localparam int TX_POST_DEFAULT = 5;
  localparam int TX_MAIN_VENDOR  = 75;
  localparam int TX_PRE_VENDOR   = 3;
  localparam int TX_POST_VENDOR  = 9;

  function automatic bit cursor_legal(input int main_sum, input int pre, input int post);
    return (main_sum >= 42) && (main_sum <= 87) &&
           (pre  >= 0) && (pre  <= 24) &&
           (post >= 0) && (post <= 24) &&
           ((pre + post) < main_sum);
  endfunction

  localparam logic [7:0] QSFP0_TXPOLARITY = 8'b0000_0000;
  localparam logic [7:0] QSFP0_RXPOLARITY = 8'b0000_0000;

  localparam logic [2:0] LOOPBACK_EXTERNAL = 3'b000;
  localparam logic [2:0] LOOPBACK_NEAR_PCS = 3'b001;
  localparam logic [7:0] LINERATE_DEFAULT  = 8'd0;

  localparam logic [7:0] DONEMASK_100G = 8'h03;
  localparam logic [7:0] DONEMASK_200G = 8'h0F;
  localparam logic [7:0] DONEMASK_400G = 8'hFF;

  localparam int RATE_CODE_100G  = 0;   localparam int RATE_FIELD_100G  = 'h04;
  localparam int RATE_CODE_200G  = 1;   localparam int RATE_FIELD_200G  = 'h08;
  localparam int RATE_CODE_400G  = 2;   localparam int RATE_FIELD_400G  = 'h10;
  localparam int RATE_FIELD_NONANCHOR = 'h04;

  function automatic logic [31:0] tx_mode_word(input int rate, input int field);
    logic [31:0] w;
    w = (32'(rate) & 32'h3) | (32'h1 << 4) | (32'h1 << 10);
    return (w & 32'hFFE0FFFF) | (32'(field) << 16);
  endfunction

  function automatic logic [31:0] rx_mode_word(input int rate, input int field);
    logic [31:0] w;
    w = (32'(rate) & 32'h3) | (32'h1 << 11) | (32'h1 << 13);
    return (w & 32'hFFE0FFFF) | (32'(field) << 16);
  endfunction

endpackage
