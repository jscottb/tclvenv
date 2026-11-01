# Black-box compatibility properties: generated modules contain only a known
# package provide, and generated scripts are compared with the native runtime.
proc ::fuzz::moduleSpec {} {
    set first pkg_[number 10000]
    set last leaf_[number 10000]
    set form [pick {plain canonical leading trailing repeated single mixed unicode}]
    switch -- $form {
        plain { set name $first }
        canonical { set name ${first}::$last }
        leading { set name [string repeat : [expr {1 + [number 6]}]]$first }
        trailing { set name $first[string repeat : [expr {1 + [number 6]}]] }
        repeated { set name $first[string repeat : [expr {3 + [number 6]}]]$last }
        single { set name ${first}:$last }
        mixed { set name ${first}::middle[string repeat : [expr {1 + [number 6]}]]$last }
        unicode { set name caf\u00e9::$last }
    }
    if {$::tcl_platform(platform) eq "windows" && [string first : $name] >= 0} {
        set form plain
        set name $first
    }
    dict create form $form name $name version [pick {0.0 1.0 1.0.0 2.1a1 3.0b2}]
}
proc ::fuzz::scenario_modulegrammar {} {
    variable active
    variable envdir
    variable current
    set spec [moduleSpec]
    dict set current input $spec
    dict set current input mode [dict get $spec form]
    cover [dict get $spec form]
    set name [dict get $spec name]
    set version [dict get $spec version]
    set source [file join $active $name-$version.tm]
    writeText $source [list package provide $name $version]
    set before [tree $source]
    set result [invoke manager [list install $envdir $source]]
    status $result [dict get $result status] "module installation transport failed"
    need [equalTree $before [tree $source]] "module installation changed source bytes"
    if {[dict get $result status] == 1} {
        # Noncanonical names may be refused. Ordinary module names must work.
        need [expr {[dict get $spec form] ni {plain canonical unicode}}] "installer rejected an ordinary Tcl module name"
        need [expr {[dict size [readData [receiptPath]]] == 0}] "rejected module name left a receipt"
        noStages
        return
    }
    status $result 0 "module installer terminated unexpectedly"
    status [invoke manager [list doctor $envdir]] 0 "installer produced an environment its own validator rejects"
    set script [file join $active require.tcl]
    writeText $script "fconfigure stdout -encoding utf-8 -translation lf\nputs \[[list package require -exact $name $version]\]\n"
    set loaded [invoke runtime [list -- $script]]
    status $loaded 0 "installer accepted a module name that its loader cannot find"
    set actual [string trim [encoding convertfrom utf-8 [dict get $loaded output]]]
    need [expr {![catch {package vcompare $actual $version} comparison] && $comparison == 0}] "module loader returned a different version"
    status [invoke manager [list remove $envdir $name@$version]] 0 "accepted module name could not be removed"
    noStages
    unlocked
}

proc ::fuzz::completionSpec {} {
    set form [pick {normal break continue return error custom nested catch}]
    set value marker-[number 100000]
    switch -- $form {
        normal { set body [list set result $value] }
        break - continue { set body $form }
        error { set body [list error $value] }
        return { set body [list return -level [pick {0 1 2 3 4 8}] $value] }
        custom {
            set code [pick {0 1 2 3 4 5 7 42}]
            set level [pick {0 1 2 3}]
            set body [list return -code $code -level $level $value]
        }
        nested {
            set command [list return -level [pick {0 1 2 3 4 8}] $value]
            set body "[list proc generated {} $command]\ngenerated"
        }
        catch {
            set command [list return -code [pick {0 1 2 3 4 7}] -level [pick {0 1 2 3}] $value]
            set body "[list set body $command]\nputs \[catch \$body result options\]\nputs \$result\nputs \[dict get \$options -code\]\nputs \[dict get \$options -level\]"
        }
    }
    dict create form $form body $body
}
proc ::fuzz::completionDiagnostic {bytes} {
    set text [encoding convertfrom utf-8 $bytes]
    if {$text eq ""} { return {} }
    if {[regexp {command returned bad code: ([0-9]+)} $text -> code]} { return [list bad-code $code] }
    foreach code {break continue} {
        if {[string first "invoked \"$code\" outside of a loop" $text] >= 0} { return $code }
    }
    # Stack frames necessarily differ; the first diagnostic line must agree.
    return [lindex [split $text \n] 0]
}
proc ::fuzz::scenario_completions {} {
    variable active
    variable current
    set spec [completionSpec]
    set entry [pick {runtime manager launcher}]
    if {$::tcl_platform(platform) ne "unix" && $entry eq "launcher"} { set entry runtime }
    cover [dict get $spec form]
    dict set current input $spec
    dict set current input mode [dict get $spec form]
    dict set current input entry $entry
    set script [file join $active completion.tcl]
    writeText $script "fconfigure stdout -encoding utf-8 -translation lf\nfconfigure stderr -encoding utf-8 -translation lf\nputs started\n[dict get $spec body]\nputs finished\n"
    set native [run [list [info nameofexecutable] $script] $active]
    dict lappend current operations [dict create entry native-script result $native]
    need [expr {[dict get $native status] in {0 1}}] "native completion fixture terminated unexpectedly"
    status $native [dict get $native status] "native completion fixture failed"
    set isolated [modeInvoke $entry [list -- $script]]
    dict set current input expected_status [dict get $native status]
    status $isolated [dict get $native status] "script completion exit status differs from native Tcl"
    need [expr {[dict get $isolated output] eq [dict get $native output]}] "script completion control flow differs from native Tcl"
    need [expr {[completionDiagnostic [dict get $isolated stderr]] eq [completionDiagnostic [dict get $native stderr]]}] "script completion diagnostic differs from native Tcl"
}
