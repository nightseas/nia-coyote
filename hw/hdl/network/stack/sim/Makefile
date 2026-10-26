TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE      := $(shell pwd)
STACK_DIR := $(HERE)/..
SCAFFOLD  := $(HERE)/../../dcmac_eth/synth

VERILOG_SOURCES := $(SCAFFOLD)/lynx_pkg_min.sv \
                   $(SCAFFOLD)/axi4s_min.sv \
                   $(STACK_DIR)/host_networking_prefilter.sv \
                   $(HERE)/host_networking_prefilter_flat.sv

TOPLEVEL := host_networking_prefilter_flat
MODULE   := test_host_networking_prefilter

EN_RDMA ?= 1
EN_TCP  ?= 0

ifeq ($(EN_RDMA),1)
    COMPILE_ARGS += +define+EN_RDMA
endif
ifeq ($(EN_TCP),1)
    COMPILE_ARGS += +define+EN_TCP
endif

export EN_RDMA
export EN_TCP

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-fatal
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
