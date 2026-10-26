// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps/1ps
`default_nettype none

module rst_sync #(

    parameter int STAGES = 3
) (
    input  wire clk,
    input  wire arst_n,
    output wire rst_n
);

initial begin
    if (STAGES < 2) begin
        $error("Error: rst_sync needs STAGES >= 2; one flop resolves nothing (instance %m)");
        $finish;
    end
end

(* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] release_chain_r = '0;
reg                                       rst_n_r         = 1'b0;

always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) begin
        release_chain_r <= '0;
        rst_n_r         <= 1'b0;
    end else begin
        release_chain_r <= {release_chain_r[STAGES-2:0], 1'b1};
        rst_n_r         <= release_chain_r[STAGES-1];
    end
end

assign rst_n = rst_n_r;

endmodule

`default_nettype wire
