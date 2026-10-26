######################################################################################
# This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
# 
# MIT Licence
# Copyright (c) 2025, Systems Group, ETH Zurich
# All rights reserved.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
######################################################################################

cmake_minimum_required(VERSION 3.5)
set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)
find_package(CoyoteHW REQUIRED)

project(example_13_perf_fpga_mq)
message("*** Coyote Example 13: Multi-Queue FPGA-Initiated Data Movement [Hardware] ***")

set(EN_STRM 1)

set(N_STRM_AXI 4 CACHE STRING "Number of host streams" FORCE)

if(NOT N_STRM_AXI EQUAL 4)
    message(FATAL_ERROR
        "Example 13 requires N_STRM_AXI=4 (got ${N_STRM_AXI}). "
        "The RTL is generic, but init_ip.tcl ILA probe widths and the software (n_threads<=4) "
        "assume 4 streams. Update init_ip.tcl and sw/src/main.cpp if you truly need another value.")
endif()

set(N_REGIONS 1)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src"
)

create_hw()
