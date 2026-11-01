#!/usr/bin/env tclsh
# Seeded, bounded property fuzzing. Inputs and reports are Tcl dictionaries,
# never scripts. Run this file directly; sourcing it only loads the harness.
namespace eval ::fuzz {
    variable self [file normalize [info script]]
    variable project [file dirname [file dirname $self]]
    # Append groups: their positions are part of the original replay seeds.
    variable groups {argv cli config inventory packages paths stdin ordering lifecycle recovery faults locks modes boundaries containment ownership interleavings crashes modulegrammar completions names datafuzz fakeruntime concurrency killpoints stdinmore archives sha256 urljoin toolarchives downloads systemadd activation tclshargs linkedlaunchers realpackages outputs installer limits stalelocks crashrecovery rollbacks}
    variable state 1
    variable seed 1
    variable serial 0
    variable timeout 5000
    variable outputLimit 65536
    variable active ""
    variable current {}
    variable children 0
    variable timeouts 0
    variable limits 0
    variable steps 12
    variable coverage {}
}

proc ::fuzz::readData {path} {
    set ch [open $path r]
    try {
        fconfigure $ch -encoding utf-8 -translation lf
        set data [read $ch]
        dict size $data
        return $data
    } finally { close $ch }
}
proc ::fuzz::writeText {path data} {
    set ch [open $path w]
    try {
        fconfigure $ch -encoding utf-8 -translation lf
        puts -nonewline $ch $data
    } finally { close $ch }
}
proc ::fuzz::writeBytes {path data} {
    set ch [open $path wb]
    try { puts -nonewline $ch $data } finally { close $ch }
}
proc ::fuzz::readBytes {path {limit -1}} {
    set ch [open $path rb]
    try {
        if {$limit >= 0} { return [read $ch $limit] }
        return [read $ch]
    } finally { close $ch }
}
proc ::fuzz::exists {path} { expr {![catch {file lstat $path st}]} }
proc ::fuzz::entries {path} {
    set entries [glob -nocomplain -directory $path -- * .*]
    set result {}
    foreach entry $entries {
        if {[file tail $entry] ni {. ..}} { lappend result $entry }
    }
    return [lsort -unique $result]
}
proc ::fuzz::cleanup {path} {
    if {![exists $path]} { return }
    set kind [file type $path]
    if {$kind eq "directory"} {
        if {$::tcl_platform(platform) eq "unix"} { file attributes $path -permissions u+rwx }
        foreach child [entries $path] { cleanup $child }
    }
    if {$::tcl_platform(platform) eq "windows" && $kind in {directory file}} {
        file attributes $path -readonly 0
    }
    file delete -- $path
}
proc ::fuzz::temporary {} {
    set ch [file tempfile path]
    close $ch
    file delete -- $path
    file mkdir $path
    return $path
}
proc ::fuzz::restoreEnv {saved keys} {
    foreach key $keys {
        unset -nocomplain ::env($key)
        if {[dict exists $saved $key]} { set ::env($key) [dict get $saved $key] }
    }
}

# A supervisor keeps its pipe descriptors open until the target has exited.
# Thus a target that closes stdout/stderr and hangs cannot make the harness
# block in close/wait after seeing a misleading EOF.
proc ::fuzz::supervise {request statusPath} {
    set data [readData $request]
    set command [dict get $data command]
    set errorPath [dict get $data stderr]
    set status 0
    set errorCode {}
    set detail ""
    if {[catch {exec -- {*}$command <@stdin >@stdout 2>$errorPath} detail options]} {
        set status -1
        set errorCode [dict get $options -errorcode]
        if {[lindex $errorCode 0] eq "CHILDSTATUS"} { set status [lindex $errorCode 2] }
    }
    writeText $statusPath [dict create status $status errorcode $errorCode detail $detail]
}
proc ::fuzz::pollError {id} {
    variable runs
    if {![info exists runs($id)] || [dict get $runs($id) done]} { return }
    set path [dict get $runs($id) stderrPath]
    if {[file isfile $path] && [file size $path] > [dict get $runs($id) cap]} {
        stop $id limited
    } else {
        dict set runs($id) stderrTimer [after 20 [list ::fuzz::pollError $id]]
    }
}

proc ::fuzz::killTree {roots} {
    if {$::tcl_platform(platform) eq "windows"} {
        foreach pid $roots { catch {exec taskkill /PID $pid /T /F} }
        return
    }
    set all $roots
    if {![catch {exec ps -e -o pid= -o ppid=} processes]} {
        set parents {}
        foreach line [split $processes \n] {
            if {[regexp {^\s*(\d+)\s+(\d+)\s*$} $line -> child parent]} {
                dict lappend parents $parent $child
            }
        }
        for {set i 0} {$i < [llength $all]} {incr i} {
            set parent [lindex $all $i]
            if {[dict exists $parents $parent]} {
                foreach child [dict get $parents $parent] {
                    if {$child ni $all} { lappend all $child }
                }
            }
        }
    }
    foreach pid [lreverse $all] { catch {exec kill -KILL -- $pid} }
}
proc ::fuzz::stop {id reason} {
    variable runs
    if {![info exists runs($id)] || [dict get $runs($id) done]} { return }
    dict set runs($id) $reason 1
    killTree [dict get $runs($id) pids]
    dict set runs($id) done 1
}
proc ::fuzz::readable {id} {
    variable runs
    if {[dict get $runs($id) done]} { return }
    set ch [dict get $runs($id) channel]
    if {[catch {
        set bytes [read $ch 16384]
        set remaining [expr {[dict get $runs($id) cap] - [string length [dict get $runs($id) output]]}]
        dict append runs($id) output [string range $bytes 0 [expr {$remaining - 1}]]
        if {[string length $bytes] > $remaining} {
            stop $id limited
        } elseif {[eof $ch]} {
            dict set runs($id) done 1
        }
    } message]} {
        dict set runs($id) ioerror $message
        stop $id aborted
    }
}
proc ::fuzz::run {command directory {input ""} {envOverrides {}} {deadline ""} {cap ""}} {
    variable self
    variable serial
    variable timeout
    variable outputLimit
    variable runs
    variable children
    variable timeouts
    variable limits
    if {$deadline eq ""} { set deadline $timeout }
    if {$cap eq ""} { set cap $outputLimit }
    file mkdir $directory
    set id [incr serial]
    set prefix [file join $directory operation-$id]
    writeText $prefix.request.tcldata [dict create command $command stderr $prefix.stderr.log]
    set launch [list [info nameofexecutable] $self --supervise $prefix.request.tcldata $prefix.status.tcldata]
    set keys [lsort -unique [concat {TCL_LIBRARY TK_LIBRARY TCLLIBPATH TCLVENV_INTERACTIVE} [dict keys $envOverrides]]]
    set saved {}
    foreach key $keys {
        if {[info exists ::env($key)]} { dict set saved $key $::env($key) }
        unset -nocomplain ::env($key)
    }
    dict for {key value} $envOverrides { set ::env($key) $value }
    try {
        # command contains trusted executable/helper paths only. All fuzzed
        # arguments travel in request data, never through Tcl exec's grammar.
        set ch [open [concat | $launch [list 2>@1]] r+]
    } finally { restoreEnv $saved $keys }
    incr children
    set runs($id) [dict create channel $ch pids [pid $ch] done 0 timedout 0 limited 0 aborted 0 \
        output {} cap $cap ioerror {} stderrPath $prefix.stderr.log stderrTimer {}]
    dict set runs($id) stderrTimer [after 20 [list ::fuzz::pollError $id]]
    set timer [after $deadline [list ::fuzz::stop $id timedout]]
    set start [clock milliseconds]
    try {
        fconfigure $ch -blocking 0 -buffering none -translation binary
        fileevent $ch readable [list ::fuzz::readable $id]
        puts -nonewline $ch [encoding convertto utf-8 $input]
        flush $ch
        chan close $ch write
        while {![dict get $runs($id) done]} { vwait ::fuzz::runs($id) }
        fileevent $ch readable {}
        set result $runs($id)
        set errorBytes ""
        if {[file isfile $prefix.stderr.log]} {
            if {[file size $prefix.stderr.log] > $cap} { dict set result limited 1 }
            set errorBytes [readBytes $prefix.stderr.log $cap]
            writeBytes $prefix.stderr.log $errorBytes
        }
        if {[dict get $result timedout]} { incr timeouts }
        if {[dict get $result limited]} { incr limits }
        set stopped [expr {[dict get $result timedout] || [dict get $result limited] || [dict get $result aborted]}]
        # Normal EOF is guaranteed to follow supervisor completion. After a
        # timeout keep close nonblocking, even if the OS has delayed delivery.
        if {!$stopped} { fconfigure $ch -blocking 1 }
        catch {close $ch}
        set ch ""
        if {[file isfile $prefix.status.tcldata]} {
            set result [dict merge $result [readData $prefix.status.tcldata]]
        } else { dict set result status -1 }
        dict unset result channel
        dict unset result pids
        dict unset result done
        dict unset result cap
        dict unset result stderrPath
        dict unset result stderrTimer
        dict set result stderr $errorBytes
        dict set result stderr_log $prefix.stderr.log
        dict set result elapsed_ms [expr {[clock milliseconds] - $start}]
        writeBytes $prefix.log [dict get $result output]
        dict set result log $prefix.log
        return $result
    } finally {
        after cancel $timer
        after cancel [dict get $runs($id) stderrTimer]
        if {$ch ne ""} {
            catch {fileevent $ch readable {}}
            killTree [dict get $runs($id) pids]
            catch {close $ch}
        }
        unset runs($id)
    }
}

proc ::fuzz::worker {request} {
    variable project
    set data [readData $request]
    set ::argv [dict get $data arguments]
    set ::argc [llength $::argv]
    switch -- [dict get $data entry] {
        fault { faultWorker $::argv; return }
        adversary { adversarialWorker $::argv; return }
        manager { set target [file join $project tclvenv.tcl] }
        runtime { set target [file join [dict get $data environment] metadata runtime.tcl] }
        default { error "unknown worker entry" }
    }
    set ::argv0 $target
    uplevel #0 [list source $target]
}

proc ::fuzz::caseSeed {group index} {
    variable groups
    variable seed
    variable state
    set state [expr {($seed ^ (([lsearch -exact $groups $group] + 1) * 2654435761) ^ \
        (($index + 1) * 2246822519)) & 0xffffffff}]
    return $state
}
proc ::fuzz::number {limit} {
    variable state
    set state [expr {(1664525 * $state + 1013904223) & 0xffffffff}]
    return [expr {($state >> 8) % $limit}]
}
proc ::fuzz::pick {items} { lindex $items [number [llength $items]] }
proc ::fuzz::word {{osArgument 0}} {
    set corpus [list {} {plain} {two words} {'} {"} {$HOME} {[exit 77]} {;exit 77} \
        {|} {|&} {>} {2>@1} {<file} {&} [format %c 92] \n \r\n \t \u2603 \u00e9 \u03bb \u4e2d \
        {--interactive} {--stdin} {-encoding} {..} {*} {[]} {{}}]
    if {!$osArgument} { lappend corpus \u0000 }
    set result ""
    for {set i 0; set n [number 7]} {$i < $n} {incr i} { append result [pick $corpus] }
    return $result
}
proc ::fuzz::leaf {prefix} {
    set chars "abcXYZ019 _-'\$\[\]{};~\u2603\u00e9"
    if {$::tcl_platform(platform) eq "unix"} { append chars "\\\"\n\t*?!<>|`" }
    set name $prefix-
    for {set i 0; set n [expr {1 + [number 18]}]} {$i < $n} {incr i} {
        append name [string index $chars [number [string length $chars]]]
    }
    return $name-x
}
proc ::fuzz::shuffle {data} {
    set keys [dict keys $data]
    for {set i [expr {[llength $keys] - 1}]} {$i > 0} {incr i -1} {
        set j [number [expr {$i + 1}]]
        set a [lindex $keys $i]
        lset keys $i [lindex $keys $j]
        lset keys $j $a
    }
    set result {}
    foreach key $keys { dict set result $key [dict get $data $key] }
    return $result
}
proc ::fuzz::sameList {a b} {
    if {[llength $a] != [llength $b]} { return 0 }
    foreach x $a y $b { if {$x ne $y} { return 0 } }
    return 1
}
proc ::fuzz::shellWord {value} {
    return [format {'%s'} [join [split $value '] {'"'"'}]]
}
proc ::fuzz::need {condition message} {
    if {!$condition} { error $message }
}
proc ::fuzz::status {result expected message} {
    need [expr {![dict get $result timedout]}] "child process timed out"
    need [expr {![dict get $result limited]}] "child process exceeded output limit"
    need [expr {![dict get $result aborted]}] "child process I/O failed"
    need [expr {[dict get $result status] == $expected}] $message
}
proc ::fuzz::invoke {entry arguments {overrides {}}} {
    variable active
    variable current
    variable self
    variable envdir
    variable serial
    set request [file join $active worker-[incr serial].tcldata]
    writeText $request [dict create entry $entry arguments $arguments environment $envdir]
    set result [run [list [info nameofexecutable] $self --worker $request] $active {} $overrides]
    dict lappend current operations [dict create entry $entry arguments $arguments result $result]
    return $result
}
proc ::fuzz::launch {arguments {overrides {}}} {
    variable active
    variable current
    variable envdir
    need [expr {$::tcl_platform(platform) eq "unix"}] "POSIX launcher unavailable"
    set command [list [file join $envdir bin tclsh] {*}$arguments]
    set quoted {}
    foreach arg $command { lappend quoted [shellWord $arg] }
    set path [file join $active launch.sh]
    writeText $path "#!/bin/sh\nexec [join $quoted { }]\n"
    set result [run [list sh $path] $active {} $overrides]
    dict lappend current operations [dict create entry launcher arguments $arguments result $result]
    return $result
}

proc ::fuzz::guard {path {data "protected fuzz sentinel\n"}} {
    variable current
    file mkdir [file dirname $path]
    writeBytes $path $data
    dict set current guards $path [binary encode base64 $data]
}
proc ::fuzz::application {path} {
    writeText $path {
        set ch [open $env(TCLVENV_FUZZ_RESULT) w]
        fconfigure $ch -encoding utf-8 -translation lf
        puts $ch [dict create argc $argc argv $argv argv0 $argv0 script [info script] cwd [pwd] \
            environment $env(TCLVENV) global_found [expr {![catch {package require fuzz_external_guard}]}]]
        close $ch
    }
}
proc ::fuzz::appResult {app arguments {entry runtime} {overrides {}}} {
    variable active
    set output [file join $active application.tcldata]
    if {[exists $output]} { file delete -- $output }
    dict set overrides TCLVENV_FUZZ_RESULT $output
    switch -- $entry {
        manager {
            variable envdir
            set result [invoke manager [list run $envdir -- $app {*}$arguments] $overrides]
        }
        runtime { set result [invoke runtime [list -- $app {*}$arguments] $overrides] }
        launcher { set result [launch [list -- $app {*}$arguments] $overrides] }
    }
    status $result 0 "application did not complete successfully"
    need [file isfile $output] "application result was not written"
    return [readData $output]
}
proc ::fuzz::checkArguments {actual app expected} {
    variable envdir
    need [expr {[dict get $actual argc] == [llength $expected]}] "argument count changed"
    need [sameList [dict get $actual argv] $expected] "argument values changed"
    need [expr {[dict get $actual argv0] eq $app && [dict get $actual script] eq $app}] "script filename changed"
    need [expr {[dict get $actual cwd] eq [pwd]}] "working directory changed"
    need [expr {[dict get $actual environment] eq [file normalize $envdir]}] "wrong environment selected"
}

proc ::fuzz::scenario_argv {} {
    variable active
    variable current
    set entry [pick {manager runtime launcher}]
    if {$::tcl_platform(platform) ne "unix" && $entry eq "launcher"} { set entry runtime }
    set arguments {}
    for {set i 0; set count [number 21]} {$i < $count} {incr i} {
        lappend arguments [word [expr {$entry eq "launcher"}]]
    }
    set app [file join $active [leaf app].tcl]
    application $app
    dict set current input [dict create entry $entry arguments $arguments script_tail [file tail $app]]
    checkArguments [appResult $app $arguments $entry] $app $arguments
}

proc ::fuzz::scenario_cli {} {
    variable active
    variable envdir
    variable current
    set mode [number 8]
    set expected 1
    set destination [file join $active must-not-be-created]
    switch -- $mode {
        0 { set args [list unknown-[number 100000] [word] [word]] }
        1 { set args [list [pick {help --help -h --version}]]; set expected 0 }
        2 { set args [list [pick {info doctor list}]] }
        3 { set args [list run $envdir invalid-separator [word]] }
        4 { set args [list create $destination --unknown-[number 100000]] }
        5 { set args [list [pick {install remove}]] }
        6 { set args [list remove $envdir absent-[number 100000]] }
        7 { set args [list [pick {info doctor list}] $envdir]; set expected 0 }
    }
    dict set current input [dict create arguments $args expected_status $expected]
    status [invoke manager $args] $expected "CLI returned the wrong exit status"
    need [expr {![exists $destination]}] "invalid CLI created a destination"
}

proc ::fuzz::configAccepted {data identity} {
    if {[catch {
        dict size $data
        set valid [expr {[dict get $data format] == 1}]
        if {![string is boolean -strict [dict get $data system_packages]]} { set valid 0 }
        dict for {key value} $identity {
            if {[dict get $data runtime $key] ne $value} { set valid 0 }
        }
    }]} { return 0 }
    return $valid
}
proc ::fuzz::scenario_config {} {
    variable active
    variable envdir
    variable baseConfig
    variable current
    variable outside
    set data $baseConfig
    set mode [number 7]
    switch -- $mode {
        0 { dict set data system_packages [pick [list 0 1 false true yes no on off 2 -1 0.5 {} [word]]] }
        1 { dict unset data [pick {format runtime system_packages}] }
        2 { dict set data runtime [pick [list {} [word] [list version [word]]]] }
        3 {
            set key [pick [dict keys [dict get $baseConfig runtime]]]
            dict set data runtime $key [word]
        }
        4 { dict set data format invalid-[word] }
        5 {
            set offset [number [expr {[string length $data] + 1}]]
            set data [string replace $data $offset $offset [word]]
        }
        6 {
            set sentinel [file join $active protected sentinel]
            set data "[list open $sentinel w]\n"
        }
    }
    set expected [configAccepted $data [dict get $baseConfig runtime]]
    writeText [file join $envdir tclvenv.cfg] $data
    set output [file join $active application.tcldata]
    set overrides [dict create TCLVENV_FUZZ_RESULT $output TCLLIBPATH [list $outside]]
    set app [file join $active app.tcl]
    application $app
    dict set current input [dict create mode $mode config $data expected_acceptance $expected]
    set result [invoke runtime [list -- $app] $overrides]
    if {$expected} {
        status $result 0 "valid configuration was rejected"
        need [file isfile $output] "valid configuration did not execute the application"
        set actual [readData $output]
        set globalExpected [expr {!![dict get $data system_packages]}]
        need [expr {[dict get $actual global_found] == $globalExpected}] "configuration changed package isolation"
    } else {
        status $result 1 "invalid configuration was accepted"
        need [expr {![exists $output]}] "invalid configuration executed application code"
    }
}

proc ::fuzz::tree {path} {
    set result {}
    set queue [list [list $path {}]]
    for {set i 0} {$i < [llength $queue]} {incr i} {
        lassign [lindex $queue $i] absolute relative
        set kind [file type $absolute]
        if {$kind eq "file"} {
            dict set result $relative [list file [binary encode base64 [readBytes $absolute]]]
        } elseif {$kind eq "link"} {
            dict set result $relative [list link [file readlink $absolute]]
        } else {
            dict set result $relative [list $kind]
            if {$kind eq "directory"} {
                foreach child [entries $absolute] {
                    # Names as written: Tcl 8.6 gives a leading ~ as ./~, and
                    # file join would take it for a home directory.
                    set name [file tail $child]
                    if {[string match ./~* $name]} { set name [string range $name 2 end] }
                    if {$relative eq ""} { set key $name } else { set key $relative/$name }
                    lappend queue [list $child $key]
                }
            }
        }
    }
    return $result
}
proc ::fuzz::equalTree {expected actual} {
    if {[lsort [dict keys $expected]] ne [lsort [dict keys $actual]]} { return 0 }
    dict for {path data} $expected {
        if {$data ne [dict get $actual $path]} { return 0 }
    }
    return 1
}
proc ::fuzz::makePackage {path} {
    file mkdir $path
    writeText [file join $path pkgIndex.tcl] {error {package index must not run during installation}}
    set directories [list $path]
    for {set i 0; set count [expr {1 + [number 4]}]} {$i < $count} {incr i} {
        set dir [file join [pick $directories] [leaf d$i]]
        file mkdir $dir
        lappend directories $dir
    }
    for {set i 0; set count [expr {1 + [number 10]}]} {$i < $count} {incr i} {
        set path [file join [pick $directories] .[leaf f$i]]
        set bytes ""
        for {set j 0; set length [number 1025]} {$j < $length} {incr j} {
            append bytes [binary format c [number 256]]
        }
        writeBytes $path $bytes
    }
}
proc ::fuzz::noStages {} {
    variable envdir
    set pending [glob -nocomplain -directory [file join $envdir metadata] -- stage-* remove-*]
    need [expr {[llength $pending] == 0}] "package operation left an unfinished transaction"
}
proc ::fuzz::scenario_packages {} {
    variable active
    variable envdir
    variable current
    set mode [number 4]
    set source [file join $active [leaf package]]
    if {$mode == 3} {
        set source [file join $active [pick {bad-name-1.0.tm 9bad-1.0.tm -1.0.tm foo-bad.tm}]]
        writeText $source [word]
        dict set current input [dict create mode invalid-module filename [file tail $source]]
        status [invoke manager [list install $envdir $source]] 1 "invalid module filename was accepted"
        need [expr {[dict size [readData [file join $envdir metadata installed.tcldata]]] == 0}] "rejected module left an installation record"
        noStages
        return
    } elseif {$mode == 0} {
        set name fuzz_module_[number 100000]
        if {$::tcl_platform(platform) eq "unix" && [number 2]} { set name fuzz::$name }
        set version [pick {0.0 1.0 1.2.3 2.0a1 3.4b2 1.0.0.0}]
        set source [file join $active $name-$version.tm]
        writeText $source [list package provide $name $version]
        set target [file join $envdir modules [string map {:: /} $name]-$version.tm]
        set id $name@$version
        set expected [tree $source]
        dict set current input [dict create mode module name $name version $version]
        status [invoke manager [list install $envdir $source]] 0 "module installation failed"
        need [equalTree $expected [tree $target]] "module bytes changed during installation"
        set app [file join $active require.tcl]
        writeText $app "puts \[[list package require -exact $name $version]\]\n"
        set loaded [invoke runtime [list $app]]
        status $loaded 0 "installed module did not load"
        need [expr {[string trim [encoding convertfrom utf-8 [dict get $loaded output]]] eq $version}] "wrong module version loaded"
    } elseif {$mode == 1 && $::tcl_platform(platform) eq "unix"} {
        makePackage $source
        file link -symbolic [file join $source symlink] [file join $active protected sentinel]
        dict set current input [dict create mode symlink source_tail [file tail $source]]
        status [invoke manager [list install $envdir $source]] 1 "symlink package was accepted"
        need [expr {![exists [file join $envdir lib [file tail $source]]]}] "rejected package left installed files"
        need [expr {[dict size [readData [file join $envdir metadata installed.tcldata]]] == 0}] "rejected package left an installation record"
        noStages
        return
    } else {
        makePackage $source
        set expected [tree $source]
        set id [file tail $source]
        set target [file join $envdir lib $id]
        dict set current input [dict create mode indexed source_tail $id tree $expected]
        status [invoke manager [list install $envdir $source]] 0 "indexed package installation failed"
        need [equalTree $expected [tree $target]] "package files or empty directories changed during installation"
    }
    status [invoke manager [list remove $envdir $id]] 0 "installed package removal failed"
    need [expr {![exists $target]}] "removed package is still present"
    need [equalTree $expected [tree $source]] "package source changed during installation or removal"
    set receipts [readData [file join $envdir metadata installed.tcldata]]
    need [expr {![dict exists $receipts $id]}] "removed package retained an installation record"
    noStages
}

proc ::fuzz::scenario_inventory {} {
    variable active
    variable envdir
    variable current
    set source [file join $active fuzzpkg]
    file mkdir $source
    writeText [file join $source pkgIndex.tcl] {}
    writeText [file join $source data] "owned package data\n"
    status [invoke manager [list install $envdir $source]] 0 "inventory fixture installation failed"
    set manifest [file join $envdir metadata installed.tcldata]
    set data [readData $manifest]
    set record [dict get $data fuzzpkg]
    set mode [number 8]
    set expected 1
    switch -- $mode {
        0 {
            dict set record target [pick [list ../protected [file join $active protected] lib/../protected modules/../lib/fuzzpkg .]]
        }
        1 { dict set record state invalid-[word] }
        2 { dict unset record [pick {target files}] }
        3 { dict set record files [pick [list {} [word] [list data [word]]]] }
        4 {
            set stage remove-unrelated
            guard [file join $envdir metadata $stage precious] "unrelated staged data\n"
            dict set record state removing
            dict set record stage $stage
        }
        5 {
            dict set record state removing
            dict set record stage [pick [list ../protected [file join $active protected] stage-other remove-other/../..]]
        }
        6 {
            set data "[list open [file join $active protected sentinel] w]\n"
        }
        7 {
            set files {}
            dict for {path info} [shuffle [dict get $record files]] { dict set files $path [shuffle $info] }
            dict set record files $files
            set record [shuffle $record]
            set expected 0
        }
    }
    if {$mode != 6} { dict set data fuzzpkg $record }
    writeText $manifest $data
    dict set current input [dict create mode $mode inventory $data expected_status $expected]
    set before [tree [file join $envdir lib fuzzpkg]]
    set result [invoke manager [list remove $envdir fuzzpkg]]
    status $result $expected "inventory mutation returned an unexpected removal status"
    if {$expected} {
        need [equalTree $before [tree [file join $envdir lib fuzzpkg]]] "rejected inventory changed package files"
    } else {
        need [expr {![exists [file join $envdir lib fuzzpkg]]}] "valid reordered inventory did not remove its package"
    }
}

proc ::fuzz::scenario_paths {} {
    variable active
    variable envdir
    variable current
    cleanup $envdir
    set envdir [file join $active [leaf environment]]
    dict set current input [dict create environment_tail [file tail $envdir]]
    status [invoke manager [list create $envdir --tcl [info nameofexecutable]]] 0 "environment creation failed for a valid pathname"
    set app [file join $active [leaf script].tcl]
    application $app
    set args [list [word 1] [word 1]]
    checkArguments [appResult $app $args] $app $args
    if {$::tcl_platform(platform) eq "unix"} {
        checkArguments [appResult $app $args launcher] $app $args
        set resultFile [file join $active activated.tcldata]
        set script [file join $active activate.sh]
        set text "#!/bin/sh\nset -eu\n"
        append text "old_path=\$PATH\nTCLVENV=before\nexport TCLVENV\n"
        append text "env_root=[shellWord $envdir]\n. \"\$env_root/bin/activate\"\n"
        append text "export TCLVENV_FUZZ_RESULT=[shellWord $resultFile]\n"
        append text "tclsh [shellWord $app]\ndeactivate\n"
        append text {test "$PATH" = "$old_path" && test "$TCLVENV" = before}
        append text \n
        writeText $script $text
        set activated [run [list sh $script] $active]
        dict lappend current operations [dict create entry activation result $activated]
        status $activated 0 "activation did not restore shell state"
        checkArguments [readData $resultFile] $app {}
    }
}

proc ::fuzz::scenario_stdin {} {
    variable active
    variable envdir
    variable current
    set script ""
    for {set i 0; set count [expr {1 + [number 15]}]} {$i < $count} {incr i} {
        set value [word 1]
        switch -- [number 7] {
            0 { append script [list puts $value] \n }
            1 { append script [list set fuzz_value $value] \n {puts $fuzz_value} \n }
            2 { append script [list error $value] \n }
            3 { append script [pick {break continue return}] \n }
            4 { append script "puts \[expr {[number 1000] + [number 1000]}\]\n" }
            5 { append script [list ::fuzz_missing_command $value] \n }
            6 {
                set callback [list set fuzz_ready $value]
                # Schedule and install the wait in the same input command.
                append script [list after 0 $callback] {; vwait fuzz_ready; puts $fuzz_ready} \n
            }
        }
    }
    if {[number 3] == 0} { append script "close stdin\n" }
    dict set current input [dict create script $script]
    set native [run [list [info nameofexecutable]] $active $script]
    set isolated [run [list [info nameofexecutable] [file join $envdir metadata runtime.tcl] --stdin] $active $script]
    dict lappend current operations [dict create entry native-stdin result $native]
    dict lappend current operations [dict create entry environment-stdin result $isolated]
    status $native 0 "bounded native stdin program failed"
    status $isolated 0 "bounded environment stdin program failed"
    need [expr {[dict get $native output] eq [dict get $isolated output] &&
        [dict get $native stderr] eq [dict get $isolated stderr]}] "stdin behavior differs from native Tcl"
}

proc ::fuzz::scenario_ordering {} {
    variable envdir
    variable current
    set cfgPath [file join $envdir tclvenv.cfg]
    set cfg [shuffle [readData $cfgPath]]
    set mode [number 4]
    if {$mode in {1 3}} { dict set cfg runtime [shuffle [dict get $cfg runtime]] }
    writeText $cfgPath $cfg
    set corePath [file join $envdir metadata core-files.tcldata]
    set reordered {}
    dict for {path info} [shuffle [readData $corePath]] { dict set reordered $path [shuffle $info] }
    writeText $corePath $reordered
    dict set current input [dict create mode $mode config $cfg core_files $reordered]
    status [invoke manager [list doctor $envdir]] 0 "doctor rejects equivalent runtime dictionary"
}

proc ::fuzz::options {arguments} {
    set options [dict create seed 20261030 iterations 100 only all case -1 timeout 5000 steps 12 report-dir {}]
    while {[llength $arguments]} {
        set option [lindex $arguments 0]
        if {$option eq "--help"} { return [dict create help 1] }
        if {![string match --* $option] || ![dict exists $options [string range $option 2 end]] || [llength $arguments] < 2} {
            error "expected --seed N, --iterations N, --only GROUP, --case N, --steps N, --timeout MS, or --report-dir PATH"
        }
        dict set options [string range $option 2 end] [lindex $arguments 1]
        set arguments [lrange $arguments 2 end]
    }
    foreach key {seed iterations case timeout steps} {
        set value [dict get $options $key]
        if {![string is wideinteger -strict $value]} { error "$key must be an integer" }
    }
    if {[dict get $options seed] < 0 || [dict get $options seed] > 0xffffffff} { error "seed must fit an unsigned 32-bit integer" }
    if {[dict get $options iterations] < 1 || [dict get $options iterations] > 10000} { error "iterations must be between 1 and 10000" }
    if {[dict get $options case] < -1} { error "case must be nonnegative" }
    if {[dict get $options timeout] < 100 || [dict get $options timeout] > 60000} { error "timeout must be between 100 and 60000 ms" }
    if {[dict get $options steps] < 1 || [dict get $options steps] > 200} { error "steps must be between 1 and 200" }
    variable groups
    if {[dict get $options only] ni [concat $groups all]} { error "unknown fuzz group" }
    return $options
}
proc ::fuzz::main {arguments} {
    variable groups
    variable seed
    variable timeout
    variable active
    variable current
    variable envdir
    variable outside
    variable baseConfig
    variable self
    variable children
    variable timeouts
    variable limits
    variable steps
    variable coverage
    set options [options $arguments]
    if {[dict exists $options help]} {
        puts {Usage: tclsh tests/fuzz.tcl ?--seed N? ?--iterations N? ?--only GROUP? ?--case N? ?--steps N? ?--timeout MS? ?--report-dir PATH?}
        puts "Groups: $groups (iterations per group; --case replays a zero-based case)"
        return 0
    }
    set seed [dict get $options seed]
    set timeout [dict get $options timeout]
    set steps [dict get $options steps]
    set report [dict get $options report-dir]
    if {$report eq ""} {
        set ch [file tempfile report]
        close $ch
        file delete -- $report
    }
    set report [file normalize $report]
    if {[exists $report]} { error "report directory already exists: $report" }
    file mkdir [file join $report artifacts]
    set work [temporary]
    set failures {}
    set saved {}
    set counts {}
    set total 0
    set started [clock milliseconds]
    set children 0
    set timeouts 0
    set limits 0
    set coverage {}
    try {
        set active [file join $work setup]
        file mkdir $active
        set envdir [file join $work template]
        set current {}
        status [invoke manager [list create $envdir --tcl [info nameofexecutable]]] 0 "could not create the fuzz template"
        set baseConfig [readData [file join $envdir tclvenv.cfg]]
        set template $envdir
        set chosen [dict get $options only]
        if {$chosen eq "all"} { set chosen $groups }
        set first 0
        set last [dict get $options iterations]
        if {[dict get $options case] >= 0} {
            set first [dict get $options case]
            set last [expr {$first + 1}]
        }
        foreach group $chosen {
            set passed 0
            set failed 0
            for {set index $first} {$index < $last} {incr index} {
                incr total
                set derived [caseSeed $group $index]
                set active [file join $work case-$group-$index]
                file mkdir $active
                set envdir [file join $active env]
                file copy -- $template $envdir
                set outside [file join $active external]
                file mkdir $outside
                writeText [file join $outside pkgIndex.tcl] {
                    package ifneeded fuzz_external_guard 1.0 {package provide fuzz_external_guard 1.0}
                }
                set current [dict create group $group case $index case_seed $derived operations {} guards {}]
                guard [file join $active protected sentinel]
                set code [catch {::fuzz::scenario_$group} message errorOptions]
                set damaged {}
                dict for {path encoded} [dict get $current guards] {
                    if {![file isfile $path] || [catch {readBytes $path} bytes] ||
                        [binary encode base64 $bytes] ne $encoded} { lappend damaged $path }
                }
                if {[llength $damaged]} {
                    set code 1
                    set message "unrelated guard files changed or were deleted"
                    dict set current damaged_guards $damaged
                }
                if {$code} {
                    incr failed
                    dict set current failure $message
                    if {[dict exists $errorOptions -errorinfo]} { dict set current errorinfo [dict get $errorOptions -errorinfo] }
                    set variant ""
                    foreach field {mode fault} {
                        if {[dict exists $current input $field]} { set variant [dict get $current input $field]; break }
                    }
                    set key [list $group $message $variant]
                    set replay [replayCommand $group $index]
                    dict set current replay $replay
                    if {![dict exists $saved $key] && [dict size $saved] < 32} {
                        set destination [file join $report artifacts $group-$index]
                        set operations {}
                        foreach operation [dict get $current operations] {
                            foreach field {log stderr_log} {
                                if {[dict exists $operation result $field]} {
                                    dict set operation result $field \
                                        [file join $destination [file tail [dict get $operation result $field]]]
                                }
                            }
                            lappend operations $operation
                        }
                        dict set current operations $operations
                        dict set current artifact $destination
                        writeText [file join $active input.tcldata] $current
                        file rename -- $active $destination
                        dict set saved $key $destination
                    } else {
                        set operations {}
                        foreach operation [dict get $current operations] {
                            foreach field {log stderr_log} {
                                if {[dict exists $operation result $field]} { dict unset operation result $field }
                            }
                            lappend operations $operation
                        }
                        dict set current operations $operations
                        dict set current artifact [expr {[dict exists $saved $key] ? [dict get $saved $key] : ""}]
                        cleanup $active
                    }
                    lappend failures $current
                } else { incr passed; cleanup $active }
            }
            dict set counts $group [dict create passed $passed failed $failed]
            puts "$group: $passed passed, $failed failed"
            flush stdout
        }
    } finally { cleanup $work }
    set summary [dict create tcl [info patchlevel] platform $::tcl_platform(os) seed $seed \
        iterations [dict get $options iterations] options $options total $total failed [llength $failures] \
        groups $counts child_processes $children timeouts $timeouts output_limits $limits \
        coverage $coverage elapsed_ms [expr {[clock milliseconds] - $started}]]
    writeText [file join $report summary.tcldata] $summary
    writeText [file join $report failures.tcldata] [dict create failures $failures]
    set text "Tcl [info patchlevel], seed $seed: $total cases, [llength $failures] failures\n"
    append text "Timeouts: $timeouts; output limits: $limits\n"
    dict for {key artifact} $saved {
        lassign $key group message variant
        set label $group
        if {$variant ne ""} { append label " ($variant)" }
        append text "$label: $message\nArtifact: $artifact\n"
        set example [readData [file join $artifact input.tcldata]]
        if {$::tcl_platform(platform) eq "unix"} {
            set words {}
            foreach arg [dict get $example replay] { lappend words [shellWord $arg] }
            append text "Replay: [join $words { }]\n"
        } else { append text "Replay argv (Tcl list): [dict get $example replay]\n" }
    }
    writeText [file join $report summary.txt] $text
    puts $text
    puts "Report: $report"
    return [expr {[llength $failures] != 0}]
}

source [file join [file dirname [info script]] fuzz_extended.tcl]
source [file join [file dirname [info script]] fuzz_adversarial.tcl]
source [file join [file dirname [info script]] fuzz_compat.tcl]
source [file join [file dirname [info script]] fuzz_hostile.tcl]
source [file join [file dirname [info script]] fuzz_sources.tcl]
source [file join [file dirname [info script]] fuzz_external.tcl]
source [file join [file dirname [info script]] fuzz_shells.tcl]
source [file join [file dirname [info script]] fuzz_system.tcl]
source [file join [file dirname [info script]] fuzz_outputs.tcl]
source [file join [file dirname [info script]] fuzz_installer.tcl]
source [file join [file dirname [info script]] fuzz_limits.tcl]
source [file join [file dirname [info script]] fuzz_recovery.tcl]

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[lindex $::argv 0] eq "--supervise"} {
        ::fuzz::supervise [lindex $::argv 1] [lindex $::argv 2]
    } elseif {[lindex $::argv 0] eq "--worker"} {
        ::fuzz::worker [lindex $::argv 1]
    } elseif {[catch {::fuzz::main $::argv} result options]} {
        puts stderr "fuzz harness: $result"
        exit 2
    } else { exit $result }
}
