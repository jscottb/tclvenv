# Loaded by fuzz.tcl. Groups against the packages really installed on this
# system, not trees the harness writes.
#
#   realpackages  add 1-3 packages chosen at random from what `available`
#                 lists (Tcllib, the distribution's binary packages, ...)
#                 to one environment, then remove everything in a random
#                 order
#
# Oracle: native tclsh with the same default package path. A package it
# loads must be added, load inside the environment at the same version, and
# leave doctor passing; one it can't load must be refused cleanly with
# nothing left behind. Removing every installation must leave lib/ and
# modules/ empty and doctor passing. With no packages available, a case
# passes, counted as skipped.

proc ::fuzz::realPackageNames {} {
    variable realNames
    variable envdir
    if {![info exists realNames]} {
        set result [invoke manager [list available $envdir]]
        status $result 0 "available failed"
        set realNames {}
        foreach line [split [encoding convertfrom utf-8 [dict get $result output]] \n] {
            set name [lindex [split $line \t] 0]
            if {$name ne "" && $name ni $realNames} { lappend realNames $name }
        }
    }
    return $realNames
}

# Loads name in a fresh interpreter: {ok VERSION} or {error MESSAGE}.
proc ::fuzz::realLoad {executable name} {
    variable active
    set probe [file join $active realprobe.tcl]
    if {![file exists $probe]} {
        writeText $probe {
            proc main {name} {
                if {[catch {package require $name} version]} {
                    set result [list error $version]
                } else { set result [list ok $version] }
                set ch [open $::env(TCLVENV_FUZZ_RESULT) w]
                fconfigure $ch -encoding utf-8 -translation lf
                puts $ch $result
                close $ch
            }
            main [lindex $::argv 0]
            exit 0
        }
    }
    set output [file join $active realprobe.tcldata]
    if {[exists $output]} { file delete -- $output }
    set result [run [list $executable $probe $name] $active "" [dict create TCLVENV_FUZZ_RESULT $output] 30000]
    dict lappend ::fuzz::current operations [dict create entry load-$name result $result]
    need [expr {![dict get $result timedout]}] "loading $name did not finish"
    need [file isfile $output] "loading $name ended without a result"
    readData $output
}

proc ::fuzz::realContents {} {
    variable envdir
    set names {}
    foreach directory {lib modules} {
        foreach name [glob -nocomplain -tails -directory [file join $envdir $directory] -- * .*] {
            if {$name ni {. ..}} { lappend names $directory/$name }
        }
    }
    lsort $names
}

proc ::fuzz::scenario_realpackages {} {
    variable timeout
    set saved $timeout
    # Adding a package with a large closure hashes megabytes with the
    # manager's Tcl SHA-256 (about 1.3 s per MB): allow a minute.
    set timeout [expr {max($timeout, 60000)}]
    try { realPackagesCase } finally { set timeout $saved }
}
proc ::fuzz::realPackagesCase {} {
    variable envdir
    variable current
    set names [realPackageNames]
    if {![llength $names]} { cover skipped; return }
    set chosen {}
    for {set i 0; set n [expr {1 + [number 3]}]} {$i < $n} {incr i} { lappend chosen [pick $names] }
    dict set current input [dict create mode [expr {[llength $chosen] > 1 ? "several" : "one"}] packages $chosen]
    set tcl [info nameofexecutable]
    set added {}
    foreach name $chosen {
        set native [realLoad $tcl $name]
        set result [invoke manager [list add $envdir $name] {} ]
        managerOutcome $result "add $name"
        set text [encoding convertfrom utf-8 [dict get $result stderr]]
        if {[lindex $native 0] eq "ok"} {
            cover native-loads
            need [expr {[dict get $result status] == 0}] "add of a package native Tcl loads failed: [string trim $text]"
            dict set added $name [lindex $native 1]
        } elseif {[dict exists $added $name]} {
            cover native-fails-already-added
        } else {
            cover native-fails
            set before [realContents]
            need [expr {[dict get $result status] == 1}] "add of a package native Tcl can't load succeeded"
            need [expr {[realContents] eq $before}] "a refused add left files"
        }
    }
    dict for {name version} $added {
        set inside [realLoad [file join $envdir bin tclsh] $name]
        need [expr {[lindex $inside 0] eq "ok"}] "an added package doesn't load in the environment: [lindex $inside 1]"
        need [expr {[lindex $inside 1] eq $version}] "the environment loads another version than native Tcl"
    }
    status [invoke manager [list doctor $envdir]] 0 "doctor fails after add"
    set listed [invoke manager [list list $envdir]]
    status $listed 0 "list failed"
    set ids {}
    foreach line [split [encoding convertfrom utf-8 [dict get $listed output]] \n] {
        if {$line ne ""} { lappend ids [lindex [split $line \t] 0] }
    }
    set order {}
    foreach id $ids { dict set order $id {} }
    foreach id [dict keys [shuffle $order]] {
        status [invoke manager [list remove $envdir $id]] 0 "remove $id failed"
    }
    need [expr {[llength [realContents]] == 0}] "removing every installation left files: [realContents]"
    status [invoke manager [list doctor $envdir]] 0 "doctor fails after removing everything"
}
