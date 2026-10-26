// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
package lynxTypes;
    localparam integer AXI_DATA_BITS   = 512;
    localparam integer AXI_DDR_BITS    = 512;
    localparam integer AXI_NET_BITS    = 512;
    localparam integer AXI_ADDR_BITS   = 64;
    localparam integer AXI_ID_BITS     = 6;
    localparam integer AXIL_DATA_BITS  = 64;
    localparam integer METAF_DATA_BITS = 64;
    localparam integer PID_BITS        = 6;
endpackage
