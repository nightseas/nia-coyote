// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module dcmac_seg_axis_rx #(
  parameter int N_SEG     = 2,
  parameter int SEG_W     = 128,
  parameter int OUT_DEPTH = 16,
  parameter bit IN_REG    = 1
)(
  input  logic                       clk,
  input  logic                       rstn,

  input  logic                       rx_seg_valid,
  input  logic [N_SEG*SEG_W-1:0]     rx_seg_dat,
  input  logic [N_SEG-1:0]           rx_seg_ena,
  input  logic [N_SEG-1:0]           rx_seg_sop,
  input  logic [N_SEG-1:0]           rx_seg_eop,
  input  logic [N_SEG-1:0]           rx_seg_err,
  input  logic [N_SEG*4-1:0]         rx_seg_mty,

  output logic [N_SEG*SEG_W-1:0]     m_axis_tdata,
  output logic [N_SEG*SEG_W/8-1:0]   m_axis_tkeep,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       m_axis_tlast,
  output logic                       m_axis_tuser,
  output logic                       rx_align_drop,
  output logic [31:0]                rx_align_stat
);
  localparam int SEG_B    = SEG_W/8;
  localparam int BEAT_B   = N_SEG*SEG_B;
  localparam int CNT_W    = $clog2(N_SEG+1);
  localparam int PTR_W    = (OUT_DEPTH > 1) ? $clog2(OUT_DEPTH) : 1;
  localparam int OCC_W    = $clog2(OUT_DEPTH+1);
  localparam int MAX_EMIT = 2;

  initial begin
    if (N_SEG > 4)
      $fatal(1, "dcmac_seg_axis_rx: N_SEG=%0d - this module supports 4 or fewer. At N_SEG of 8 two frames can complete in one segmented cycle, PG369 p119, which requires three beats to be assembled in one cycle and MAX_EMIT is 2 (instance %m)", N_SEG);
    if (OUT_DEPTH < 2)
      $fatal(1, "dcmac_seg_axis_rx: OUT_DEPTH=%0d - a cycle can complete two beats, so the queue holds 2 or more (instance %m)", OUT_DEPTH);
    if (OUT_DEPTH != (1 << PTR_W))
      $fatal(1, "dcmac_seg_axis_rx: OUT_DEPTH=%0d is not a power of two - the queue pointers are PTR_W=%0d bits and wrap at %0d, while q_space is computed against OUT_DEPTH, so the addressing and the occupancy disagree (instance %m)", OUT_DEPTH, PTR_W, 1 << PTR_W);
    if (SEG_W % 8 != 0)
      $fatal(1, "dcmac_seg_axis_rx: SEG_W=%0d is not a multiple of 8 (instance %m)", SEG_W);
  end

  logic                   seg_valid;
  logic [N_SEG*SEG_W-1:0] seg_dat;
  logic [N_SEG-1:0]       seg_ena;
  logic [N_SEG-1:0]       seg_sop;
  logic [N_SEG-1:0]       seg_eop;
  logic [N_SEG-1:0]       seg_err;
  logic [N_SEG*4-1:0]     seg_mty;

  if (IN_REG) begin : g_seg_in_reg
    always_ff @(posedge clk) begin
      if (!rstn) begin
        seg_valid <= 1'b0;
      end else begin
        seg_valid <= rx_seg_valid;
      end
      seg_dat <= rx_seg_dat;
      seg_ena <= rx_seg_ena;
      seg_sop <= rx_seg_sop;
      seg_eop <= rx_seg_eop;
      seg_err <= rx_seg_err;
      seg_mty <= rx_seg_mty;
    end
  end else begin : g_seg_in_comb
    always_comb begin
      seg_valid = rx_seg_valid;
      seg_dat   = rx_seg_dat;
      seg_ena   = rx_seg_ena;
      seg_sop   = rx_seg_sop;
      seg_eop   = rx_seg_eop;
      seg_err   = rx_seg_err;
      seg_mty   = rx_seg_mty;
    end
  end

  logic [SEG_W-1:0] asm_dat [N_SEG];
  logic [CNT_W-1:0] asm_cnt;
  logic             asm_err;

  logic [SEG_W-1:0] nxt_dat [N_SEG];
  logic [CNT_W-1:0] nxt_cnt;
  logic             nxt_err;

  logic                   sop_abort;
  logic [1:0]             emit_n;
  logic [N_SEG*SEG_W-1:0] e_dat  [MAX_EMIT];
  logic [BEAT_B-1:0]      e_keep [MAX_EMIT];
  logic [MAX_EMIT-1:0]    e_last;
  logic [MAX_EMIT-1:0]    e_user;

  always_comb begin
    logic [CNT_W-1:0] fill;
    logic [3:0]       mty_s;
    int               nbytes;
    int               slot;

    for (int s = 0; s < N_SEG; s++) nxt_dat[s] = asm_dat[s];
    nxt_cnt   = asm_cnt;
    nxt_err   = asm_err;
    emit_n    = '0;
    e_last    = '0;
    e_user    = '0;
    sop_abort = 1'b0;
    for (int e = 0; e < MAX_EMIT; e++) begin
      e_dat[e]  = '0;
      e_keep[e] = '0;
    end
    fill   = '0;
    mty_s  = '0;
    nbytes = SEG_B;
    slot   = 0;

    if (seg_valid) begin
      for (int s = 0; s < N_SEG; s++) begin
        if (seg_ena[s]) begin
          if (seg_sop[s]) begin
            if (nxt_cnt != '0) sop_abort = 1'b1;
            nxt_cnt = '0;
            nxt_err = 1'b0;
          end
          nxt_dat[nxt_cnt] = seg_dat[s*SEG_W +: SEG_W];
          nxt_err          = nxt_err | seg_err[s];
          fill             = nxt_cnt + 1'b1;
          nxt_cnt          = fill;
          if (seg_eop[s] || (int'(fill) == N_SEG)) begin
            mty_s  = seg_mty[s*4 +: 4];
            nbytes = seg_eop[s] ? (SEG_B - int'(mty_s)) : SEG_B;
            slot   = int'(emit_n);
            if (slot < MAX_EMIT) begin
              e_last[slot] = seg_eop[s];
              e_user[slot] = nxt_err;
              for (int t = 0; t < N_SEG; t++) begin
                e_dat[slot][t*SEG_W +: SEG_W] = nxt_dat[t];
                if (int'(fill) > (t + 1))
                  e_keep[slot][t*SEG_B +: SEG_B] = {SEG_B{1'b1}};
                else if (int'(fill) == (t + 1))
                  e_keep[slot][t*SEG_B +: SEG_B] = ({SEG_B{1'b1}} >> (SEG_B - nbytes));
              end
              emit_n = emit_n + 1'b1;
            end
            nxt_cnt = '0;
            nxt_err = 1'b0;
          end
        end
      end
    end
  end

  logic [N_SEG*SEG_W-1:0] q_dat  [OUT_DEPTH];
  logic [BEAT_B-1:0]      q_keep [OUT_DEPTH];
  logic                   q_last [OUT_DEPTH];
  logic                   q_user [OUT_DEPTH];
  logic [PTR_W-1:0]       q_wr, q_rd;
  logic [OCC_W-1:0]       q_occ;
  logic                   pend_err;
  logic [15:0]            drop_cnt;
  logic [15:0]            abort_cnt;

  wire             q_pop   = m_axis_tvalid & m_axis_tready;
  wire [OCC_W-1:0] q_space = OCC_W'(OUT_DEPTH) - q_occ;
  wire [1:0]       q_push_n = (q_space >= OCC_W'(2)) ? emit_n :
                              (q_space == OCC_W'(1)) ? ((emit_n != '0) ? 2'd1 : 2'd0) : 2'd0;
  wire [1:0]       q_drop_n = emit_n - q_push_n;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      asm_cnt       <= '0;
      asm_err       <= 1'b0;
      q_wr          <= '0;
      q_rd          <= '0;
      q_occ         <= '0;
      pend_err      <= 1'b0;
      rx_align_drop <= 1'b0;
      drop_cnt      <= '0;
      abort_cnt     <= '0;
    end else begin
      for (int s = 0; s < N_SEG; s++) asm_dat[s] <= nxt_dat[s];
      asm_cnt <= nxt_cnt;
      asm_err <= nxt_err;

      for (int e = 0; e < MAX_EMIT; e++) begin
        if (e < int'(q_push_n)) begin
          q_dat [PTR_W'(q_wr + PTR_W'(e))] <= e_dat[e];
          q_keep[PTR_W'(q_wr + PTR_W'(e))] <= e_keep[e];
          q_last[PTR_W'(q_wr + PTR_W'(e))] <= e_last[e];
          q_user[PTR_W'(q_wr + PTR_W'(e))] <= e_user[e] | pend_err;
          if (e_last[e]) pend_err <= 1'b0;
        end
      end
      q_wr <= q_wr + PTR_W'(q_push_n);

      if (q_drop_n != '0 || sop_abort) begin
        pend_err      <= 1'b1;
        rx_align_drop <= 1'b1;
      end
      if (q_drop_n != '0 && drop_cnt != 16'hFFFF)  drop_cnt  <= drop_cnt + 16'(q_drop_n);
      if (sop_abort     && abort_cnt != 16'hFFFF)  abort_cnt <= abort_cnt + 16'd1;

      if (q_pop) q_rd <= q_rd + 1'b1;

      q_occ <= q_occ + OCC_W'(q_push_n) - (q_pop ? OCC_W'(1) : OCC_W'(0));
    end
  end

  assign m_axis_tvalid = (q_occ != '0);
  assign m_axis_tdata  = q_dat[q_rd];
  assign m_axis_tkeep  = q_keep[q_rd];
  assign m_axis_tlast  = q_last[q_rd];
  assign m_axis_tuser  = q_user[q_rd];
  assign rx_align_stat = {abort_cnt, drop_cnt};
endmodule

module dcmac_seg_axis_tx #(
  parameter int N_SEG = 2,
  parameter int SEG_W = 128
)(
  input  logic                       clk,
  input  logic                       rstn,

  input  logic [N_SEG*SEG_W-1:0]     s_axis_tdata,
  input  logic [N_SEG*SEG_W/8-1:0]   s_axis_tkeep,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tuser,

  input  logic                       tx_seg_ready,
  output logic                       tx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]     tx_seg_dat,
  output logic [N_SEG-1:0]           tx_seg_ena,
  output logic [N_SEG-1:0]           tx_seg_sop,
  output logic [N_SEG-1:0]           tx_seg_eop,
  output logic [N_SEG-1:0]           tx_seg_err,
  output logic [N_SEG*4-1:0]         tx_seg_mty
);
  localparam int SEG_B = SEG_W/8;

  logic first_beat;
  always_ff @(posedge clk) begin
    if (!rstn)                              first_beat <= 1'b1;
    else if (s_axis_tvalid && s_axis_tready) first_beat <= s_axis_tlast;
  end

  logic [$clog2(N_SEG+1)-1:0] last_ena;
  always_comb begin
    last_ena = '0;
    for (int s = 0; s < N_SEG; s++)
      if (|s_axis_tkeep[s*SEG_B +: SEG_B]) last_ena = s[$clog2(N_SEG+1)-1:0];
  end

  logic                   c_valid;
  logic [N_SEG-1:0]       c_ena;
  logic [N_SEG-1:0]       c_sop;
  logic [N_SEG-1:0]       c_eop;
  logic [N_SEG-1:0]       c_err;
  logic [N_SEG*4-1:0]     c_mty;

  always_comb begin
    c_valid = s_axis_tvalid & (|s_axis_tkeep | ~first_beat);
    c_ena   = '0;
    c_sop   = '0;
    c_eop   = '0;
    c_err   = '0;
    c_mty   = '0;
    for (int s = 0; s < N_SEG; s++) begin
      logic [SEG_B-1:0] keepseg;
      logic             ena_s, eop_s;
      keepseg      = s_axis_tkeep[s*SEG_B +: SEG_B];
      ena_s        = |keepseg;
      eop_s        = s_axis_tlast & ena_s & (s == int'(last_ena));
      c_ena[s]     = ena_s;
      c_eop[s]     = eop_s;
      c_sop[s]     = first_beat & (s == 0) & ena_s;
      c_err[s]     = s_axis_tuser & eop_s;

      c_mty[s*4 +: 4] = eop_s ? (SEG_B[3:0] - $countones(keepseg)) : 4'd0;
    end
  end

  logic                     q_valid;
  logic [N_SEG*SEG_W-1:0]   q_dat;
  logic [N_SEG-1:0]         q_ena, q_sop, q_eop, q_err;
  logic [N_SEG*4-1:0]       q_mty;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      q_valid <= 1'b0;
      q_ena   <= '0;
      q_sop   <= '0;
      q_eop   <= '0;
      q_err   <= '0;
      q_mty   <= '0;
    end else if (tx_seg_ready) begin
      q_valid <= c_valid;
      q_dat   <= s_axis_tdata;
      q_ena   <= c_ena;
      q_sop   <= c_sop;
      q_eop   <= c_eop;
      q_err   <= c_err;
      q_mty   <= c_mty;
    end
  end

  assign tx_seg_valid = q_valid;
  assign tx_seg_dat   = q_dat;
  assign tx_seg_ena   = q_ena;
  assign tx_seg_sop   = q_sop;
  assign tx_seg_eop   = q_eop;
  assign tx_seg_err   = q_err;
  assign tx_seg_mty   = q_mty;

  assign s_axis_tready = tx_seg_ready;
endmodule

module dcmac_seg_axis_adapter #(
  parameter int N_SEG = 2,
  parameter int SEG_W = 128
)(
  input  logic                       clk,
  input  logic                       rstn,

  input  logic                       rx_seg_valid,
  input  logic [N_SEG*SEG_W-1:0]     rx_seg_dat,
  input  logic [N_SEG-1:0]           rx_seg_ena,
  input  logic [N_SEG-1:0]           rx_seg_sop,
  input  logic [N_SEG-1:0]           rx_seg_eop,
  input  logic [N_SEG-1:0]           rx_seg_err,
  input  logic [N_SEG*4-1:0]         rx_seg_mty,
  output logic [N_SEG*SEG_W-1:0]     m_axis_tdata,
  output logic [N_SEG*SEG_W/8-1:0]   m_axis_tkeep,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       m_axis_tlast,
  output logic                       m_axis_tuser,
  output logic                       rx_align_drop,
  output logic [31:0]                rx_align_stat,

  input  logic [N_SEG*SEG_W-1:0]     s_axis_tdata,
  input  logic [N_SEG*SEG_W/8-1:0]   s_axis_tkeep,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tuser,
  input  logic                       tx_seg_ready,
  output logic                       tx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]     tx_seg_dat,
  output logic [N_SEG-1:0]           tx_seg_ena,
  output logic [N_SEG-1:0]           tx_seg_sop,
  output logic [N_SEG-1:0]           tx_seg_eop,
  output logic [N_SEG-1:0]           tx_seg_err,
  output logic [N_SEG*4-1:0]         tx_seg_mty
);
  dcmac_seg_axis_rx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_rx (
    .clk, .rstn,
    .rx_seg_valid, .rx_seg_dat, .rx_seg_ena, .rx_seg_sop, .rx_seg_eop, .rx_seg_err, .rx_seg_mty,
    .m_axis_tdata, .m_axis_tkeep, .m_axis_tvalid, .m_axis_tready, .m_axis_tlast, .m_axis_tuser,
    .rx_align_drop, .rx_align_stat
  );

  dcmac_seg_axis_tx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_tx (
    .clk, .rstn,
    .s_axis_tdata, .s_axis_tkeep, .s_axis_tvalid, .s_axis_tready, .s_axis_tlast, .s_axis_tuser,
    .tx_seg_ready, .tx_seg_valid, .tx_seg_dat, .tx_seg_ena, .tx_seg_sop, .tx_seg_eop, .tx_seg_err, .tx_seg_mty
  );
endmodule
