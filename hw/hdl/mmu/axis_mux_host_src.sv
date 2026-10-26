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
 * @brief   Host multiplexer source
 *
 * Sources multiple vFPGA streams from one host (QDMA/XDMA) stream.
 *
 *  @param DATA_BITS    Data bus size
 */
module axis_mux_host_src #(
    parameter integer MUX_DATA_BITS = AXI_DATA_BITS,
    parameter integer N_ID = N_REGIONS
) (
    input  logic                            aclk,
    input  logic                            aresetn,

    metaIntf.s                              s_mux,

    AXI4S.s                                 s_axis,
    AXI4S.m                                 m_axis [N_ID]
);

localparam integer BEAT_BYTES = MUX_DATA_BITS/8;
localparam integer BEAT_LOG_BITS = $clog2(MUX_DATA_BITS/8);
localparam integer BLEN_BITS = LEN_BITS - BEAT_LOG_BITS;
localparam integer N_ID_BITS = clog2s(N_ID);

typedef enum logic[1:0]  {ST_IDLE, ST_MUX, ST_FLUSH} state_t;
logic [1:0] state_C, state_N;

logic nxt_valid_C;
logic [N_ID_BITS-1:0] nxt_vfid_C;
logic [BLEN_BITS-1:0] nxt_cnt_C;
logic nxt_last_C;
logic nxt_fin_C;
logic [BEAT_LOG_BITS-1:0] nxt_rsel_C;
logic [BEAT_BYTES-1:0] nxt_mask_C;
logic nxt_emit_fin_C;
logic nxt_small_fin_C;
logic nxt_flush_fin_C;
logic nxt_tlast_fin_C;
logic [BEAT_BYTES-1:0] nxt_keep_fin_C;
logic [BEAT_BYTES-1:0] nxt_keep_flush_C;

logic [N_ID_BITS-1:0] vfid_C, vfid_N;
logic [BLEN_BITS-1:0] cnt_C, cnt_N;
logic last_C, last_N;
logic fin_C, fin_N;
logic [BEAT_LOG_BITS-1:0] rsel_C, rsel_N;
logic [BEAT_BYTES-1:0] mask_C, mask_N;
logic emit_fin_C, emit_fin_N;
logic small_fin_C, small_fin_N;
logic flush_fin_C, flush_fin_N;
logic tlast_fin_C, tlast_fin_N;
logic [BEAT_BYTES-1:0] keep_fin_C, keep_fin_N;
logic [BEAT_BYTES-1:0] keep_flush_C, keep_flush_N;

logic [N_ID-1:0][MUX_DATA_BITS-1:0] carry_C;

logic out_valid_C;
logic [N_ID_BITS-1:0] out_vfid_C;
logic [MUX_DATA_BITS-1:0] out_data_C;
logic [BEAT_BYTES-1:0] out_keep_C;
logic out_last_C;

logic [N_ID-1:0] m_axis_tready;

logic [2*MUX_DATA_BITS-1:0] in_pair;
logic [MUX_DATA_BITS-1:0] rot_data;
logic [MUX_DATA_BITS-1:0] carry_sel;
logic [MUX_DATA_BITS-1:0] merged_data;
logic emit;
logic out_valid;
logic [MUX_DATA_BITS-1:0] out_data;
logic [BEAT_BYTES-1:0] out_keep;
logic out_last;
logic out_ready;
logic out_hs;
logic in_hs;
logic piece_done;
logic load;
logic nxt_ready;

logic [BEAT_LOG_BITS:0] ld_lastb;
logic [BEAT_LOG_BITS:0] ld_sum;
logic [BEAT_LOG_BITS:0] ld_rem;
logic [BEAT_BYTES-1:0] ld_mask;
logic [BEAT_BYTES-1:0] ld_keep_fin;
logic [BEAT_BYTES-1:0] ld_keep_flush;

for(genvar i = 0; i < N_ID; i++) begin
    assign m_axis[i].tvalid = out_valid_C && (out_vfid_C == i);
    assign m_axis[i].tdata = out_data_C;
    assign m_axis[i].tkeep = out_keep_C;
    assign m_axis[i].tlast = out_last_C;
    assign m_axis_tready[i] = m_axis[i].tready;
end

assign in_pair = {s_axis.tdata, s_axis.tdata};
assign rot_data = in_pair[{rsel_C, 3'b000} +: MUX_DATA_BITS];
assign carry_sel = carry_C[vfid_C];

always_comb begin
    for(int b = 0; b < BEAT_BYTES; b++) begin
        merged_data[b*8+:8] = mask_C[b] ? carry_sel[b*8+:8] : rot_data[b*8+:8];
    end
end

assign emit = fin_C ? emit_fin_C : 1'b1;
assign out_ready = !out_valid_C || m_axis_tready[out_vfid_C];

always_comb begin
    if (state_C == ST_FLUSH) begin
        out_valid = 1'b1;
        out_data = carry_sel;
        out_keep = keep_flush_C;
        out_last = last_C;
    end
    else begin
        out_valid = (state_C == ST_MUX) && s_axis.tvalid && emit;
        out_data = merged_data;
        out_keep = fin_C ? keep_fin_C : {BEAT_BYTES{1'b1}};
        out_last = fin_C && tlast_fin_C;
    end
end

assign s_axis.tready = (state_C == ST_MUX) && (emit ? out_ready : 1'b1);
assign out_hs = out_valid && out_ready;
assign in_hs = s_axis.tvalid && s_axis.tready;

assign piece_done = ((state_C == ST_MUX) && in_hs && fin_C && !flush_fin_C) || ((state_C == ST_FLUSH) && out_hs);
assign load = nxt_valid_C && ((state_C == ST_IDLE) || piece_done);
assign nxt_ready = !nxt_valid_C || load;
assign s_mux.ready = nxt_ready;

assign ld_lastb = (s_mux.data.tail == 0) ? BEAT_BYTES : {1'b0, s_mux.data.tail};
assign ld_sum = {1'b0, s_mux.data.offs} + ld_lastb;
assign ld_rem = ld_sum - BEAT_BYTES;
always_comb begin
    for(int b = 0; b < BEAT_BYTES; b++) begin
        ld_mask[b] = (b < s_mux.data.offs);
        ld_keep_fin[b] = (ld_sum >= BEAT_BYTES) || (b < ld_sum);
        ld_keep_flush[b] = (b < ld_rem);
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
        nxt_fin_C <= (s_mux.data.len == 0);
        nxt_rsel_C <= ~s_mux.data.offs + 1'b1;
        nxt_mask_C <= ld_mask;
        nxt_emit_fin_C <= (ld_sum >= BEAT_BYTES) || s_mux.data.cmd_last;
        nxt_small_fin_C <= (ld_sum < BEAT_BYTES);
        nxt_flush_fin_C <= s_mux.data.cmd_last && (ld_sum > BEAT_BYTES);
        nxt_tlast_fin_C <= s_mux.data.last && !(ld_sum > BEAT_BYTES);
        nxt_keep_fin_C <= ld_keep_fin;
        nxt_keep_flush_C <= ld_keep_flush;
    end
end

always_comb begin
    state_N = state_C;
    vfid_N = vfid_C;
    cnt_N = cnt_C;
    last_N = last_C;
    fin_N = fin_C;
    rsel_N = rsel_C;
    mask_N = mask_C;
    emit_fin_N = emit_fin_C;
    small_fin_N = small_fin_C;
    flush_fin_N = flush_fin_C;
    tlast_fin_N = tlast_fin_C;
    keep_fin_N = keep_fin_C;
    keep_flush_N = keep_flush_C;

    if (load) begin
        state_N = ST_MUX;
        vfid_N = nxt_vfid_C;
        cnt_N = nxt_cnt_C;
        last_N = nxt_last_C;
        fin_N = nxt_fin_C;
        rsel_N = nxt_rsel_C;
        mask_N = nxt_mask_C;
        emit_fin_N = nxt_emit_fin_C;
        small_fin_N = nxt_small_fin_C;
        flush_fin_N = nxt_flush_fin_C;
        tlast_fin_N = nxt_tlast_fin_C;
        keep_fin_N = nxt_keep_fin_C;
        keep_flush_N = nxt_keep_flush_C;
    end
    else if (piece_done) begin
        state_N = ST_IDLE;
    end
    else if ((state_C == ST_MUX) && in_hs) begin
        if (fin_C) begin
            state_N = ST_FLUSH;
        end
        else begin
            cnt_N = cnt_C - 1;
            fin_N = (cnt_C == 1);
        end
    end
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        state_C <= ST_IDLE;
        vfid_C <= 0;
        cnt_C <= 0;
        last_C <= 1'b0;
        fin_C <= 1'b0;
        rsel_C <= 0;
        mask_C <= 0;
        emit_fin_C <= 1'b0;
        small_fin_C <= 1'b0;
        flush_fin_C <= 1'b0;
        tlast_fin_C <= 1'b0;
        keep_fin_C <= 0;
        keep_flush_C <= 0;
        out_valid_C <= 1'b0;
    end
    else begin
        state_C <= state_N;
        vfid_C <= vfid_N;
        cnt_C <= cnt_N;
        last_C <= last_N;
        fin_C <= fin_N;
        rsel_C <= rsel_N;
        mask_C <= mask_N;
        emit_fin_C <= emit_fin_N;
        small_fin_C <= small_fin_N;
        flush_fin_C <= flush_fin_N;
        tlast_fin_C <= tlast_fin_N;
        keep_fin_C <= keep_fin_N;
        keep_flush_C <= keep_flush_N;
        if (out_ready) begin
            out_valid_C <= out_valid;
        end
    end
end

always_ff @(posedge aclk) begin
    if (out_ready) begin
        out_vfid_C <= vfid_C;
        out_data_C <= out_data;
        out_keep_C <= out_keep;
        out_last_C <= out_last;
    end
end

always_ff @(posedge aclk) begin
    for(int i = 0; i < N_ID; i++) begin
        if (in_hs && (vfid_C == i)) begin
            carry_C[i] <= (fin_C && small_fin_C) ? merged_data : rot_data;
        end
    end
end

endmodule
