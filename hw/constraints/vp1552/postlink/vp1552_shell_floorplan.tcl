# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set nia_fplan_enable 0
if {[info exists ::env(NIA_FPLAN_ROCE_SLR1)] && $::env(NIA_FPLAN_ROCE_SLR1) eq "1"} {
  set nia_fplan_enable 1
}

if {$nia_fplan_enable eq 0} {
  puts "NIA_FPLAN disabled, every cell is placed without a region assignment"
} else {
  set nia_fplan_slr [get_slrs -quiet SLR1]
  if {[llength $nia_fplan_slr] != 1} {
    error "NIA_FPLAN FAIL: SLR1 does not resolve on this part, so no region assignment can be made"
  }
  set nia_fplan_regions [get_clock_regions -quiet -of_objects $nia_fplan_slr]
  if {[llength $nia_fplan_regions] == 0} {
    error "NIA_FPLAN FAIL: SLR1 reports no clock region, so the pblock would bound nothing"
  }

  set nia_fplan_target [get_cells -quiet -hier -filter {NAME =~ *inst_network_stack/inst_roce_stack}]
  if {[llength $nia_fplan_target] != 1} {
    error "NIA_FPLAN FAIL: the RDMA service resolves to [llength $nia_fplan_target] cell(s) named\
 *inst_network_stack/inst_roce_stack. The hierarchy has moved, so the region assignment names the\
 wrong logic and is refused"
  }

  set nia_fplan_leaves [get_cells -quiet -hier -filter "NAME =~ [get_property NAME $nia_fplan_target]/*"]
  set nia_fplan_sites  [llength [get_sites -quiet -of_objects $nia_fplan_slr -filter {SITE_TYPE =~ SLICE*}]]

  set nia_fplan_ranges [list]
  foreach nia_fplan_region [lsort [get_property NAME $nia_fplan_regions]] {
    lappend nia_fplan_ranges "CLOCKREGION_$nia_fplan_region"
  }

  create_pblock nia_pblock_roce
  add_cells_to_pblock [get_pblocks nia_pblock_roce] $nia_fplan_target
  resize_pblock [get_pblocks nia_pblock_roce] -add [join $nia_fplan_ranges " "]
  set_property SNAPPING_MODE ON [get_pblocks nia_pblock_roce]
  set_property EXCLUDE_PLACEMENT 0 [get_pblocks nia_pblock_roce]

  puts "NIA_FPLAN pblock nia_pblock_roce holds [get_property NAME $nia_fplan_target] with\
 [llength $nia_fplan_leaves] descendant cell(s) over [llength $nia_fplan_regions] clock region(s)\
 of SLR1 carrying $nia_fplan_sites slice site(s)"
  puts "NIA_FPLAN regions [lsort [get_property NAME $nia_fplan_regions]]"
}
