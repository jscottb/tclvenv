# Adds every package `available` lists, each to a fresh environment, and
# compares with native package require (the realpackages fuzz group samples
# the same oracle). Prints one line per problem.
# Usage: tclshX.Y tests/sweep_packages.tcl WORKDIR ?FIRST? ?COUNT?
# WORKDIR must not exist or be a previous sweep's; it is not removed.
if {[llength $argv] < 1} { puts stderr "usage: tclsh tests/sweep_packages.tcl WORKDIR ?FIRST? ?COUNT?"; exit 2 }
set work [file normalize [lindex $argv 0]]
set first [expr {[llength $argv] > 1 ? [lindex $argv 1] : 0}]
set count [expr {[llength $argv] > 2 ? [lindex $argv 2] : 100000}]
set cli [file join [file dirname [file dirname [file normalize [info script]]]] tclvenv.tcl]
set tcl [info nameofexecutable]
file mkdir $work
proc sh {args} {
    set status 0
    if {[catch {exec -- {*}$args 2>@1} out opts]} {
        set code [dict get $opts -errorcode]
        set status [expr {[lindex $code 0] eq "CHILDSTATUS" ? [lindex $code 2] : -1}]
    }
    list $status $out
}
unset -nocomplain ::env(TCLLIBPATH)
set template [file join $work template]
if {![file exists $template]} { exec -- $tcl $cli create $template }
set names {}
foreach line [split [lindex [sh $tcl $cli available $template] 1] \n] {
    set name [lindex [split $line \t] 0]
    if {$name ne "" && $name ni $names} { lappend names $name }
}
set probe [file join $work probe.tcl]
set ch [open $probe w]
puts $ch {
    proc main {name} {
        set before [package names]
        if {[catch {package require $name} v]} { puts [list error $v]; return }
        set loaded {}
        foreach n [package names] { if {[package provide $n] ne ""} { lappend loaded $n [package provide $n] } }
        puts [list ok $v [lsort -stride 2 $loaded]]
    }
    main [lindex $argv 0]
    exit 0
}
close $ch
set results {}
set i -1
foreach name $names {
    incr i
    if {$i < $first || $i >= $first + $count} continue
    set envd [file join $work env-$i]
    file delete -force $envd
    file copy $template $envd
    lassign [sh $tcl $probe $name] - native
    set native [lindex [split $native \n] end]
    lassign [sh $tcl $cli add $envd $name] addStatus addOut
    set problem {}
    if {[lindex $native 0] eq "ok"} {
        set want [lindex $native 1]
        if {$addStatus != 0} {
            set problem [list add-failed $addOut]
        } else {
            lassign [sh [file join $envd bin tclsh] $probe $name] - inEnv
            set inEnv [lindex [split $inEnv \n] end]
            if {[lindex $inEnv 0] ne "ok"} {
                set problem [list env-load-failed $inEnv]
            } elseif {[lindex $inEnv 1] ne $want} {
                set problem [list version native $want env [lindex $inEnv 1]]
            }
            if {$problem eq ""} {
                lassign [sh $tcl $cli doctor $envd] d dOut
                if {$d != 0} { set problem [list doctor $dOut] }
            }
            if {$problem eq ""} {
                set ids [lmap l [split [lindex [sh $tcl $cli list $envd] 1] \n] {lindex [split $l \t] 0}]
                foreach id [lreverse $ids] {
                    if {$id eq ""} continue
                    lassign [sh $tcl $cli remove $envd $id] r rOut
                    if {$r != 0} { set problem [list remove $id $rOut]; break }
                }
                if {$problem eq "" && ([llength [glob -nocomplain -directory [file join $envd lib] *]] ||
                                       [llength [glob -nocomplain -directory [file join $envd modules] *]])} {
                    set problem [list leftovers [glob -nocomplain -directory [file join $envd lib] *] \
                        [glob -nocomplain -directory [file join $envd modules] *]]
                }
            }
        }
    } else {
        if {$addStatus == 0} {
            set problem [list add-succeeded-native-failed $native $addOut]
        } elseif {![string match "tclvenv: *" $addOut] || [string match "*while executing*" $addOut]} {
            set problem [list unclean-failure $addOut]
        } elseif {[llength [glob -nocomplain -directory [file join $envd lib] *]]} {
            set problem [list failed-add-left-files]
        }
    }
    if {$problem ne ""} {
        puts "$i $name: [string range $problem 0 400]"
        flush stdout
    }
    file delete -force $envd
    lappend results $name $problem
}
set ch [open [file join $work results-$first.tcldata] w]
puts $ch $results
close $ch
puts "done [llength $names] names, checked [expr {[llength $results] / 2}]"
