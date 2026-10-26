// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module dcmac_mac_ctl_fsm #(

  parameter int CYC_PER_MS      = 390930,
  parameter int T_RXDP_MS       = 100,
  parameter int T_SERDES_MS     = 100,
  parameter int PORT_MAX        = 6,
  parameter int NPORTS          = 1,
  parameter int ANCHOR          = 0,

  parameter int LINK_CONFIRM_N  = 2,

  parameter int PLL_ESC_EVERY   = 0,

  parameter int GT_ESC_AFTER    = 0
)(
  input  logic       seg_clk,
  input  logic       seg_rstn,

  input  logic       configured,

  input  logic       stat_rx_aligned,
  input  logic       stat_remote_fault,

  input  logic       reset_req,

  input  logic       gt_rx_done,

  output logic       reset_ack,

  input  logic       rx_force_resync_req,

  output logic       ctl_rx_enable,
  output logic       ctl_rx_force_resync,
  output logic       ctl_tx_enable,
  output logic       ctl_tx_send_idle,
  output logic       ctl_tx_send_lfi,
  output logic       ctl_tx_send_rfi,

  output logic                rx_datapath_reset,
  output logic                rx_pll_datapath_reset,
  output logic                gt_all_reset_req,
  output logic                rx_serdes_reset_req,
  output logic                rx_flush_req,

  output logic [PORT_MAX-1:0] rx_datapath_reset_ports,

  output logic [7:0]          repair_count,
  output logic [7:0]          repair_tmo_count,

  output logic       tx_rst_seg,
  output logic       link_up,
  output logic       carrier,
  output logic [2:0] fsm_state
);

  localparam logic [2:0] S_IDLE       = 3'd0;

  localparam logic [2:0] S_WAIT_ALIGN = 3'd2;
  localparam logic [2:0] S_XFER       = 3'd3;
  localparam logic [2:0] S_RX_RESET   = 3'd4;
  localparam logic [2:0] S_RX_DONE    = 3'd5;
  localparam logic [2:0] S_RX_FLUSH   = 3'd6;
  localparam logic [2:0] S_RX_SETTLE  = 3'd7;

  localparam int CW = 32;
  localparam logic [CW-1:0] rxdp_cyc   = CW'(T_RXDP_MS)   * CW'(CYC_PER_MS);
  localparam logic [CW-1:0] done_cyc   = CW'(T_SERDES_MS) * CW'(CYC_PER_MS);
  localparam logic [CW-1:0] settle_cyc = CW'(T_SERDES_MS) * CW'(CYC_PER_MS);
  localparam int FLUSH_CYC_EFF = (CYC_PER_MS >= 5000) ? (CYC_PER_MS / 100) : 2;
  localparam logic [CW-1:0] flush_cyc  = CW'(FLUSH_CYC_EFF);
  localparam int CFMW = (LINK_CONFIRM_N < 2) ? 1 : $clog2(LINK_CONFIRM_N + 1);

  initial begin
    if (LINK_CONFIRM_N < 1)
      $fatal(1, "dcmac_mac_ctl_fsm: LINK_CONFIRM_N must be >= 1 (got %0d)", LINK_CONFIRM_N);
    if (T_RXDP_MS < 1 || T_SERDES_MS < 1)
      $fatal(1, "dcmac_mac_ctl_fsm: T_RXDP_MS and T_SERDES_MS must be >= 1 ms");
    if (CYC_PER_MS < 1)
      $fatal(1, "dcmac_mac_ctl_fsm: CYC_PER_MS must be >= 1");
    if (NPORTS < 1 || (ANCHOR + NPORTS) > PORT_MAX)
      $fatal(1, "dcmac_mac_ctl_fsm: ANCHOR+NPORTS (%0d) exceeds PORT_MAX (%0d)",
             ANCHOR + NPORTS, PORT_MAX);
  end

  logic [2:0]    state;
  logic          aligned_1d;
  wire           use_pll_reset = (PLL_ESC_EVERY != 0)
                               && (esc_phase_r == 8'(PLL_ESC_EVERY - 1));
  wire           use_gt_all_reset = (GT_ESC_AFTER != 0)
                                  && (fail_run_r >= 8'(GT_ESC_AFTER - 1));

  logic [CW-1:0] rst_cnt;
  logic [CFMW-1:0] fall_cnt;
  logic          link_up_r;

  logic ctl_rx_enable_r, ctl_tx_enable_r;
  logic ctl_tx_send_lfi_r, ctl_tx_send_rfi_r, ctl_tx_send_idle_r;
  logic rx_dp_reset_r;
  logic rx_pll_dp_reset_r;
  logic gt_all_reset_r;
  logic [7:0] fail_run_r;
  logic [7:0] esc_phase_r;
  logic rx_serdes_req_r;
  logic rx_flush_req_r;
  logic [7:0] repair_cnt_r;
  logic [7:0] repair_tmo_cnt_r;
  logic post_r;
  logic reset_ack_r;

  logic tx_rst_r;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      state              <= S_IDLE;
      aligned_1d         <= 1'b0;
      rst_cnt            <= '0;
      fall_cnt           <= '0;
      link_up_r          <= 1'b0;
      ctl_rx_enable_r    <= 1'b0;
      ctl_tx_enable_r    <= 1'b0;
      ctl_tx_send_lfi_r  <= 1'b1;
      ctl_tx_send_rfi_r  <= 1'b1;
      ctl_tx_send_idle_r <= 1'b0;
      rx_dp_reset_r      <= 1'b0;
      rx_pll_dp_reset_r  <= 1'b0;
      gt_all_reset_r     <= 1'b0;
      fail_run_r         <= '0;
      esc_phase_r        <= '0;
      rx_serdes_req_r    <= 1'b0;
      rx_flush_req_r     <= 1'b0;
      repair_cnt_r       <= '0;
      repair_tmo_cnt_r   <= '0;
      post_r             <= 1'b0;
      reset_ack_r        <= 1'b0;
    end else begin
      aligned_1d  <= stat_rx_aligned;

      ctl_tx_send_idle_r <= stat_remote_fault & ctl_tx_enable_r;

      if (!configured) begin
        state             <= S_IDLE;
        ctl_tx_enable_r   <= 1'b0;
        ctl_tx_send_lfi_r <= 1'b1;
        ctl_tx_send_rfi_r <= 1'b1;
        rx_dp_reset_r     <= 1'b0;
        rx_pll_dp_reset_r <= 1'b0;
        gt_all_reset_r    <= 1'b0;
        fail_run_r        <= '0;
        esc_phase_r       <= '0;
        rx_serdes_req_r   <= 1'b0;
        rx_flush_req_r    <= 1'b0;
        post_r            <= 1'b0;
        reset_ack_r       <= 1'b0;
        rst_cnt           <= '0;
      end
      else case (state)
        S_IDLE: begin
          ctl_rx_enable_r    <= 1'b0;
          ctl_tx_enable_r    <= 1'b0;
          ctl_tx_send_lfi_r  <= 1'b1;
          ctl_tx_send_rfi_r  <= 1'b1;
          rx_dp_reset_r      <= 1'b0;

          ctl_rx_enable_r <= 1'b1;

          state <= S_WAIT_ALIGN;
        end

        S_WAIT_ALIGN: begin
          if (aligned_1d) begin
            fail_run_r <= '0;
            state      <= S_XFER;
          end
          else if (reset_req)  begin
            reset_ack_r     <= 1'b1;
            rst_cnt         <= rxdp_cyc;
            repair_cnt_r    <= repair_cnt_r + 8'd1;
            rx_serdes_req_r <= 1'b1;
            rx_flush_req_r  <= 1'b1;
            state           <= S_RX_RESET;
          end
        end

        S_XFER: begin
          ctl_tx_send_lfi_r <= 1'b0;
          ctl_tx_send_rfi_r <= 1'b0;
          ctl_tx_enable_r   <= 1'b1;
          if (!aligned_1d) begin
            ctl_tx_enable_r   <= 1'b0;
            ctl_tx_send_lfi_r <= 1'b1;
            ctl_tx_send_rfi_r <= 1'b1;
            fall_cnt          <= CFMW'(LINK_CONFIRM_N);

            state             <= S_WAIT_ALIGN;
          end

          else if (reset_req) begin
            ctl_tx_enable_r   <= 1'b0;
            ctl_tx_send_lfi_r <= 1'b1;
            ctl_tx_send_rfi_r <= 1'b1;
            fall_cnt          <= CFMW'(LINK_CONFIRM_N);
            reset_ack_r       <= 1'b1;
            rst_cnt           <= rxdp_cyc;
            repair_cnt_r      <= repair_cnt_r + 8'd1;
            rx_serdes_req_r   <= 1'b1;
            rx_flush_req_r    <= 1'b1;
            state             <= S_RX_RESET;
          end
        end

        S_RX_RESET: begin
          ctl_rx_enable_r   <= 1'b0;
          rx_dp_reset_r     <= ~use_pll_reset;
          rx_pll_dp_reset_r <=  use_pll_reset;
          gt_all_reset_r    <= use_gt_all_reset;
          if (rst_cnt == '0) begin
            rx_dp_reset_r     <= 1'b0;
            rx_pll_dp_reset_r <= 1'b0;
            rst_cnt       <= done_cyc;
            state         <= S_RX_DONE;
          end else begin
            rst_cnt <= rst_cnt - 1'b1;
          end
        end

        S_RX_DONE: begin
          if (gt_rx_done) begin
            rst_cnt <= flush_cyc;
            state   <= S_RX_FLUSH;
          end else if (rst_cnt == '0) begin
            repair_tmo_cnt_r <= repair_tmo_cnt_r + 8'd1;
            rst_cnt          <= flush_cyc;
            state            <= S_RX_FLUSH;
          end else begin
            rst_cnt <= rst_cnt - 1'b1;
          end
        end

        S_RX_FLUSH: begin
          if (rst_cnt == '0) begin
            if (!post_r) begin
              rx_flush_req_r <= 1'b0;
              post_r         <= 1'b1;
              rst_cnt        <= flush_cyc;
            end else begin
              rx_serdes_req_r <= 1'b0;
              post_r          <= 1'b0;
              rst_cnt         <= settle_cyc;
              state           <= S_RX_SETTLE;
            end
          end else begin
            rst_cnt <= rst_cnt - 1'b1;
          end
        end

        S_RX_SETTLE: begin
          gt_all_reset_r <= 1'b0;
          if (rst_cnt == '0) begin
            reset_ack_r <= 1'b0;
            if (GT_ESC_AFTER != 0) begin
              if (fail_run_r >= 8'(GT_ESC_AFTER - 1)) fail_run_r <= '0;
              else                                    fail_run_r <= fail_run_r + 8'd1;
            end
            esc_phase_r <= (PLL_ESC_EVERY == 0) ? 8'd0
                         : ((esc_phase_r >= 8'(PLL_ESC_EVERY - 1)) ? 8'd0 : esc_phase_r + 8'd1);
            state       <= S_IDLE;
          end else begin
            rst_cnt <= rst_cnt - 1'b1;
          end
        end

        default: state <= S_IDLE;
      endcase

      if (state == S_XFER) begin
        link_up_r <= 1'b1;
        fall_cnt  <= CFMW'(LINK_CONFIRM_N);
      end else if (link_up_r) begin
        if (fall_cnt == '0) link_up_r <= 1'b0;
        else                fall_cnt  <= fall_cnt - 1'b1;
      end
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

  assign rx_datapath_reset   = rx_dp_reset_r;
  assign rx_pll_datapath_reset = rx_pll_dp_reset_r;
  assign gt_all_reset_req      = gt_all_reset_r;
  assign rx_serdes_reset_req = rx_serdes_req_r;
  assign rx_flush_req        = rx_flush_req_r;
  assign rx_datapath_reset_ports = (rx_dp_reset_r || rx_pll_dp_reset_r) ? port_group_mask : '0;
  assign repair_count        = repair_cnt_r;
  assign repair_tmo_count    = repair_tmo_cnt_r;

  assign tx_rst_seg          = tx_rst_r;
  assign link_up             = (state == S_XFER);
  assign carrier             = link_up_r;
  assign reset_ack           = reset_ack_r;
  assign fsm_state           = state;
endmodule
