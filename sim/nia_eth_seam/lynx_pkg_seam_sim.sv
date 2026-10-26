// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ps / 1ps

package lynxTypes;

    localparam integer AXIL_DATA_BITS = 64;
    localparam integer AXI_DATA_BITS = 512;
    localparam integer AXI_ADDR_BITS = 64;
    localparam integer AXI_NET_BITS = 512;
    localparam integer AXI_ID_BITS = 6;
    localparam integer PID_BITS = 6;
    localparam INPUT_TIMING = 1step;
    localparam OUTPUT_TIMING = 1step;

endpackage
