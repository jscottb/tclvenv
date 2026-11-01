# Loaded by fuzz.tcl. Package sources:
#
#   archives  random tar, tar.gz and zip archives of a package, some with a
#             hostile entry, some corrupted, some over a size limit
#
# The archives are written here, independently of lib/archive.tcl. Oracles:
# a hostile entry, an archive over the limit or a truncated one is refused
# cleanly with the environment unchanged; a sound archive must install, and
# installs exactly the package
# directory of the model and removes cleanly; a corrupted one is refused or,
# if accepted, stays inside the environment (and for tar.gz, whose CRC covers
# every byte, matches the model). Nothing is ever left in, or written to,
# the temporary directory.

proc ::fuzz::randomBytes {length} {
    set bytes ""
    for {set i 0} {$i < $length} {incr i} { append bytes [binary format c [number 256]] }
    return $bytes
}

proc ::fuzz::shuffleList {items} {
    for {set i [expr {[llength $items] - 1}]} {$i > 0} {incr i -1} {
        set j [number [expr {$i + 1}]]
        set swap [lindex $items $i]
        lset items $i [lindex $items $j]
        lset items $j $swap
    }
    return $items
}

# A safe path component: none is ".", ".." or empty, and none holds a
# backslash (refused on purpose: a separator on Windows).
proc ::fuzz::safeComponent {} {
    pick [list a b data lib x.tcl "with space" -dash _under ~tilde .hidden \u00e9t\u00e9 \u4e2d\u6587 \
        {star*} {q?} {[br]} 0x10 007 1e3 [string repeat n 120] [string map {\\ _} [leaf c]]]
}

# Joins relative components under a base, a leading ~ protected (Tcl 8.6).
proc ::fuzz::joinUnder {base relative} {
    file join $base {*}[lmap part [split $relative /] {
        if {[string match ~* $part]} { string cat ./ $part } else { set part }
    }]
}

proc ::fuzz::tarHeader {name type size mode link} {
    set name [encoding convertto utf-8 $name]
    set field {{value width} { return [format %0*o [expr {$width - 1}] $value]\0 }}
    set header [binary format a100a8a8a8a12a12a8a1a100a6a2a32a32a8a8a155a12 \
        $name [apply $field $mode 8] [apply $field 0 8] [apply $field 0 8] \
        [apply $field $size 12] [apply $field 0 12] "        " $type $link ustar\0 00 "" "" "" "" "" ""]
    binary scan $header cu* bytes
    set sum 0
    foreach byte $bytes { incr sum $byte }
    string replace $header 148 155 [format %06o $sum]\0\x20
}

# entries: dicts with name, kind (file directory symlink hardlink fifo),
# data, mode, link, and for zip: method, flags.
proc ::fuzz::tarArchive {entries} {
    set out ""
    foreach entry $entries {
        set data [dict get $entry data]
        set type [dict get {file 0 directory 5 symlink 2 hardlink 1 fifo 6} [dict get $entry kind]]
        set name [dict get $entry name]
        if {[dict get $entry kind] eq "directory" && ![string match */ $name]} { append name / }
        set encoded [encoding convertto utf-8 $name]
        if {[string length $encoded] > 99} {
            # A GNU long-name record (written as bytes: no further encoding).
            set long $encoded\0
            append out [tarHeader ././@LongLink L [string length $long] 0o644 ""]
            append out $long [string repeat \0 [expr {(512 - [string length $long] % 512) % 512}]]
            cover long-name
        }
        append out [tarHeader $name $type [string length $data] [dict get $entry mode] [dict get $entry link]]
        append out $data [string repeat \0 [expr {(512 - [string length $data] % 512) % 512}]]
    }
    append out [string repeat \0 1024]
}

proc ::fuzz::zipArchive {entries} {
    set out ""
    set central ""
    foreach entry $entries {
        set name [encoding convertto utf-8 [dict get $entry name]]
        set data [dict get $entry data]
        switch -- [dict get $entry kind] {
            directory { set type 0o040000; if {![string match */ $name]} { append name / } }
            symlink { set type 0o120000; set data [dict get $entry link] }
            default { set type 0o100000 }
        }
        set method [dict get $entry method]
        if {$method == 8} { set packed [zlib deflate $data] } else { set packed $data }
        set crc [zlib crc32 $data]
        set flags [expr {0x800 | [dict get $entry flags]}]
        set offset [string length $out]
        append out [binary format a4sssssiiiss PK\x03\x04 20 $flags $method 0 0 $crc \
            [string length $packed] [string length $data] [string length $name] 0] $name $packed
        append central [binary format a4ccsssssiiisssssii PK\x01\x02 20 3 20 $flags $method 0 0 \
            $crc [string length $packed] [string length $data] [string length $name] 0 0 0 0 \
            [expr {($type | [dict get $entry mode]) << 16}] $offset] $name
    }
    set start [string length $out]
    append out $central [binary format a4ssssiis PK\x05\x06 0 0 [llength $entries] [llength $entries] \
        [string length $central] $start 0]
}

proc ::fuzz::archiveEntry {name kind {data ""} args} {
    dict merge [dict create name $name kind $kind data $data mode 0o644 link "" \
        method [pick {0 8}] flags 0] $args
}

# A hostile entry for the package directory prefix (with a trailing / or
# empty) and the format; {} if none applies. The archive must be refused.
proc ::fuzz::hostileEntry {prefix format safeNames} {
    variable active
    set tmp [file join $active tmp]
    set kinds {traversal nested-traversal absolute backslash drive symlink duplicate conflict}
    if {$format in {tar tgz}} { lappend kinds hardlink fifo }
    if {$format eq "zip"} { lappend kinds encrypted method }
    set kind [pick $kinds]
    cover hostile-$kind
    switch -- $kind {
        traversal { archiveEntry ../escape-[number 1000] file "escaped\n" }
        nested-traversal { archiveEntry ${prefix}a/../../../escape-[number 1000] file "escaped\n" }
        absolute { archiveEntry [file join $tmp absolute-[number 1000]] file "escaped\n" }
        backslash { archiveEntry "..\\escape-[number 1000]" file "escaped\n" }
        drive { archiveEntry C:/escape file "escaped\n" }
        symlink { archiveEntry ${prefix}link symlink "" link [file join $active protected sentinel] mode 0o777 }
        hardlink { archiveEntry ${prefix}hard hardlink "" link ${prefix}pkgIndex.tcl }
        fifo { archiveEntry ${prefix}fifo fifo }
        duplicate { archiveEntry ./[pick $safeNames] file "second copy\n" }
        conflict { archiveEntry [pick $safeNames]/below file "under a file\n" }
        encrypted { archiveEntry ${prefix}secret file "x" flags 1 }
        method { archiveEntry ${prefix}packed file "x" method 12 }
    }
}

proc ::fuzz::scenario_archives {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    set tmp [file join $active tmp]
    file mkdir $tmp
    guard [file join $active protected sentinel]
    set overrides [dict create TMPDIR $tmp]

    set format [pick {tar tgz zip}]
    set layout [pick {top single nested}]
    cover format-$format
    cover layout-$layout
    set base fz[number 1000]-1.[number 10]
    switch -- $layout {
        top { set prefix ""; set id $base }
        single { set id [pick [list pkg1.0 [safeComponent]]]; set prefix $id/ }
        nested { set id pkg[number 10]; set prefix [pick {r/lib/ release/x/ a/b/}]$id/ }
    }
    if {$id in {. ..} || [string match .* $id]} { set id pkg; if {$prefix ne ""} { set prefix [regsub {[^/]+/$} $prefix pkg/] } }

    # The package: pkgIndex.tcl and random files and directories in it.
    set model [dict create pkgIndex.tcl [encoding convertto utf-8 "package ifneeded fz 1.0 {package provide fz 1.0}\n"]]
    set directories {}
    for {set i 0; set n [number 6]} {$i < $n} {incr i} {
        set parts {}
        for {set j 0; set depth [expr {1 + [number 3]}]} {$j < $depth} {incr j} { lappend parts [safeComponent] }
        set path [join $parts /]
        if {[dict exists $model $path] || [lsearch -glob [dict keys $model] [string map {* \\* ? \\? [ \\[ ] \\] \\ \\\\} $path]/*] >= 0} { continue }
        # No file may also be a directory of another.
        set clash 0
        for {set k 1} {$k < [llength $parts]} {incr k} {
            if {[dict exists $model [join [lrange $parts 0 [expr {$k - 1}]] /]]} { set clash 1 }
        }
        if {$clash || $path in $directories} { continue }
        dict set model $path [randomBytes [pick [list 0 1 [number 600] [number 3000] 70000]]]
    }
    if {[number 3] == 0} {
        set empty [safeComponent]
        if {![dict exists $model $empty] && [lsearch -glob [dict keys $model] [string map {* \\* ? \\? [ \\[ ] \\] \\ \\\\} $empty]/*] < 0} {
            lappend directories $empty
            cover empty-directory
        }
    }
    set entries {}
    set explicitDirs [expr {[number 2]}]
    set madeDirs {}
    dict for {path data} $model {
        if {$explicitDirs} {
            set parts [split $prefix$path /]
            for {set k 1} {$k < [llength $parts]} {incr k} {
                set dir [join [lrange $parts 0 [expr {$k - 1}]] /]
                if {$dir ni $madeDirs} { lappend madeDirs $dir; lappend entries [archiveEntry $dir directory "" mode 0o755] }
            }
        }
        lappend entries [archiveEntry $prefix$path file $data mode [pick {0o644 0o755 0o4755 0o600}]]
    }
    foreach dir $directories { lappend entries [archiveEntry $prefix$dir directory "" mode 0o755] }
    # Files beside the package directory, not part of it.
    if {$layout ne "top"} {
        lappend entries [archiveEntry README file "not installed\n"]
        lappend entries [archiveEntry docs/manual.txt file "not installed\n"]
    }
    set entries [shuffleList $entries]
    # As "tar -C dir ." writes it: ./ first, every name under it.
    set rooted [expr {[number 4] == 0}]
    if {$rooted} {
        cover rooted
        set entries [lmap entry $entries { dict set entry name ./[dict get $entry name] }]
        set entries [linsert $entries 0 [archiveEntry ./ directory "" mode 0o755]]
        if {$prefix ne ""} { set prefix ./$prefix }
    }

    set hostile ""
    if {[number 10] < 4} {
        set safeNames [lmap path [dict keys $model] {string cat $prefix $path}]
        set hostile [hostileEntry $prefix $format $safeNames]
        set entries [linsert $entries [number [expr {[llength $entries] + 1}]] $hostile]
    }
    set truncated 0
    if {$format ne "zip"} {
        set stream [tarArchive $entries]
        # Cut short at a 512-byte boundary before the end-of-archive
        # marker: it can look complete, and must be refused.
        if {$hostile eq "" && [number 10] == 0} {
            set truncated 1
            cover truncated
            set stream [string range $stream 0 [expr {512 * [number [expr {([string length $stream] - 1024) / 512 + 1}]] - 1}]]
        }
    }
    switch -- $format {
        tar { set bytes $stream; set extension .tar }
        tgz {
            # One gzip member, or several (concatenated, as gzip allows).
            set members [pick {1 1 2 3}]
            set cuts [lsort -integer [lmap i [lrepeat [expr {$members - 1}] x] {number [expr {[string length $stream] + 1}]}]]
            set bytes ""
            set from 0
            foreach cut [concat $cuts [string length $stream]] {
                append bytes [zlib gzip [string range $stream $from [expr {$cut - 1}]]]
                set from $cut
            }
            if {$members > 1} { cover gzip-members }
            set extension .tar.gz
        }
        zip { set bytes [zipArchive $entries]; set extension .zip }
    }
    set corrupted 0
    if {$hostile eq "" && !$truncated && [number 10] < 2} {
        set corrupted 1
        cover corrupted
        for {set i 0; set n [expr {1 + [number 3]}]} {$i < $n} {incr i} {
            set at [number [string length $bytes]]
            set bytes [string replace $bytes $at $at [binary format c [number 256]]]
        }
    }
    # A size limit: clearly below or clearly above what the archive needs.
    set total 0
    dict for {path data} $model { incr total [string length $data] }
    set expanded [string length $bytes]
    if {$format eq "tgz"} { set expanded [string length $stream] }
    set overLimit 0
    if {$hostile eq "" && !$corrupted && !$truncated && [number 10] < 2} {
        if {$total > 2000 && [number 2]} {
            dict set overrides TCLVENV_ARCHIVE_LIMIT [expr {$total / 2}]
            set overLimit 1
            cover over-limit
        } else {
            dict set overrides TCLVENV_ARCHIVE_LIMIT [expr {2 * max($expanded, [string length $bytes], $total) + 1000}]
            cover under-limit
        }
    }
    set archive [file join $active $base$extension]
    writeBytes $archive $bytes
    dict set current input [dict create format $format layout $layout id $id \
        hostile [expr {$hostile eq "" ? "" : [dict get $hostile name]}] corrupted $corrupted \
        rooted $rooted truncated $truncated \
        limit [expr {[dict exists $overrides TCLVENV_ARCHIVE_LIMIT] ? [dict get $overrides TCLVENV_ARCHIVE_LIMIT] : ""}] \
        archive [binary encode base64 $bytes]]

    set before [tree $envdir]
    set result [invoke manager [list install $envdir $archive --no-deps --no-check] $overrides]
    managerOutcome $result "install of an archive"
    set left [entries $tmp]
    need [expr {![llength $left]}] "install left files in the temporary directory: $left"
    need [expr {[readBytes $archive] eq $bytes}] "installation changed the archive"
    if {$hostile ne "" || $overLimit || $truncated} {
        need [expr {[dict get $result status] == 1}] \
            "a [expr {$overLimit ? {too large} : $truncated ? {truncated} : {hostile}}] archive was installed"
    }
    if {$hostile eq "" && !$overLimit && !$truncated && !$corrupted} {
        need [expr {[dict get $result status] == 0}] "a sound archive was refused: [string trim [dict get $result stderr]]"
    }
    if {[dict get $result status] == 1} {
        cover rejected
        need [equalTree $before [tree $envdir]] "refused archive changed the environment"
        noStages
        return
    }
    cover accepted
    set records [readData [receiptPath]]
    need [expr {[dict size $records] == 1}] "installation did not add exactly one receipt"
    set actualId [lindex [dict keys $records] 0]
    set target [dict get $records $actualId target]
    need [string match lib/* $target] "archive installed outside lib: [list $target]"
    if {!$corrupted || $format eq "tgz"} {
        need [expr {$actualId eq $id}] "installation ID [list $actualId] differs from the expected [list $id]"
        # The model as a tree: written out, then read as the installed one is.
        set modelRoot [file join $active model]
        file mkdir $modelRoot
        dict for {path data} $model {
            set file [joinUnder $modelRoot $path]
            file mkdir [file dirname $file]
            writeBytes $file $data
        }
        foreach dir $directories { file mkdir [joinUnder $modelRoot $dir] }
        need [equalTree [tree $modelRoot] [tree [joinUnder $envdir $target]]] \
            "installed package differs from the archive's package directory"
        foreach {path data} $model {
            set mode [file attributes [joinUnder $envdir $target/$path] -permissions]
            need [expr {($mode & 0o7022) == 0}] "installed file $path has mode [format %o $mode]"
        }
    }
    need [expr {[doctorAgrees $envdir] == 0}] "doctor rejects a freshly installed archive"
    set removed [invoke manager [list remove $envdir $actualId] $overrides]
    managerOutcome $removed "remove of an installed archive"
    need [expr {[dict get $removed status] == 0}] "installed archive could not be removed"
    need [equalTree $before [tree $envdir]] "install and remove did not restore the environment"
}
