# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set part xcvp1552-vsva2785-2mhp-i-s
set which [lindex $argv 0]
if {$which eq ""} { set which core }

set rtl [file normalize [file join [file dirname [info script]] ..]]
set scaf [file normalize [file dirname [info script]]]

create_project -in_memory -part $part

set core_srcs [list \
  $rtl/dcmac_seg_axis_adapter.sv \
  $rtl/nia_axis_dwidth.sv \
  $rtl/nia_axis_async_fifo.sv \
  $rtl/dcmac_axis_frame_fifo.sv \
  $rtl/dcmac_mac_ctl_fsm.sv \
  $rtl/dcmac_axis_core.sv ]

if {$which eq "core"} {
  read_verilog -sv $core_srcs
  set top dcmac_axis_core
} else {
  read_verilog -sv [concat [list $scaf/lynx_pkg_min.sv $scaf/axi4s_min.sv] $core_srcs \
                    [list $rtl/ctl/dcmac_ctl_pkg.sv $rtl/ctl/dcmac_ctl_seq.sv \
                          $rtl/dcmac_100g_phy_stub.sv $rtl/dcmac_axis_wrapper.sv]]
  set top dcmac_axis_wrapper
}

synth_design -top $top -part $part -mode out_of_context
puts "OOC_TOP=$top"
puts "OOC_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "OOC_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"
report_utilization
puts "OOC_DONE"
