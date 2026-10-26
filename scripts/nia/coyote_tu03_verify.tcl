# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
set dcp    [lindex $argv 0]
set outdir [lindex $argv 1]
set xdcs   [lrange $argv 2 end]

if {$dcp eq "" || ![file exists $dcp]} {
    puts "NIA_VERIFY_DONE rc=2 reason=no_dcp:$dcp"
    exit 2
}
file mkdir $outdir

open_checkpoint $dcp

set ct [file join $outdir check_timing.rpt]
check_timing -verbose -file $ct
set fh [open $ct r]; set ctxt [read $fh]; close $fh
set noclk -1
if {[regexp {There are ([0-9]+) register/latch pins with no clock} $ctxt -> n]} {
    set noclk $n
}
puts "NIA_VERIFY_NOCLOCK $noclk"

report_clocks -file [file join $outdir clocks.rpt]
foreach c [get_clocks -quiet] {
    set p [get_property -quiet PERIOD $c]
    if {$p eq "" || $p == 0} { set f 0 } else { set f [expr {1000.0 / $p}] }
    puts [format "NIA_VERIFY_CLOCK %s %s %.3f" [get_property NAME $c] $p $f]
}

report_timing_summary -file [file join $outdir timing_summary.rpt]
set ts [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup]
if {$ts ne ""} { puts "NIA_VERIFY_WNS [get_property -quiet SLACK $ts]" }
set th [get_timing_paths -quiet -max_paths 1 -nworst 1 -hold]
if {$th ne ""} { puts "NIA_VERIFY_WHS [get_property -quiet SLACK $th]" }

foreach f $xdcs {
    if {![file exists $f]} { continue }
    set fh [open $f r]; set lines [split [read $fh] \n]; close $fh
    foreach ln $lines {
        set t [string trim $ln]
        if {[string index $t 0] eq "#"} { continue }
        foreach {full} [regexp -all -inline {\[get_(?:cells|ips|ports)[^\]]*\]} $t] {
            set n -1
            if {[catch {set n [llength [eval [string range $full 1 end-1]]]}]} { set n -1 }
            if {$n >= 1} {
                puts "NIA_VERIFY_FILTER PASS $n $full"
            } else {
                puts "NIA_VERIFY_FILTER FAIL $n $full  (file=$f)"
            }
        }
    }
}

set cir [file join $outdir clock_interaction.rpt]
if {[catch {report_clock_interaction -file $cir} e]} {
    puts "NIA_VERIFY_CLKPAIR_SKIP report_clock_interaction_failed"
} else {
    proc mmcm_clocks {pat} {
        set cells [get_cells -quiet -hier -filter "NAME =~ $pat"]
        if {[llength $cells] == 0} { return {} }
        set pins [get_pins -quiet -of_objects $cells -filter {NAME =~ *CLKOUT*}]
        if {[llength $pins] == 0} { return {} }
        set out {}
        foreach c [get_clocks -quiet -of_objects $pins] { lappend out [get_property NAME $c] }
        return $out
    }
    set fam(pl) {}
    foreach c [get_clocks -quiet -include_generated_clocks clk_pl_0] {
        lappend fam(pl) [get_property NAME $c]
    }
    set fam(dcmac) [mmcm_clocks {*i_dcmac_clk_wiz/inst/clock_primitive_inst/MMCME5_inst}]
    set fam(usr)   [mmcm_clocks {*i_usr_clk_wiz/inst/clock_primitive_inst/MMCME5_inst}]
    foreach k {pl dcmac usr} { puts "NIA_VERIFY_CLKFAMILY $k [llength $fam($k)] $fam($k)" }

    proc famof {a} {
        upvar 1 fam fam
        foreach k {pl dcmac usr} {
            if {[lsearch -exact $fam($k) $a] >= 0} { return $k }
        }
        return "-"
    }

    set rels {{Asynchronous Groups} {Exclusive Groups} {Partial False Path}
              {Max Delay Datapath Only} {No Common Clock} {Timed}}
    set fh [open $cir r]
    foreach ln [split [read $fh] \n] {
        set t [string trim $ln]
        if {$t eq "" || [string match "-*" $t] || [string match "|*" $t]} { continue }
        set rel ""
        foreach r $rels { if {[string match "*$r" $t]} { set rel $r; break } }
        if {$rel eq ""} { continue }
        if {![regexp {^(\S+)\s+(\S+)\s} $t -> a b]} { continue }
        if {$a eq $b} { continue }
        set fa [famof $a]; set fb [famof $b]
        if {$fa eq "-" || $fb eq "-" || $fa eq $fb} { continue }
        set n 0
        foreach tok [split $t] { if {[string is integer -strict $tok] && $tok > $n} { set n $tok } }
        if {$rel eq "Timed"} {
            puts "NIA_VERIFY_CLKPAIR TIMED $n $a $b $fa-$fb $rel"
        } else {
            puts "NIA_VERIFY_CLKPAIR OK $n $a $b $fa-$fb $rel"
        }
    }
    close $fh
}

puts "NIA_VERIFY_DONE rc=0"
exit 0