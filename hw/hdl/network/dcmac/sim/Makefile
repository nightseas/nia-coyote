
TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

RTL_DIR := $(shell pwd)/..
VERILOG_SOURCES := \
  $(RTL_DIR)/dcmac_seg_axis_adapter.sv \
  $(RTL_DIR)/nia_axis_dwidth.sv \
  $(RTL_DIR)/nia_axis_async_fifo.sv \
  $(RTL_DIR)/dcmac_axis_frame_fifo.sv \
  $(RTL_DIR)/dcmac_mac_ctl_fsm.sv \
  $(RTL_DIR)/dcmac_axis_core.sv

TOPLEVEL := dcmac_axis_core
MODULE   := test_dcmac_axis_core

export N_SEG   ?= 2
export SEG_W   ?= 128
export USR_MHZ ?= 250
export NPORTS  ?= 1
export ANCHOR  ?= 0

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace --trace-structs
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
    COMPILE_ARGS += -GNPORTS=$(NPORTS) -GANCHOR=$(ANCHOR)
    ifeq ($(FF_BRAM),1)
        COMPILE_ARGS += +define+DCMAC_FRAME_FIFO_BRAM
    endif
    ifeq ($(TX_FF_BRAM),1)
        COMPILE_ARGS += +define+DCMAC_TX_FRAME_FIFO_BRAM
    endif
endif

export FF_BRAM    ?= 0
export TX_FF_BRAM ?= 0

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
