# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set outdir [lindex $argv 0]
if {$outdir eq ""} { set outdir "./ip" }
file mkdir $outdir

set part "xcvp1552-vsva2785-2mhp-i-s"
puts "SEAMIP_PART=$part"
puts "SEAMIP_VIVADO=[version -short]"

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property ip_output_repo $outdir [current_project]
set_property ip_repo_paths {} [current_project]
update_ip_catalog -quiet

create_ip -name axis_dwidth_converter -vendor xilinx.com -library ip -version 1.1 \
    -module_name axis_dwidth_converter_nia_eth_rx_1024_to_512 -dir $outdir
set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {128} CONFIG.M_TDATA_NUM_BYTES {64} \
    CONFIG.HAS_TKEEP {1} CONFIG.HAS_MI_TKEEP {1} CONFIG.HAS_TLAST {1}] \
    [get_ips axis_dwidth_converter_nia_eth_rx_1024_to_512]

create_ip -name axis_dwidth_converter -vendor xilinx.com -library ip -version 1.1 \
    -module_name axis_dwidth_converter_nia_eth_tx_512_to_1024 -dir $outdir
set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {64} CONFIG.M_TDATA_NUM_BYTES {128} \
    CONFIG.HAS_TKEEP {1} CONFIG.HAS_MI_TKEEP {1} CONFIG.HAS_TLAST {1}] \
    [get_ips axis_dwidth_converter_nia_eth_tx_512_to_1024]

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 \
    -module_name axis_data_fifo_net_ccross_early_512 -dir $outdir
set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.FIFO_DEPTH {512} CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1}] \
    [get_ips axis_data_fifo_net_ccross_early_512]

create_ip -name axis_register_slice -vendor xilinx.com -library ip -version 1.1 \
    -module_name axis_register_slice_512 -dir $outdir
set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.REG_CONFIG {8} \
    CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1}] [get_ips axis_register_slice_512]

set ip_list {axis_dwidth_converter_nia_eth_rx_1024_to_512
             axis_dwidth_converter_nia_eth_tx_512_to_1024 axis_data_fifo_net_ccross_early_512
             axis_register_slice_512}

foreach ip $ip_list {
    puts "SEAMIP_BEGIN=$ip"
    generate_target {simulation instantiation_template} [get_ips $ip]
    set files [get_files -compile_order sources -used_in simulation -of_objects [get_ips $ip]]
    set handle [open "$outdir/${ip}.simfiles" w]
    foreach file $files { puts $handle $file }
    close $handle
    puts "SEAMIP_NFILES=$ip:[llength $files]"
    foreach property {TDATA_NUM_BYTES S_TDATA_NUM_BYTES M_TDATA_NUM_BYTES FIFO_DEPTH \
                      IS_ACLK_ASYNC HAS_TKEEP HAS_MI_TKEEP HAS_TLAST} {
        catch { puts "SEAMIP_CFG=$ip:$property=[get_property CONFIG.$property [get_ips $ip]]" }
    }
    puts "SEAMIP_END=$ip"
}

puts "SEAMIP_DONE rc=0"
