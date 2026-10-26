// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

`default_nettype none

module dcmac_sync2 #(
  parameter int  WIDTH  = 1,
  parameter int  STAGES = 2,
  parameter logic [WIDTH-1:0] INIT = '0
)(
  input  wire              clk,
  input  wire  [WIDTH-1:0] din,
  output wire  [WIDTH-1:0] dout
);

  // synthesis translate_off
  initial begin
    if (STAGES < 2)
      $fatal(1, "dcmac_sync2: violated - STAGES=%0d, a synchroniser needs >= 2", STAGES);
  end
  // synthesis translate_on

  (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sr [0:STAGES-1];

  integer s;
  initial for (s = 0; s < STAGES; s = s + 1) sr[s] = INIT;

  always_ff @(posedge clk) begin
    sr[0] <= din;
    for (s = 1; s < STAGES; s = s + 1) sr[s] <= sr[s-1];
  end

  assign dout = sr[STAGES-1];

endmodule

`default_nettype wire
