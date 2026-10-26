// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module dcmac_axis_frame_fifo #(
  parameter int DATA_W         = 512,
  parameter int KEEP_W         = DATA_W/8,
  parameter int USER_W         = 1,
  parameter int ADDR_W         = 9,
  parameter bit DROP_BAD_FRAME = 1'b0,
  parameter bit FLAG_BAD_FRAME = 1'b0,
  parameter bit DROP_WHEN_FULL = 1'b0,
  parameter int MAX_FRAME_BEATS = 0,
  parameter     MEM_STYLE      = "distributed"
)(
  input  logic               clk,
  input  logic               rstn,

  input  logic               abort,

  input  logic [DATA_W-1:0]  s_axis_tdata,
  input  logic [KEEP_W-1:0]  s_axis_tkeep,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  input  logic               s_axis_tlast,
  input  logic [USER_W-1:0]  s_axis_tuser,

  output logic [DATA_W-1:0]  m_axis_tdata,
  output logic [KEEP_W-1:0]  m_axis_tkeep,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready,
  output logic               m_axis_tlast,
  output logic [USER_W-1:0]  m_axis_tuser,

  output logic [31:0]        drop_frames,
  output logic               overflow
);
  localparam int DEPTH = 1 << ADDR_W;
  localparam int W     = DATA_W + KEEP_W + 1 + USER_W;
  localparam bit BRAM  = (MEM_STYLE == "block");

  initial begin
    if (!DROP_WHEN_FULL && (MAX_FRAME_BEATS == 0 || MAX_FRAME_BEATS > DEPTH)) begin
      $error("Error: dcmac_axis_frame_fifo commits on tlast and back pressures when full, so a frame that alone fills the depth deadlocks the writer permanently: tlast can never arrive, wr_commit can never advance, and the reader drains to empty with used stuck at DEPTH. State the bound with MAX_FRAME_BEATS <= DEPTH, or set DROP_WHEN_FULL (instance %m)");
      $display("  ADDR_W=%0d DEPTH=%0d MAX_FRAME_BEATS=%0d DROP_WHEN_FULL=%0b",
               ADDR_W, DEPTH, MAX_FRAME_BEATS, DROP_WHEN_FULL);
      $finish;
    end
  end

  logic [W-1:0] mem [DEPTH];

  logic [ADDR_W:0] wr_cur;
  logic [ADDR_W:0] wr_commit;
  logic [ADDR_W:0] rd_ptr;

  logic            drop_frame;
  logic            err_seen;
  logic [31:0]     drop_cnt;
  logic            ovf;

  wire full = (wr_cur == (rd_ptr ^ {1'b1, {ADDR_W{1'b0}}}));

  assign s_axis_tready = DROP_WHEN_FULL ? 1'b1 : ~full;

  wire wr_fire  = s_axis_tvalid & s_axis_tready;
  wire wr_store = wr_fire & ~drop_frame & ~full;

  wire frame_err = s_axis_tuser[0] | err_seen;

  wire bad_eop  = DROP_BAD_FRAME & frame_err;
  wire kill     = drop_frame | (wr_fire & full) | (wr_fire & s_axis_tlast & bad_eop);

  logic [USER_W-1:0] wr_user;
  always_comb begin
    wr_user = s_axis_tuser;
    if (FLAG_BAD_FRAME) wr_user[0] = s_axis_tlast ? frame_err : 1'b0;
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr_cur     <= '0;
      wr_commit  <= '0;
      drop_frame <= 1'b0;
      err_seen   <= 1'b0;
      drop_cnt   <= '0;
      ovf        <= 1'b0;
    end else if (abort) begin
      wr_cur     <= wr_commit;
      drop_frame <= 1'b0;
      err_seen   <= 1'b0;
    end else begin
      if (wr_store) mem[wr_cur[ADDR_W-1:0]] <= {wr_user, s_axis_tlast,
                                                s_axis_tkeep, s_axis_tdata};
      if (wr_fire) begin
        if (s_axis_tlast) begin

          if (kill) begin
            wr_cur <= wr_commit;
            ovf    <= 1'b1;
            if (drop_cnt != 32'hFFFF_FFFF) drop_cnt <= drop_cnt + 1'b1;
          end else begin
            wr_cur    <= wr_cur + 1'b1;
            wr_commit <= wr_cur + 1'b1;
          end
          drop_frame <= 1'b0;
          err_seen   <= 1'b0;
        end else begin
          err_seen <= err_seen | s_axis_tuser[0];
          if (full)          drop_frame <= 1'b1;
          else if (!drop_frame) wr_cur   <= wr_cur + 1'b1;
        end
      end
    end
  end

  logic [W-1:0] rd_word;

  generate
  if (BRAM) begin : g_bram_read

    logic rd_word_valid;
    wire  fetch = (rd_ptr != wr_commit) &&
                  (!rd_word_valid || (m_axis_tvalid && m_axis_tready));

    always_ff @(posedge clk) begin
      if (!rstn) begin
        rd_ptr        <= '0;
        rd_word_valid <= 1'b0;
      end else begin
        if (m_axis_tvalid && m_axis_tready) rd_word_valid <= 1'b0;
        if (fetch) begin
          rd_word       <= mem[rd_ptr[ADDR_W-1:0]];
          rd_ptr        <= rd_ptr + 1'b1;
          rd_word_valid <= 1'b1;
        end
      end
    end

    assign m_axis_tvalid = rd_word_valid;
  end else begin : g_dist_read

    assign rd_word       = mem[rd_ptr[ADDR_W-1:0]];
    assign m_axis_tvalid = (rd_ptr != wr_commit);

    always_ff @(posedge clk) begin
      if (!rstn)                               rd_ptr <= '0;
      else if (m_axis_tvalid && m_axis_tready) rd_ptr <= rd_ptr + 1'b1;
    end
  end
  endgenerate

  assign m_axis_tdata  = rd_word[DATA_W-1:0];
  assign m_axis_tkeep  = rd_word[DATA_W+KEEP_W-1:DATA_W];
  assign m_axis_tlast  = rd_word[DATA_W+KEEP_W];
  assign m_axis_tuser  = rd_word[DATA_W+KEEP_W+1 +: USER_W];

  assign drop_frames = drop_cnt;
  assign overflow    = ovf;
endmodule
