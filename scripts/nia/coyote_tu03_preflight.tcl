# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set part [lindex $argv 0]
set files [lrange $argv 1 end]

if {$part eq "" || [llength $files] == 0} {
    puts "NIA_PREFLIGHT_XDC rc=2 reason=no_args"
    puts "NIA_PREFLIGHT_DONE rc=2"
    exit 2
}

create_project -in_memory -part $part

set rc 0
foreach f $files {
    if {![file exists $f]} {
        puts "NIA_PREFLIGHT_XDC FAIL file=$f reason=missing"
        set rc 1
        continue
    }
    set n0_bad  [get_msg_config -id {Designutils 20-1307} -count]
    set n0_err  [get_msg_config -severity {ERROR} -count]
    set ok 1
    if {[catch {read_xdc -quiet $f} emsg]} {
        puts "NIA_PREFLIGHT_XDC FAIL file=$f reason=read_xdc_threw msg=[string map {\n { }} $emsg]"
        set ok 0
    }
    set d_bad [expr {[get_msg_config -id {Designutils 20-1307} -count] - $n0_bad}]
    set d_err [expr {[get_msg_config -severity {ERROR} -count] - $n0_err}]
    if {$d_bad > 0} {
        puts "NIA_PREFLIGHT_XDC FAIL file=$f reason=unsupported_tcl_in_xdc\
              count=$d_bad code={Designutils 20-1307}\
              hint={Vivado's XDC parser has no control flow. Move the guard OUT of the\
              XDC and INTO the flow script that adds the directory - see the header of\
              hw/constraints/vp1552/dcmac/dcmac_bank202_qsfp0.xdc.}"
        set ok 0
    }
    if {$d_err > 0} {
        puts "NIA_PREFLIGHT_XDC FAIL file=$f reason=errors count=$d_err"
        set ok 0
    }
    if {$ok} { puts "NIA_PREFLIGHT_XDC PASS file=$f" } else { set rc 1 }
}

puts "NIA_PREFLIGHT_DONE rc=$rc"
exit $rc
