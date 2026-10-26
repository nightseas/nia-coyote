// Copyright (c) 2022-2025 Systems Group, ETH Zurich
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps
`default_nettype none

module dcmac_usr_reset_gen #(
  parameter int MODE        = 1,
  parameter int HOLD_CYCLES = 1024
)(
  input  wire  clk,
  input  wire  sys_reset,
  input  wire  mac_link_up,
  input  wire  mac_tx_rst,
  output wire  tx_rst
);

  localparam int HCW = (HOLD_CYCLES < 2) ? 1 : $clog2(HOLD_CYCLES + 1);

  initial begin
    if (MODE != 0 && MODE != 1 && MODE != 2) begin
      $error("Error: dcmac_usr_reset_gen MODE=%0d is not 0, 1 or 2. 0 releases tx_rst after the system reset hold, 1 additionally waits for the first link up and is the shipped default, 2 follows the MAC link state and is the negative control arm only (instance %m)", MODE);
      $finish;
    end
    if (HOLD_CYCLES < 1) begin
      $error("Error: dcmac_usr_reset_gen HOLD_CYCLES=%0d must be at least 1 (instance %m)", HOLD_CYCLES);
      $finish;
    end
  end

  (* ASYNC_REG = "TRUE" *) logic sys_reset_s0 = 1'b1;
  (* ASYNC_REG = "TRUE" *) logic sys_reset_s1 = 1'b1;

  always_ff @(posedge clk) begin
    sys_reset_s0 <= sys_reset;
    sys_reset_s1 <= sys_reset_s0;
  end

  wire sys_reset_sync = sys_reset_s1;

  logic [HCW-1:0] hold_cnt  = HCW'(HOLD_CYCLES);
  logic           hold_done = 1'b0;

  always_ff @(posedge clk) begin
    if (sys_reset_sync) begin
      hold_cnt  <= HCW'(HOLD_CYCLES);
      hold_done <= 1'b0;
    end
    else if (hold_cnt != '0) begin
      hold_cnt <= hold_cnt - 1'b1;
    end
    else begin
      hold_done <= 1'b1;
    end
  end

  logic link_seen = 1'b0;

  always_ff @(posedge clk) begin
    if (sys_reset_sync)   link_seen <= 1'b0;
    else if (mac_link_up) link_seen <= 1'b1;
  end

  wire release_cond = (MODE == 0) ? hold_done : (hold_done && link_seen);

  logic released = 1'b0;

  always_ff @(posedge clk) begin
    if (sys_reset_sync)    released <= 1'b0;
    else if (release_cond) released <= 1'b1;
  end

  generate
  if (MODE == 2) begin : g_link_tracking
    logic tx_rst_r = 1'b1;
    always_ff @(posedge clk) tx_rst_r <= sys_reset_sync || mac_tx_rst;
    assign tx_rst = tx_rst_r;
  end
  else begin : g_one_shot
    logic tx_rst_r = 1'b1;
    always_ff @(posedge clk) tx_rst_r <= ~released;
    assign tx_rst = tx_rst_r;
  end
  endgenerate

  wire unused_by_mode = |{mac_tx_rst, mac_link_up, link_seen, hold_done, released, release_cond};

endmodule

`default_nettype wire
