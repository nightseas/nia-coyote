# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set part xcvp1552-vsva2785-2mhp-i-s
set which [lindex $argv 0]
if {$which eq ""} { set which reset_gen }

set rtl  [file normalize [file join [file dirname [info script]] ..]]
set scaf [file normalize [file dirname [info script]]]
set eth  [file normalize [file join $rtl nia_eth]]

create_project -in_memory -part $part

set eth_common [list \
  $eth/ctl/dcmac_ctl_pkg.sv \
  $eth/ctl/dcmac_ctl_seq.sv \
  $eth/ctl/wdt.sv \
  $eth/ctl/dcmac_link_sample.sv \
  $eth/ctl/dcmac_link_wdt.sv \
  $eth/ctl/dcmac_axil_exec.sv \
  $eth/ctl/dcmac_axil_arb.sv \
  $eth/ctl/dcmac_mac_ctl_fsm.sv \
  $eth/ctl/dcmac_link_ctl.sv \
  $eth/dcmac_sync2.sv \
  $eth/gt_rst_req_gate.sv \
  $eth/dcmac_seg_axis_adapter.sv \
  $eth/eth_axis_dwidth.sv \
  $eth/dcmac_axis_frame_fifo.sv \
  $eth/dcmac_axis_adapter.sv \
  $eth/dcmac_port.sv \
  $eth/dcmac_axis_top.sv ]

switch -- $which {
  reset_gen {
    read_verilog -sv [list $rtl/dcmac_usr_reset_gen.sv]
    set top dcmac_usr_reset_gen
    set generics [list MODE=1]
  }
  reset_gen_m2 {
    read_verilog -sv [list $rtl/dcmac_usr_reset_gen.sv]
    set top dcmac_usr_reset_gen
    set generics [list MODE=2]
  }
  link_ctl {
    read_verilog -sv [list \
      $eth/ctl/dcmac_ctl_pkg.sv \
      $eth/ctl/dcmac_ctl_seq.sv \
      $eth/ctl/wdt.sv \
      $eth/ctl/dcmac_link_sample.sv \
      $eth/ctl/dcmac_link_wdt.sv \
      $eth/ctl/dcmac_axil_exec.sv \
      $eth/ctl/dcmac_axil_arb.sv \
      $eth/ctl/dcmac_mac_ctl_fsm.sv \
      $eth/dcmac_sync2.sv \
      $eth/gt_rst_req_gate.sv \
      $eth/ctl/dcmac_link_ctl.sv ]
    set top dcmac_link_ctl
  }
  wrapper {
    read_verilog -sv [concat \
      [list $scaf/lynx_pkg_min.sv $scaf/axi4s_min.sv] \
      $eth_common \
      [list $eth/dcmac_phy_model.sv \
            $eth/eth_axis_async_fifo.sv \
            $eth/tx_frame_fifo.sv \
            $rtl/dcmac_usr_reset_gen.sv \
            $rtl/dcmac_axis_wrapper.sv]]
    set top dcmac_axis_wrapper
  }
  wrapper_200g {
    read_verilog -sv [concat \
      [list $scaf/lynx_pkg_min.sv $scaf/axi4s_min.sv] \
      $eth_common \
      [list $eth/dcmac_phy_model.sv \
            $eth/eth_axis_async_fifo.sv \
            $eth/tx_frame_fifo.sv \
            $rtl/dcmac_usr_reset_gen.sv \
            $rtl/dcmac_axis_wrapper.sv]]
    set top dcmac_axis_wrapper
    set generics [list N_SEG=4]
  }
  default {
    puts "OOC_ERROR unknown arm $which, expected reset_gen, reset_gen_m2, link_ctl, wrapper or wrapper_200g"
    exit 1
  }
}

if {![info exists generics]} { set generics [list] }
if {[llength $generics]} {
  synth_design -top $top -part $part -mode out_of_context -generic $generics
} else {
  synth_design -top $top -part $part -mode out_of_context
}
foreach {cp period} {usr_clk 4.000 clk 4.000 aclk 4.000 seg_clk 2.558 init_clk 10.000} {
  set cp_obj [get_ports -quiet $cp]
  if {[llength $cp_obj]} {
    create_clock -period $period -name $cp $cp_obj
  }
}

set async_pair [list aclk seg_clk]
set have_pair 1
foreach c $async_pair {
  if {![llength [get_clocks -quiet $c]]} { set have_pair 0 }
}
if {$have_pair} {
  set cross 0
  set synced 0
  set unsynced [list]
  foreach a $async_pair {
    foreach b $async_pair {
      if {$a eq $b} { continue }
      foreach p [get_timing_paths -quiet -from [get_clocks $a] -to [get_clocks $b] \
                     -max_paths 5000 -nworst 5000 -delay_type max] {
        set ep [get_property ENDPOINT_PIN $p]
        set cell [get_property NAME [get_cells -quiet -of_objects $ep]]
        incr cross
        if {[string match {*_sync*} $cell] || [string match {*rst_sync*} $cell]} {
          incr synced
        } else {
          lappend unsynced $cell
        }
      }
    }
  }
  puts "OOC_XCLK_ENDPOINTS=$cross OOC_XCLK_SYNCED=$synced"
  foreach c [lsort -unique $unsynced] { puts "OOC_XCLK_UNSYNCED=$c" }
  if {$cross > 0 && [llength $unsynced] == 0} {
    set_clock_groups -asynchronous -name ooc_async_aclk_seg \
        -group [get_clocks aclk] -group [get_clocks seg_clk]
    puts "OOC_ASYNC_APPLIED=1"
  } else {
    puts "OOC_ASYNC_APPLIED=0"
  }
}
puts "OOC_TOP=$top OOC_ARM=$which OOC_GENERICS=$generics"
puts "OOC_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "OOC_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"
report_utilization
report_timing_summary -max_paths 1
report_timing -max_paths 5 -nworst 5 -delay_type max -sort_by group
puts "OOC_DONE"
