// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps

module host_networking_prefilter_flat #(
    parameter integer DATA_BITS = 512
) (
    input  wire                    nclk,
    input  wire                    nresetn,

    input  wire [DATA_BITS-1:0]    rx_tdata,
    input  wire [DATA_BITS/8-1:0]  rx_tkeep,
    input  wire                    rx_tlast,
    input  wire                    rx_tvalid,
    output wire                    rx_tready,

    output wire [DATA_BITS-1:0]    host_tdata,
    output wire [DATA_BITS/8-1:0]  host_tkeep,
    output wire                    host_tlast,
    output wire                    host_tvalid,
    input  wire                    host_tready,

    output wire [DATA_BITS-1:0]    offloaded_tdata,
    output wire [DATA_BITS/8-1:0]  offloaded_tkeep,
    output wire                    offloaded_tlast,
    output wire                    offloaded_tvalid,
    input  wire                    offloaded_tready
);

    AXI4S #(.AXI4S_DATA_BITS(DATA_BITS)) axis_rx (nclk, nresetn);
    AXI4S #(.AXI4S_DATA_BITS(DATA_BITS)) axis_host (nclk, nresetn);
    AXI4S #(.AXI4S_DATA_BITS(DATA_BITS)) axis_offloaded (nclk, nresetn);

    assign axis_rx.tdata = rx_tdata;
    assign axis_rx.tkeep = rx_tkeep;
    assign axis_rx.tlast = rx_tlast;
    assign axis_rx.tvalid = rx_tvalid;
    assign rx_tready = axis_rx.tready;

    assign host_tdata = axis_host.tdata;
    assign host_tkeep = axis_host.tkeep;
    assign host_tlast = axis_host.tlast;
    assign host_tvalid = axis_host.tvalid;
    assign axis_host.tready = host_tready;

    assign offloaded_tdata = axis_offloaded.tdata;
    assign offloaded_tkeep = axis_offloaded.tkeep;
    assign offloaded_tlast = axis_offloaded.tlast;
    assign offloaded_tvalid = axis_offloaded.tvalid;
    assign axis_offloaded.tready = offloaded_tready;

    host_networking_prefilter prefilter (
        .nclk                 (nclk),
        .nresetn              (nresetn),
        .s_axis_rx            (axis_rx),
        .m_axis_rx            (axis_host),
        .m_axis_offloaded_rx  (axis_offloaded)
    );

endmodule
