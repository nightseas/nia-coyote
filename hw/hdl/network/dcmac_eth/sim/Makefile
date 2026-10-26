TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

RTL_DIR := $(shell pwd)/..

VERILOG_SOURCES := $(RTL_DIR)/dcmac_usr_reset_gen.sv

TOPLEVEL := dcmac_usr_reset_gen
MODULE   := test_dcmac_usr_reset_gen

export MODE        ?= 1
export HOLD_CYCLES ?= 16
export USR_MHZ     ?= 250

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS   += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT
    COMPILE_ARGS += -GMODE=$(MODE) -GHOLD_CYCLES=$(HOLD_CYCLES)
endif
ifeq ($(SIM),icarus)
    COMPILE_ARGS += -Pdcmac_usr_reset_gen.MODE=$(MODE)
    COMPILE_ARGS += -Pdcmac_usr_reset_gen.HOLD_CYCLES=$(HOLD_CYCLES)
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: arms
arms:
	$(MAKE) clean && $(MAKE) MODE=1 HOLD_CYCLES=16
	$(MAKE) clean && $(MAKE) MODE=1 HOLD_CYCLES=64 SEED=2
	$(MAKE) clean && $(MAKE) MODE=0 HOLD_CYCLES=16
	$(MAKE) clean && $(MAKE) MODE=2 HOLD_CYCLES=16
