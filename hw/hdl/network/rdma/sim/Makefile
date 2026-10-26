TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

RTL_DIR := $(shell pwd)/..
VERILOG_SOURCES := $(RTL_DIR)/nia_rdma_psn_probe.sv

TOPLEVEL := nia_rdma_psn_probe
MODULE   := test_nia_rdma_psn_probe

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
                  -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
