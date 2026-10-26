# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

set outdir [lindex $argv 0]
if {$outdir eq ""} { set outdir "./ip" }
file mkdir $outdir

set part "xcvp1552-vsva2785-2mhp-i-s"
puts "NIA_GENIP_PART=$part"
puts "NIA_GENIP_VIVADO=[version -short]"

create_project -in_memory -part $part
set_property ip_output_repo $outdir [current_project]
set_property ip_repo_paths {} [current_project]
update_ip_catalog -quiet

set ips [get_ipdefs -filter {NAME == axis_switch}]
puts "NIA_GENIP_IPDEFS=$ips"

create_ip -name axis_switch -vendor xilinx.com -library ip -version 1.1 \
    -module_name axis_switch_512_4to1 -dir $outdir
set_property -dict [list CONFIG.NUM_SI {4} CONFIG.NUM_MI {1} CONFIG.TDATA_NUM_BYTES {64} \
    CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.HAS_TSTRB {0} CONFIG.TID_WIDTH {0} \
    CONFIG.TDEST_WIDTH {0} CONFIG.TUSER_WIDTH {0} CONFIG.ROUTING_MODE {0} \
    CONFIG.ARB_ON_TLAST {1} CONFIG.ARB_ON_MAX_XFERS {0}] [get_ips axis_switch_512_4to1]

create_ip -name axis_switch -vendor xilinx.com -library ip -version 1.1 \
    -module_name axis_switch_512_2to1 -dir $outdir
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1} CONFIG.TDATA_NUM_BYTES {64} \
    CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.HAS_TSTRB {0} CONFIG.TID_WIDTH {0} \
    CONFIG.TDEST_WIDTH {0} CONFIG.TUSER_WIDTH {0} CONFIG.ROUTING_MODE {0} \
    CONFIG.ARB_ON_TLAST {1} CONFIG.ARB_ON_MAX_XFERS {0}] [get_ips axis_switch_512_2to1]

foreach ip {axis_switch_512_4to1 axis_switch_512_2to1} {
    puts "NIA_GENIP_BEGIN=$ip"
    generate_target {simulation instantiation_template} [get_ips $ip]
    set fl [get_files -compile_order sources -used_in simulation -of_objects [get_ips $ip]]
    set fh [open "$outdir/${ip}.simfiles" w]
    foreach f $fl { puts $fh $f }
    close $fh
    puts "NIA_GENIP_NFILES=$ip:[llength $fl]"
    foreach p {NUM_SI NUM_MI TDATA_NUM_BYTES HAS_TKEEP HAS_TLAST ROUTING_MODE ARB_ON_TLAST ARB_ON_MAX_XFERS TDEST_WIDTH} {
        catch { puts "NIA_GENIP_CFG=$ip:$p=[get_property CONFIG.$p [get_ips $ip]]" }
    }
    puts "NIA_GENIP_END=$ip"
}

puts "NIA_GENIP_DONE rc=0"
