// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`default_nettype none

module dcmac_link_sample #(

  parameter int CYC_PER_US      = 250,
  parameter int CYC_PER_MS      = 250000,

  parameter int T_SAMPLE_MS     = 50,
  parameter int T_ERR_MS        = 10,

  parameter int LINK_WDT_MS     = 750,
  parameter int LINK_WDT_MS_MIN = 10,
  parameter int LINK_WDT_MS_MAX = 60000,

  parameter int N_BUS_ERR       = 16,

  parameter int T_ACK_TMO_US    = 1000,

  parameter int AW              = 20,
  parameter int A_ALIGN_ADDR    = 0,
  parameter int A_FAULT_ADDR    = 0,
  parameter logic [31:0]  ALIGN_MASK = 32'h0000_0005
) (
  input  wire        clk,
  input  wire        rstn,

  input  wire        enable,

  input  wire [15:0] wdt_ms,

  output wire            req_valid,
  output wire            req_write,
  output wire [AW-1:0]   req_addr,
  output wire [31:0]     req_mask,
  input  wire            req_gnt,
  input  wire            req_ack,

  input  wire [31:0]     ack_rdata,
  input  wire            ack_aligned,
  input  wire            ack_err,

  output wire        aligned,
  output wire        valid,
  output wire [31:0] align_word,
  output wire [31:0] align_sticky,
  output wire [3:0]  fault,
  output wire        remote_fault,
  output wire        recv_local_fault,

  output wire        reset_req,

  input  wire        reset_ack,

  output wire        bus_stuck,

  output wire [15:0] sample_count,
  output wire [15:0] esc_count,
  output wire [15:0] bus_err_count,
  output wire        ever_aligned,
  output wire        window_running,

  output wire        last_was_fault,

  output wire [39:0] window_remaining
);

  initial begin
    if (CYC_PER_US < 1)
      $fatal(1, "dcmac_link_sample: CYC_PER_US must be >= 1");
    if (CYC_PER_MS < CYC_PER_US)
      $fatal(1, "dcmac_link_sample: CYC_PER_MS (%0d) < CYC_PER_US (%0d)", CYC_PER_MS, CYC_PER_US);

    if (T_SAMPLE_MS < 1)
      $fatal(1, "dcmac_link_sample: T_SAMPLE_MS must be >= 1 (got %0d)", T_SAMPLE_MS);
    if (T_SAMPLE_MS * 2 > LINK_WDT_MS)
      $fatal(1, "dcmac_link_sample: T_SAMPLE_MS (%0d) x 2 > LINK_WDT_MS (%0d) - the window could expire with no sample in it",
             T_SAMPLE_MS, LINK_WDT_MS);
    if (T_ERR_MS < 1)
      $fatal(1, "dcmac_link_sample: T_ERR_MS must be >= 1");
    if (LINK_WDT_MS < LINK_WDT_MS_MIN || LINK_WDT_MS > LINK_WDT_MS_MAX)
      $fatal(1, "dcmac_link_sample: LINK_WDT_MS=%0d outside [%0d,%0d]",
             LINK_WDT_MS, LINK_WDT_MS_MIN, LINK_WDT_MS_MAX);
    if (N_BUS_ERR < 1)
      $fatal(1, "dcmac_link_sample: N_BUS_ERR must be >= 1");

    if (T_ACK_TMO_US < 1)
      $fatal(1, "dcmac_link_sample: T_ACK_TMO_US must be >= 1");
    if (A_ALIGN_ADDR == A_FAULT_ADDR)
      $fatal(1, "dcmac_link_sample: A_ALIGN_ADDR and A_FAULT_ADDR must differ - two are read");
    if (ALIGN_MASK == 32'h0)
      $fatal(1, "dcmac_link_sample: ALIGN_MASK must be non-zero, else every read reports aligned");
  end

  localparam int CW = 40;

  localparam logic [AW-1:0] A_ALIGN = AW'(A_ALIGN_ADDR);
  localparam logic [AW-1:0] A_FAULT = AW'(A_FAULT_ADDR);

  wire [CW-1:0] gap_cyc  = CW'(T_SAMPLE_MS) * CW'(CYC_PER_MS);
  wire [CW-1:0] err_cyc  = CW'(T_ERR_MS) * CW'(CYC_PER_MS);

  typedef enum logic [2:0] {
    S_OFF   = 3'd0,
    S_RD_A  = 3'd1,
    S_RD_F  = 3'd2,
    S_GAP   = 3'd3,
    S_EGAP  = 3'd4
  } st_e;

  st_e          st;
  logic [CW-1:0] gap_r;

  logic         aligned_r;
  logic         valid_r;
  logic [31:0]  align_word_r;
  logic [31:0]  align_sticky_r;
  logic [3:0]   fault_r;
  logic         ever_aligned_r;

  logic          reset_req_r;

  localparam int ACK_TMO_CYC = T_ACK_TMO_US * CYC_PER_US;
  logic [31:0]   ack_tmo_r;
  logic          ack_tmo_hit;

  logic [15:0]   bus_err_r;
  logic          bus_stuck_r;

  logic [15:0]   sample_cnt_r, esc_cnt_r, bus_err_cnt_r;

  logic req_valid_r;

  wire is_rd_a = (st == S_RD_A);

  assign req_valid = req_valid_r;
  assign req_write = 1'b0;
  assign req_addr  = is_rd_a ? A_ALIGN : A_FAULT;
  assign req_mask  = is_rd_a ? ALIGN_MASK : 32'h0;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st            <= S_OFF;
      gap_r         <= '0;
      req_valid_r   <= 1'b0;
      aligned_r     <= 1'b0;
      valid_r       <= 1'b0;
      fault_r       <= '0;
      ever_aligned_r<= 1'b0;
      reset_req_r   <= 1'b0;
      bus_err_r     <= '0;
      bus_stuck_r   <= 1'b0;
      ack_tmo_r     <= 32'(ACK_TMO_CYC);
      ack_tmo_hit   <= 1'b0;
      sample_cnt_r  <= '0;
      esc_cnt_r     <= '0;
      bus_err_cnt_r <= '0;
      align_word_r  <= '0;
      align_sticky_r<= '0;
    end else if (!enable) begin

      st            <= S_OFF;
      req_valid_r   <= 1'b0;
      aligned_r     <= 1'b0;
      valid_r       <= 1'b0;
      fault_r       <= '0;
      ever_aligned_r<= 1'b0;
      reset_req_r   <= 1'b0;
      bus_err_r     <= '0;
      bus_stuck_r   <= 1'b0;
      align_word_r  <= '0;
      align_sticky_r<= '0;
    end else begin

      if (wdt_timeout && valid_r && !aligned_r) begin
        reset_req_r <= 1'b1;
        esc_cnt_r   <= esc_cnt_r + 16'd1;
      end

      if (reset_ack) reset_req_r <= 1'b0;

      ack_tmo_hit <= 1'b0;
      if ((st != S_RD_A) && (st != S_RD_F)) begin
        ack_tmo_r <= 32'(ACK_TMO_CYC);
      end else if (req_ack) begin
        ack_tmo_r <= 32'(ACK_TMO_CYC);
      end else if (ack_tmo_r != '0) begin
        ack_tmo_r <= ack_tmo_r - 32'd1;
        if (ack_tmo_r == 32'd1) ack_tmo_hit <= 1'b1;
      end

      case (st)
        S_OFF: begin
          req_valid_r <= 1'b1;
          st          <= S_RD_A;
        end

        S_RD_A: begin
          if (req_gnt) req_valid_r <= 1'b0;

          if (req_ack || ack_tmo_hit) begin
            if (ack_err || ack_tmo_hit) begin

              bus_err_r     <= bus_err_r + 16'd1;
              bus_err_cnt_r <= bus_err_cnt_r + 16'd1;
              req_valid_r   <= 1'b0;
              if (bus_err_r >= 16'(N_BUS_ERR - 1)) bus_stuck_r <= 1'b1;
              gap_r <= err_cyc;
              st    <= S_EGAP;
            end else begin
              bus_err_r    <= '0;
              bus_stuck_r  <= 1'b0;
              aligned_r    <= ack_aligned;
              align_word_r <= ack_rdata;
              align_sticky_r <= align_sticky_r | ack_rdata;
              valid_r      <= 1'b1;
              sample_cnt_r <= sample_cnt_r + 16'd1;

              if (ack_aligned) ever_aligned_r <= 1'b1;
              req_valid_r <= 1'b1;
              st          <= S_RD_F;
            end
          end
        end

        S_RD_F: begin
          if (req_gnt) req_valid_r <= 1'b0;

          if (req_ack || ack_tmo_hit) begin
            if (ack_err || ack_tmo_hit) begin
              bus_err_r     <= bus_err_r + 16'd1;
              bus_err_cnt_r <= bus_err_cnt_r + 16'd1;
              req_valid_r   <= 1'b0;
              if (bus_err_r >= 16'(N_BUS_ERR - 1)) bus_stuck_r <= 1'b1;
              gap_r <= err_cyc;
              st    <= S_EGAP;
            end else begin
              bus_err_r   <= '0;
              bus_stuck_r <= 1'b0;
              fault_r     <= ack_rdata[3:0];
              gap_r       <= gap_cyc;
              st          <= S_GAP;
            end
          end
        end

        S_GAP: begin
          if (gap_r == '0) begin
            req_valid_r <= 1'b1;
            st          <= S_RD_A;
          end else begin
            gap_r <= gap_r - 1'b1;
          end
        end

        S_EGAP: begin
          if (gap_r == '0) begin
            req_valid_r <= 1'b1;
            st          <= S_RD_A;
          end else begin
            gap_r <= gap_r - 1'b1;
          end
        end

        default: st <= S_OFF;
      endcase
    end
  end

  wire          wdt_timeout;
  wire          wdt_running;
  wire [39:0]   wdt_remaining;

  localparam int WDT_MS_MIN_EFF = (LINK_WDT_MS_MIN > (2 * T_SAMPLE_MS))
                                ? LINK_WDT_MS_MIN : (2 * T_SAMPLE_MS);

  wdt #(
    .CYC_PER_MS (CYC_PER_MS),
    .MS_DEFAULT (LINK_WDT_MS),
    .MS_MIN     (WDT_MS_MIN_EFF),
    .MS_MAX     (LINK_WDT_MS_MAX),
    .CW         (40)
  ) u_wdt (
    .clk       (clk),
    .rstn      (rstn && enable),
    .ms        (wdt_ms),
    .en        (valid_r),
    .clear     (aligned_r),
    .timeout   (wdt_timeout),
    .running   (wdt_running),
    .remaining (wdt_remaining)
  );

  assign aligned          = aligned_r;
  assign valid            = valid_r;
  assign align_word       = align_word_r;
  assign align_sticky     = align_sticky_r;
  assign fault            = fault_r;
  assign remote_fault     = fault_r[0];
  assign recv_local_fault = fault_r[3];
  assign reset_req        = reset_req_r;
  assign bus_stuck        = bus_stuck_r;
  assign sample_count     = sample_cnt_r;
  assign esc_count        = esc_cnt_r;
  assign bus_err_count    = bus_err_cnt_r;
  assign ever_aligned     = ever_aligned_r;
  assign window_running   = wdt_running;

  assign last_was_fault   = (st == S_RD_F) || (st == S_GAP);
  assign window_remaining = wdt_remaining;

endmodule

`default_nettype wire
