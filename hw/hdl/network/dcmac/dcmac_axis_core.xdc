# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

set _sync_cells [get_cells -quiet -hier -regexp \
  {.*u_(rx|tx)_cdc/(rgray_s1|rgray_s2|wgray_s1|wgray_s2)_reg.*}]
if {[llength $_sync_cells] > 0} {
  set_property ASYNC_REG TRUE $_sync_cells
}

set _usr [get_clocks -quiet -of_objects [get_ports -quiet usr_clk]]
set _seg [get_clocks -quiet -of_objects [get_ports -quiet seg_clk]]
if {[llength $_usr] > 0 && [llength $_seg] > 0} {
  set_clock_groups -asynchronous -group $_usr -group $_seg
}
