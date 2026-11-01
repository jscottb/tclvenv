# Loaded by fuzz.tcl. What the manager does when its output can't be written.
#
#   outputs  one manager command (create, install of a directory, module or
#            archive, add, remove, run, info, list, doctor, available, help)
#            with stdout full (/dev/full), a pipe its reader closes after
#            0-400 bytes, or closed; sometimes stderr full as well
#
# Oracle: the same command run on an identical copy with stdout and stderr
# to files (the control). A command that changes the environment makes
# exactly the control's change and exits as the control did: progress
# messages never decide what is done. A read-only command whose output
# couldn't be written exits 1. No Tcl stack trace is printed, and every
# environment passes doctor afterwards. Unix only (sh, /dev/full).

proc ::fuzz::outputsSetup {} {
    variable active
    variable envdir
    set sources [file join $active sources]
    file mkdir [file join $sources pkga]
    writeText [file join $sources pkga pkgIndex.tcl] \
        {package ifneeded pkga 1.0 [list source [file join $dir pkga.tcl]]}
    writeText [file join $sources pkga pkga.tcl] "package provide pkga 1.0\n"
    file mkdir [file join $sources usesjson]
    writeText [file join $sources usesjson pkgIndex.tcl] \
        {package ifneeded usesjson 1.0 [list source [file join $dir u.tcl]]}
    writeText [file join $sources usesjson u.tcl] "package require json\npackage provide usesjson 1.0\n"
    writeText [file join $sources mod-1.0.tm] "package provide mod 1.0\n"
    set made [run [list sh -c {cd "$1" && tar czf usesjson.tar.gz usesjson} sh $sources] $active]
    status $made 0 "could not make the archive fixture"
    # One installation to remove, present in both copies.
    status [invoke manager [list install $envdir [file join $sources pkga]]] 0 "fixture install failed"
    return $sources
}

# Runs the manager with stdout/stderr arranged as mode says:
# {status stderr} (stdout is lost, or discarded by the reader).
proc ::fuzz::outputsRun {arguments mode errMode} {
    variable active
    variable project
    variable serial
    set words [list [info nameofexecutable] [file join $project tclvenv.tcl] {*}$arguments]
    set quoted [join [lmap word $words {shellWord $word}] { }]
    set statusFile [file join $active status-[incr serial]]
    set errFile [file join $active stderr-$serial]
    set err [expr {$errMode eq "full" ? "2>/dev/full" : "2>[shellWord $errFile]"}]
    switch -- [lindex $mode 0] {
        file { set line "$quoted >[shellWord [file join $active stdout-$serial]] $err; echo \$? >[shellWord $statusFile]" }
        full { set line "$quoted >/dev/full $err; echo \$? >[shellWord $statusFile]" }
        closed { set line "$quoted >&- $err; echo \$? >[shellWord $statusFile]" }
        pipe {
            set line "{ $quoted $err; echo \$? >[shellWord $statusFile]; } | head -c [lindex $mode 1] >/dev/null"
        }
    }
    set script [file join $active outputs-$serial.sh]
    writeText $script "#!/bin/sh\n$line\n"
    set result [run [list sh $script] $active "" {} 60000]
    dict lappend ::fuzz::current operations [dict create entry outputs-$mode arguments $arguments result $result]
    need [expr {![dict get $result timedout]}] "the command did not finish"
    need [file isfile $statusFile] "no exit status was recorded"
    set code [string trim [readBytes $statusFile]]
    set text ""
    if {[file isfile $errFile]} { set text [encoding convertfrom utf-8 [readBytes $errFile]] }
    list $code $text
}

proc ::fuzz::outputsState {root} {
    if {![file isdirectory $root]} { return absent }
    set names {}
    foreach directory {lib modules} {
        foreach path [glob -nocomplain -tails -directory [file join $root $directory] -- * .*] {
            if {$path ni {. ..}} { lappend names $directory/$path }
        }
    }
    lsort $names
}

proc ::fuzz::scenario_outputs {} {
    variable active
    variable envdir
    variable current
    if {$::tcl_platform(platform) ne "unix" || ![file writable /dev/full]} { cover skipped; return }
    set sources [outputsSetup]
    # Two identical copies: one for the control, one for the broken output.
    set control [file join $active control]
    set broken [file join $active broken]
    file copy -- $envdir $control
    file copy -- $envdir $broken
    set script [file join $active app.tcl]
    writeText $script "puts \[string repeat x 300\]\nputs done\n"
    set kind [pick {create install-dir install-module install-archive add remove run info list doctor available help}]
    set mutating [expr {$kind in {create install-dir install-module install-archive add remove}}]
    proc ::fuzz::outputsArgs {kind root sources script} {
        switch -- $kind {
            create { list create $root-new }
            install-dir { list install $root [file join $sources usesjson] --check --deps }
            install-module { list install $root [file join $sources mod-1.0.tm] }
            install-archive { list install $root [file join $sources usesjson.tar.gz] }
            add { list add $root json }
            remove { list remove $root pkga }
            run { list run $root -- $script }
            info - list - doctor { list $kind $root }
            available { list available $root json* }
            help { list --help }
        }
    }
    set mode [pick [list full closed [list pipe [number 400]] [list pipe 0]]]
    set errMode [pick {file file file full}]
    cover $kind
    cover [lindex $mode 0]
    dict set current input [dict create mode $kind stdout $mode stderr $errMode]
    lassign [outputsRun [outputsArgs $kind $control $sources $script] {file} file] controlCode controlErr
    lassign [outputsRun [outputsArgs $kind $broken $sources $script] $mode $errMode] code errText
    if {$kind eq "run"} {
        # The script's own failed puts is reported as native tclsh reports
        # it; the launcher's frames must not show.
        need [expr {[string first tclvenv::runtime $errText] < 0}] "launcher frames were printed: [string range $errText 0 300]"
    } else {
        need [expr {[string first "while executing" $errText] < 0}] "a stack trace was printed: [string range $errText 0 300]"
    }
    set target [expr {$kind eq "create" ? "$broken-new" : $broken}]
    set controlTarget [expr {$kind eq "create" ? "$control-new" : $control}]
    if {$mutating} {
        need [expr {[outputsState $target] eq [outputsState $controlTarget]}] \
            "the change differs from the control's with output broken ([outputsState $target] vs [outputsState $controlTarget])"
        need [expr {$code == $controlCode}] "exit status $code, the control's $controlCode: the change was made, or not, regardless"
    } elseif {$kind ne "run"} {
        need [expr {[outputsState $broken] eq [outputsState $control]}] "a read-only command changed the environment"
        if {[lindex $mode 0] eq "full"} {
            need [expr {$code == 1}] "a read-only command whose output couldn't be written exited $code"
        }
    }
    foreach root [list $target $controlTarget] {
        if {[file isdirectory $root]} {
            status [invoke manager [list doctor $root]] 0 "doctor fails after the command"
        }
    }
}
