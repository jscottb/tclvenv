# Loaded by fuzz.tcl. Groups for what an interrupted or failing command
# leaves behind, and how the next command deals with it.
#
#   stalelocks     a mutation or creation lock (and its breaker) in one of
#                  many shapes: a dead or live holder on this host, another
#                  host, older formats, garbage, odd pids, directories,
#                  links, oversized files; or several processes taking over
#                  one stale lock at once
#   crashrecovery  a command killed with SIGKILL at a transaction cut point
#                  or a random time (install or remove, of a package
#                  directory or a module), then recovery by recover, by the
#                  next command, or by a recover that is itself killed
#   rollbacks      a package whose load check changes its own files and
#                  then fails (an error, exit, a hang past the deadline) or
#                  passes; and remove --discard-changes of a package changed
#                  after installation
#
# Oracles (independent of the manager's own checks):
# - A lock is taken over exactly when it is a regular file recording this
#   host and a pid with no process, and no live breaker; otherwise the
#   command fails cleanly and the lock, breaker and environment are byte
#   for byte unchanged. A breaker left by a dead process doesn't block a
#   takeover. Concurrent takeovers never lose a receipt: every
#   package a successful process installed has its receipt, and nothing is
#   installed without one.
# - After recovery an interrupted operation is all or nothing: a package is
#   installed byte for byte with its receipt, or absent with no receipt;
#   committed operations (a written receipt, a "removing" receipt) keep
#   their outcome and uncommitted ones are undone. No stage, temporary file
#   or lock remains, doctor agrees with the independent check, the package
#   source and the guards are unchanged, recovery repeated changes nothing,
#   and the package can be installed or removed again.
# - A failure message saying "nothing was installed" leaves nothing
#   installed; one naming what couldn't be undone leaves exactly that.
#   --discard-changes is refused without the flag (nothing changes) and
#   removes the package with it, never following a link out of it.

# --- stalelocks ----------------------------------------------------------------

proc ::fuzz::deadPid {} {
    exec -- [info nameofexecutable] << {puts [pid]}
}

# A lock-like file at path in the given shape; returns whether a command
# may take it over.
proc ::fuzz::lockShape {path shape} {
    variable active
    set host [info hostname]
    switch -- $shape {
        dead { writeText $path "[list host $host pid [deadPid]]\n"; return 1 }
        dead-nonewline { writeText $path [list host $host pid [deadPid]]; return 1 }
        dead-reordered { writeText $path "[list pid [deadPid] host $host]\n"; return 1 }
        dead-spaced { writeText $path "  host   [list $host]\tpid   [deadPid]  \n\n"; return 1 }
        live { writeText $path "[list host $host pid [liveHolder]]\n"; return 0 }
        self-parent { writeText $path "[list host $host pid [pid]]\n"; return 0 }
        other-host { writeText $path "[list host [word]$host-x pid [deadPid]]\n"; return 0 }
        old-format { writeText $path "pid [deadPid]\n"; return 0 }
        garbage { writeText $path [word]; return 0 }
        empty { writeText $path ""; return 0 }
        extra-key { writeText $path "[list host $host pid [deadPid] [word] x]\n"; return 0 }
        pid-zero { writeText $path "[list host $host pid 0]\n"; return 0 }
        pid-negative { writeText $path "[list host $host pid -[deadPid]]\n"; return 0 }
        pid-word { writeText $path "[list host $host pid [word]x]\n"; return 0 }
        pid-huge { writeText $path "[list host $host pid 99999999999999999999]\n"; return 0 }
        oversized { writeText $path "[list host $host pid [deadPid]][string repeat { } 5000]\n"; return 0 }
        directory { file mkdir $path; writeText [file join $path owner] [list host $host pid [deadPid]]; return 0 }
        link {
            set target [file join $active protected lock-target]
            guard $target "[list host $host pid [deadPid]]\n"
            file link -symbolic $path $target
            return 0
        }
    }
}

# A process that stays alive until the case ends (its pid is a live holder).
proc ::fuzz::liveHolder {} {
    variable liveHolders
    set ch [open |[list [info nameofexecutable]] r+]
    lappend liveHolders $ch
    pid $ch
}
proc ::fuzz::releaseHolders {} {
    variable liveHolders
    if {![info exists liveHolders]} { return }
    foreach ch $liveHolders { catch {close $ch} }
    set liveHolders {}
}

proc ::fuzz::scenario_stalelocks {} {
    if {![unixOnly]} { return }
    try { staleLocksCase } finally { releaseHolders }
}
proc ::fuzz::staleLocksCase {} {
    variable active
    variable envdir
    variable current
    if {[number 5] == 0} { return [staleLockRace] }
    set shapes {dead dead-nonewline dead-reordered dead-spaced live self-parent other-host old-format
        garbage empty extra-key pid-zero pid-negative pid-word pid-huge oversized directory link}
    set shape [pick $shapes]
    set breaker [pick {none none none live dead garbage directory}]
    set creation [expr {[number 3] == 0}]
    cover [list $shape $breaker [expr {$creation ? "create" : "mutation"}]]
    if {$creation} {
        set destination [file join $active [leaf created]]
        set lock $destination.tclvenv-create.lock
        set command [list create $destination --tcl [info nameofexecutable]]
    } else {
        set lock [file join $envdir metadata mutation.lock]
        set source [simplePackage lockpkg]
        set command [list install $envdir $source]
    }
    set stale [lockShape $lock $shape]
    switch -- $breaker {
        none {}
        live { writeText $lock.break "[list host [info hostname] pid [liveHolder]]\n" }
        dead { writeText $lock.break "[list host [info hostname] pid [deadPid]]\n" }
        garbage { writeText $lock.break [word] }
        directory { file mkdir $lock.break }
    }
    dict set current input [dict create shape $shape breaker $breaker creation $creation]
    set beforeEnv [tree $envdir]
    set beforeLock [tree $lock]
    set beforeBreaker [expr {[exists $lock.break] ? [tree $lock.break] : {}}]
    set result [invoke manager $command]
    managerOutcome $result "command with a $shape lock"
    # A breaker left by a dead process is cleared, and the takeover goes on.
    set expected [expr {$stale && $breaker in {none dead}}]
    if {$expected} {
        status $result 0 "a stale $shape lock was not taken over: [string trim [dict get $result stderr]]"
        need [string match "*took over*no longer exists*" [dict get $result stderr]] "a takeover was not reported"
        need [expr {![exists $lock] && ![exists $lock.break]}] "the taken-over lock or its breaker remained"
        if {$creation} {
            need [expr {[doctorAgrees $destination] == 0}] "the environment created after a takeover is not healthy"
        } else {
            need [dict exists [readData [receiptPath]] lockpkg] "the install after a takeover has no receipt"
            noStages
            need [expr {[doctorAgrees $envdir] == 0}] "the environment is not healthy after a takeover"
        }
    } else {
        status $result 1 "a $shape lock (breaker $breaker) was taken over"
        need [string match "*is locked*" [dict get $result stderr]] "a refused lock wasn't reported as a lock"
        need [equalTree $beforeEnv [tree $envdir]] "a refused lock changed the environment"
        need [equalTree $beforeLock [tree $lock]] "a refused lock was changed"
        if {$breaker ni {none dead}} {
            need [equalTree $beforeBreaker [tree $lock.break]] "a breaker in place was changed"
        }
        if {$creation} { need [expr {![exists $destination]}] "a refused creation published a destination" }
    }
}

# Several installs at once, each of its own package, against one stale lock.
proc ::fuzz::staleLockRace {} {
    variable active
    variable envdir
    variable project
    variable current
    set count [expr {2 + [number 3]}]
    cover race-$count
    set lock [file join $envdir metadata mutation.lock]
    lockShape $lock dead
    set script "#!/bin/sh\n"
    set names {}
    for {set i 0} {$i < $count} {incr i} {
        set name racer$i
        lappend names $name
        set source [simplePackage $name]
        append script "[shellWord [info nameofexecutable]] [shellWord [file join $project tclvenv.tcl]] install [shellWord $envdir] [shellWord $source] > /dev/null 2>[shellWord $active/race$i.err] &\n"
        append script "pid$i=\$!\n"
    }
    for {set i 0} {$i < $count} {incr i} {
        append script "wait \$pid$i; echo \$? > [shellWord $active/race$i.status]\n"
    }
    writeText [file join $active race.sh] $script
    dict set current input [dict create race $count]
    set result [run [list sh [file join $active race.sh]] $active {} {} 120000]
    need [expr {![dict get $result timedout]}] "racing installs did not finish"
    set records [readData [receiptPath]]
    set winners 0
    foreach name $names i [lsearch -all $names *] {
        set code [string trim [readBytes $active/race$i.status]]
        set err [raceText $active/race$i.err]
        if {$code == 0} {
            incr winners
            need [dict exists $records $name] "$name was reported installed but has no receipt (a lost update)"
        } else {
            need [expr {$code == 1 && [string match "*is locked*" $err]}] "a racing install failed otherwise: $err"
            need [expr {![dict exists $records $name]}] "$name was refused but has a receipt"
        }
    }
    need [expr {$winners >= 1}] "no racing install took over the stale lock"
    foreach entry [glob -nocomplain -tails -directory [file join $envdir lib] -- *] {
        need [dict exists $records $entry] "lib/$entry is installed without a receipt (two holders at once)"
    }
    need [expr {![exists $lock] && ![exists $lock.break]}] "a lock or breaker remained after the race"
    noStages
    need [expr {[doctorAgrees $envdir] == 0}] "the environment is not healthy after racing takeovers"
}
proc ::fuzz::raceText {path} {
    set ch [open $path r]
    try { read $ch } finally { close $ch }
}

# --- crashrecovery --------------------------------------------------------------

# A package to crash: {source id target}, a directory or a module.
proc ::fuzz::crashSubject {} {
    variable active
    if {[number 3] == 0} {
        set name [pick {cmod nsx::cmod}]
        set version 1.[number 9]
        set file [file join $active modsrc $name-$version.tm]
        file mkdir [file dirname $file]
        writeText $file "package provide $name $version\n# [word]\n"
        return [list $file $name@$version modules/[string map {:: /} $name]-$version.tm]
    }
    # (./ keeps Tcl 8.6 from taking ~tilde for a home directory.)
    set name [pick {crashpkg ~tilde {sp ace}}]
    set source [bigOrSmall [file join $active ./$name]]
    return [list $source $name lib/$name]
}
proc ::fuzz::bigOrSmall {path} {
    if {[number 2]} { makePackage $path; writeBytes [file join $path data] [encoding convertto utf-8 [word]] } else { bigPackage $path }
    return $path
}

# Whether the package is installed byte for byte with its receipt (1),
# absent without one (0); an error for anything in between.
proc ::fuzz::allOrNothing {original id target} {
    variable envdir
    set records [readData [receiptPath]]
    set path [file join $envdir $target]
    if {[dict exists $records $id]} {
        need [expr {![dict exists $records $id state] || [dict get $records $id state] eq "installed"}] \
            "$id is still pending after recovery"
        need [exists $path] "$id has a receipt but no files"
        need [equalTree $original [tree $path]] "$id is installed with changed files"
        return 1
    }
    need [expr {![exists $path]}] "$target exists without a receipt"
    return 0
}

proc ::fuzz::scenario_crashrecovery {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    lassign [crashSubject] source id target
    set original [tree $source]
    set removing [number 2]
    set points [expr {$removing ? {remove-journal remove-marker remove-detach remove-pending remove-delete remove-final random}
                                : {install-copy install-journal install-marker install-publish write-temp install-receipt random}}]
    set point [pick $points]
    # (The adversary's remove-delete deletes payload/data: directories only.)
    if {$point eq "remove-delete" && [string match modules/* $target]} { set point remove-pending }
    set how [pick {recover recover next-install next-remove-other killed-recover doctor-first}]
    cover [list [expr {$removing ? "remove" : "install"}] $point $how]
    # An unrelated package that recovery must leave alone.
    set other [simplePackage bystander]
    status [invoke manager [list install $envdir $other]] 0 "bystander install failed"
    set otherTree [tree [file join $envdir lib bystander]]
    if {$removing} { status [invoke manager [list install $envdir $source]] 0 "crash fixture install failed" }
    set object [expr {$removing ? $id : $source}]
    dict set current input [dict create point $point how $how removing $removing id $id]
    if {$point eq "random"} {
        set span [expr {int([dict get [killCalibration] [expr {$removing ? "remove" : "install"}]] * 12)}]
        set delay [expr {[number [expr {max($span, 1)}]] / 10.0}]
        dict set current input delay_ms $delay
        killDuring [list [expr {$removing ? "remove" : "install"}] $envdir $object] $delay
    } else {
        set event [file join $active crash.tcldata]
        set result [invoke adversary [list crash $point $envdir $object $event {} {}]]
        status $result -1 "crash worker did not terminate at $point"
        need [file isfile $event] "crash point $point was not reached"
    }
    need [equalTree $original [tree $source]] "an interrupted operation changed its source"
    switch -- $how {
        doctor-first {
            set result [invoke manager [list doctor $envdir]]
            managerOutcome $result "doctor after a crash"
            if {[dict get $result status]} {
                need [regexp {recover|remove} [dict get $result stderr]] "doctor didn't say how to recover: [dict get $result stderr]"
            }
            set result [invoke manager [list recover $envdir]]
        }
        killed-recover {
            # Recovery itself interrupted at a random time, then run again.
            killDuring [list recover $envdir] [expr {[number 400] / 10.0}]
            set result [invoke manager [list recover $envdir]]
        }
        next-install {
            set result [invoke manager [list install $envdir [simplePackage nextpkg]]]
        }
        next-remove-other {
            set result [invoke manager [list remove $envdir bystander]]
        }
        default { set result [invoke manager [list recover $envdir]] }
    }
    managerOutcome $result "recovery ($how)"
    set records [readData [receiptPath]]
    # A committed removal is finished by remove (recover says so).
    if {[dict exists $records $id state] && [dict get $records $id state] eq "removing"} {
        cover pending-removal
        if {$how in {recover doctor-first killed-recover}} {
            status $result 1 "recover didn't report a pending removal"
            need [string match "*unfinished removal of*run remove*" [dict get $result stderr]] "recover didn't say to run remove"
        }
        status [invoke manager [list remove $envdir $id]] 0 "a pending removal could not be finished"
    } else {
        status $result 0 "recovery failed: [string trim [dict get $result stderr]]"
    }
    set installed [allOrNothing $original $id $target]
    cover [list $point [expr {$installed ? "kept" : "undone"}]]
    # Committed points have a fixed outcome; a random kill may land anywhere.
    switch -- $point {
        install-copy - install-journal - install-marker - install-publish - write-temp {
            need [expr {!$installed}] "an uncommitted install ($point) was kept"
        }
        install-receipt { need $installed "a committed install was undone" }
        remove-journal - remove-marker - remove-detach {
            need $installed "an uncommitted removal ($point) was not undone"
        }
        remove-pending - remove-delete - remove-final {
            need [expr {!$installed}] "a committed removal ($point) left the package"
        }
    }
    if {$how ne "next-remove-other"} {
        need [dict exists [readData [receiptPath]] bystander] "recovery removed an unrelated package"
        need [equalTree $otherTree [tree [file join $envdir lib bystander]]] "recovery changed an unrelated package"
    }
    noStages
    need [expr {![llength [glob -nocomplain -directory [file join $envdir metadata] -- .tclvenv-* tcl_*.tclvenv-* mutation.lock*]]}] \
        "recovery left a temporary file or lock"
    need [expr {[doctorAgrees $envdir] == 0}] "doctor fails after recovery"
    # Recovery is idempotent.
    set before [tree $envdir]
    status [invoke manager [list recover $envdir]] 0 "a second recover failed"
    need [equalTree $before [tree $envdir]] "a second recover changed the environment"
    # And the package can be installed or removed again.
    if {$installed} {
        status [invoke manager [list remove $envdir $id]] 0 "the recovered package could not be removed"
    } else {
        status [invoke manager [list install $envdir $source]] 0 "the package could not be installed after recovery"
        need [allOrNothing $original $id $target] "the reinstall is not complete"
    }
    need [expr {[doctorAgrees $envdir] == 0}] "doctor fails after reusing the recovered environment"
}

# --- rollbacks --------------------------------------------------------------------

# A load script that changes the package's own files: Tcl text run with $dir.
proc ::fuzz::selfChange {contentVar} {
    upvar 1 $contentVar content
    set content 0
    set steps {}
    for {set i 0; set n [expr {1 + [number 3]}]} {$i < $n} {incr i} {
        set step [number 5]
        # (Only a mode change leaves the content as recorded.)
        if {$step != 4} { set content 1 }
        switch -- $step {
            0 { lappend steps {set ch [open [file join $dir cache.dat] w]; puts $ch x; close $ch} }
            1 { lappend steps {set ch [open [file join $dir data] a]; puts $ch appended; close $ch} }
            2 { lappend steps {file delete -- [file join $dir data]} }
            3 { lappend steps {file mkdir [file join $dir cache sub]; close [open [file join $dir cache sub f] w]} }
            4 { lappend steps {file attributes [file join $dir pkgIndex.tcl] -permissions 0444} }
        }
    }
    join $steps "\n"
}

proc ::fuzz::scenario_rollbacks {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    if {[number 3] == 0} { return [discardCase] }
    set ending [pick {error exit hang pass}]
    set changes [selfChange contentChanged]
    set viaArchive [number 2]
    cover [list $ending [expr {$viaArchive ? "archive" : "directory"}]]
    set source [file join $active src selfpkg]
    file mkdir $source
    writeText [file join $source data] [word]
    set end [dict get {error {error "load failed"} exit {exit 3} hang {after 60000} pass {}} $ending]
    writeText [file join $source pkgIndex.tcl] \
        "package ifneeded selfpkg 1.0 \[list apply {{dir} {[string map {\n ;} $changes]; $end; package provide selfpkg 1.0}} \$dir\]\n"
    set original [tree $source]
    dict set current input [dict create ending $ending changes $changes archive $viaArchive]
    if {$viaArchive} {
        set archive [file join $active selfpkg.tar]
        exec tar -C [file dirname $source] -cf $archive selfpkg
        set command [list install $envdir $archive --no-deps]
    } else {
        set command [list install $envdir $source --check]
    }
    set result [invoke manager $command [dict create TCLVENV_PROBE_TIMEOUT 3000]]
    managerOutcome $result "install of a self-changing package"
    need [equalTree $original [tree $source]] "the load check changed the package source"
    set records [readData [receiptPath]]
    set err [dict get $result stderr]
    if {$ending eq "pass"} {
        status $result 0 "a package that loads was refused: $err"
        need [dict exists $records selfpkg] "a package that loads was not installed"
        # Its load changed its files: remove refuses them until told to
        # discard (a change of mode alone isn't one).
        if {$contentChanged} {
            status [invoke manager [list remove $envdir selfpkg]] 1 "a changed package was removed without --discard-changes"
            status [invoke manager [list remove $envdir selfpkg --discard-changes]] 0 "--discard-changes failed"
        } else {
            status [invoke manager [list remove $envdir selfpkg]] 0 "an unchanged package could not be removed"
        }
    } else {
        status $result 1 "a package whose load check fails was installed"
        if {[string match "*so nothing was installed*" $err]} {
            need [expr {![dict size $records]}] "said nothing was installed, but [dict keys $records] is"
            need [expr {![llength [glob -nocomplain -directory [file join $envdir lib] -- *]]}] "said nothing was installed, but lib/ isn't empty"
        } else {
            need [regexp {could not be undone: (\S+)} $err -> left] "the failure says neither outcome: $err"
            need [dict exists $records $left] "said $left could not be undone, but it has no receipt"
        }
    }
    noStages
    unlocked
    need [expr {[doctorAgrees $envdir] == 0}] "doctor fails after a rolled-back install"
}

# remove --discard-changes of a package changed after installation.
proc ::fuzz::discardCase {} {
    variable active
    variable envdir
    variable current
    set source [simplePackage discarded]
    status [invoke manager [list install $envdir $source]] 0 "discard fixture install failed"
    set target [file join $envdir lib discarded]
    set outsideTarget [file join $active protected outside]
    guard $outsideTarget
    set edits {}
    for {set i 0; set n [expr {1 + [number 3]}]} {$i < $n} {incr i} {
        set edit [pick {add modify delete subdir link-out link-dir readonly-dir}]
        lappend edits $edit
        switch -- $edit {
            add { writeText [file join $target [leaf added]] [word] }
            modify { writeText [file join $target data] [word]x }
            delete { catch {file delete -- [file join $target data]} }
            subdir { file mkdir [file join $target [leaf sub] deeper]; writeText [file join $target added-dir-file] x }
            link-out { file link -symbolic [file join $target [leaf link]] $outsideTarget }
            link-dir { file link -symbolic [file join $target [leaf dirlink]] [file dirname $outsideTarget] }
            readonly-dir {
                set dir [file join $target [leaf ro]]
                file mkdir $dir
                writeText [file join $dir f] x
                file attributes $dir -permissions 0555
            }
        }
    }
    cover [list discard {*}[lsort -unique $edits]]
    dict set current input [dict create discard $edits]
    set before [tree $envdir]
    set refused [invoke manager [list remove $envdir discarded]]
    managerOutcome $refused "remove of a changed package"
    if {[dict get $refused status] == 0} {
        # Only when the edits happened to change nothing (a delete of a
        # file already gone, say); otherwise removal must refuse.
        return
    }
    need [equalTree $before [tree $envdir]] "a refused removal changed the environment"
    need [string match "*--discard-changes*" [dict get $refused stderr]] "the refusal doesn't mention --discard-changes"
    status [invoke manager [list remove $envdir discarded --discard-changes]] 0 "--discard-changes failed"
    need [expr {![exists $target]}] "--discard-changes left the package"
    need [expr {![dict exists [readData [receiptPath]] discarded]}] "--discard-changes left the receipt"
    need [file isdirectory [file dirname $outsideTarget]] "--discard-changes followed a link out of the package"
    noStages
    unlocked
    need [expr {[doctorAgrees $envdir] == 0}] "doctor fails after --discard-changes"
}
