# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set part xcvp1552-vsva2785-2mhp-i-s
set here [file dirname [info script]]
set rtl  [file normalize [file join $here ..]]

proc probe {tag top addr_w} {
  global part rtl here
  puts "NIA_PROBE_BEGIN $tag"
  if {[catch {
    create_project -in_memory -part $part
    read_verilog -sv [list $rtl/dcmac_axis_frame_fifo.sv $here/frame_fifo_mem_style_tops.sv]
    set xdcf [file join [pwd] s20_probe_clk.xdc]
    set fh [open $xdcf w]; puts $fh "create_clock -period 4.000 -name clk \[get_ports clk\]"; close $fh
    read_xdc $xdcf
    synth_design -top $top -part $part -mode out_of_context -generic ADDR_W=$addr_w
    puts "PROBE=$tag ERRORS=[get_msg_config -severity {ERROR} -count] CRIT=[get_msg_config -severity {CRITICAL WARNING} -count]"
    puts "PROBE=$tag LUTCELLS=[llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]"
    puts "PROBE=$tag RAMB36=[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]"
    puts "PROBE=$tag RAMB18=[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]"
    puts "PROBE=$tag URAM=[llength [get_cells -hier -filter {REF_NAME =~ URAM*}]]"
    report_utilization
    catch {
      set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
      if {[llength $p] > 0} { puts "PROBE=$tag WNS=[get_property SLACK $p]" }
    }
  } e]} { puts "PROBE=$tag FAILED: [string range $e 0 400]" }
  catch {close_project}
  puts "NIA_PROBE_END $tag"
}

probe D9 frame_fifo_distributed_ram_top  9
probe B9 frame_fifo_block_ram_top 9
probe D8 frame_fifo_distributed_ram_top  8
probe B8 frame_fifo_block_ram_top 8

puts "NIA_S20_AREA_PROBE_DONE"
