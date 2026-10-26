// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

module axis_register_slice_meta_stub #(
    parameter integer DATA_BITS = 32
) (
    input  logic                    aclk,
    input  logic                    aresetn,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic [DATA_BITS-1:0]    s_axis_tdata,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic [DATA_BITS-1:0]    m_axis_tdata
);

    logic                  held_valid;
    logic [DATA_BITS-1:0]  held_data;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            held_valid <= 1'b0;
            held_data <= '0;
        end
        else if (s_axis_tvalid && s_axis_tready) begin
            held_valid <= 1'b1;
            held_data <= s_axis_tdata;
        end
        else if (held_valid && m_axis_tready) begin
            held_valid <= 1'b0;
        end
    end

    assign s_axis_tready = !held_valid || m_axis_tready;
    assign m_axis_tvalid = held_valid;
    assign m_axis_tdata = held_data;

endmodule

module axis_register_slice_meta_8 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [7:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [7:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(8)) inst (.*);
endmodule

module axis_register_slice_meta_16 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [15:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [15:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(16)) inst (.*);
endmodule

module axis_register_slice_meta_32 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [31:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [31:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(32)) inst (.*);
endmodule

module axis_register_slice_meta_56 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [55:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [55:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(56)) inst (.*);
endmodule

module axis_register_slice_meta_64 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [63:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [63:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(64)) inst (.*);
endmodule

module axis_register_slice_meta_72 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [71:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [71:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(72)) inst (.*);
endmodule

module axis_register_slice_meta_96 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [95:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [95:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(96)) inst (.*);
endmodule

module axis_register_slice_meta_128 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [127:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [127:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(128)) inst (.*);
endmodule

module axis_register_slice_meta_256 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [255:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [255:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(256)) inst (.*);
endmodule

module axis_register_slice_meta_512 (
    input logic aclk, input logic aresetn,
    input logic s_axis_tvalid, output logic s_axis_tready, input logic [511:0] s_axis_tdata,
    output logic m_axis_tvalid, input logic m_axis_tready, output logic [511:0] m_axis_tdata
);
    axis_register_slice_meta_stub #(.DATA_BITS(512)) inst (.*);
endmodule

module axis_data_fifo_req_256_used (
    input  logic s_axis_aresetn,
    input  logic s_axis_aclk,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic [255:0] s_axis_tdata,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic [255:0] m_axis_tdata,
    output logic [4:0] axis_wr_data_count
);

    localparam integer DEPTH = 16;

    logic [255:0] store [DEPTH];
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
                used <= used + 1;
            end
            if (m_axis_tvalid && m_axis_tready) begin
                rptr <= (rptr + 1) % DEPTH;
                used <= used - 1;
            end
            if (s_axis_tvalid && s_axis_tready && m_axis_tvalid && m_axis_tready) begin
                used <= used;
            end
        end
    end

    assign s_axis_tready = (used < DEPTH);
    assign m_axis_tvalid = (used > 0);
    assign m_axis_tdata = store[rptr];
    assign axis_wr_data_count = used[4:0];

endmodule
