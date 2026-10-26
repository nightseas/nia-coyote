# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design];

create_clock -period 10.000 -name pcie_ref_clk [get_ports pcie_clk_clk_p];

create_clock -period 6.400 -name gt0_refclk_p [get_ports gt0_refclk_p];
