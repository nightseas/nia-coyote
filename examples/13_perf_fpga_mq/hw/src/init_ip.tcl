# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT

if {$cfg(fpga_arch) eq "ultrascale_plus"} {
    create_ip -name ila -vendor xilinx.com -library ip -module_name ila_perf_fpga_mq
} elseif {$cfg(fpga_arch) eq "versal"} {
    create_ip -name axis_ila -vendor xilinx.com -library ip -module_name ila_perf_fpga_mq
} else {
    puts "ERROR: Unsupported FPGA architecture: $cfg(fpga_arch)"
    exit 1
}

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {15} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
    CONFIG.C_PROBE0_WIDTH {8} \
    CONFIG.C_PROBE1_WIDTH {4} \
    CONFIG.C_PROBE2_WIDTH {4} \
    CONFIG.C_PROBE3_WIDTH {32} \
    CONFIG.C_PROBE4_WIDTH {64} \
    CONFIG.C_PROBE5_WIDTH {64} \
    CONFIG.C_PROBE6_WIDTH {32} \
    CONFIG.C_PROBE13_WIDTH {2} \
    CONFIG.C_PROBE14_WIDTH {2} \
] [get_ips ila_perf_fpga_mq]
