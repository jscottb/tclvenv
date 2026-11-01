# Loaded by fuzz.tcl. These properties use independent filesystem snapshots
# and a package-state model; no production comparison helpers form the oracle.
proc ::fuzz::cover {label} {
    variable coverage
    variable current
    dict incr coverage [list [dict get $current group] $label]
}
proc ::fuzz::replayCommand {group index} {
    variable self
    variable seed
    variable timeout
    variable steps
    list [info nameofexecutable] $self --seed $seed --only $group --case $index --timeout $timeout --steps $steps
}

proc ::fuzz::lifecyclePlan {count} {
    set result {}
    for {set i 0} {$i < $count} {incr i} {
        lappend result [list [pick {install install remove remove edit restore doctor list}] [number 4]]
    }
    return $result
}
proc ::fuzz::receiptPath {} {
    variable envdir
    file join $envdir metadata installed.tcldata
}
proc ::fuzz::unlocked {} {
    variable envdir
    need [expr {![exists [file join $envdir metadata mutation.lock]]}] "completed operation retained its mutation lock"
}
proc ::fuzz::simplePackage {name} {
    variable active
    set path [file join $active $name]
    makePackage $path
    writeBytes [file join $path data] [encoding convertto utf-8 [word]]
    return $path
}
proc ::fuzz::checkModel {model} {
    variable envdir
    set records [readData [receiptPath]]
    set expectedIds {}
    dict for {id item} $model {
        need [equalTree [dict get $item base] [tree [dict get $item source]]] "lifecycle changed package source data"
        set target [file join $envdir lib $id]
        if {[dict get $item installed]} {
            lappend expectedIds $id
            need [equalTree [dict get $item live] [tree $target]] "lifecycle changed unexpected installed files"
            need [dict exists $records $id] "lifecycle lost an installed receipt"
            need [expr {[dict get $records $id target] eq [file join lib $id]}] "lifecycle receipt targets the wrong package"
            need [expr {[dict get $records $id state] eq "installed"}] "lifecycle left a pending removal"
        } else {
            need [expr {![exists $target]}] "lifecycle retained an uninstalled package"
        }
    }
    need [sameList [lsort $expectedIds] [lsort [dict keys $records]]] "lifecycle receipt set differs from the state model"
    noStages
    unlocked
}
proc ::fuzz::scenario_lifecycle {} {
    variable envdir
    variable current
    variable steps
    set model {}
    for {set i 0} {$i < 4} {incr i} {
        set id life-$i
        set source [simplePackage $id]
        set base [tree $source]
        dict set model $id [dict create source $source base $base live $base installed 0 dirty 0]
    }
    set plan [lifecyclePlan $steps]
    dict set current input [dict create plan $plan steps $steps]
    foreach operation $plan {
        lassign $operation action slot
        cover $action
        set id life-$slot
        set item [dict get $model $id]
        set present [dict get $item installed]
        set target [file join $envdir lib $id]
        switch -- $action {
            install {
                status [invoke manager [list install $envdir [dict get $item source]]] $present "lifecycle install disagrees with the state model"
                if {!$present} {
                    dict set item installed 1
                    dict set item dirty 0
                    dict set item live [dict get $item base]
                }
            }
            remove {
                set reject [expr {!$present || [dict get $item dirty]}]
                status [invoke manager [list remove $envdir $id]] $reject "lifecycle remove disagrees with the state model"
                if {!$reject} { dict set item installed 0 }
            }
            edit {
                if {$present} {
                    set path [file join $target data]
                    writeBytes $path "[readBytes [file join [dict get $item source] data]]\x00changed"
                    dict set item dirty 1
                    dict set item live [tree $target]
                }
            }
            restore {
                if {$present} {
                    writeBytes [file join $target data] [readBytes [file join [dict get $item source] data]]
                    dict set item dirty 0
                    dict set item live [dict get $item base]
                }
            }
            doctor {
                set dirty 0
                dict for {other record} $model {
                    if {[dict get $record installed] && [dict get $record dirty]} { set dirty 1 }
                }
                status [invoke manager [list doctor $envdir]] $dirty "lifecycle doctor disagrees with the state model"
            }
            list { status [invoke manager [list list $envdir]] 0 "lifecycle list failed" }
        }
        dict set model $id $item
        checkModel $model
    }
    dict for {id item} $model {
        if {![dict get $item installed]} { continue }
        writeBytes [file join $envdir lib $id data] [readBytes [file join [dict get $item source] data]]
        status [invoke manager [list remove $envdir $id]] 0 "lifecycle final cleanup failed"
        dict set item installed 0
        dict set model $id $item
    }
    checkModel $model
}

proc ::fuzz::shuffleFiles {files} {
    set result {}
    dict for {path info} [shuffle $files] { dict set result $path [shuffle $info] }
    return $result
}
proc ::fuzz::scenario_recovery {} {
    variable active
    variable envdir
    variable current
    set mode [pick {valid partial empty reordered missing mismatch malformed extra payload-change payload-extra journal-link stage-link absent-stage}]
    if {$::tcl_platform(platform) ne "unix" && $mode in {journal-link stage-link}} { set mode missing }
    cover $mode
    set source [simplePackage recoverpkg]
    set originalSource [tree $source]
    status [invoke manager [list install $envdir $source]] 0 "recovery fixture install failed"
    set receipt [dict get [readData [receiptPath]] recoverpkg]
    set stage [file join $envdir metadata remove-fuzz]
    file mkdir $stage
    set journal [file join $stage transaction.tcldata]
    writeText $journal $receipt
    set payload [file join $stage payload]
    set external ""
    file rename -- [file join $envdir lib recoverpkg] $payload
    dict set receipt state removing
    dict set receipt stage [file tail $stage]
    set expected 1
    switch -- $mode {
        valid { set expected 0 }
        partial {
            dict for {relative data} [tree $payload] {
                if {[lindex $data 0] eq "file" && [number 2]} { file delete -- [file join $payload $relative] }
            }
            set expected 0
        }
        empty { cleanup $payload; set expected 0 }
        reordered {
            set data [shuffle [readData $journal]]
            dict set data files [shuffleFiles [dict get $data files]]
            writeText $journal $data
            dict set receipt files [shuffleFiles [dict get $receipt files]]
            set receipt [shuffle $receipt]
            set expected 0
        }
        missing { file delete -- $journal }
        mismatch {
            set data [readData $journal]
            dict set data [pick {source target}] mismatch-[word]
            writeText $journal $data
        }
        malformed { writeText $journal "\{" }
        extra { guard [file join $stage precious] }
        payload-change { writeBytes [file join $payload data] [encoding convertto utf-8 changed-[word]] }
        payload-extra { guard [file join $payload precious] }
        journal-link {
            set saved [file join $active saved-journal]
            file rename -- $journal $saved
            file link -symbolic $journal $saved
            set external $saved
        }
        stage-link {
            set saved [file join $active saved-stage]
            file rename -- $stage $saved
            file link -symbolic $stage $saved
            set external $saved
        }
        absent-stage {
            cleanup $stage
            guard [file join $envdir lib recoverpkg replacement]
            set expected 0
        }
    }
    writeText [receiptPath] [dict create recoverpkg $receipt]
    dict set current input [dict create mode $mode expected_status $expected receipt $receipt]
    set before [tree $envdir]
    if {$external ne ""} { set beforeExternal [tree $external] }
    status [invoke manager [list remove $envdir recoverpkg]] $expected "recovery status disagrees with the transaction model"
    if {$expected} {
        need [equalTree $before [tree $envdir]] "rejected recovery changed environment data"
    } else {
        need [expr {![dict exists [readData [receiptPath]] recoverpkg]}] "completed recovery retained its receipt"
        noStages
    }
    need [equalTree $originalSource [tree $source]] "recovery changed original source data"
    if {$external ne ""} {
        need [equalTree $beforeExternal [tree $external]] "rejected recovery changed a symlink target"
    }
    unlocked
}

# Faults are selected from a fixed vocabulary, injected inside an isolated
# worker process, and required to fire. Generated strings are never evaluated.
proc ::fuzz::faultWorker {arguments} {
    variable project
    lassign $arguments fault root object relative
    if {$fault ni {install-copy install-move install-journal install-write remove-journal remove-write remove-delete remove-final}} {
        error "unknown fault injection"
    }
    source [file join $project lib manager.tcl]
    namespace eval ::fuzz::injection {}
    set ::fuzz::injection::fault $fault
    set ::fuzz::injection::object $object
    set ::fuzz::injection::relative $relative
    set ::fuzz::injection::fired 0
    proc ::fuzz::injection::fail {} {
        variable fault
        variable fired 1
        error "FUZZ_INJECTED($fault)"
    }
    # Tcl procedures resolve namespace variables in their current namespace.
    # Save them in place so hooks preserve production namespace semantics.
    rename ::tclvenv::writeData ::tclvenv::__fuzzOriginalWrite
    proc ::tclvenv::writeData {path data} {
        set fault $::fuzz::injection::fault
        set tail [file tail $path]
        if {($tail eq "transaction.tcldata" && $fault in {install-journal remove-journal}) ||
            ($tail eq "installed.tcldata" && $fault in {install-write remove-write}) ||
            ($tail eq "installed.tcldata" && $fault eq "remove-final" &&
                ![dict exists $data $::fuzz::injection::object])} {
            ::fuzz::injection::fail
        }
        ::tclvenv::__fuzzOriginalWrite $path $data
    }
    if {$fault eq "install-copy"} {
        rename ::file ::fuzz::injection::file
        proc ::file {operation args} {
            if {$operation eq "copy" && [lindex $args end-1] eq $::fuzz::injection::object} {
                set destination [lindex $args end]
                ::fuzz::injection::file mkdir $destination
                ::fuzz::writeBytes [::fuzz::injection::file join $destination partial] partial
                ::fuzz::injection::fail
            }
            # tempfile/lstat write variables in their caller's frame.
            tailcall ::fuzz::injection::file $operation {*}$args
        }
    } elseif {$fault eq "install-move"} {
        rename ::tclvenv::moveExclusive ::tclvenv::__fuzzOriginalMove
        proc ::tclvenv::moveExclusive {source destination} { ::fuzz::injection::fail }
    } elseif {$fault eq "remove-delete"} {
        rename ::tclvenv::deleteOwned ::tclvenv::__fuzzOriginalDelete
        proc ::tclvenv::deleteOwned {path} {
            if {[file tail $path] eq "payload"} {
                file delete -- [file join $path $::fuzz::injection::relative]
                ::fuzz::injection::fail
            }
            ::tclvenv::__fuzzOriginalDelete $path
        }
    }
    set command [expr {[string match install-* $fault] ? "install" : "remove"}]
    set code [catch {::tclvenv::$command $root $object} message options]
    if {!$::fuzz::injection::fired} { error "injection did not fire: $fault ($message)" }
    if {!$code} { error "injected operation unexpectedly succeeded: $fault" }
    ::tclvenv::reportError $message $options
}
proc ::fuzz::scenario_faults {} {
    variable active
    variable envdir
    variable current
    set fault [pick {install-copy install-move install-journal install-write remove-journal remove-write remove-delete remove-final}]
    cover $fault
    set source [simplePackage faultpkg]
    set original [tree $source]
    set target [file join $envdir lib faultpkg]
    set removal [string match remove-* $fault]
    if {$removal} { status [invoke manager [list install $envdir $source]] 0 "fault fixture install failed" }
    dict set current input [dict create fault $fault source_tree $original]
    set object [expr {$removal ? "faultpkg" : $source}]
    set result [invoke fault [list $fault $envdir $object data]]
    status $result 1 "injected operation did not fail"
    need [expr {[string first "FUZZ_INJECTED($fault)" [dict get $result stderr]] >= 0}] "injected failure was not observed"
    set records [readData [receiptPath]]
    if {!$removal} {
        need [expr {![exists $target] && ![dict exists $records faultpkg]}] "failed install published a package or receipt"
        noStages
        status [invoke manager [list install $envdir $source]] 0 "installation did not recover after an injected failure"
    } elseif {$fault in {remove-delete remove-final}} {
        need [expr {[dict get $records faultpkg state] eq "removing"}] "failed deletion lost its pending state"
        set stage [file join $envdir metadata [dict get $records faultpkg stage]]
        need [file isfile [file join $stage transaction.tcldata]] "failed deletion lost its recovery journal"
        set expectedPayload [file join $stage payload]
        if {$fault eq "remove-delete"} {
            set partial $original
            dict unset partial data
            need [equalTree $partial [tree $expectedPayload]] "partial deletion changed unexpected files"
        } else {
            need [expr {![exists $expectedPayload]}] "final write failure occurred before the payload was deleted"
        }
        guard [file join $target replacement]
    } else {
        need [expr {[dict get $records faultpkg state] eq "installed"}] "failed removal did not restore installed state"
        need [equalTree $original [tree $target]] "failed removal did not restore all package bytes"
        noStages
    }
    unlocked
    status [invoke manager [list remove $envdir faultpkg]] 0 "removal did not recover after an injected failure"
    need [expr {![dict exists [readData [receiptPath]] faultpkg]}] "fault recovery retained an installation receipt"
    need [equalTree $original [tree $source]] "injected failure changed package source data"
    noStages
    unlocked
}

proc ::fuzz::scenario_locks {} {
    variable active
    variable envdir
    variable current
    set kind [pick {file directory symlink}]
    if {$::tcl_platform(platform) ne "unix" && $kind eq "symlink"} { set kind file }
    set creation [number 2]
    cover [list $creation $kind]
    set source [simplePackage lockpkg]
    if {$creation} {
        set destination [file join $active [leaf destination]]
        set lock $destination.tclvenv-create.lock
    } else {
        status [invoke manager [list install $envdir $source]] 0 "lock fixture install failed"
        set lock [file join $envdir metadata mutation.lock]
    }
    set marker [file join $active protected lock-target]
    guard $marker
    switch -- $kind {
        file { writeText $lock [word] }
        directory { file mkdir $lock; writeText [file join $lock owner] [word] }
        symlink { file link -symbolic $lock $marker }
    }
    dict set current input [dict create creation $creation kind $kind]
    set beforeEnv [tree $envdir]
    set beforeSource [tree $source]
    set beforeLock [tree $lock]
    if {$creation} {
        status [invoke manager [list create $destination --tcl [info nameofexecutable]]] 1 "creation ignored an existing lock"
        need [expr {![exists $destination]}] "locked creation published a destination"
    } else {
        status [invoke manager [list remove $envdir lockpkg]] 1 "removal ignored an existing lock"
        status [invoke manager [list install $envdir $source]] 1 "installation ignored an existing lock"
    }
    need [equalTree $beforeEnv [tree $envdir]] "lock refusal changed environment data"
    need [equalTree $beforeSource [tree $source]] "lock refusal changed package source data"
    need [equalTree $beforeLock [tree $lock]] "lock refusal changed the existing lock"
    cleanup $lock
    if {$creation} {
        status [invoke manager [list create $destination --tcl [info nameofexecutable]]] 0 "creation failed after the lock was released"
    } else {
        status [invoke manager [list remove $envdir lockpkg]] 0 "removal failed after the lock was released"
        noStages
        unlocked
    }
}

proc ::fuzz::modeInvoke {entry arguments} {
    variable envdir
    switch -- $entry {
        runtime { invoke runtime $arguments }
        manager { invoke manager [list run $envdir -- {*}$arguments] }
        launcher { launch $arguments }
    }
}
proc ::fuzz::scenario_modes {} {
    variable active
    variable current
    set mode [pick {exit encoding double-dash error missing invalid-encoding invalid-options}]
    cover $mode
    set entry [pick {runtime manager launcher}]
    if {$::tcl_platform(platform) ne "unix" && $entry eq "launcher"} { set entry runtime }
    set app [file join $active script.tcl]
    set expected 0
    set expectedOutput ""
    set marker [file join $active executed]
    switch -- $mode {
        exit {
            set expected [number 126]
            writeText $app [list exit $expected]
            set args [list $app]
        }
        encoding {
            set encoding [pick {utf-8 iso8859-1 unicode}]
            set value "caf\u00e9-[number 100000]"
            set script "fconfigure stdout -encoding utf-8 -translation lf\n[list puts $value]\n"
            writeBytes $app [encoding convertto $encoding $script]
            set args [list -encoding $encoding $app]
            set native [run [list [info nameofexecutable] -encoding $encoding $app] $active]
            dict lappend current operations [dict create entry native-encoding result $native]
            status $native 0 "native interpreter rejected the encoding fixture"
            set expectedOutput [encoding convertto utf-8 "$value\n"]
            need [expr {[dict get $native output] eq $expectedOutput}] "native encoding fixture produced unexpected bytes"
        }
        double-dash {
            set app [file join $active --stdin.tcl]
            application $app
            set arguments [list --interactive -encoding --stdin [word [expr {$entry eq "launcher"}]]]
            dict set current input [dict create mode $mode entry $entry arguments $arguments]
            checkArguments [appResult $app $arguments $entry] $app $arguments
            return
        }
        error {
            set value "fuzz-error:[word]"
            set encoded [binary encode base64 [encoding convertto utf-8 $value]]
            writeText $app "fconfigure stderr -encoding utf-8 -translation lf\n[format {error [encoding convertfrom utf-8 [binary decode base64 %s]]} [list $encoded]]\n"
            set args [list $app]
            set expected 1
        }
        missing { set args [list [file join $active no-such-script.tcl]]; set expected 1 }
        invalid-encoding {
            writeText $app {
                set ch [open [file join [file dirname [info script]] executed] w]
                close $ch
                exit 1
            }
            set args [list -encoding fuzz-invalid-encoding $app]
            set expected 1
        }
        invalid-options {
            writeText $app {
                set ch [open [file join [file dirname [info script]] executed] w]
                close $ch
                exit 1
            }
            set args [pick [list [list --interactive $app] [list --stdin $app] [list -encoding utf-8]]]
            # -encoding without a script reads stdin (empty here), as
            # native tclsh does; the others are the launcher's own errors.
            set expected [expr {[lindex $args 0] eq "-encoding" ? 0 : 1}]
        }
    }
    dict set current input [dict create mode $mode entry $entry arguments $args expected_status $expected]
    set result [modeInvoke $entry $args]
    status $result $expected "script mode returned an unexpected status"
    need [expr {[dict get $result output] eq $expectedOutput}] "script mode produced unexpected stdout bytes"
    need [expr {![exists $marker]}] "invalid script options executed application code"
    if {$mode eq "error"} {
        need [expr {[string first [encoding convertto utf-8 $value] [dict get $result stderr]] >= 0}] "script error lost its diagnostic value"
    }
}

proc ::fuzz::scenario_boundaries {} {
    variable envdir
    variable current
    set length [pick {0 1 65535 65536 65537 131071 131072 131073}]
    cover $length
    set pattern ""
    for {set i 0} {$i < 256} {incr i} { append pattern [binary format c [number 256]] }
    set bytes [string range [string repeat $pattern [expr {($length + 255) / 256}]] 0 [expr {$length - 1}]]
    set source [simplePackage boundarypkg]
    writeBytes [file join $source data] $bytes
    set before [tree $source]
    dict set current input [dict create length $length pattern_base64 [binary encode base64 $pattern]]
    status [invoke manager [list install $envdir $source]] 0 "boundary fixture installation failed"
    set target [file join $envdir lib boundarypkg]
    need [equalTree $before [tree $target]] "boundary-sized package bytes changed during copy"
    set index [expr {$length ? [pick [list 0 [expr {$length - 1}] [expr {min(65536, $length - 1)}]]] : 0}]
    if {!$length} {
        set changed X
    } else {
        set changed [string replace $bytes $index $index X]
        if {$changed eq $bytes} { set changed [string replace $bytes $index $index Y] }
    }
    writeBytes [file join $target data] $changed
    set mutated [tree $target]
    need [expr {![equalTree $before $mutated]}] "boundary mutation did not change file bytes"
    status [invoke manager [list doctor $envdir]] 1 "doctor missed a boundary file mutation"
    status [invoke manager [list remove $envdir boundarypkg]] 1 "removal accepted a boundary file mutation"
    need [equalTree $mutated [tree $target]] "rejected boundary removal changed installed data"
    writeBytes [file join $target data] $bytes
    status [invoke manager [list remove $envdir boundarypkg]] 0 "restored boundary package could not be removed"
    need [equalTree $before [tree $source]] "boundary test changed source data"
    noStages
    unlocked
}
