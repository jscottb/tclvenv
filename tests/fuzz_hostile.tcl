# Loaded by fuzz.tcl. Hostile-input groups: generated rather than enumerated
# inputs, checked against oracles written apart from the production code.
#
#   names        hostile package names, module filenames, and removal IDs
#   datafuzz     random structural and byte mutations of persisted data
#   fakeruntime  creation with broken or hostile "Tcl" executables
#   concurrency  real simultaneous manager processes, no hooks
#   killpoints   SIGKILL at random times during install/remove/create
#   stdinmore    a wider stdin grammar compared with native tclsh
#
# The Unix-only groups (they need sh, kill and symlink-free fake runtimes)
# pass trivially elsewhere, counting the case as skipped.

# --- Shared oracles ----------------------------------------------------------

# A failed manager command reports one clean message: no Tcl stack trace.
proc ::fuzz::cleanFailure {result what} {
    if {[dict get $result status] != 1} { return }
    set text [encoding convertfrom utf-8 [dict get $result stderr]]
    need [string match "tclvenv: *" $text] "$what failed without a clean tclvenv: message"
    need [expr {[string first "while executing" $text] < 0}] "$what printed a Tcl stack trace"
}

# Status 0 or 1, terminated, within limits; a failure is clean.
proc ::fuzz::managerOutcome {result what} {
    need [expr {![dict get $result timedout]}] "$what did not terminate"
    need [expr {![dict get $result limited]}] "$what exceeded the output limit"
    need [expr {![dict get $result aborted]}] "$what child I/O failed"
    need [expr {[dict get $result status] in {0 1}}] "$what ended with status [dict get $result status]"
    cleanFailure $result $what
}

# Added, removed and changed relative paths between two tree snapshots.
proc ::fuzz::treeDiff {before after} {
    set added {}
    set removed {}
    set changed {}
    dict for {path data} $after {
        if {![dict exists $before $path]} {
            lappend added $path
        } elseif {[dict get $before $path] ne $data} {
            lappend changed $path
        }
    }
    dict for {path data} $before {
        if {![dict exists $after $path]} { lappend removed $path }
    }
    dict create added $added removed $removed changed $changed
}

# Whether path is prefix itself or below it (relative tree paths).
proc ::fuzz::under {path prefix} {
    expr {$path eq $prefix || [string match [string map {* \\* ? \\? [ \\[ ] \\] \\ \\\\} $prefix]/* $path]}
}

proc ::fuzz::sameFiles {a b} {
    if {[catch {dict size $a} n] || [catch {dict size $b} m] || $n != $m} { return 0 }
    dict for {path info} $a {
        if {![dict exists $b $path]} { return 0 }
        set other [dict get $b $path]
        if {[catch {dict size $info} x] || [catch {dict size $other} y] || $x != $y} { return 0 }
        dict for {field value} $info {
            if {![dict exists $other $field] || [dict get $other $field] ne $value} { return 0 }
        }
    }
    return 1
}

# SHA-256 of a file from the system's tools (independent of the manager's
# own implementation), or "" where there are none.
proc ::fuzz::systemSha256 {path} {
    # The file on stdin: a name on the command line would be escaped in
    # the output.
    foreach command {sha256sum {shasum -a 256}} {
        if {[auto_execok [lindex $command 0]] ne ""} {
            regexp {[0-9a-f]{64}} [exec {*}$command < $path] hash
            return $hash
        }
    }
    return ""
}

# Whether the records describe the tree at path: the same entries, types,
# sizes and CRC-32s (computed here), and SHA-256s checked with the system's
# tools. mtime is recorded but, by design, never compared.
proc ::fuzz::recordsMatch {path records} {
    set actual [recordFiles $path]
    if {[catch {dict size $records}] || [lsort [dict keys $actual]] ne [lsort [dict keys $records]]} { return 0 }
    dict for {relative info} $actual {
        set recorded [dict get $records $relative]
        if {[catch {dict size $recorded}]} { return 0 }
        foreach field [dict keys $recorded] {
            if {$field ni {type size crc32 sha256 mtime}} { return 0 }
        }
        dict for {field value} $info {
            if {![dict exists $recorded $field] || [dict get $recorded $field] ne $value} { return 0 }
        }
        if {[dict exists $recorded sha256]} {
            # (A string join: a ~ name must not mean a home directory.)
            if {$relative eq ""} { set file $path } else { set file $path/$relative }
            set expected [systemSha256 $file]
            if {$expected ne "" && $expected ne [dict get $recorded sha256]} { return 0 }
        }
    }
    return 1
}

# Problems an environment has, judged without the production code: a
# readable configuration, receipts whose files match what is on disk, the
# core-module snapshot, no lock, no pending or staged operation.
proc ::fuzz::independentProblems {root} {
    set problems {}
    if {[catch {
        set cfg [readData [file join $root tclvenv.cfg]]
        if {!([dict get $cfg format] == 1)} { lappend problems "configuration format" }
        if {![string is boolean -strict [dict get $cfg system_packages]]} { lappend problems "system_packages" }
        set records [readData [file join $root metadata installed.tcldata]]
        dict for {id record} $records {
            set target [dict get $record target]
            set parts [file split $target]
            if {[lindex $parts 0] ni {lib modules} || ".." in $parts || [file pathtype $target] ne "relative"} {
                lappend problems "receipt $id targets $target"
                continue
            }
            if {[dict exists $record state] && [dict get $record state] ne "installed"} {
                lappend problems "receipt $id is [dict get $record state]"
                continue
            }
            if {[catch {recordsMatch "$root/$target" [dict get $record files]} matches]} {
                lappend problems "receipt $id: $matches"
            } elseif {!$matches} {
                lappend problems "receipt $id does not match its files"
            }
        }
        if {![recordsMatch [file join $root metadata core-modules] \
                [readData [file join $root metadata core-files.tcldata]]]} {
            lappend problems "core modules"
        }
    } message]} { lappend problems "unreadable: $message" }
    if {[exists [file join $root metadata mutation.lock]]} { lappend problems "lock" }
    foreach leftover [glob -nocomplain -directory [file join $root metadata] -- stage-* remove-* .tclvenv-*] {
        lappend problems "leftover [file tail $leftover]"
    }
    return $problems
}

# doctor passing must mean the environment really is consistent.
proc ::fuzz::doctorAgrees {root} {
    set result [invoke manager [list doctor $root]]
    managerOutcome $result doctor
    if {[dict get $result status] == 0} {
        set problems [independentProblems $root]
        need [expr {![llength $problems]}] "doctor passed an inconsistent environment: [join $problems {; }]"
    }
    return [dict get $result status]
}

proc ::fuzz::unixOnly {} {
    if {$::tcl_platform(platform) ne "unix"} {
        cover skipped-non-unix
        return 0
    }
    return 1
}

# --- names -------------------------------------------------------------------

proc ::fuzz::hostileName {} {
    set whole [list ~ ~x ~root ... - -- -x --help x@1.0 lib modules metadata pkgIndex.tcl \
        installed.tcldata * ? {[x]} {{x}} "x " " x" x. é é "a\nb" {a\b} a:b a::b \
        [string repeat a 255] [string repeat a 256] [string repeat é 128] CON nul "x\ty" \
        .hidden {$HOME} {;rm} | > & "x​y" ﻿x 007 0x10 1e3 " 12" 00]
    if {[number 2]} { return [pick $whole] }
    set fragments [list ~ . - @ * ? \[ \] \{ \} " " \\ : \n \t é é 中 x y 1.0 lib ..]
    set name ""
    for {set i 0; set n [expr {1 + [number 5]}]} {$i < $n} {incr i} { append name [pick $fragments] }
    return $name
}

proc ::fuzz::hostileModule {} {
    set name [pick [list hm_[number 1000] _x X9 a::b été A_[number 99]]]
    set version [pick [list 1.0 0 01 1.0.0.0.0 1..0 1. .1 1.0a 1.0a1b2 1.0-2 1.0.tm ١ 1e2 0x10 \
        "1.0 " 999999999999999999999 1a1 1b 2.0b3 0.0.0]]
    return [list $name $version]
}

# A package directory providing hostile_probe 1.0, built by string paths so
# a name like ~x stays a literal component on Tcl 8.6.
proc ::fuzz::probePackage {path} {
    file mkdir $path
    writeText "$path/pkgIndex.tcl" {package ifneeded hostile_probe 1.0 [list source [file join $dir probe.tcl]]}
    writeText "$path/probe.tcl" "package provide hostile_probe 1.0\n"
    writeBytes "$path/data" [encoding convertto utf-8 [word]]
    # A top-level entry with a hostile name too (one that looks like a
    # number was recorded as the number).
    set inner [pick [list 007 0x10 1e3 " 12" 00 ~y .z -w "a b" \u00e9]]
    writeBytes "$path/$inner" inner
}

proc ::fuzz::scenario_names {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    set home [file join $active home]
    file mkdir $home
    guard [file join $home precious]
    set overrides [dict create HOME $home]
    set kind [pick {directory directory module removal}]
    cover $kind
    set srcdir [file join $active src]
    file mkdir $srcdir
    set before [tree $envdir]
    if {$kind eq "removal"} {
        set source [simplePackage plainpkg]
        status [invoke manager [list install $envdir $source] $overrides] 0 "removal fixture install failed"
        set before [tree $envdir]
        set id [hostileName]
        if {$id eq "plainpkg"} { set id plainpkg-x }
        dict set current input [dict create mode removal id $id]
        set result [invoke manager [list remove $envdir $id] $overrides]
        managerOutcome $result "remove of a hostile ID"
        need [expr {[dict get $result status] == 1}] "removal of an uninstalled hostile ID succeeded"
        need [equalTree $before [tree $envdir]] "removal of an uninstalled hostile ID changed the environment"
        return
    }
    if {$kind eq "directory"} {
        set name [hostileName]
        set source "$srcdir/$name"
        set expectedId $name
        dict set current input [dict create mode directory name $name]
        if {$name in {. .. ...} || [catch {probePackage $source}]} {
            cover unrepresentable
            return
        }
    } else {
        lassign [hostileModule] mname version
        set name "$mname-$version.tm"
        set source "$srcdir/$name"
        set expectedId $mname@$version
        dict set current input [dict create mode module name $mname version $version]
        if {[catch {writeText $source [list package provide $mname $version]}]} {
            cover unrepresentable
            return
        }
    }
    set sourceTree [tree $source]
    set result [invoke manager [list install $envdir $source] $overrides]
    managerOutcome $result "install of a hostile name"
    need [equalTree $sourceTree [tree $source]] "installation changed its source"
    if {[dict get $result status] == 1} {
        cover rejected
        need [equalTree $before [tree $envdir]] "rejected installation changed the environment"
        noStages
        return
    }
    cover accepted
    set records [readData [receiptPath]]
    need [expr {[dict size $records] == 1}] "installation did not add exactly one receipt"
    set id [lindex [dict keys $records] 0]
    need [expr {$id eq $expectedId}] "installation ID [list $id] differs from the documented [list $expectedId]"
    set target [dict get $records $id target]
    if {$kind eq "directory"} {
        need [expr {$target eq "lib/$name"}] "package installed at [list $target], not under its basename"
        need [equalTree $sourceTree [tree "$envdir/lib/$name"]] "installed package differs from its source"
    }
    set listed [encoding convertfrom utf-8 [dict get [invoke manager [list list $envdir] $overrides] output]]
    need [expr {[string first "$id\t" $listed] == 0}] "list does not show the installation ID"
    # Accepted must mean usable: the package or module loads.
    set app [file join $active load.tcl]
    if {$kind eq "directory"} {
        writeText $app "puts \[package require hostile_probe\]\n"
        set want 1.0
    } else {
        writeText $app "puts \[[list package require -exact $mname $version]\]\n"
        set want $version
    }
    set loaded [invoke runtime [list -- $app] $overrides]
    need [expr {[dict get $loaded status] == 0 &&
        [string trim [encoding convertfrom utf-8 [dict get $loaded output]]] eq $want}] \
        "accepted package cannot be loaded"
    need [expr {[doctorAgrees $envdir] == 0}] "doctor rejects a freshly installed package"
    set removed [invoke manager [list remove $envdir $id] $overrides]
    managerOutcome $removed "remove of an accepted hostile name"
    need [expr {[dict get $removed status] == 0}] "accepted package could not be removed by its listed ID"
    need [equalTree $before [tree $envdir]] "install and remove did not restore the environment"
}

# --- datafuzz ----------------------------------------------------------------

proc ::fuzz::hostileValue {} {
    pick [list {} 0 -1 1 2 9999999999999999999 1e309 NaN {{}} "\{" "\}" "\"" "\\" / /etc/passwd ../.. \
        ../outside lib lib/x lib/../.. modules/x.tm modules/../lib ~ ~root * {[exit 3]} {$env(HOME)} \
        "a\nb" removing installed remove-x stage-x metadata {type file size 1 crc32 00000000} \
        {type directory} {type link} {{} {type directory}} [word]]
}

# One random structural change somewhere in a nested dictionary.
proc ::fuzz::structMutate {data} {
    set path {}
    while {[llength $path] < 3 && [number 2]} {
        set node [dict get $data {*}$path]
        if {[catch {dict size $node} n] || $n == 0} { break }
        set key [pick [dict keys $node]]
        set child [dict get $node $key]
        if {[catch {dict size $child} m] || $m == 0} { break }
        lappend path $key
    }
    set node [expr {[llength $path] ? [dict get $data {*}$path] : $data}]
    set keys [dict keys $node]
    set op [expr {[llength $keys] ? [number 4] : 1}]
    switch -- $op {
        0 { dict set data {*}$path [pick $keys] [hostileValue] }
        1 { dict set data {*}$path [hostileValue] [hostileValue] }
        2 { dict unset data {*}$path [pick $keys] }
        3 {
            set key [pick $keys]
            set value [dict get $node $key]
            dict unset data {*}$path $key
            dict set data {*}$path [hostileValue] $value
        }
    }
    return $data
}

proc ::fuzz::byteMutate {bytes} {
    set n [string length $bytes]
    set at [number [expr {$n + 1}]]
    switch -- [number 7] {
        0 { return [string range $bytes 0 [expr {$at - 1}]] }
        1 { return [string replace $bytes $at [expr {$at + [number 8]}]] }
        2 {
            set insert [pick [list "\{" "\}" "\"" "\\" "\x00" "\xff\xfe" "\r" "\n" " " "#" "\xc3"]]
            return "[string range $bytes 0 [expr {$at - 1}]]$insert[string range $bytes $at end]"
        }
        3 {
            set span [string range $bytes $at [expr {$at + [number 40]}]]
            return "[string range $bytes 0 [expr {$at - 1}]]$span$span[string range $bytes [expr {$at + [string length $span]}] end]"
        }
        4 {
            if {!$n} { return [binary format c [number 256]] }
            set at [number $n]
            return [string replace $bytes $at $at [binary format c [number 256]]]
        }
        5 { return [string map [list \n \r\n] $bytes] }
        6 { return "\xef\xbb\xbf$bytes" }
    }
}

proc ::fuzz::scenario_datafuzz {} {
    variable active
    variable envdir
    variable current
    set sourceA [simplePackage dataA]
    status [invoke manager [list install $envdir $sourceA]] 0 "datafuzz fixture install failed"
    set sourceM [file join $active dataM-1.0.tm]
    writeText $sourceM {package provide dataM 1.0}
    status [invoke manager [list install $envdir $sourceM]] 0 "datafuzz module install failed"
    set sourceN [simplePackage datanew]
    set file [pick {tclvenv.cfg metadata/installed.tcldata metadata/installed.tcldata metadata/core-files.tcldata}]
    set path [file join $envdir $file]
    set mutations {}
    for {set i 0; set n [expr {1 + [number 4]}]} {$i < $n} {incr i} {
        set data [readBytes $path]
        if {[number 2] && ![catch {dict size [encoding convertfrom utf-8 $data]}]} {
            lappend mutations structural
            writeText $path [structMutate [encoding convertfrom utf-8 $data]]
        } else {
            lappend mutations bytes
            writeBytes $path [byteMutate $data]
        }
    }
    set command [pick {list info doctor install remove-A remove-M run}]
    cover $command
    dict set current input [dict create mode $command file $file mutations $mutations \
        mutated_base64 [binary encode base64 [readBytes $path]]]
    set before [tree $envdir]
    set app [file join $active app.tcl]
    writeText $app "puts ok\n"
    switch -- $command {
        install { set result [invoke manager [list install $envdir $sourceN]] }
        remove-A { set result [invoke manager [list remove $envdir dataA]] }
        remove-M { set result [invoke manager [list remove $envdir dataM@1.0]] }
        run { set result [invoke manager [list run $envdir -- $app]] }
        default { set result [invoke manager [list $command $envdir]] }
    }
    cover "$command exit [dict get $result status]"
    if {$command eq "run"} {
        # The application's own failure output isn't the manager's.
        need [expr {![dict get $result timedout] && [dict get $result status] in {0 1}}] "run did not end cleanly"
    } else {
        managerOutcome $result $command
    }
    set diff [treeDiff $before [tree $envdir]]
    switch -- $command {
        install {
            foreach p [dict get $diff added] {
                need [expr {[under $p lib/datanew] || [string match metadata/stage-* $p]}] \
                    "install of an unrelated package added $p"
            }
            need [expr {![llength [dict get $diff removed]]}] "install removed [dict get $diff removed]"
            foreach p [dict get $diff changed] {
                need [expr {$p eq "metadata/installed.tcldata"}] "install changed $p"
            }
        }
        remove-A - remove-M {
            set own [expr {$command eq "remove-A" ? "lib/dataA" : "modules/dataM-1.0.tm"}]
            foreach p [dict get $diff removed] {
                need [under $p $own] "removing one package deleted $p"
            }
            foreach p [dict get $diff changed] {
                need [expr {$p eq "metadata/installed.tcldata"}] "removal changed $p"
            }
            foreach p [dict get $diff added] {
                need [string match metadata/remove-* $p] "removal added $p"
            }
        }
        default {
            need [expr {![llength [dict get $diff added]] && ![llength [dict get $diff removed]] &&
                ![llength [dict get $diff changed]]}] "read-only command $command changed the environment: $diff"
        }
    }
    doctorAgrees $envdir
}

# --- fakeruntime -------------------------------------------------------------

proc ::fuzz::scenario_fakeruntime {} {
    variable active
    variable current
    if {![unixOnly]} { return }
    set tcl [info nameofexecutable]
    set kind [pick {hang garbage oldversion futureversion huge failing stderr-noise wrapper directory not-executable missing injection}]
    cover $kind
    set fake [file join $active fake-tclsh]
    set marker [file join $active injected]
    set identity "version 8.6.99 library /nonexistent platform unix os Linux machine x86_64 pointerSize 8 threaded 1 core_modules {}"
    set leftover ""
    switch -- $kind {
        hang {
            # The runtime hangs, closes its output and keeps running, or is
            # a wrapper whose child hangs; none may outlive the creation.
            set leftover "sleep 30.[number 1000]"
            set body [pick [list "exec $leftover" "exec >&-\nexec $leftover" "$leftover\necho never"]]
        }
        garbage { set body "echo 'not a dictionary \{'" }
        oldversion { set body "echo 'executable /bin/sh [string map {8.6.99 8.5.19} $identity]'" }
        futureversion { set body "echo 'executable /bin/sh [string map {8.6.99 10.0} $identity]'" }
        huge { set body "head -c 20000000 /dev/zero" }
        failing { set body "echo failing >&2; exit 3" }
        stderr-noise { set body "echo 'warning from the runtime' >&2\nexec [shellWord $tcl] \"\$@\"" }
        wrapper { set body "exec [shellWord $tcl] \"\$@\"" }
        injection {
            set exe [pick [list "/x'; touch [shellWord $marker]; '" "/x\$(touch $marker)" "/x`touch $marker`" \
                "/x\ntouch $marker" "/x\"; touch $marker; \""]]
            set body "cat <<'EOF'\n[list executable $exe] $identity\nEOF"
        }
        default { set body "" }
    }
    switch -- $kind {
        directory { file mkdir $fake }
        missing {}
        not-executable { writeText $fake "#!/bin/sh\n$body\n" }
        default {
            writeText $fake "#!/bin/sh\n$body\n"
            file attributes $fake -permissions 0755
        }
    }
    set destination [file join $active [leaf env]]
    dict set current input [dict create mode $kind]
    # A short probe deadline, so a hanging runtime is stopped well inside
    # this harness's own limit.
    set result [invoke manager [list create $destination --tcl $fake] [dict create TCLVENV_PROBE_TIMEOUT 1000]]
    managerOutcome $result "create with a $kind runtime"
    need [expr {![llength [glob -nocomplain -directory $active -- .tclvenv-create-*]]}] "failed creation left a staging directory"
    need [expr {![exists $destination.tclvenv-create.lock]}] "creation left its lock"
    if {[dict get $result status] == 1} {
        need [expr {![exists $destination]}] "failed creation left a destination"
        need [expr {$kind ni {wrapper}}] "creation with a working runtime wrapper failed"
    } else {
        need [expr {$kind in {wrapper stderr-noise injection futureversion}}] "creation accepted a $kind runtime"
        if {$kind eq "injection"} {
            # Running the launcher must not run anything the reported path contains.
            set launched [run [list sh [file join $destination bin tclsh] -c exit] $active]
            dict lappend current operations [dict create entry launcher result $launched]
        }
    }
    need [expr {![exists $marker]}] "a reported runtime path was executed as shell code"
    if {$leftover ne ""} {
        need [catch {exec pgrep -f "^$leftover\$"}] "a stopped runtime's process is still running"
    }
}

# --- concurrency -------------------------------------------------------------

proc ::fuzz::scenario_concurrency {} {
    variable active
    variable envdir
    variable current
    variable project
    if {![unixOnly]} { return }
    set sources [dict create conA [simplePackage conA] conB [simplePackage conB]]
    set moduleSource [file join $active conM-1.0.tm]
    writeText $moduleSource {package provide conM 1.0}
    dict set sources conM@1.0 $moduleSource
    set trees {}
    dict for {id source} $sources { dict set trees $id [tree $source] }
    set initially {}
    dict for {id source} $sources {
        if {[number 2]} {
            status [invoke manager [list install $envdir $source]] 0 "concurrency fixture install failed"
            lappend initially $id
        }
    }
    set ops {}
    for {set i 0; set n [expr {2 + [number 6]}]} {$i < $n} {incr i} {
        set id [pick [dict keys $sources]]
        switch -- [pick {install install remove remove list info doctor}] {
            install { lappend ops [list install $envdir [dict get $sources $id]] }
            remove { lappend ops [list remove $envdir $id] }
            list { lappend ops [list list $envdir] }
            info { lappend ops [list info $envdir] }
            doctor { lappend ops [list doctor $envdir] }
        }
    }
    dict set current input [dict create mode concurrent initially $initially operations $ops]
    set driver "#!/bin/sh\n"
    set tcl [shellWord [info nameofexecutable]]
    set manager [shellWord [file join $project tclvenv.tcl]]
    set i 0
    foreach op $ops {
        set words [lmap a $op {shellWord $a}]
        append driver "( $tcl $manager [join $words { }] > [shellWord $active/op$i.out] 2> [shellWord $active/op$i.err]; echo \$? > [shellWord $active/op$i.status] ) &\n"
        incr i
    }
    append driver "wait\n"
    writeText [file join $active driver.sh] $driver
    set result [run [list sh [file join $active driver.sh]] $active {} {} 30000]
    dict lappend current operations [dict create entry concurrent result $result]
    need [expr {![dict get $result timedout]}] "concurrent operations did not finish"
    set succeeded {}
    set i 0
    foreach op $ops {
        set st [string trim [readBytes $active/op$i.status]]
        set err [encoding convertfrom utf-8 [readBytes $active/op$i.err]]
        need [expr {$st in {0 1}}] "concurrent [lindex $op 0] ended with status $st"
        switch -- [lindex $op 0] {
            install - remove {
                if {$st == 1} {
                    set known 0
                    foreach pattern {"environment is locked" "already installed or destination exists" "package is not installed"} {
                        if {[string first $pattern $err] >= 0} { set known 1 }
                    }
                    need $known "concurrent [lindex $op 0] failed unexpectedly: [string trim $err]"
                } elseif {[lindex $op 0] eq "install"} {
                    lappend succeeded [file tail [lindex $op 2]]
                }
            }
            list - info {
                need [expr {$st == 0}] "concurrent [lindex $op 0] failed: [string trim $err]"
            }
        }
        incr i
    }
    need [expr {![llength [independentProblems $envdir]]}] "concurrent operations left: [join [independentProblems $envdir] {; }]"
    set records [readData [receiptPath]]
    set expectedLib {}
    set expectedModules {}
    dict for {id record} $records {
        need [dict exists $sources $id] "unknown receipt $id after concurrent operations"
        need [equalTree [dict get $trees $id] [tree [file join $envdir [dict get $record target]]]] "package $id differs from its source"
        if {$id ni $initially} {
            set tail [expr {$id eq "conM@1.0" ? "conM-1.0.tm" : $id}]
            need [expr {[lsearch -exact $succeeded $tail] >= 0}] "package $id is installed but no install of it succeeded"
        }
    }
    foreach entry [entries [file join $envdir lib]] {
        need [dict exists $records [file tail $entry]] "unreceipted [file tail $entry] in lib"
    }
    need [expr {[doctorAgrees $envdir] == 0}] "doctor fails after concurrent operations ended"
}

# --- killpoints --------------------------------------------------------------

proc ::fuzz::bigPackage {path} {
    file mkdir $path
    writeText [file join $path pkgIndex.tcl] {}
    foreach d {a b c d e} { file mkdir [file join $path $d] }
    set chunk ""
    for {set i 0} {$i < 1024} {incr i} { append chunk [binary format c [number 256]] }
    for {set i 0} {$i < 200} {incr i} {
        writeBytes [file join $path [pick {a b c d e}] f$i] [string repeat $chunk [expr {1 + [number 8]}]]
    }
}

# How long install, remove and create of a bigPackage take here, timed once
# per run, so kill delays land inside the operations rather than after.
proc ::fuzz::killCalibration {} {
    variable killTimes
    variable project
    if {[info exists killTimes]} { return $killTimes }
    set work [temporary]
    try {
        set saved $::fuzz::state
        bigPackage [file join $work bigpkg]
        set ::fuzz::state $saved
        set tcl [info nameofexecutable]
        set manager [file join $project tclvenv.tcl]
        set killTimes {}
        foreach {op arguments} [list create [list create [file join $work env]] \
                install [list install [file join $work env] [file join $work bigpkg]] \
                remove [list remove [file join $work env] bigpkg]] {
            set start [clock microseconds]
            exec -- $tcl $manager {*}$arguments
            dict set killTimes $op [expr {([clock microseconds] - $start) / 1000.0}]
        }
    } finally { cleanup $work }
    return $killTimes
}

proc ::fuzz::killDuring {arguments delay} {
    variable active
    variable project
    set script "#!/bin/sh\n[shellWord [info nameofexecutable]] [shellWord [file join $project tclvenv.tcl]] [join [lmap a $arguments {shellWord $a}] { }] > /dev/null 2>&1 &\n"
    append script "pid=\$!\nsleep [format %.3f [expr {$delay / 1000.0}]]\nkill -KILL \$pid 2>/dev/null\nwait \$pid\necho \$? > [shellWord $active/killed.status]\n"
    writeText [file join $active kill.sh] $script
    set result [run [list sh [file join $active kill.sh]] $active {} {} 30000]
    need [expr {![dict get $result timedout]}] "killed operation did not finish"
    return [string trim [readBytes $active/killed.status]]
}

proc ::fuzz::scenario_killpoints {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    set op [pick {install remove remove create}]
    # Uniform over 0 to 1.2 times the operation's own duration, in 0.1 ms steps.
    set span [expr {int([dict get [killCalibration] $op] * 12)}]
    set delay [expr {[number [expr {max($span, 1)}]] / 10.0}]
    cover $op
    set source [file join $active bigpkg]
    bigPackage $source
    set original [tree $source]
    set target [file join $envdir lib bigpkg]
    dict set current input [dict create mode $op delay_ms $delay]
    if {$op eq "create"} {
        set destination [file join $active created]
        set code [killDuring [list create $destination --tcl [info nameofexecutable]] $delay]
        dict set current input exit $code
        if {[exists $destination]} {
            need [expr {[doctorAgrees $destination] == 0}] "an interrupted creation published an incomplete environment"
        }
        if {[exists $destination.tclvenv-create.lock] && ![exists $destination]} {
            # The creator is dead: its lock is taken over (when it got to
            # write one, which is then complete), and creation succeeds.
            set again [invoke manager [list create $destination --tcl [info nameofexecutable]]]
            need [expr {[dict get $again status] == 0}] "creation didn't take over a dead creator's lock: [string trim [dict get $again stderr]]"
            need [expr {![exists $destination.tclvenv-create.lock]}] "creation after a takeover left its lock"
            need [expr {[doctorAgrees $destination] == 0}] "the environment created after a takeover is not healthy"
        }
        return
    }
    if {$op eq "remove"} {
        status [invoke manager [list install $envdir $source]] 0 "kill fixture install failed"
        set code [killDuring [list remove $envdir bigpkg] $delay]
    } else {
        set code [killDuring [list install $envdir $source] $delay]
    }
    dict set current input exit $code
    cover [expr {$code == 137 ? "$op killed" : "$op finished first"}]
    need [equalTree $original [tree $source]] "an interrupted operation changed its source"
    # The process is dead: its lock is stale.
    set lock [file join $envdir metadata mutation.lock]
    if {[exists $lock]} { file delete -- $lock }
    set records [readData [receiptPath]]
    if {[dict exists $records bigpkg]} {
        set state [expr {[dict exists $records bigpkg state] ? [dict get $records bigpkg state] : "installed"}]
        if {$state eq "installed"} {
            if {![exists $target] || ![equalTree $original [tree $target]]} {
                # Detached by a removal that died before its receipt changed:
                # the files must be complete in a journal's payload.
                cover detached
                set found 0
                foreach stage [glob -nocomplain -directory [file join $envdir metadata] -- remove-*] {
                    set payload [file join $stage payload]
                    if {[exists $payload] && [equalTree $original [tree $payload]]} { set found 1 }
                }
                need $found "a receipted package lost files"
            }
        } else {
            cover resumed
            set retry [invoke manager [list remove $envdir bigpkg]]
            managerOutcome $retry "resumed removal"
            need [expr {[dict get $retry status] == 0}] "a pending removal could not be resumed: [string trim [dict get $retry stderr]]"
            need [expr {![exists $target]}] "a resumed removal left the package"
        }
    } elseif {[exists $target]} {
        cover published-unreceipted
        # Published but not receipted: only a recovery journal may explain it.
        need [expr {[llength [glob -nocomplain -directory [file join $envdir metadata] -- stage-* remove-*]] > 0}] \
            "a package is published without a receipt or a journal"
    }
    doctorAgrees $envdir
}

# --- stdinmore ---------------------------------------------------------------

proc ::fuzz::scenario_stdinmore {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    set lines {}
    for {set i 0; set n [expr {1 + [number 10]}]} {$i < $n} {incr i} {
        set value [word 1]
        switch -- [number 11] {
            0 { lappend lines [list puts $value] }
            1 { lappend lines {puts "read: [gets stdin]"} [string map {\n " "} $value] }
            2 { lappend lines "puts \\\n    [list $value]" }
            3 { lappend lines "puts [list @INVALID@$value]" }
            4 { lappend lines [list puts [string repeat x [expr {60000 + [number 20000]}]]] }
            5 { lappend lines [list exit [number 5]] }
            6 { lappend lines "fconfigure stdin -translation [pick {lf crlf auto binary}]" }
            7 { lappend lines {puts [info script]} {puts $tcl_interactive} }
            8 { lappend lines [list error $value] }
            9 { lappend lines "set x \{" }
            10 { lappend lines [list puts [string length $value]] }
        }
    }
    set script [join $lines \n]
    set ending [pick {lf lf crlf none}]
    switch -- $ending {
        lf { append script \n }
        crlf { set script "[string map [list \n \r\n] $script]\r\n" }
        none {}
    }
    cover $ending
    # Bytes, so invalid UTF-8 (the placeholder) reaches both interpreters
    # unchanged.
    set bytes [string map [list @INVALID@ \xff\xfe] [encoding convertto utf-8 $script]]
    set input [file join $active input.tcl]
    writeBytes $input $bytes
    dict set current input [dict create mode $ending script_base64 [binary encode base64 $bytes]]
    set tcl [info nameofexecutable]
    # The long lines exceed the usual 64 KiB output cap: allow 1 MiB, and
    # treat reaching it as an error rather than a difference.
    set cap 1048576
    set native [run [list sh -c {exec "$0" < "$1"} $tcl $input] $active {} {} {} $cap]
    set isolated [run [list sh -c {exec "$0" "$1" --stdin < "$2"} $tcl [file join $envdir metadata runtime.tcl] $input] $active {} {} {} $cap]
    dict lappend current operations [dict create entry native-stdin result $native]
    dict lappend current operations [dict create entry environment-stdin result $isolated]
    need [expr {![dict get $native timedout] && ![dict get $isolated timedout]}] "a stdin program did not finish"
    need [expr {![dict get $native limited] && ![dict get $isolated limited]}] "a stdin program exceeded the output cap"
    need [expr {[dict get $native status] == [dict get $isolated status]}] \
        "stdin exit status differs from native Tcl ([dict get $native status] vs [dict get $isolated status])"
    need [expr {[dict get $native output] eq [dict get $isolated output]}] "stdin output differs from native Tcl"
    need [expr {[dict get $native stderr] eq [dict get $isolated stderr]}] "stdin diagnostics differ from native Tcl"
}
