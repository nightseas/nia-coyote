// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`default_nettype none

module dcmac_link_wdt #(

  parameter int CYC_PER_MS      = 250000,

  parameter int LINK_WDT_MS     = 750,
  parameter int LINK_WDT_MS_MIN = 10,
  parameter int LINK_WDT_MS_MAX = 60000,

  parameter int LINK_CONFIRM_N  = 2,

  parameter int ESC_MAX_STAGE   = 3,
  parameter int T_RXDP_MS       = 100,
  parameter int T_SETTLE_MS     = 10,
  parameter int T_ERR_MS        = 10
) (
  input  wire        clk,
  input  wire        rstn,

  input  wire        enable,

  input  wire [15:0] wdt_ms,

  output wire        poll_req,
  input  wire        poll_gnt,
  input  wire        poll_ack,
  input  wire        poll_aligned,
  input  wire        poll_err,

  output wire        link_up,
  output wire        link_live,
  output wire [15:0] up_events,
  output wire [15:0] dn_events,

  output wire        fault_diag,

  output wire        esc_rx_dp_reset,
  output wire        esc_gt_tx_reset,
  output wire        esc_gt_rx_reset,
  output wire        esc_bringup_req,
  output wire [1:0]  esc_stage,
  output wire [15:0] esc_count,
  output wire        supervising
);

  initial begin
    if (LINK_CONFIRM_N < 1)
      $fatal(1, "dcmac_link_wdt: LINK_CONFIRM_N must be >= 1 (got %0d)", LINK_CONFIRM_N);
    if (ESC_MAX_STAGE < 1 || ESC_MAX_STAGE > 3)
      $fatal(1, "dcmac_link_wdt: ESC_MAX_STAGE must be 1..3 (got %0d)", ESC_MAX_STAGE);
    if (LINK_WDT_MS < LINK_WDT_MS_MIN || LINK_WDT_MS > LINK_WDT_MS_MAX)
      $fatal(1, "dcmac_link_wdt: LINK_WDT_MS=%0d outside [%0d,%0d]",
             LINK_WDT_MS, LINK_WDT_MS_MIN, LINK_WDT_MS_MAX);
    if (CYC_PER_MS < 1)
      $fatal(1, "dcmac_link_wdt: CYC_PER_MS must be >= 1");
  end

  localparam int CW = 40;
  localparam int CFMW = (LINK_CONFIRM_N < 2) ? 1 : $clog2(LINK_CONFIRM_N + 1);

  wire [15:0] ms_eff = (wdt_ms == 16'd0) ? 16'(LINK_WDT_MS) : wdt_ms;
  wire [CW-1:0] wdt_cyc = CW'(ms_eff) * CW'(CYC_PER_MS);
  wire [CW-1:0] rxdp_cyc = CW'(T_RXDP_MS) * CW'(CYC_PER_MS);
  wire [CW-1:0] stl_cyc = CW'(T_SETTLE_MS) * CW'(CYC_PER_MS);
  wire [CW-1:0] err_cyc = CW'(T_ERR_MS) * CW'(CYC_PER_MS);

  typedef enum logic [3:0] {
    S_OFF      = 4'd0,
    S_WINDOW   = 4'd1,
    S_POLL     = 4'd2,
    S_E1_HOLD  = 4'd3,
    S_E2_TX    = 4'd4,
    S_E2_STL   = 4'd5,
    S_E2_RX    = 4'd6,
    S_E3_PULSE = 4'd7,
    S_ERRWAIT  = 4'd8
  } state_e;

  state_e            st;
  logic [CW-1:0]     tmr;
  logic              up_r, live_r;
  logic [CFMW-1:0]   cfm_r;
  logic [1:0]        stage_r;
  logic [1:0]        esc_stage_r;
  logic [15:0]       upev_r, dnev_r, escn_r;
  logic              fault_r;
  logic              req_r;
  logic              rxdp_r, gttx_r, gtrx_r, brup_r;
  logic              first_poll_r;

  wire cfm_reached = (LINK_CONFIRM_N <= 1) ? 1'b1
                                           : (cfm_r >= CFMW'(LINK_CONFIRM_N - 1));

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st           <= S_OFF;
      tmr          <= '0;
      up_r         <= 1'b0;
      live_r       <= 1'b0;
      cfm_r        <= '0;
      stage_r      <= 2'd1;
      esc_stage_r  <= 2'd0;
      upev_r       <= '0;
      dnev_r       <= '0;
      escn_r       <= '0;
      fault_r      <= 1'b0;
      req_r        <= 1'b0;
      rxdp_r       <= 1'b0;
      gttx_r       <= 1'b0;
      gtrx_r       <= 1'b0;
      brup_r       <= 1'b0;
      first_poll_r <= 1'b1;
    end else if (!enable) begin

      st           <= S_OFF;
      up_r         <= 1'b0;
      live_r       <= 1'b0;
      cfm_r        <= '0;
      stage_r      <= 2'd1;
      esc_stage_r  <= 2'd0;
      req_r        <= 1'b0;
      rxdp_r       <= 1'b0;
      gttx_r       <= 1'b0;
      gtrx_r       <= 1'b0;
      brup_r       <= 1'b0;
      first_poll_r <= 1'b1;
      tmr          <= '0;
    end else begin
      brup_r <= 1'b0;

      unique case (st)

        S_OFF: begin

          req_r        <= 1'b1;
          first_poll_r <= 1'b0;
          st           <= S_POLL;
        end

        S_WINDOW: begin
          if (tmr <= 1) begin
            req_r <= 1'b1;
            st    <= S_POLL;
          end else begin
            tmr <= tmr - 1'b1;
          end
        end

        S_POLL: begin
          if (poll_gnt) req_r <= 1'b0;
          if (poll_ack) begin
            req_r <= 1'b0;
            if (poll_err) begin

              tmr <= err_cyc;
              st  <= S_ERRWAIT;
            end else if (poll_aligned) begin

              live_r  <= 1'b1;
              cfm_r   <= '0;
              stage_r <= 2'd1;
              if (!up_r) begin
                up_r   <= 1'b1;
                upev_r <= (upev_r == 16'hFFFF) ? upev_r : upev_r + 16'd1;
              end
              tmr <= wdt_cyc;
              st  <= S_WINDOW;
            end else begin

              live_r <= 1'b0;
              if (up_r) begin

                if (cfm_reached) begin
                  up_r   <= 1'b0;
                  cfm_r  <= '0;
                  dnev_r <= (dnev_r == 16'hFFFF) ? dnev_r : dnev_r + 16'd1;
                end else begin
                  cfm_r <= cfm_r + 1'b1;
                end
              end

              fault_r <= 1'b1;
              escn_r  <= (escn_r == 16'hFFFF) ? escn_r : escn_r + 16'd1;
              esc_stage_r <= stage_r;
              unique case (stage_r)
                2'd1: begin rxdp_r <= 1'b1; tmr <= rxdp_cyc; st <= S_E1_HOLD; end
                2'd2: begin gttx_r <= 1'b1; tmr <= rxdp_cyc; st <= S_E2_TX;   end
                default: begin brup_r <= 1'b1; tmr <= rxdp_cyc; st <= S_E3_PULSE; end
              endcase
            end
          end
        end

        S_E1_HOLD: begin
          if (tmr <= 1) begin
            rxdp_r      <= 1'b0;
            esc_stage_r <= 2'd0;
            stage_r     <= (2'd1 < 2'(ESC_MAX_STAGE)) ? 2'd2 : 2'd1;
            tmr         <= wdt_cyc;
            st          <= S_WINDOW;
          end else tmr <= tmr - 1'b1;
        end

        S_E2_TX: begin
          if (tmr <= 1) begin
            gttx_r <= 1'b0;
            tmr    <= stl_cyc;
            st     <= S_E2_STL;
          end else tmr <= tmr - 1'b1;
        end
        S_E2_STL: begin
          if (tmr <= 1) begin
            gtrx_r <= 1'b1;
            tmr    <= rxdp_cyc;
            st     <= S_E2_RX;
          end else tmr <= tmr - 1'b1;
        end
        S_E2_RX: begin
          if (tmr <= 1) begin
            gtrx_r      <= 1'b0;
            esc_stage_r <= 2'd0;
            stage_r     <= (2'd2 < 2'(ESC_MAX_STAGE)) ? 2'd3 : 2'd2;
            tmr         <= wdt_cyc;
            st          <= S_WINDOW;
          end else tmr <= tmr - 1'b1;
        end

        S_E3_PULSE: begin
          if (tmr <= 1) begin
            esc_stage_r <= 2'd0;

            stage_r     <= 2'(ESC_MAX_STAGE);
            tmr         <= wdt_cyc;
            st          <= S_WINDOW;
          end else tmr <= tmr - 1'b1;
        end

        S_ERRWAIT: begin
          if (tmr <= 1) begin
            req_r <= 1'b1;
            st    <= S_POLL;
          end else tmr <= tmr - 1'b1;
        end

        default: st <= S_OFF;
      endcase
    end
  end

  assign poll_req        = req_r;
  assign link_up         = up_r;
  assign link_live       = live_r;
  assign up_events       = upev_r;
  assign dn_events       = dnev_r;
  assign fault_diag      = fault_r;
  assign esc_rx_dp_reset = rxdp_r;
  assign esc_gt_tx_reset = gttx_r;
  assign esc_gt_rx_reset = gtrx_r;
  assign esc_bringup_req = brup_r;
  assign esc_stage       = esc_stage_r;
  assign esc_count       = escn_r;
  assign supervising     = (st == S_WINDOW) || (st == S_POLL);

  wire _unused_first = first_poll_r;

endmodule

`default_nettype wire
