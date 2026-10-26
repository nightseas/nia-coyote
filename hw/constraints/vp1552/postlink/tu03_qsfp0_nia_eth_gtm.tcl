# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
create_clock -period 6.400 -name gt0_refclk_p -waveform {0.000 3.200} [get_ports gt0_refclk_p];

set tu03_gtm_quad_sites {GTM_QUAD_X0Y0 GTM_QUAD_X0Y1}
set tu03_gtm_refclk_sites {GTM_REFCLK_X0Y0 GTM_REFCLK_X0Y2}

set tu03_gtm_quads [lsort [get_cells -quiet -hier \
  -filter {NAME =~ *i_gtwiz*/*gt_quad_base_0_inst/inst/quad_inst}]]
set tu03_gtm_refclk_buffers [lsort [get_cells -quiet -hier \
  -filter {NAME =~ *dcmac_IBUFDS_GTE5_REFCLK*}]]

if {[llength $tu03_gtm_quads] == 0} {
  error "TU03_XDC FAIL: no transceiver quad matched, so no quad would be placed"
}
if {[llength $tu03_gtm_quads] > [llength $tu03_gtm_quad_sites]} {
  error "TU03_XDC FAIL: [llength $tu03_gtm_quads] transceiver quad(s) against\
         [llength $tu03_gtm_quad_sites] site(s) on QSFP0"
}
if {[llength $tu03_gtm_refclk_buffers] > [llength $tu03_gtm_refclk_sites]} {
  error "TU03_XDC FAIL: [llength $tu03_gtm_refclk_buffers] reference clock buffer(s) against\
         [llength $tu03_gtm_refclk_sites] site(s) on QSFP0"
}

set tu03_site_index 0
foreach tu03_quad $tu03_gtm_quads {
  set_property LOC [lindex $tu03_gtm_quad_sites $tu03_site_index] [get_cells $tu03_quad]
  incr tu03_site_index
}

set tu03_site_index 0
foreach tu03_refclk_buffer $tu03_gtm_refclk_buffers {
  set_property LOC [lindex $tu03_gtm_refclk_sites $tu03_site_index] [get_cells $tu03_refclk_buffer]
  incr tu03_site_index
}

puts "TU03_XDC placed [llength $tu03_gtm_quads] transceiver quad(s) and\
      [llength $tu03_gtm_refclk_buffers] reference clock buffer(s)"

set tu03_platform_clocks [get_clocks -quiet -include_generated_clocks clk_pl_0]
if {[llength $tu03_platform_clocks] == 0} {
  error "TU03_XDC FAIL: clk_pl_0 matched no clock, so the platform tree cannot be grouped. Every\
 clock of the static layer, the shell and the network stack is generated from it, per\
 hw/templates/common/shell_ctrl_tmplt.txt, which derives aclk, nclk and uclk from xclk"
}

set tu03_mac_wizard_groups [list]
set tu03_mac_wizard_names [list]
foreach tu03_wizard_pattern {*i_dcmac_clk_wiz*MMCME5_inst *i_usr_clk_wiz*MMCME5_inst} {
  set tu03_wizard_cells [get_cells -quiet -hier -filter "NAME =~ $tu03_wizard_pattern"]
  if {[llength $tu03_wizard_cells] == 0} {
    error "TU03_XDC FAIL: no clock generator matched $tu03_wizard_pattern, so the MAC clock trees\
 cannot be separated from the platform tree"
  }
  set tu03_wizard_clocks [get_clocks -quiet -of_objects [get_pins -quiet \
    -of_objects $tu03_wizard_cells -filter {REF_PIN_NAME =~ CLKOUT*}]]
  if {[llength $tu03_wizard_clocks] == 0} {
    error "TU03_XDC FAIL: $tu03_wizard_pattern drives no clock, so its tree cannot be grouped"
  }
  lappend tu03_mac_wizard_groups $tu03_wizard_clocks
  lappend tu03_mac_wizard_names $tu03_wizard_pattern
}

set tu03_membership [dict create]
set tu03_duplicated [list]
set tu03_group_index 0
foreach tu03_set [concat [list $tu03_platform_clocks] $tu03_mac_wizard_groups] {
  incr tu03_group_index
  foreach tu03_clock $tu03_set {
    set tu03_clock_name [get_property NAME $tu03_clock]
    if {[dict exists $tu03_membership $tu03_clock_name]} {
      lappend tu03_duplicated $tu03_clock_name
    } else {
      dict set tu03_membership $tu03_clock_name $tu03_group_index
    }
  }
}
if {[llength $tu03_duplicated] > 0} {
  error "TU03_XDC FAIL: [llength [lsort -unique $tu03_duplicated]] clock(s) belong to more than one\
 group, so every synchronous path between them would be excluded from timing analysis. This is the\
 defect Vivado reports as 12-3521 and it removed the static layer to shell register path from\
 analysis in job t9postlink_0921_2350: [lsort -unique $tu03_duplicated]"
}

set tu03_group_arguments [list -group $tu03_platform_clocks]
foreach tu03_set $tu03_mac_wizard_groups {
  lappend tu03_group_arguments -group $tu03_set
}
set_clock_groups -asynchronous -name tu03_platform_against_mac_wizards {*}$tu03_group_arguments
puts "TU03_XDC asynchronous groups: platform tree [llength $tu03_platform_clocks] clock(s) against\
 [llength $tu03_mac_wizard_groups] MAC clock generator group(s) over [dict size $tu03_membership]\
 clock(s), 0 overlap"

set tu03_rst_sync_cells [get_cells -quiet -hier \
  -filter {ORIG_REF_NAME == rst_sync || REF_NAME == rst_sync}]
set tu03_reset_async_pins [list]
foreach tu03_rst_sync $tu03_rst_sync_cells {
  foreach tu03_pin [get_pins -quiet -of_objects \
    [get_cells -quiet -hier -filter "PARENT == $tu03_rst_sync"] \
    -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}] {
    lappend tu03_reset_async_pins $tu03_pin
  }
}
if {[llength $tu03_reset_async_pins] == 0} {
  set tu03_reset_async_pins [get_pins -quiet -hier -filter {NAME =~ *release_chain_r_reg*/CLR}]
  foreach tu03_pin [get_pins -quiet -hier -filter {NAME =~ *release_chain_r_reg*/PRE}] {
    lappend tu03_reset_async_pins $tu03_pin
  }
}
if {[llength $tu03_reset_async_pins] == 0} {
  error "TU03_XDC FAIL: no reset synchroniser asynchronous pin matched"
}
set_false_path -to $tu03_reset_async_pins
puts "TU03_XDC rst_sync instances [llength $tu03_rst_sync_cells] asynchronous pins\
 [llength $tu03_reset_async_pins]"

proc tu03_bound_crossings_into {entry_dict label} {
  dict for {tu03_dst tu03_pins} $entry_dict {
    set tu03_from [list]
    foreach tu03_clk [get_clocks -quiet] {
      set tu03_name [get_property NAME $tu03_clk]
      if {$tu03_name ne $tu03_dst} { lappend tu03_from $tu03_name }
    }
    if {[llength $tu03_from] == 0} {
      error "TU03_XDC FAIL: $tu03_dst is the only clock, so no crossing into it can be named"
    }
    set tu03_period [get_property PERIOD [get_clocks $tu03_dst]]
    set_max_delay -datapath_only $tu03_period -from [get_clocks $tu03_from] -to $tu03_pins
    puts "TU03_XDC $label entries [llength $tu03_pins] into $tu03_dst bounded at\
 $tu03_period ns from [llength $tu03_from] other clock(s)"
  }
}

set tu03_sync2_cells [get_cells -quiet -hier \
  -filter {ORIG_REF_NAME == dcmac_sync2 || REF_NAME == dcmac_sync2}]
if {[llength $tu03_sync2_cells] == 0} {
  error "TU03_XDC FAIL: no dcmac_sync2 instance matched, so every crossing into a synchroniser\
 would be timed against the clock relationship the synchroniser exists to break"
}
set tu03_sync2_flops [list]
foreach tu03_sync2 $tu03_sync2_cells {
  foreach tu03_cell [get_cells -quiet -hier -filter "PARENT == $tu03_sync2"] {
    lappend tu03_sync2_flops $tu03_cell
  }
}
set tu03_sync2_entry [dict create]
foreach tu03_pin [get_pins -quiet -of_objects $tu03_sync2_flops -filter {REF_PIN_NAME == D}] {
  if {![regexp {sr_reg\[0\]} [get_property NAME $tu03_pin]]} { continue }
  set tu03_dst_clk [get_clocks -quiet -of_objects \
    [get_pins -quiet -of_objects [get_cells -quiet -of_objects $tu03_pin] \
       -filter {REF_PIN_NAME == C}]]
  if {[llength $tu03_dst_clk] != 1} { continue }
  dict lappend tu03_sync2_entry [get_property NAME [lindex $tu03_dst_clk 0]] $tu03_pin
}
if {[dict size $tu03_sync2_entry] == 0} {
  error "TU03_XDC FAIL: no dcmac_sync2 first stage input matched, so the crossing bound would\
 name nothing"
}
tu03_bound_crossings_into $tu03_sync2_entry synchroniser

set tu03_snap_cells [get_cells -quiet -hier \
  -filter {ORIG_REF_NAME =~ dcmac_csr_snap* || REF_NAME =~ dcmac_csr_snap*}]
if {[llength $tu03_snap_cells] == 0} {
  set tu03_axil_driven [get_pins -quiet -hier -filter {NAME =~ *u_mac*s_axil_awvalid*}]
  puts "TU03_XDC handshake instances 0, so no register plane vector crosses a clock boundary.\
 This configuration ties the MAC control plane off at dcmac_axis_wrapper.sv, and the AXI-Lite\
 write valid matches [llength $tu03_axil_driven] pin(s). Where a later configuration drives that\
 control plane, dcmac_csr_snap appears and the bound below applies to it"
} else {
  set tu03_snap_entry [dict create]
  foreach tu03_snap $tu03_snap_cells {
    foreach tu03_pin [get_pins -quiet -of_objects \
      [get_cells -quiet -hier -filter "PARENT =~ $tu03_snap*"] -filter {REF_PIN_NAME == D}] {
      if {![regexp {(dout_r_reg|hold_reg)} [get_property NAME $tu03_pin]]} { continue }
      set tu03_dst_clk [get_clocks -quiet -of_objects \
        [get_pins -quiet -of_objects [get_cells -quiet -of_objects $tu03_pin] \
           -filter {REF_PIN_NAME == C}]]
      if {[llength $tu03_dst_clk] != 1} { continue }
      dict lappend tu03_snap_entry [get_property NAME [lindex $tu03_dst_clk 0]] $tu03_pin
    }
  }
  if {[dict size $tu03_snap_entry] == 0} {
    error "TU03_XDC FAIL: dcmac_csr_snap is instantiated and no handshake stage matched, so the\
 register plane vector would be timed as a synchronous path and would fail by most of a cycle"
  }
  tu03_bound_crossings_into $tu03_snap_entry handshake
}

