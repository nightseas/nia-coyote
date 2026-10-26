# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

set part xcvp1552-vsva2785-2mhp-i-s
set which [lindex $argv 0]
if {$which eq ""} { set which flat }

set here [file normalize [file dirname [info script]]]
set rtl  [file normalize [file join $here ..]]
set hdl  [file normalize [file join $rtl ../..]]

create_project -in_memory -part $part

set srcs [list $rtl/nia_uram_sdp.sv $rtl/axi_uram_mem.sv]
set gens {}

switch -- $which {
  flat {
    set top axi_uram_mem
    set gens [list ADDR_MAP=flat N_SESSIONS=16 WINDOW_BITS=18]
  }
  rdma_slot {
    set top axi_uram_mem
    set gens [list ADDR_MAP=rdma_slot PMTU_BYTES=4096 PID_BITS=6 RDMA_OST_BITS=4 RDMA_SHIFT=27]
  }
  intf {
    set top axi_uram_mem_intf
    set srcs [concat [list $here/lynx_pkg_min.sv $hdl/pkg/axi_intf.sv] $srcs \
                     [list $rtl/axi_uram_mem_intf.sv]]
    set gens [list ADDR_MAP=flat N_SESSIONS=16 WINDOW_BITS=18]
  }
  default { puts "OOC_ERROR unknown target $which"; exit 1 }
}

read_verilog -sv $srcs

set xdc [file join $here ooc_gen.xdc]
set fh [open $xdc w]
puts $fh "create_clock -period 4.000 -name aclk \[get_ports aclk\]"
close $fh
read_xdc $xdc

set cmd [list synth_design -top $top -part $part -mode out_of_context]
foreach g $gens { lappend cmd -generic $g }
eval $cmd

puts "OOC_TOP=$top"
puts "OOC_TARGET=$which"
puts "OOC_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "OOC_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"
puts "OOC_URAM=[llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]"
puts "OOC_RAMB36=[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]"
puts "OOC_RAMB18=[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]"
puts "OOC_LUT=[llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]"
puts "OOC_FF=[llength [get_cells -hier -filter {REF_NAME =~ FD*}]]"
set wns "n/a"
catch {set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]}
puts "OOC_POSTSYNTH_WNS=$wns"
report_utilization
puts "OOC_DONE"
