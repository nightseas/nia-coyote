// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`default_nettype none

module wdt #(
  parameter int CYC_PER_MS = 250000,
  parameter int MS_DEFAULT  = 750,
  parameter int MS_MIN      = 10,
  parameter int MS_MAX      = 60000,
  parameter int CW          = 40
) (
  input  wire            clk,
  input  wire            rstn,

  input  wire [15:0]     ms,

  input  wire            en,
  input  wire            clear,

  output wire            timeout,
  output wire            running,
  output wire [CW-1:0]   remaining

);

  initial begin
    if (CYC_PER_MS < 1)
      $fatal(1, "wdt: CYC_PER_MS must be >= 1");
    if (MS_DEFAULT < MS_MIN || MS_DEFAULT > MS_MAX)
      $fatal(1, "wdt: MS_DEFAULT=%0d outside [%0d,%0d]", MS_DEFAULT, MS_MIN, MS_MAX);
    if (CW < 2)
      $fatal(1, "wdt: CW must be >= 2");
  end

  wire [15:0]   ms_eff  = (ms == 16'd0) ? 16'(MS_DEFAULT) : ms;
  wire [CW-1:0] win_cyc = CW'(ms_eff) * CW'(CYC_PER_MS);

  logic [CW-1:0] cnt;
  logic          tmo;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      cnt <= '0;
      tmo <= 1'b0;
    end else begin
      tmo <= 1'b0;
      if (!en || clear) begin

        cnt <= win_cyc;
      end else if (cnt == '0) begin
        tmo <= 1'b1;
        cnt <= win_cyc;
      end else begin
        cnt <= cnt - 1'b1;
      end
    end
  end

  assign timeout   = tmo;
  assign running   = rstn && en && !clear;
  assign remaining = cnt;

endmodule

`default_nettype wire
