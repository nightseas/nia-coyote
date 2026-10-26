// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT

`timescale 1ns / 1ps

module axi_uram_mem_intf #(
    parameter int    N_SESSIONS    = 16,
    parameter int    WINDOW_BITS   = 18,
    parameter        ADDR_MAP      = "flat",
    parameter int    PMTU_BYTES    = 4096,
    parameter int    RDMA_SHIFT    = 27,
    parameter int    RDMA_OST_BITS = 4,
    parameter int    PID_BITS      = 6,
    parameter int    VFID_BITS     = 0,
    parameter int    BANKS         = 1,
    parameter int    RD_LAT        = 2,
    parameter int    OSTD          = 8
) (
    input  logic        aclk,
    input  logic        aresetn,

    AXI4.s              s_axi,

    output logic        oob_err,
    output logic [31:0] oob_cnt,
    output logic        proto_err,
    output logic [31:0] proto_cnt,
    output logic        xsess_err,
    output logic [31:0] xsess_cnt,
    output logic        slot_ovf_err,
    output logic [31:0] slot_ovf_cnt
);

    axi_uram_mem #(
        .DATA_BITS     ($bits(s_axi.wdata)),
        .ADDR_BITS     ($bits(s_axi.awaddr)),
        .ID_BITS       ($bits(s_axi.awid)),
        .N_SESSIONS    (N_SESSIONS),
        .WINDOW_BITS   (WINDOW_BITS),
        .ADDR_MAP      (ADDR_MAP),
        .PMTU_BYTES    (PMTU_BYTES),
        .RDMA_SHIFT    (RDMA_SHIFT),
        .RDMA_OST_BITS (RDMA_OST_BITS),
        .PID_BITS      (PID_BITS),
        .VFID_BITS     (VFID_BITS),
        .BANKS         (BANKS),
        .RD_LAT        (RD_LAT),
        .OSTD          (OSTD)
    ) inst_mem (
        .aclk          (aclk),
        .aresetn       (aresetn),

        .s_axi_awaddr  (s_axi.awaddr),
        .s_axi_awburst (s_axi.awburst),
        .s_axi_awid    (s_axi.awid),
        .s_axi_awlen   (s_axi.awlen),
        .s_axi_awsize  (s_axi.awsize),
        .s_axi_awvalid (s_axi.awvalid),
        .s_axi_awready (s_axi.awready),

        .s_axi_wdata   (s_axi.wdata),
        .s_axi_wstrb   (s_axi.wstrb),
        .s_axi_wlast   (s_axi.wlast),
        .s_axi_wvalid  (s_axi.wvalid),
        .s_axi_wready  (s_axi.wready),

        .s_axi_bid     (s_axi.bid),
        .s_axi_bresp   (s_axi.bresp),
        .s_axi_bvalid  (s_axi.bvalid),
        .s_axi_bready  (s_axi.bready),

        .s_axi_araddr  (s_axi.araddr),
        .s_axi_arburst (s_axi.arburst),
        .s_axi_arid    (s_axi.arid),
        .s_axi_arlen   (s_axi.arlen),
        .s_axi_arsize  (s_axi.arsize),
        .s_axi_arvalid (s_axi.arvalid),
        .s_axi_arready (s_axi.arready),

        .s_axi_rdata   (s_axi.rdata),
        .s_axi_rid     (s_axi.rid),
        .s_axi_rlast   (s_axi.rlast),
        .s_axi_rresp   (s_axi.rresp),
        .s_axi_rvalid  (s_axi.rvalid),
        .s_axi_rready  (s_axi.rready),

        .oob_err       (oob_err),
        .oob_cnt       (oob_cnt),
        .proto_err     (proto_err),
        .proto_cnt     (proto_cnt),
        .xsess_err     (xsess_err),
        .xsess_cnt     (xsess_cnt),
        .slot_ovf_err  (slot_ovf_err),
        .slot_ovf_cnt  (slot_ovf_cnt)
    );

endmodule
