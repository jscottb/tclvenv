# Loaded by fuzz.tcl. Real I/O errors in the middle of an operation.
#
#   limits  one operation (create, install of a package directory, install of
#           a .tar.gz, add of a system package, remove) under one fault:
#           a file-size limit (ulimit -f, SIGXFSZ ignored, so a write past it
#           fails with EFBIG) from 1 block to about the operation's size;
#           a descriptor limit (ulimit -n 5-24, so an open fails with
#           EMFILE); or a directory made read-only (the environment, its
#           lib/, modules/ or metadata/, the parent a new environment goes
#           in, or the temporary directory)
#
# Oracle: success leaves what an unlimited control run leaves. Failure
# prints one clean tclvenv: message (no stack trace) and leaves the
# environment as it was (for create: no destination, lock or staging
# directory). With the fault lifted, doctor passes, the same command
# succeeds with the control's result, and nothing is left in the private
# temporary directory. Unix only (sh, ulimit).

proc ::fuzz::limitsState {root} {
    if {![exists $root]} { return absent }
    set result {}
    foreach directory {lib modules} {
        set base [file join $root $directory]
        set queue [list $base]
        while {[llength $queue]} {
            set queue [lassign $queue item]
            foreach child [glob -nocomplain -directory $item -- * .*] {
                if {[file tail $child] in {. ..}} continue
                set relative [string range $child [string length $root]+1 end]
                if {[file isdirectory $child]} {
                    lappend result [list $relative dir]
                    lappend queue $child
                } else {
                    lappend result [list $relative [file size $child]]
                }
            }
        }
    }
    lappend result [list receipts [lsort [dict keys [readData [file join $root metadata installed.tcldata]]]]]
    lsort $result
}

proc ::fuzz::limitsSources {} {
    variable active
    set sources [file join $active sources]
    # A package of several files, some large enough to cross small limits.
    set package [file join $sources bigpkg]
    file mkdir [file join $package sub]
    writeText [file join $package pkgIndex.tcl] \
        {package ifneeded bigpkg 1.0 [list source [file join $dir bigpkg.tcl]]}
    writeText [file join $package bigpkg.tcl] "package provide bigpkg 1.0\n"
    for {set i 0; set n [expr {2 + [number 6]}]} {$i < $n} {incr i} {
        writeBytes [file join $package sub data$i.bin] [string repeat [format %c [expr {65 + $i}]] [expr {1 + [number 120000]}]]
    }
    status [run [list sh -c {cd "$1" && tar czf bigpkg.tar.gz bigpkg} sh $sources] $active] 0 "could not make the archive"
    return $sources
}

# Runs the manager under a fault: {status stderr}.
proc ::fuzz::limitsRun {arguments fault tmp} {
    variable active
    variable project
    set words [lmap word [list [info nameofexecutable] [file join $project tclvenv.tcl] {*}$arguments] {shellWord $word}]
    set prefix ""
    switch -- [lindex $fault 0] {
        fsize { set prefix "trap '' XFSZ; ulimit -f [lindex $fault 1]; " }
        nofile { set prefix "ulimit -n [lindex $fault 1]; " }
    }
    set script "${prefix}exec [join $words { }]"
    set result [run [list sh -c $script] $active "" [dict create TMPDIR $tmp] 120000]
    dict lappend ::fuzz::current operations [dict create entry manager fault $fault arguments $arguments result $result]
    need [expr {![dict get $result timedout]}] "the command did not finish"
    list [dict get $result status] [encoding convertfrom utf-8 [dict get $result stderr]]
}

proc ::fuzz::scenario_limits {} {
    variable active
    variable envdir
    variable current
    if {$::tcl_platform(platform) ne "unix"} { cover skipped; return }
    set sources [limitsSources]
    set fixture [file join $sources fixture]
    file mkdir $fixture
    writeText [file join $fixture pkgIndex.tcl] {package ifneeded fixture 1.0 [list package provide fixture 1.0]}
    status [invoke manager [list install $envdir $fixture]] 0 "fixture install failed"
    set control [file join $active control]
    file copy -- $envdir $control
    set operation [pick {create install-dir install-archive add remove}]
    proc ::fuzz::limitsArgs {operation root sources} {
        switch -- $operation {
            create { list create [file join [file dirname $root] parent new-[file tail $root]] }
            install-dir { list install $root [file join $sources bigpkg] }
            install-archive { list install $root [file join $sources bigpkg.tar.gz] --no-deps --no-check }
            add { list add $root json }
            remove { list remove $root fixture }
        }
    }
    file mkdir [file join $active parent]
    set target [expr {$operation eq "create" ? [file join $active parent new-env] : $envdir}]
    set controlTarget [expr {$operation eq "create" ? [file join $active parent new-control] : $control}]
    set kind [pick {fsize fsize nofile readonly}]
    switch -- $kind {
        fsize { set fault [list fsize [expr {1 + [number [pick {8 64 400 1200}]]}]] }
        nofile { set fault [list nofile [expr {5 + [number 20]}]] }
        readonly {
            set choices [expr {$operation eq "create" ? {parent tmp} : {env lib modules metadata tmp}}]
            set fault [list readonly [pick $choices]]
        }
    }
    cover $operation
    cover $kind
    dict set current input [dict create mode $operation fault $fault]
    set tmp [file join $active tmp]
    file mkdir $tmp
    set controlTmp [file join $active control-tmp]
    file mkdir $controlTmp
    lassign [limitsRun [limitsArgs $operation $control $sources] {} $controlTmp] controlStatus
    set expected [limitsState $controlTarget]
    set before [limitsState $target]
    # A read-only directory: made so now, restored after.
    set locked ""
    if {$kind eq "readonly"} {
        switch -- [lindex $fault 1] {
            parent { set locked [file join $active parent] }
            tmp { set locked $tmp }
            env { set locked $envdir }
            default { set locked [file join $envdir [lindex $fault 1]] }
        }
        file attributes $locked -permissions 0555
    }
    try {
        lassign [limitsRun [limitsArgs $operation $envdir $sources] $fault $tmp] code errors
    } finally {
        if {$locked ne ""} { file attributes $locked -permissions 0755 }
    }
    # With very few descriptors, tclsh itself can't start (its init.tcl):
    # that is Tcl's message, before tclvenv runs; native tclsh fails alike.
    set unstarted [string match "application-specific initialization failed*" $errors]
    if {$unstarted} { cover tcl-did-not-start }
    if {!$unstarted} {
        need [expr {[string first "while executing" $errors] < 0}] "a stack trace was printed: [string range $errors 0 300]"
    }
    if {$code == 0} {
        cover succeeded
        need [expr {[limitsState $target] eq $expected}] "the operation succeeded under the fault with a different result"
    } else {
        cover failed
        need [expr {$code == 1}] "exit status $code"
        need [expr {$unstarted || [string match "tclvenv: *" $errors]}] "the failure wasn't one tclvenv: message: [string range $errors 0 300]"
        need [expr {[limitsState $target] eq $before}] "a failed operation changed the environment"
        if {$operation eq "create"} {
            set leftovers [glob -nocomplain -directory [file join $active parent] -- *.tclvenv-create.lock .tclvenv-create-*]
            need [expr {![llength $leftovers]}] "a failed create left [join $leftovers {, }]"
        }
    }
    if {[exists $target]} { status [invoke manager [list doctor $target]] 0 "doctor fails after the fault" }
    # The same command again, without the fault.
    if {$code != 0} {
        lassign [limitsRun [limitsArgs $operation $envdir $sources] {} $tmp] again againErrors
        need [expr {$again == $controlStatus}] "the command fails once the fault is lifted: [string range $againErrors 0 300]"
        need [expr {[limitsState $target] eq $expected}] "once the fault is lifted, the result differs from the control's"
        status [invoke manager [list doctor $target]] 0 "doctor fails after the retry"
    }
    set left [glob -nocomplain -directory $tmp -- * .*]
    set left [lmap path $left { if {[file tail $path] in {. ..}} continue; set path }]
    need [expr {![llength $left]}] "temporary files left: [join $left {, }]"
}
