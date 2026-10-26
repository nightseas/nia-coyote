/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2021-2025, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

`timescale 1ns / 1ps

import lynxTypes::*;
/**
 * @brief   Host multiplexer sink
 *
 * Sinks multiple vFPGA streams into one host DMA  (XDMA/QDMA) stream
 *
 *  @param DATA_BITS    Data bus size
 */
module axis_mux_host_sink #(
    parameter integer DATA_BITS = AXI_DATA_BITS,
    parameter integer N_ID = N_REGIONS
) (
    input  logic                            aclk,
    input  logic                            aresetn,

    metaIntf.s                              s_mux,

    AXI4S.s                                 s_axis [N_ID],
    AXI4S.m                                 m_axis
);

localparam integer BEAT_BYTES = DATA_BITS/8;
localparam integer BEAT_LOG_BITS = $clog2(DATA_BITS/8);
localparam integer BLEN_BITS = LEN_BITS - BEAT_LOG_BITS;
localparam integer N_ID_BITS = clog2s(N_ID);

typedef enum logic[0:0]  {ST_IDLE, ST_MUX} state_t;
logic [0:0] state_C, state_N;

logic nxt_valid_C;
logic [N_ID_BITS-1:0] nxt_vfid_C;
logic [BLEN_BITS-1:0] nxt_cnt_C;
logic nxt_last_C;
logic [BEAT_LOG_BITS-1:0] nxt_offs_C;
logic nxt_zero_C;
logic nxt_fin_C;
logic nxt_take_fin_C;
logic nxt_take_C;
logic [BEAT_BYTES-1:0] nxt_keep_fin_C;

logic [N_ID_BITS-1:0] vfid_C, vfid_N;
logic [BLEN_BITS-1:0] cnt_C, cnt_N;
logic last_C, last_N;
logic [BEAT_LOG_BITS-1:0] offs_C, offs_N;
logic zero_C, zero_N;
logic fin_C, fin_N;
logic take_fin_C, take_fin_N;
logic take_C, take_N;
logic [BEAT_BYTES-1:0] keep_fin_C, keep_fin_N;

logic [N_ID-1:0][DATA_BITS-1:0] save_C;

logic out_valid_C;
logic [DATA_BITS-1:0] out_data_C;
logic [BEAT_BYTES-1:0] out_keep_C;
logic out_last_C;

logic [N_ID-1:0] s_axis_tvalid;
logic [N_ID-1:0] s_axis_tready;
logic [N_ID-1:0][DATA_BITS-1:0] s_axis_tdata;

logic in_valid;
logic [DATA_BITS-1:0] in_data;
logic [2*DATA_BITS-1:0] in_pair;
logic [DATA_BITS-1:0] shift_data;
logic out_valid;
logic out_ready;
logic out_hs;
logic in_hs;
logic load;
logic nxt_ready;

logic [BEAT_LOG_BITS:0] ld_sum;
logic ld_take_fin;
logic [BEAT_BYTES-1:0] ld_keep_fin;

for(genvar i = 0; i < N_ID; i++) begin
    assign s_axis_tvalid[i] = s_axis[i].tvalid;
    assign s_axis_tdata[i] = s_axis[i].tdata;
    assign s_axis[i].tready = s_axis_tready[i];
    assign s_axis_tready[i] = (state_C == ST_MUX) && (vfid_C == i) && take_C && out_ready;
end

assign m_axis.tvalid = out_valid_C;
assign m_axis.tdata = out_data_C;
assign m_axis.tkeep = out_keep_C;
assign m_axis.tlast = out_last_C;

assign in_valid = s_axis_tvalid[vfid_C];
assign in_data = s_axis_tdata[vfid_C];
assign in_pair = {in_data, save_C[vfid_C]};
assign shift_data = in_pair[{offs_C, 3'b000} +: DATA_BITS];

assign out_ready = !out_valid_C || m_axis.tready;
assign out_valid = (state_C == ST_MUX) && (take_C ? in_valid : 1'b1);
assign out_hs = out_valid && out_ready;
assign in_hs = out_hs && take_C;

assign load = nxt_valid_C && ((state_C == ST_IDLE) || (out_hs && fin_C));
assign nxt_ready = !nxt_valid_C || load;
assign s_mux.ready = nxt_ready;

assign ld_sum = {1'b0, s_mux.data.offs} + {1'b0, s_mux.data.tail};
assign ld_take_fin = (s_mux.data.offs == 0) || (s_mux.data.tail == 0) || (ld_sum > BEAT_BYTES);
always_comb begin
    for(int b = 0; b < BEAT_BYTES; b++) begin
        ld_keep_fin[b] = (s_mux.data.tail == 0) || (b < s_mux.data.tail);
    end
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        nxt_valid_C <= 1'b0;
    end
    else if (nxt_ready) begin
        nxt_valid_C <= s_mux.valid;
    end
end

always_ff @(posedge aclk) begin
    if (nxt_ready && s_mux.valid) begin
        nxt_vfid_C <= s_mux.data.vfid;
        nxt_cnt_C <= s_mux.data.len;
        nxt_last_C <= s_mux.data.last;
        nxt_offs_C <= s_mux.data.offs;
        nxt_zero_C <= (s_mux.data.offs == 0);
        nxt_fin_C <= (s_mux.data.len == 0);
        nxt_take_fin_C <= ld_take_fin;
        nxt_take_C <= (s_mux.data.len == 0) ? ld_take_fin : 1'b1;
        nxt_keep_fin_C <= ld_keep_fin;
    end
end

always_comb begin
    state_N = state_C;
    vfid_N = vfid_C;
    cnt_N = cnt_C;
    last_N = last_C;
    offs_N = offs_C;
    zero_N = zero_C;
    fin_N = fin_C;
    take_fin_N = take_fin_C;
    take_N = take_C;
    keep_fin_N = keep_fin_C;

    if (load) begin
        state_N = ST_MUX;
        vfid_N = nxt_vfid_C;
        cnt_N = nxt_cnt_C;
        last_N = nxt_last_C;
        offs_N = nxt_offs_C;
        zero_N = nxt_zero_C;
        fin_N = nxt_fin_C;
        take_fin_N = nxt_take_fin_C;
        take_N = nxt_take_C;
        keep_fin_N = nxt_keep_fin_C;
    end
    else if (out_hs) begin
        if (fin_C) begin
            state_N = ST_IDLE;
        end
        else begin
            cnt_N = cnt_C - 1;
            fin_N = (cnt_C == 1);
            take_N = (cnt_C == 1) ? take_fin_C : 1'b1;
        end
    end
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        state_C <= ST_IDLE;
        vfid_C <= 0;
        cnt_C <= 0;
        last_C <= 1'b0;
        offs_C <= 0;
        zero_C <= 1'b1;
        fin_C <= 1'b0;
        take_fin_C <= 1'b0;
        take_C <= 1'b0;
        keep_fin_C <= 0;
        out_valid_C <= 1'b0;
    end
    else begin
        state_C <= state_N;
        vfid_C <= vfid_N;
        cnt_C <= cnt_N;
        last_C <= last_N;
        offs_C <= offs_N;
        zero_C <= zero_N;
        fin_C <= fin_N;
        take_fin_C <= take_fin_N;
        take_C <= take_N;
        keep_fin_C <= keep_fin_N;
        if (out_ready) begin
            out_valid_C <= out_valid;
        end
    end
end

always_ff @(posedge aclk) begin
    if (out_ready) begin
        out_data_C <= zero_C ? in_data : shift_data;
        out_keep_C <= fin_C ? keep_fin_C : {BEAT_BYTES{1'b1}};
        out_last_C <= fin_C && last_C;
    end
end

always_ff @(posedge aclk) begin
    for(int i = 0; i < N_ID; i++) begin
        if (in_hs && (vfid_C == i)) begin
            save_C[i] <= in_data;
        end
    end
end

endmodule
