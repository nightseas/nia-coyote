// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gt_rst_req_gate #(

  parameter int PULSE_CYC    = 64,

  parameter int SETTLE_CYC   = 250000,

  parameter int DONE_TMO_CYC = 50000000,

  parameter int EN_GATE      = 1,

  parameter int SYNC_DONE    = 0
)(
  input  wire        clk,
  input  wire        rstn,

  input  wire        req_level,

  input  wire        gt_reset_done,
  input  wire        seq_busy,

  output wire        req_pulse,

  output wire [1:0]  sts_state,
  output wire        sts_stuck,
  output wire        sts_refused,
  output wire [3:0]  sts_refuse_cnt,
  input  wire        clr_status
);

  initial begin
    if (PULSE_CYC < 8) begin
      $fatal(1, "gt_rst_req_gate: violated - PULSE_CYC=%0d < 8 (PG442 p.14 'Wait for 8 clocks')", PULSE_CYC);
    end
    if (DONE_TMO_CYC <= SETTLE_CYC) begin
      $fatal(1, "gt_rst_req_gate: violated - DONE_TMO_CYC=%0d <= SETTLE_CYC=%0d", DONE_TMO_CYC, SETTLE_CYC);
    end
  end

  localparam int CW = (DONE_TMO_CYC > SETTLE_CYC) ? $clog2(DONE_TMO_CYC + 1)
                                                  : $clog2(SETTLE_CYC + 1);

  localparam logic [1:0] S_IDLE = 2'd0, S_PULSE = 2'd1, S_WAITD = 2'd2, S_HOLD = 2'd3;

  wire done_q;
  generate
  if (SYNC_DONE != 0) begin : g_sync_done

    dcmac_sync2 #(.WIDTH(1), .STAGES(2), .INIT(1'b0)) u_sync (
      .clk(clk), .din(gt_reset_done), .dout(done_q)
    );
  end else begin : g_done_direct
    assign done_q = gt_reset_done;
  end
  endgenerate

  logic [1:0]    state_r   = S_IDLE;
  logic [CW-1:0] cnt_r     = '0;
  logic          arm_r     = 1'b1;
  logic          pulse_r   = 1'b0;
  logic          stuck_r   = 1'b0;
  logic          refused_r = 1'b0;
  logic [3:0]    rcnt_r    = 4'd0;
  logic          done_1d   = 1'b0;
  logic          req_1d    = 1'b0;

  wire done_rise = done_q & ~done_1d;

  wire req_rise  = req_level & ~req_1d;
  wire want      = req_rise & arm_r;

  wire allow     = done_q & ~seq_busy & ~stuck_r;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      state_r   <= S_IDLE;
      cnt_r     <= '0;
      arm_r     <= 1'b1;
      pulse_r   <= 1'b0;
      stuck_r   <= 1'b0;
      refused_r <= 1'b0;
      rcnt_r    <= 4'd0;
      done_1d   <= 1'b0;
      req_1d    <= 1'b0;
    end else begin
      done_1d <= done_q;
      req_1d  <= req_level;

      if (!req_level) arm_r <= 1'b1;

      if (clr_status) begin
        stuck_r   <= 1'b0;
        refused_r <= 1'b0;
        rcnt_r    <= 4'd0;
      end

      case (state_r)

        S_IDLE: begin
          pulse_r <= 1'b0;
          if (want) begin
            arm_r <= 1'b0;
            if (allow) begin
              pulse_r <= 1'b1;
              cnt_r   <= CW'(PULSE_CYC - 1);
              state_r <= S_PULSE;
            end else begin

              refused_r <= 1'b1;
              if (rcnt_r != 4'hF) rcnt_r <= rcnt_r + 4'd1;
            end
          end
        end

        S_PULSE: begin

          if (cnt_r == '0) begin
            pulse_r <= 1'b0;
            cnt_r   <= CW'(DONE_TMO_CYC - 1);
            state_r <= S_WAITD;
          end else begin
            cnt_r <= cnt_r - 1'b1;
          end

          if (want) begin
            arm_r     <= 1'b0;
            refused_r <= 1'b1;
            if (rcnt_r != 4'hF) rcnt_r <= rcnt_r + 4'd1;
          end
        end

        S_WAITD: begin

          if (done_rise) begin
            cnt_r   <= CW'(SETTLE_CYC - 1);
            state_r <= S_HOLD;
          end else if (cnt_r == '0) begin
            stuck_r <= 1'b1;
            state_r <= S_IDLE;
          end else begin
            cnt_r <= cnt_r - 1'b1;
          end
          if (want) begin
            arm_r     <= 1'b0;
            refused_r <= 1'b1;
            if (rcnt_r != 4'hF) rcnt_r <= rcnt_r + 4'd1;
          end
        end

        S_HOLD: begin
          if (cnt_r == '0) state_r <= S_IDLE;
          else             cnt_r   <= cnt_r - 1'b1;
          if (want) begin
            arm_r     <= 1'b0;
            refused_r <= 1'b1;
            if (rcnt_r != 4'hF) rcnt_r <= rcnt_r + 4'd1;
          end
        end
        default: state_r <= S_IDLE;
      endcase
    end
  end

  assign req_pulse      = (EN_GATE != 0) ? pulse_r : req_level;
  assign sts_state      = state_r;
  assign sts_stuck      = stuck_r;
  assign sts_refused    = refused_r;
  assign sts_refuse_cnt = rcnt_r;

endmodule

`resetall
