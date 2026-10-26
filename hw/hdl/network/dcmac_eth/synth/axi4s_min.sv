// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`ifndef AXI_INTF_MIN_SV_
`define AXI_INTF_MIN_SV_
`timescale 1ns / 1ps
import lynxTypes::*;
`define ASSERT_SIGNAL_STABLE(x)
`define ASSERT_NOT_UNDEFINED(x)
interface AXI4S #(
	parameter AXI4S_DATA_BITS = AXI_DATA_BITS
) (
    input logic aclk,
    input logic aresetn
);

typedef logic [AXI4S_DATA_BITS-1:0] data_t;
typedef logic [AXI4S_DATA_BITS/8-1:0] keep_t;

data_t          tdata;
keep_t  		tkeep;
logic           tlast;
logic           tready;
logic           tvalid;

task tie_off_m ();
    tdata      = 0;
    tkeep      = 0;
    tlast     = 1'b0;
    tvalid     = 1'b0;
endtask

task tie_off_s ();
    tready     = 1'b0;
endtask

modport m (
	import tie_off_m,
	input tready,
	output tdata, tkeep, tlast, tvalid
);

modport s (
    import tie_off_s,
    input tdata, tkeep, tlast, tvalid,
    output tready
);

`ifndef SYNTHESIS
`ASSERT_SIGNAL_STABLE(tdata);
`ASSERT_SIGNAL_STABLE(tkeep);
`ASSERT_SIGNAL_STABLE(tlast);
`ASSERT_NOT_UNDEFINED(tvalid);
`ASSERT_NOT_UNDEFINED(tready);
`endif

endinterface
`endif
