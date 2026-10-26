# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

array set ::nia_dp_pol_tx {
    202 {0 0 1 1}
    203 {1 1 0 0}
    204 {1 1 0 0}
    205 {1 1 0 0}
}
array set ::nia_dp_pol_rx {
    202 {0 0 0 0}
    203 {1 1 1 1}
    204 {1 1 0 0}
    205 {1 1 1 1}
}

array set ::nia_dp_gtwiz_bank {
    0 202
    1 204
}

proc nia_dp_log {msg} {
    puts "NIA_DP_POL \[[clock format [clock seconds] -format %H:%M:%S]\] $msg"
}

proc nia_dp_gtwiz_ips {} {
    set out {}
    foreach ip [get_ips -quiet -filter {NAME =~ *gtwiz_versal_*}] {
        if {![string match *gt_quad_base* $ip]} { lappend out $ip }
    }
    return [lsort $out]
}

proc nia_dp_pol_enable_ports {} {
    set gtwiz [nia_dp_gtwiz_ips]
    if {![llength $gtwiz]} {
        error "nia_dp_pol_enable_ports: no gtwiz_versal IP in the project - the DCMAC IP recipe\
               must import its XCI(s) before this is called. The dual 100GAUI-1 and dual 200GAUI-2\
               images import TWO, one per client and one quad each, because one quad cannot reach\
               two QSFP cages; the single 400GAUI-4 image imports ONE, which carries two quads of\
               the same cage."
    }
    nia_dp_log "gtwiz IPs: $gtwiz"
    set touched {}
    foreach ip $gtwiz {
        set lanes "<unreadable>"
        catch { set lanes [get_property CONFIG.INTF0_NO_OF_LANES [get_ips $ip]] }
        nia_dp_log "$ip: INTF0_NO_OF_LANES = $lanes"
        set cur ""
        catch { set cur [get_property CONFIG.INTF0_OPTIONAL_PORTS [get_ips $ip]] }
        nia_dp_log "$ip: INTF0_OPTIONAL_PORTS before = '$cur'"
        set new $cur
        foreach p {ch_txpolarity ch_rxpolarity} {
            if {![regexp "(^|\\s)$p\\s+true(\\s|$)" $new]} { set new [string trim "$new $p true"] }
        }
        if {$new eq $cur} {
            nia_dp_log "$ip: polarity ports already enabled"
            continue
        }
        if {[get_property IS_LOCKED [get_ips $ip]]} {
            if {[info exists ::env(NIA_DP_GTWIZ_UPGRADE)] && $::env(NIA_DP_GTWIZ_UPGRADE) ne "0"} {
                nia_dp_log "$ip: IS_LOCKED and NIA_DP_GTWIZ_UPGRADE is set -> upgrade_ip (OWNER-ENABLED)"
                upgrade_ip [get_ips $ip]
            } else {
                error "$ip is LOCKED, so CONFIG.INTF0_OPTIONAL_PORTS cannot be set and the polarity\
                       ports cannot be created. This is the ONLY mechanism there is: polarity is a\
                       gtwiz optional PORT, not an XDC property. Do not work around it by\
                       tying the PHY to a constant - that produces an image which is correct in\
                       every report and never links on QSFP1. Either regenerate the XCI from an\
                       example project for this Vivado version, or set NIA_DP_GTWIZ_UPGRADE=1 to\
                       allow `upgrade_ip` AND re-verify the whole 1140-parameter configuration."
            }
        }
        set_property CONFIG.INTF0_OPTIONAL_PORTS $new [get_ips $ip]
        nia_dp_log "$ip: INTF0_OPTIONAL_PORTS += ch_txpolarity/ch_rxpolarity"
        lappend touched $ip
    }
    if {[llength $touched]} {
        nia_dp_log "regenerating output products for: $touched"
        foreach ip $touched {
            reset_target -quiet all [get_ips $ip]
            generate_target all [get_ips $ip]
        }
    }
    foreach ip $gtwiz {
        set v [get_property CONFIG.INTF0_OPTIONAL_PORTS [get_ips $ip]]
        puts "NIA_DP_POLARITY ip=$ip INTF0_OPTIONAL_PORTS = '$v'"
        if {![regexp {ch_txpolarity\s+true} $v] || ![regexp {ch_rxpolarity\s+true} $v]} {
            error "$ip: polarity ports still NOT enabled after set_property + generate_target\
                   (value: '$v'). Abort before synth."
        }
    }
    return $gtwiz
}

proc nia_dp_pol_port_names {ip} {
    set names [dict create]
    set files {}
    foreach pat [list *${ip}_sv.sv *${ip}_inst.v *${ip}.v intf_ports.txt intf_ports_inst.txt] {
        foreach f [get_files -quiet -all $pat] { lappend files $f }
    }
    set ipdir ""
    catch { set ipdir [get_property IP_DIR [get_ips $ip]] }
    if {$ipdir ne "" && [file isdirectory $ipdir]} {
        foreach pat [list ${ip}_sv.sv ${ip}_inst.v ${ip}.v intf_ports.txt intf_ports_inst.txt] {
            foreach f [glob -nocomplain -directory $ipdir $pat] { lappend files $f }
        }
    }
    foreach f [lsort -unique $files] {
        if {![file exists $f]} { continue }
        set fh [open $f r]; set d [read $fh]; close $fh
        foreach {m full dir ch tr} [regexp -all -inline \
                {((?:INTF\d+_)?(TX|RX)(\d+)_ch_((?:tx|rx)polarity))} $d] {
            dict set names ${dir}${ch} $full
        }
    }
    return $names
}

set ::nia_pol_rtl [file normalize [file join [file dirname [info script]] .. rtl]]

array set ::nia_dp_pol_rate_wiz  {100 2 200 2 400 1}
array set ::nia_dp_pol_rate_lane {100 2 200 4 400 8}
array set ::nia_dp_pol_rate_phy  {100 dcmac_phy_wrapper.sv
                                  200 rate/dcmac_phy_wrapper_200g.sv
                                  400 rate/dcmac_phy_wrapper_400g.sv}
array set ::nia_dp_pol_rate_bank {100 {202 204} 200 {202 204} 400 {202 203}}

proc nia_dp_pol_bank_bits {bank dir} {
    upvar #0 ::nia_dp_pol_$dir row
    if {![info exists row($bank)]} { return "" }
    set out ""
    foreach b [lreverse $row($bank)] { append out $b }
    return $out
}

proc nia_dp_pol_conn_list {rate} {
    set out {}
    set lanes $::nia_dp_pol_rate_lane($rate)
    if {$::nia_dp_pol_rate_wiz($rate) > 1} {
        foreach q {Q0 Q1} {
            for {set k 0} {$k < $lanes} {incr k} {
                lappend out ".INTF0_TX${k}_ch_txpolarity (POLARITY_TX_${q}\[$k\])"
                lappend out ".INTF0_RX${k}_ch_rxpolarity (POLARITY_RX_${q}\[$k\])"
            }
        }
    } else {
        for {set k 0} {$k < $lanes} {incr k} {
            set q [expr {$k < 4 ? "Q0" : "Q1"}]
            set b [expr {$k % 4}]
            lappend out ".INTF0_TX${k}_ch_txpolarity (POLARITY_TX_${q}\[$b\])"
            lappend out ".INTF0_RX${k}_ch_rxpolarity (POLARITY_RX_${q}\[$b\])"
        }
    }
    return $out
}

proc nia_dp_pol_assert {{rate 100}} {
    set bad 0
    if {![info exists ::nia_dp_pol_rate_phy($rate)]} {
        error "nia_dp_pol_assert: NIA_RATE=$rate is not one of 100, 200, 400"
    }
    set want_wiz  $::nia_dp_pol_rate_wiz($rate)
    set want_lane $::nia_dp_pol_rate_lane($rate)
    set banks     $::nia_dp_pol_rate_bank($rate)
    set phy   [file join $::nia_pol_rtl $::nia_dp_pol_rate_phy($rate)]
    set stub  $::nia_pol_rtl/dcmac_phy_model.sv
    set pkg   $::nia_pol_rtl/ctl/dcmac_ctl_pkg.sv
    puts "NIA_DP_POLARITY RATE $rate phy=$::nia_dp_pol_rate_phy($rate) want_gtwiz=$want_wiz\
          want_lanes=$want_lane banks=$banks"

    set gtwiz [nia_dp_gtwiz_ips]
    puts "NIA_DP_POLARITY C1 gtwiz_count=[llength $gtwiz] (want $want_wiz at rate $rate)"
    if {[llength $gtwiz] != $want_wiz} {
        if {$want_wiz == 2} {
            puts "NIA_DP_POLARITY C1 FAIL expected two gtwiz IPs at rate $rate; polarity is per\
                  quad, so with one gtwiz the second cage does not exist to be polarised: one quad\
                  cannot reach two QSFP cages)."
        } else {
            puts "NIA_DP_POLARITY C1 FAIL expected ONE gtwiz IP at rate $rate: a 400GAUI-4 client is\
                  eight lanes across two quads of the SAME cage and the harvested\
                  ip/rate400 wizard carries both (NO_OF_QUADS 2). Two wizards here means a dual\
                  configuration crept in and half the port would be driven from the wrong cage."
        }
        incr bad
    }
    set n_en 0
    foreach ip $gtwiz {
        set v ""
        catch { set v [get_property CONFIG.INTF0_OPTIONAL_PORTS [get_ips $ip]] }
        set a [regexp {ch_txpolarity\s+true} $v]
        set b [regexp {ch_rxpolarity\s+true} $v]
        set l "<unreadable>"
        catch { set l [get_property CONFIG.INTF0_NO_OF_LANES [get_ips $ip]] }
        puts "NIA_DP_POLARITY C1 ip=$ip lanes=$l ch_txpolarity_true=$a ch_rxpolarity_true=$b"
        if {$l ne "<unreadable>" && $l ne "$want_lane"} {
            puts "NIA_DP_POLARITY C1 FAIL $ip has INTF0_NO_OF_LANES = $l but rate $rate needs\
                  $want_lane. The PHY connects channels 0..[expr {$want_lane - 1}] of this wizard,\
                  so a narrower one leaves the connections dangling and a wider one leaves lanes at\
                  the default polarity of 0."
            incr bad
        }
        if {$a && $b} { incr n_en } else { incr bad }
    }
    puts "NIA_DP_POLARITY C1 enabled_on=$n_en of [llength $gtwiz]"

    set want {}
    for {set k 0} {$k < $want_lane} {incr k} {
        lappend want INTF0_TX${k}_ch_txpolarity INTF0_RX${k}_ch_rxpolarity
    }
    foreach ip $gtwiz {
        set nm [nia_dp_pol_port_names $ip]
        if {![dict size $nm]} {
            puts "NIA_DP_POLARITY C2 FAIL $ip: enabled ch_txpolarity/ch_rxpolarity but NO polarity\
                  port appears in its generated sources. The name could not be confirmed, so the\
                  PHY's static connections would reference non-existent ports. Inspect the\
                  regenerated wrapper (*_sv.sv / intf_ports.txt) and update the `want` list here\
                  AND the PHY together."
            incr bad
            continue
        }
        set got [lsort [dict values $nm]]
        puts "NIA_DP_POLARITY C2 ip=$ip discovered=[join $got { }]"
        foreach w $want {
            if {[lsearch -exact $got $w] < 0} {
                puts "NIA_DP_POLARITY C2 FAIL $ip: the PHY connects `$w` but the generator did not\
                      emit it. Discovered names are listed on the line above - the fix is to rename\
                      in BOTH dcmac_phy_wrapper.sv and this `want` list, never in one of them."
                incr bad
            }
        }
    }

    if {![file exists $pkg]} {
        puts "NIA_DP_POLARITY C3 FAIL missing $pkg"
        incr bad
    } else {
        set fh [open $pkg r]; set pt [read $fh]; close $fh
        array set pol {}
        foreach k {QSFP0_TXPOLARITY QSFP0_RXPOLARITY QSFP1_TXPOLARITY QSFP1_RXPOLARITY} {
            set pol($k) "-"
            if {[regexp "${k}\\s*=\\s*8'b(\[01_\]+)" $pt -> v]} { set pol($k) $v }
        }
        puts "NIA_DP_POLARITY C3 qsfp0 tx=$pol(QSFP0_TXPOLARITY) rx=$pol(QSFP0_RXPOLARITY)\
              (202.CH0 must be 0/0)"
        puts "NIA_DP_POLARITY C3 qsfp1 tx=$pol(QSFP1_TXPOLARITY) rx=$pol(QSFP1_RXPOLARITY)\
              (204.CH0 must be 1/1 - INVERSION REQUIRED)"
        foreach {k bank ch expect} [list \
                QSFP0_TXPOLARITY 202 0 [lindex $::nia_dp_pol_tx(202) 0] \
                QSFP0_RXPOLARITY 202 0 [lindex $::nia_dp_pol_rx(202) 0] \
                QSFP1_TXPOLARITY 204 0 [lindex $::nia_dp_pol_tx(204) 0] \
                QSFP1_RXPOLARITY 204 0 [lindex $::nia_dp_pol_rx(204) 0]] {
            set v $pol($k)
            if {$v eq "-"} {
                puts "NIA_DP_POLARITY C3 FAIL $k is ABSENT from dcmac_ctl_pkg.sv, so the board fact\
                      for ${bank}.CH${ch} has no source of truth and that lane would be built at the\
                      gtwiz default of 0."
                incr bad
                continue
            }
            set bits [string map {_ ""} $v]
            set got  [string index $bits end]
            if {$got ne "$expect"} {
                puts "NIA_DP_POLARITY C3 FAIL $k bit0 = $got but ${bank}.CH${ch} requires $expect\
                      (lib_polarity.tcl:31 / polarity_pindef.tcl:20-31). Absolute per-lane polarity\
                      is a board fact with no runtime escape; a wrong value is a permanently\
                      unaligned link that looks exactly like silicon."
                incr bad
            }
        }
    }

    if {![file exists $phy]} {
        puts "NIA_DP_POLARITY C4 FAIL missing $phy"
        incr bad
    } else {
        set fh [open $phy r]; set ft [read $fh]; close $fh
        if {$want_wiz > 1} {
            foreach {p src} [list POLARITY_TX_Q0 QSFP0_TXPOLARITY POLARITY_RX_Q0 QSFP0_RXPOLARITY \
                                  POLARITY_TX_Q1 QSFP1_TXPOLARITY POLARITY_RX_Q1 QSFP1_RXPOLARITY] {
                if {[regexp "${p}\\s*=\\s*dcmac_ctl_pkg::${src}" $ft]} {
                    puts "NIA_DP_POLARITY C4 ok $p defaults from dcmac_ctl_pkg::$src"
                } else {
                    puts "NIA_DP_POLARITY C4 FAIL $p does not default from dcmac_ctl_pkg::$src - the\
                          board fact would then live in two places and could drift silently."
                    incr bad
                }
            }
        } else {
            set q 0
            foreach bank $banks {
                foreach {p dir} [list POLARITY_TX_Q$q pol_tx POLARITY_RX_Q$q pol_rx] {
                    set exp [nia_dp_pol_bank_bits $bank [string range $dir 4 end]]
                    set got "-"
                    if {[regexp "${p}\\s*=\\s*8'b(\[01_\]+)" $ft -> v]} {
                        set got [string range [string map {_ ""} $v] end-3 end]
                    }
                    if {$got eq $exp} {
                        puts "NIA_DP_POLARITY C4 ok $p = ${got} = bank $bank CH3..CH0"
                    } else {
                        puts "NIA_DP_POLARITY C4 FAIL $p = $got but bank $bank requires $exp\
                              (CH3..CH0, from nia_dp_pol_tx/nia_dp_pol_rx in this file). A 400GAUI-4\
                              client is on ONE cage: quad 1 is bank 203, NOT the bank 204 that\
                              dcmac_ctl_pkg::QSFP1_* describes. Their TX rows happen to match and\
                              their RX rows do not, so borrowing QSFP1_RXPOLARITY here is a link\
                              that never aligns and looks exactly like silicon."
                        incr bad
                    }
                }
                incr q
            }
        }
        set fn $ft
        regsub -all {\s+} $fn " " fn
        foreach conn [nia_dp_pol_conn_list $rate] {
            if {[string first $conn $fn] >= 0} {
                puts "NIA_DP_POLARITY C5 ok [file tail $phy] $conn"
            } else {
                puts "NIA_DP_POLARITY C5 FAIL [file tail $phy]: `$conn` is NOT present. An\
                      unconnected polarity port defaults to 0, which on an inverted lane is a link\
                      that never aligns and looks exactly like silicon."
                incr bad
            }
        }
        set n_tx [regexp -all {ch_txpolarity} $ft]
        set n_rx [regexp -all {ch_rxpolarity} $ft]
        set n_want [expr {$want_wiz * $want_lane}]
        puts "NIA_DP_POLARITY C5 phy=[file tail $phy] txpolarity_refs=$n_tx rxpolarity_refs=$n_rx\
              (want >= $n_want each: $want_lane channel(s) on each of $want_wiz wizard(s))"
        if {$n_tx < $n_want || $n_rx < $n_want} { incr bad }
    }

    if {![file exists $stub]} {
        puts "NIA_DP_POLARITY C6 FAIL missing $stub"
        incr bad
    } else {
        set fh [open $stub r]; set st [read $fh]; close $fh
        foreach p {POLARITY_TX_Q0 POLARITY_RX_Q0 POLARITY_TX_Q1 POLARITY_RX_Q1} {
            if {![regexp "parameter\\s+logic\\s*\\\[7:0\\\]\\s+$p" $st]} {
                puts "NIA_DP_POLARITY C6 FAIL dcmac_phy_model.sv is missing parameter $p. The two\
                      PHY implementations MUST keep identical port and parameter lists - choosing\
                      between them is a FILE-LIST SWAP and that property is load-bearing."
                incr bad
            }
        }
    }

    puts "NIA_DP_POLARITY VERDICT bad=$bad"
    return $bad
}

proc nia_dp_preflight_polarity_or_die {{rate 100}} {
    set bad [nia_dp_pol_assert $rate]
    if {$bad > 0} {
        error "POLARITY PREFLIGHT FAILED at rate $rate with $bad problem(s), BEFORE synth_design on\
               purpose. Every FAIL above is the kind of defect that yields an image which builds,\
               closes timing, programs, and never aligns on one or both wires. 204.CH0 requires\
               TX_INV=1 / RX_INV=1 (app/dcmac_pktgen/recipes/polarity_pindef.tcl:24)."
    }
    puts "NIA_DP_POLARITY PREFLIGHT=PASS rate=$rate"
    return 0
}
