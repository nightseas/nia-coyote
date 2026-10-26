// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module dcmac_mac_ctl_fsm #(
  parameter int RX_RESET_CYCLES = 16,
  parameter int PORT_MAX        = 6,
  parameter int NPORTS          = 1,
  parameter int ANCHOR          = 0
)(
  input  logic       seg_clk,
  input  logic       seg_rstn,

  input  logic       stat_rx_aligned,

  input  logic       rx_datapath_reset_req,
  input  logic       tx_datapath_reset_req,
  input  logic       rx_force_resync_req,

  output logic       ctl_rx_enable,
  output logic       ctl_rx_force_resync,
  output logic       ctl_tx_enable,
  output logic       ctl_tx_send_idle,
  output logic       ctl_tx_send_lfi,
  output logic       ctl_tx_send_rfi,

  output logic                rx_datapath_reset,
  output logic                tx_datapath_reset,
  output logic [PORT_MAX-1:0] rx_datapath_reset_ports,

  output logic       tx_rst_seg,
  output logic       link_up,
  output logic [2:0] fsm_state
);
  localparam logic [2:0] S_IDLE       = 3'd0;
  localparam logic [2:0] S_GT_LOCKED  = 3'd1;
  localparam logic [2:0] S_WAIT_ALIGN = 3'd2;
  localparam logic [2:0] S_XFER       = 3'd3;
  localparam logic [2:0] S_RX_RESET   = 3'd4;

  localparam int CW = (RX_RESET_CYCLES > 1) ? $clog2(RX_RESET_CYCLES + 1) : 1;

  logic [2:0]    state;
  logic          aligned_1d;
  logic          reset_done;
  logic [CW-1:0] rst_cnt;

  logic ctl_rx_enable_r, ctl_tx_enable_r;
  logic ctl_tx_send_lfi_r, ctl_tx_send_rfi_r, ctl_tx_send_idle_r;
  logic rx_dp_reset_r;
  logic tx_rst_r;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      state              <= S_IDLE;
      aligned_1d         <= 1'b0;
      reset_done         <= 1'b0;
      rst_cnt            <= '0;
      ctl_rx_enable_r    <= 1'b0;
      ctl_tx_enable_r    <= 1'b0;
      ctl_tx_send_lfi_r  <= 1'b1;
      ctl_tx_send_rfi_r  <= 1'b1;
      ctl_tx_send_idle_r <= 1'b0;
      rx_dp_reset_r      <= 1'b0;
    end else begin
      reset_done <= 1'b1;
      aligned_1d <= stat_rx_aligned;
      case (state)
        S_IDLE: begin
          ctl_rx_enable_r    <= 1'b0;
          ctl_tx_enable_r    <= 1'b0;
          ctl_tx_send_lfi_r  <= 1'b1;
          ctl_tx_send_rfi_r  <= 1'b1;
          ctl_tx_send_idle_r <= 1'b0;
          rx_dp_reset_r      <= 1'b0;
          if (reset_done) state <= S_GT_LOCKED;
        end
        S_GT_LOCKED: begin
          ctl_rx_enable_r   <= 1'b1;
          ctl_tx_send_lfi_r <= 1'b1;
          ctl_tx_send_rfi_r <= 1'b1;
          state             <= S_WAIT_ALIGN;
        end
        S_WAIT_ALIGN: begin
          if (aligned_1d) state <= S_XFER;
        end
        S_XFER: begin
          ctl_tx_send_lfi_r <= 1'b0;
          ctl_tx_send_rfi_r <= 1'b0;
          ctl_tx_enable_r   <= 1'b1;
          if (!aligned_1d) begin
            ctl_tx_enable_r   <= 1'b0;
            ctl_tx_send_lfi_r <= 1'b1;
            ctl_tx_send_rfi_r <= 1'b1;
            rst_cnt           <= RX_RESET_CYCLES[CW-1:0];
            state             <= S_RX_RESET;
          end
        end
        S_RX_RESET: begin
          ctl_rx_enable_r <= 1'b0;
          rx_dp_reset_r   <= 1'b1;
          if (rst_cnt == '0) begin
            rx_dp_reset_r <= 1'b0;
            state         <= S_IDLE;
          end else begin
            rst_cnt <= rst_cnt - 1'b1;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  always_ff @(posedge seg_clk) begin
    tx_rst_r <= ~seg_rstn | (state != S_XFER) | ~stat_rx_aligned;
  end

  logic [PORT_MAX-1:0] port_group_mask;
  always_comb begin
    port_group_mask = '0;
    for (int p = 0; p < PORT_MAX; p++)
      if (p >= ANCHOR && p < (ANCHOR + NPORTS)) port_group_mask[p] = 1'b1;
  end

  assign ctl_rx_enable       = ctl_rx_enable_r;
  assign ctl_rx_force_resync = rx_force_resync_req;
  assign ctl_tx_enable       = ctl_tx_enable_r;
  assign ctl_tx_send_idle    = ctl_tx_send_idle_r;
  assign ctl_tx_send_lfi     = ctl_tx_send_lfi_r;
  assign ctl_tx_send_rfi     = ctl_tx_send_rfi_r;
  assign rx_datapath_reset   = rx_dp_reset_r | rx_datapath_reset_req;
  assign tx_datapath_reset   = tx_datapath_reset_req;
  assign rx_datapath_reset_ports = rx_datapath_reset ? port_group_mask : '0;
  assign tx_rst_seg          = tx_rst_r;
  assign link_up             = (state == S_XFER);
  assign fsm_state           = state;
endmodule
