
TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

RTL_DIR := $(shell pwd)/..
VERILOG_SOURCES := \
  $(RTL_DIR)/nia_uram_sdp.sv \
  $(RTL_DIR)/axi_uram_mem.sv

TOPLEVEL := axi_uram_mem
MODULE   := test_axi_uram_mem

export ADDR_MAP      ?= flat
export N_SESSIONS    ?= 16
export WINDOW_BITS   ?= 18
export PMTU_BYTES    ?= 4096
export PID_BITS      ?= 6
export RDMA_OST_BITS ?= 4
export RDMA_SHIFT    ?= 27
export SOAK_BURSTS   ?= 2500
export TPUT_CYCLES   ?= 20000
export RAW_N         ?= 400

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
                  -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET
    ifneq ($(TRACE),)
        EXTRA_ARGS += --trace --trace-structs
    endif
    COMPILE_ARGS += -GN_SESSIONS=$(N_SESSIONS) -GWINDOW_BITS=$(WINDOW_BITS)
    COMPILE_ARGS += -GPMTU_BYTES=$(PMTU_BYTES) -GPID_BITS=$(PID_BITS)
    COMPILE_ARGS += -GRDMA_OST_BITS=$(RDMA_OST_BITS) -GRDMA_SHIFT=$(RDMA_SHIFT)
    COMPILE_ARGS += -GADDR_MAP='"$(ADDR_MAP)"'
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
