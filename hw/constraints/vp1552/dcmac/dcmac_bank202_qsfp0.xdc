# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

create_clock -period 6.400 -name gt_ref_clk0_p -waveform {0.000 3.200} [get_ports gt0_refclk_p]

set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks clk_pl_0] \
  -group [get_clocks -of_objects [get_pins -of [get_cells -hier -filter {NAME =~ *i_dcmac_clk_wiz/inst/clock_primitive_inst/MMCME5_inst}] -filter {NAME =~ *CLKOUT*}]] \
  -group [get_clocks -of_objects [get_pins -of [get_cells -hier -filter {NAME =~ *i_usr_clk_wiz/inst/clock_primitive_inst/MMCME5_inst}] -filter {NAME =~ *CLKOUT*}]]

set_property LOC GTM_QUAD_X0Y0 [get_cells -hier -filter {REF_NAME == GTME5_QUAD}]

set_property LOC GTM_REFCLK_X0Y0 [get_cells -hier -filter {NAME =~ *dcmac_IBUFDS_GTE5_REFCLK0_gt0}]

