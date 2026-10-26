# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

set part xcvp1552-vsva2785-2mhp-i-s
set which [lindex $argv 0]
if {$which eq ""} { set which np1 }

set here [file normalize [file dirname [info script]]]
set rtl  [file normalize [file join $here ..]]

create_project -in_memory -part $part

read_verilog -sv [list $rtl/dcmac_ctl_pkg.sv $rtl/dcmac_ctl_seq.sv]

switch -- $which {
  np1 { set gens [list NPORTS=1 ANCHOR=0 RATE_CODE=0 RATE_FIELD=4  DONE_MASK=3]   }
  np4 { set gens [list NPORTS=4 ANCHOR=0 RATE_CODE=2 RATE_FIELD=16 DONE_MASK=255] }
  default { puts "OOC_ERROR unknown target $which"; exit 1 }
}

set xdc [file join $here ooc_gen_$which.xdc]
set fh [open $xdc w]
puts $fh "create_clock -period 4.000 -name aclk \[get_ports aclk\]"
close $fh
read_xdc $xdc

set cmd [list synth_design -top dcmac_ctl_seq -part $part -mode out_of_context]
foreach g $gens { lappend cmd -generic $g }
eval $cmd

puts "OOC_TARGET=$which"
puts "OOC_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "OOC_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"
puts "OOC_LUT=[llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]"
puts "OOC_FF=[llength [get_cells -hier -filter {REF_NAME =~ FD*}]]"
puts "OOC_RAMB36=[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]"
puts "OOC_RAMB18=[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]"
puts "OOC_URAM=[llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]"
puts "OOC_DSP=[llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]"
set wns "n/a"
catch {set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]}
puts "OOC_POSTSYNTH_WNS=$wns"

set nfan "n/a"
catch {
  set tx [get_pins -quiet -of_objects [get_ports tx_datapath_reset]]
  set nfan [llength [all_fanin -quiet -flat -startpoints_only [get_ports tx_datapath_reset]]]
}
puts "OOC_TXDPRESET_FANIN=$nfan"

report_utilization
puts "OOC_DONE"
