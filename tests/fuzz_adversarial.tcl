# Challenge ownership and recovery assumptions using disposable trees only.
# Interleavings model uncoordinated writers, including behavior the README
# excludes from its supported concurrency contract. Report that distinction.
proc ::fuzz::scenario_containment {} {
    variable active
    variable envdir
    variable current
    set mode [pick {lib-link modules-link namespace-link metadata-link lib-file modules-file metadata-file}]
    if {$::tcl_platform(platform) ne "unix" && [string match *-link $mode]} { set mode lib-file }
    cover $mode
    set protected [file join $active protected]
    set escape [file join $protected escape]
    file mkdir $escape
    guard [file join $escape precious]
    set kind [lindex [split $mode -] 0]
    if {$kind in {modules namespace}} {
        set name [expr {$kind eq "namespace" ? "escape::probe" : "probe"}]
        set source [file join $active $name-1.0.tm]
        writeText $source [list package provide $name 1.0]
    } else { set source [simplePackage escape-package] }
    set destination [file join $envdir $kind]
    if {$kind eq "namespace"} { set destination [file join $envdir modules escape] }
    if {[exists $destination]} {
        # Park the original metadata so the linked directory remains a fully
        # usable receipt/journal store. The tested command must refuse it.
        if {$kind eq "metadata" && [string match *-link $mode]} {
            set escape [file join $protected redirected-metadata]
            file rename -- $destination $escape
        } else { cleanup $destination }
    }
    if {[string match *-link $mode]} {
        file link -symbolic $destination $escape
    } else { guard $destination "unrelated replacement file\n" }
    dict set current input [dict create mode $mode source $source redirected_path $destination]
    set before [tree $protected]
    set sourceBefore [tree $source]
    set result [invoke manager [list install $envdir $source]]
    need [equalTree $before [tree $protected]] "installation wrote outside the environment through a redirected directory"
    need [equalTree $sourceBefore [tree $source]] "redirected installation changed source data"
    status $result 1 "installation accepted a replaced environment directory"
}

proc ::fuzz::recordFiles {path} {
    set result {}
    dict for {relative data} [tree $path] {
        switch -- [lindex $data 0] {
            directory { dict set result $relative [dict create type directory] }
            file {
                set bytes [binary decode base64 [lindex $data 1]]
                dict set result $relative [dict create type file size [string length $bytes] crc32 [format %08x [zlib crc32 $bytes]]]
            }
            default { error "record fixture must contain regular files and directories" }
        }
    }
    return $result
}
proc ::fuzz::scenario_ownership {} {
    variable active
    variable envdir
    variable current
    set mode [pick {duplicate duplicate-reordered duplicate-source module-directory missing-journal}]
    cover $mode
    if {$mode eq "module-directory"} {
        set source [file join $active owner-1.0.tm]
        writeText $source {package provide owner 1.0}
        set id owner@1.0
        set target [file join $envdir modules owner-1.0.tm]
    } else {
        set source [simplePackage owner]
        set id owner
        set target [file join $envdir lib owner]
    }
    status [invoke manager [list install $envdir $source]] 0 "ownership fixture installation failed"
    set records [readData [receiptPath]]
    set receipt [dict get $records $id]
    switch -- $mode {
        duplicate - duplicate-reordered - duplicate-source {
            set duplicate $receipt
            if {$mode eq "duplicate-reordered"} {
                dict set duplicate files [shuffleFiles [dict get $duplicate files]]
                set duplicate [shuffle $duplicate]
            }
            if {$mode eq "duplicate-source"} { dict set duplicate source [file join $active other-source] }
            dict set records another-owner $duplicate
        }
        module-directory {
            file delete -- $target
            file mkdir $target
            guard [file join $target precious] "unrelated directory replacing a module\n"
            dict set records $id files [recordFiles $target]
        }
        missing-journal {
            set stage [file join $envdir metadata remove-forged]
            file mkdir $stage
            guard [file join $stage precious]
            dict set records $id state removing
            dict set records $id stage [file tail $stage]
        }
    }
    writeText [receiptPath] $records
    dict set current input [dict create mode $mode records $records]
    set before [tree $envdir]
    set result [invoke manager [list remove $envdir $id]]
    need [equalTree $before [tree $envdir]] "removal changed files or receipts with contradictory ownership metadata"
    status $result 1 "removal accepted contradictory ownership metadata"
}

proc ::fuzz::adversarialWorker {arguments} {
    variable project
    lassign $arguments family mode root object event protected parked
    if {$family ni {race crash}} { error "unknown adversarial worker" }
    if {$family eq "race" && $mode ni {payload-added stage-added parent-swap symlink-delete}} { error "unknown interleaving" }
    if {$family eq "crash" && $mode ni {install-journal install-publish install-receipt remove-journal remove-detach remove-pending remove-delete remove-final install-copy install-marker remove-marker write-temp}} { error "unknown crash point" }
    source [file join $project lib manager.tcl]
    namespace eval ::fuzz::adversary {}
    foreach key {family mode root object event protected parked} {
        set ::fuzz::adversary::$key [set $key]
    }
    set ::fuzz::adversary::fired 0
    set ::fuzz::adversary::stage ""
    proc ::fuzz::adversary::record {data} {
        variable event
        variable fired 1
        ::fuzz::writeText $event $data
    }
    proc ::fuzz::adversary::crash {} {
        variable mode
        record [dict create mode $mode pid [pid]]
        if {$::tcl_platform(platform) eq "unix"} { exec kill -KILL -- [pid] }
        exit 97
    }
    rename ::tclvenv::writeData ::tclvenv::__adversarialWrite
    proc ::tclvenv::writeData {path data} {
        set mode $::fuzz::adversary::mode
        # (fuzz_recovery: copied, journal not yet written.)
        if {$mode eq "install-copy" && [file tail $path] eq "transaction.tcldata"} { ::fuzz::adversary::crash }
        ::tclvenv::__adversarialWrite $path $data
        if {[file tail $path] eq "transaction.tcldata" && $mode in {install-journal remove-journal}} {
            ::fuzz::adversary::crash
        }
        if {[file tail $path] ne "installed.tcldata"} { return }
        if {$mode eq "install-receipt"} { ::fuzz::adversary::crash }
        if {[dict exists $data $::fuzz::adversary::object] &&
            [dict get $data $::fuzz::adversary::object state] eq "removing"} {
            set ::fuzz::adversary::stage [file join $::fuzz::adversary::root metadata [dict get $data $::fuzz::adversary::object stage]]
            if {$mode eq "remove-pending"} { ::fuzz::adversary::crash }
        } elseif {![dict exists $data $::fuzz::adversary::object]} {
            if {$mode eq "remove-final"} { ::fuzz::adversary::crash }
            if {$mode eq "stage-added"} {
                set marker [file join $::fuzz::adversary::stage precious]
                ::fuzz::writeText $marker unrelated-race-data
                ::fuzz::adversary::record [dict create marker $marker]
            }
        }
    }
    # (fuzz_recovery: a temporary file open beside installed.tcldata.)
    rename ::tclvenv::openTemporary ::tclvenv::__adversarialTemporary
    proc ::tclvenv::openTemporary {directory pathVar args} {
        upvar 1 $pathVar path
        set ch [::tclvenv::__adversarialTemporary $directory path {*}$args]
        if {$::fuzz::adversary::mode eq "write-temp" && [file tail $directory] eq "metadata"} {
            ::fuzz::adversary::crash
        }
        return $ch
    }
    rename ::tclvenv::moveExclusive ::tclvenv::__adversarialMove
    proc ::tclvenv::moveExclusive {source destination} {
        set mode $::fuzz::adversary::mode
        # (fuzz_recovery: the move marker is written, the rename not done.)
        if {($mode eq "install-marker" && [file tail $source] eq "payload") ||
            ($mode eq "remove-marker" && [file tail $destination] eq "payload")} {
            rename ::file ::fuzz::adversary::realFile
            proc ::file {args} {
                if {[lindex $args 0] eq "rename"} { ::fuzz::adversary::crash }
                uplevel 1 [list ::fuzz::adversary::realFile {*}$args]
            }
        }
        if {$mode eq "parent-swap" && !$::fuzz::adversary::fired} {
            set parent [file dirname $destination]
            file rename -- $parent $::fuzz::adversary::parked
            file link -symbolic $parent $::fuzz::adversary::protected
            ::fuzz::adversary::record [dict create parent $parent]
        }
        ::tclvenv::__adversarialMove $source $destination
        if {$mode eq "install-publish" || ($mode eq "remove-detach" && [file tail $destination] eq "payload")} {
            ::fuzz::adversary::crash
        }
    }
    rename ::tclvenv::deleteOwned ::tclvenv::__adversarialDelete
    proc ::tclvenv::deleteOwned {path} {
        set mode $::fuzz::adversary::mode
        if {[file tail $path] eq "payload"} {
            if {$mode eq "payload-added"} {
                set marker [file join $path precious]
                ::fuzz::writeText $marker unrelated-race-data
                ::fuzz::adversary::record [dict create marker $marker]
            } elseif {$mode eq "remove-delete"} {
                file delete -- [file join $path data]
                ::fuzz::adversary::crash
            }
        }
        ::tclvenv::__adversarialDelete $path
    }
    rename ::tclvenv::makeWritable ::tclvenv::__adversarialWritable
    proc ::tclvenv::makeWritable {path} {
        if {$::fuzz::adversary::mode eq "symlink-delete" && [file tail $path] eq "swap" &&
            [file tail [file dirname $path]] eq "payload" && !$::fuzz::adversary::fired} {
            file rename -- $path $::fuzz::adversary::parked
            file link -symbolic $path $::fuzz::adversary::protected
            ::fuzz::adversary::record [dict create redirected $path]
        }
        ::tclvenv::__adversarialWritable $path
    }
    set command [expr {$mode in {parent-swap write-temp} || [string match install-* $mode] ? "install" : "remove"}]
    set code [catch {::tclvenv::$command $root $object} message options]
    if {!$::fuzz::adversary::fired} { error "adversarial hook did not fire: $mode ($message)" }
    if {$family eq "crash"} { error "crash hook did not terminate the worker" }
    if {$code} { ::tclvenv::reportError $message $options }
}

proc ::fuzz::scenario_interleavings {} {
    variable active
    variable envdir
    variable current
    set modes {payload-added stage-added parent-swap symlink-delete}
    if {$::tcl_platform(platform) ne "unix"} { set modes {payload-added stage-added} }
    set mode [pick $modes]
    cover $mode
    set protected [file join $active protected race]
    file mkdir $protected
    guard [file join $protected precious] unrelated-race-data
    if {$mode eq "parent-swap"} {
        set source [file join $active escape::probe-1.0.tm]
        writeText $source {package provide escape::probe 1.0}
        set object $source
    } else {
        set source [simplePackage racer]
        file mkdir [file join $source swap]
        writeText [file join $source swap data] owned
        status [invoke manager [list install $envdir $source]] 0 "interleaving fixture installation failed"
        set object racer
    }
    set before [tree $protected]
    set sourceBefore [tree $source]
    set event [file join $active interleaving.tcldata]
    dict set current input [dict create mode $mode concurrency_contract uncoordinated-writer]
    set result [invoke adversary [list race $mode $envdir $object $event $protected [file join $active parked]]]
    need [file isfile $event] "interleaving was not exercised"
    set data [readData $event]
    if {[dict exists $data marker]} {
        set marker [dict get $data marker]
        dict set current guards $marker [binary encode base64 unrelated-race-data]
        need [expr {[file isfile $marker] && [readBytes $marker] eq "unrelated-race-data"}] "removal deleted unrelated data added after validation"
    }
    need [equalTree $before [tree $protected]] "filesystem interleaving wrote or deleted data outside the environment"
    need [equalTree $sourceBefore [tree $source]] "filesystem interleaving changed source data"
    need [expr {[dict get $result status] in {0 1}}] "interleaving worker failed unexpectedly"
}

proc ::fuzz::scenario_crashes {} {
    variable active
    variable envdir
    variable current
    set mode [pick {install-journal install-publish install-receipt remove-journal remove-detach remove-pending remove-delete remove-final}]
    cover $mode
    set source [simplePackage crashpkg]
    set original [tree $source]
    set removing [string match remove-* $mode]
    if {$removing} { status [invoke manager [list install $envdir $source]] 0 "crash fixture installation failed" }
    set object [expr {$removing ? "crashpkg" : $source}]
    set event [file join $active crash.tcldata]
    dict set current input [dict create mode $mode termination [expr {$::tcl_platform(platform) eq "unix" ? "SIGKILL" : "exit97"}]]
    set result [invoke adversary [list crash $mode $envdir $object $event {} {}]]
    status $result [expr {$::tcl_platform(platform) eq "unix" ? -1 : 97}] "crash worker did not terminate at the requested cut point"
    need [file isfile $event] "crash cut point was not reached"
    need [file isfile [file join $envdir metadata mutation.lock]] "hard termination unexpectedly ran lock cleanup"
    status [invoke manager [list doctor $envdir]] 1 "doctor accepted an interrupted transaction"
    set records [readData [receiptPath]]
    set stages [glob -nocomplain -directory [file join $envdir metadata] -- stage-* remove-*]
    need [expr {[llength $stages] == 1}] "hard termination lost or duplicated its transaction staging directory"
    set stage [lindex $stages 0]
    need [file isfile [file join $stage transaction.tcldata]] "hard termination lost the transaction journal"
    set target [file join $envdir lib crashpkg]
    if {$mode in {install-journal remove-detach}} {
        need [equalTree $original [tree [file join $stage payload]]] "crash lost package bytes before publication or deletion authorization"
    } elseif {$mode in {install-publish install-receipt remove-journal}} {
        need [equalTree $original [tree $target]] "crash lost published package data"
    }
    need [equalTree $original [tree $source]] "crash changed original package source data"
    # Only after the worker's death is confirmed may this fixture's stale lock
    # be removed. Resume only states the documented protocol can resume.
    file delete -- [file join $envdir metadata mutation.lock]
    if {$mode in {remove-pending remove-delete remove-final}} {
        if {$mode ne "remove-final"} {
            status [invoke manager [list remove $envdir crashpkg]] 0 "committed removal could not resume after SIGKILL"
            noStages
        } else {
            need [expr {![dict exists $records crashpkg]}] "final removal receipt was not committed before the crash"
        }
    } elseif {$mode eq "install-receipt"} {
        need [dict exists $records crashpkg] "committed installation lost its receipt"
    }
}
