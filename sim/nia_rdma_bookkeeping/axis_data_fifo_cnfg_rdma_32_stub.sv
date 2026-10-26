// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module axis_data_fifo_cnfg_rdma_32 (
    input  logic        s_axis_aresetn,
    input  logic        s_axis_aclk,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  ack_t        s_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output ack_t        m_axis_tdata,
    output logic [5:0]  axis_wr_data_count
);

    localparam integer DEPTH = 32;

    ack_t store [DEPTH];
    integer wptr = 0;
    integer rptr = 0;
    integer used = 0;

    always_ff @(posedge s_axis_aclk) begin
        if (!s_axis_aresetn) begin
            wptr <= 0;
            rptr <= 0;
            used <= 0;
        end
        else begin
            if (s_axis_tvalid && s_axis_tready) begin
                store[wptr] <= s_axis_tdata;
                wptr <= (wptr + 1) % DEPTH;
            end
            if (m_axis_tvalid && m_axis_tready) begin
                rptr <= (rptr + 1) % DEPTH;
            end
            if ((s_axis_tvalid && s_axis_tready) && !(m_axis_tvalid && m_axis_tready)) begin
                used <= used + 1;
            end
            else if (!(s_axis_tvalid && s_axis_tready) && (m_axis_tvalid && m_axis_tready)) begin
                used <= used - 1;
            end
        end
    end

    assign s_axis_tready = (used < DEPTH);
    assign m_axis_tvalid = (used > 0);
    assign m_axis_tdata = store[rptr];
    assign axis_wr_data_count = used[5:0];

endmodule
