/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2026, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

`timescale 1ns / 1ps

module axis_interconnect_512_4to1 (
    input  wire             aclk,
    input  wire             aresetn,

    input  wire             S00_AXIS_tvalid,
    output wire             S00_AXIS_tready,
    input  wire [511:0]     S00_AXIS_tdata,
    input  wire [63:0]      S00_AXIS_tkeep,
    input  wire             S00_AXIS_tlast,

    input  wire             S01_AXIS_tvalid,
    output wire             S01_AXIS_tready,
    input  wire [511:0]     S01_AXIS_tdata,
    input  wire [63:0]      S01_AXIS_tkeep,
    input  wire             S01_AXIS_tlast,

    input  wire             S02_AXIS_tvalid,
    output wire             S02_AXIS_tready,
    input  wire [511:0]     S02_AXIS_tdata,
    input  wire [63:0]      S02_AXIS_tkeep,
    input  wire             S02_AXIS_tlast,

    input  wire             S03_AXIS_tvalid,
    output wire             S03_AXIS_tready,
    input  wire [511:0]     S03_AXIS_tdata,
    input  wire [63:0]      S03_AXIS_tkeep,
    input  wire             S03_AXIS_tlast,

    output wire             M00_AXIS_tvalid,
    input  wire             M00_AXIS_tready,
    output wire [511:0]     M00_AXIS_tdata,
    output wire [63:0]      M00_AXIS_tkeep,
    output wire             M00_AXIS_tlast
);

    localparam int SLAVE_PORTS = 4;

    wire [SLAVE_PORTS-1:0]        slave_tvalid;
    wire [SLAVE_PORTS-1:0]        slave_tready;
    wire [SLAVE_PORTS*512-1:0]    slave_tdata;
    wire [SLAVE_PORTS*64-1:0]     slave_tkeep;
    wire [SLAVE_PORTS-1:0]        slave_tlast;
    wire [0:0]                    master_tvalid;
    wire [0:0]                    master_tlast;

    assign slave_tvalid = {S03_AXIS_tvalid, S02_AXIS_tvalid, S01_AXIS_tvalid, S00_AXIS_tvalid};
    assign slave_tdata  = {S03_AXIS_tdata,  S02_AXIS_tdata,  S01_AXIS_tdata,  S00_AXIS_tdata};
    assign slave_tkeep  = {S03_AXIS_tkeep,  S02_AXIS_tkeep,  S01_AXIS_tkeep,  S00_AXIS_tkeep};
    assign slave_tlast  = {S03_AXIS_tlast,  S02_AXIS_tlast,  S01_AXIS_tlast,  S00_AXIS_tlast};

    assign {S03_AXIS_tready, S02_AXIS_tready, S01_AXIS_tready, S00_AXIS_tready} = slave_tready;

    assign M00_AXIS_tvalid = master_tvalid[0];
    assign M00_AXIS_tlast  = master_tlast[0];

    axis_switch_512_4to1 inst_axis_switch (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axis_tvalid  (slave_tvalid),
        .s_axis_tready  (slave_tready),
        .s_axis_tdata   (slave_tdata),
        .s_axis_tkeep   (slave_tkeep),
        .s_axis_tlast   (slave_tlast),
        .m_axis_tvalid  (master_tvalid),
        .m_axis_tready  (M00_AXIS_tready),
        .m_axis_tdata   (M00_AXIS_tdata),
        .m_axis_tkeep   (M00_AXIS_tkeep),
        .m_axis_tlast   (master_tlast),
        .s_req_suppress ({SLAVE_PORTS{1'b0}}),
        .s_decode_err   ()
    );

endmodule


module axis_interconnect_512_2to1 (
    input  wire             aclk,
    input  wire             aresetn,

    input  wire             S00_AXIS_tvalid,
    output wire             S00_AXIS_tready,
    input  wire [511:0]     S00_AXIS_tdata,
    input  wire [63:0]      S00_AXIS_tkeep,
    input  wire             S00_AXIS_tlast,

    input  wire             S01_AXIS_tvalid,
    output wire             S01_AXIS_tready,
    input  wire [511:0]     S01_AXIS_tdata,
    input  wire [63:0]      S01_AXIS_tkeep,
    input  wire             S01_AXIS_tlast,

    output wire             M00_AXIS_tvalid,
    input  wire             M00_AXIS_tready,
    output wire [511:0]     M00_AXIS_tdata,
    output wire [63:0]      M00_AXIS_tkeep,
    output wire             M00_AXIS_tlast
);

    localparam int SLAVE_PORTS = 2;

    wire [SLAVE_PORTS-1:0]        slave_tvalid;
    wire [SLAVE_PORTS-1:0]        slave_tready;
    wire [SLAVE_PORTS*512-1:0]    slave_tdata;
    wire [SLAVE_PORTS*64-1:0]     slave_tkeep;
    wire [SLAVE_PORTS-1:0]        slave_tlast;
    wire [0:0]                    master_tvalid;
    wire [0:0]                    master_tlast;

    assign slave_tvalid = {S01_AXIS_tvalid, S00_AXIS_tvalid};
    assign slave_tdata  = {S01_AXIS_tdata,  S00_AXIS_tdata};
    assign slave_tkeep  = {S01_AXIS_tkeep,  S00_AXIS_tkeep};
    assign slave_tlast  = {S01_AXIS_tlast,  S00_AXIS_tlast};

    assign {S01_AXIS_tready, S00_AXIS_tready} = slave_tready;

    assign M00_AXIS_tvalid = master_tvalid[0];
    assign M00_AXIS_tlast  = master_tlast[0];

    axis_switch_512_2to1 inst_axis_switch (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axis_tvalid  (slave_tvalid),
        .s_axis_tready  (slave_tready),
        .s_axis_tdata   (slave_tdata),
        .s_axis_tkeep   (slave_tkeep),
        .s_axis_tlast   (slave_tlast),
        .m_axis_tvalid  (master_tvalid),
        .m_axis_tready  (M00_AXIS_tready),
        .m_axis_tdata   (M00_AXIS_tdata),
        .m_axis_tkeep   (M00_AXIS_tkeep),
        .m_axis_tlast   (master_tlast),
        .s_req_suppress ({SLAVE_PORTS{1'b0}}),
        .s_decode_err   ()
    );

endmodule
