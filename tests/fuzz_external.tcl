# Loaded by fuzz.tcl. Groups judged against implementations outside
# tclvenv: system tools, a reference written from the RFC, a local HTTP
# server, native tclsh.
#
#   sha256        fileSha256 and incremental updates against sha256sum, at
#                 block and 64 KiB read boundaries; --sha256 spellings
#   urljoin       resolveUrl against RFC 3986 section 5.2 (written here from
#                 the RFC's own algorithm) for relative references
#   toolarchives  packages archived by GNU tar (every format, -G, gzip, several
#                 members), Info-ZIP (stored, deflated, streamed, -D, -y),
#                 7-Zip and Python's zipfile/tarfile; a sound archive must
#                 install exactly the packed directory, a link be refused
#   downloads     URL installs from a local HTTP server: redirect chains
#                 (statuses, absolute/relative/dot-segment locations, header
#                 case), chunked and close-delimited bodies, content
#                 encodings, short and long bodies, size limits, endless
#                 bodies; what is installed must be the resource's bytes,
#                 every request must be the one RFC 3986 resolves, and the
#                 temporary directory must stay within the size limit
#   systemadd     add from random system package trees (dependency graphs,
#                 versions in several directories, modules with namespaces,
#                 collection indexes, links); the environment must load the
#                 same versions native tclsh loads, from its own files only
#
# Tools that are missing make their variants count as skipped.

# --- Shared ------------------------------------------------------------------

# The library, loaded once into a child interpreter (not the harness's).
proc ::fuzz::library {} {
    variable project
    variable libInterp
    if {![info exists libInterp]} {
        set libInterp [interp create]
        $libInterp eval [list source [file join $project lib manager.tcl]]
    }
    return $libInterp
}

proc ::fuzz::haveTool {name} { expr {[auto_execok $name] ne ""} }

# SHA-256 of a file by sha256sum (or Python's hashlib).
proc ::fuzz::referenceSha256 {path} {
    if {[haveTool sha256sum]} { return [lindex [exec -- sha256sum -b $path] 0] }
    exec -- python3 -I -c {import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())} $path
}

# Runs a tool in a directory: arguments go to it directly (no shell words).
proc ::fuzz::inDirectory {directory args} {
    exec -- sh -c {cd "$1" && shift && exec "$@"} sh $directory {*}$args 2>@1
}

# --- RFC 3986 reference -------------------------------------------------------

# Section 3 / appendix B: scheme, authority, path, query, fragment; an
# undefined component is the list {} (defined ones are {1 value}).
proc ::fuzz::uriParts {uri} {
    regexp {^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?$} $uri \
        -> s scheme a authority path q query f fragment
    dict create \
        scheme [expr {$s ne "" ? [list 1 $scheme] : {}}] \
        authority [expr {$a ne "" ? [list 1 $authority] : {}}] \
        path $path \
        query [expr {$q ne "" ? [list 1 $query] : {}}] \
        fragment [expr {$f ne "" ? [list 1 $fragment] : {}}]
}

# Section 5.2.4, by its input/output buffer rules A to E.
proc ::fuzz::removeDotSegments {input} {
    set output ""
    while {$input ne ""} {
        if {[string match ../* $input]} {
            set input [string range $input 3 end]
        } elseif {[string match ./* $input]} {
            set input [string range $input 2 end]
        } elseif {[string match /./* $input]} {
            set input [string range $input 2 end]
        } elseif {$input eq "/."} {
            set input /
        } elseif {[string match /../* $input] || $input eq "/.."} {
            set input /[string range $input [expr {$input eq "/.." ? 3 : 4}] end]
            set cut [string last / $output]
            set output [string range $output 0 [expr {$cut < 0 ? -1 : $cut - 1}]]
        } elseif {$input in {. ..}} {
            set input ""
        } else {
            regexp {^(/?[^/]*)(.*)$} $input -> segment input
            append output $segment
        }
    }
    return $output
}

# Section 5.2.2 (strict), 5.2.3 merge, 5.3 recomposition.
proc ::fuzz::rfcResolve {base reference} {
    set B [uriParts $base]
    set R [uriParts $reference]
    set T [dict create fragment [dict get $R fragment]]
    if {[llength [dict get $R scheme]]} {
        dict set T scheme [dict get $R scheme]
        dict set T authority [dict get $R authority]
        dict set T path [removeDotSegments [dict get $R path]]
        dict set T query [dict get $R query]
    } else {
        if {[llength [dict get $R authority]]} {
            dict set T authority [dict get $R authority]
            dict set T path [removeDotSegments [dict get $R path]]
            dict set T query [dict get $R query]
        } else {
            if {[dict get $R path] eq ""} {
                dict set T path [dict get $B path]
                dict set T query [expr {[llength [dict get $R query]] ? [dict get $R query] : [dict get $B query]}]
            } else {
                if {[string match /* [dict get $R path]]} {
                    dict set T path [removeDotSegments [dict get $R path]]
                } else {
                    if {[llength [dict get $B authority]] && [dict get $B path] eq ""} {
                        set merged /[dict get $R path]
                    } else {
                        set bp [dict get $B path]
                        set merged [string range $bp 0 [string last / $bp]][dict get $R path]
                    }
                    dict set T path [removeDotSegments $merged]
                }
                dict set T query [dict get $R query]
            }
            dict set T authority [dict get $B authority]
        }
        dict set T scheme [dict get $B scheme]
    }
    set result ""
    if {[llength [dict get $T scheme]]} { append result [lindex [dict get $T scheme] 1]: }
    if {[llength [dict get $T authority]]} { append result //[lindex [dict get $T authority] 1] }
    append result [dict get $T path]
    if {[llength [dict get $T query]]} { append result ?[lindex [dict get $T query] 1] }
    if {[llength [dict get $T fragment]]} { append result #[lindex [dict get $T fragment] 1] }
    return $result
}

# A path segment for URLs: ordinary, dot-like, empty, or with ; = : %.
proc ::fuzz::urlSegment {} {
    pick {g h a b c d g. .g g.. ..g . .. . .. "" a;x=1 b;p p:q %2e %2E%2E x~y file.tar.gz 007}
}
proc ::fuzz::urlPath {count {absolute 1}} {
    set parts {}
    for {set i 0} {$i < $count} {incr i} { lappend parts [urlSegment] }
    if {$absolute} { return /[join $parts /] }
    # A first segment with a colon would read as a scheme (RFC 3986 4.2).
    if {[string first : [lindex $parts 0]] >= 0} { set parts [linsert $parts 0 .] }
    join $parts /
}

# A relative reference of a random kind: {kind reference}.
proc ::fuzz::relativeReference {host} {
    set query [expr {[number 3] == 0 ? "?[pick {y q=1 a/../b {} x?y}]" : ""}]
    set fragment [expr {[number 4] == 0 ? "#[pick {s f/../x {}}]" : ""}]
    set kind [pick {relative relative relative absolute-path network query fragment}]
    switch -- $kind {
        relative {
            set path [urlPath [expr {1 + [number 5]}] 0]
            if {$path eq ""} { set path g }
            set reference $path$query$fragment
        }
        absolute-path {
            set reference [urlPath [expr {[number 5]}]]$query$fragment
            # An empty first segment makes it a network-path reference.
            if {[string match //* $reference]} { set kind network }
        }
        network { set reference //$host[urlPath [number 4]]$query$fragment }
        query { set reference ?[pick {y q=1 a/../b {} x?y}]$fragment }
        fragment { set reference #[pick {s f/../x {}}] }
    }
    list $kind $reference
}

# --- sha256 ----------------------------------------------------------------

proc ::fuzz::scenario_sha256 {} {
    variable active
    set lib [library]
    set kind [pick {small small block chunk large}]
    cover length-$kind
    switch -- $kind {
        small { set length [number 300] }
        block { set length [expr {64 * (1 + [number 40]) + [number 7] - 3}] }
        chunk { set length [expr {65536 * (1 + [number 3]) + [number 141] - 70}] }
        large { set length [number 300000] }
    }
    set fill [pick {random zeros ones pattern}]
    cover fill-$fill
    switch -- $fill {
        random { set data [randomBytes $length] }
        zeros { set data [string repeat \0 $length] }
        ones { set data [string repeat \xff $length] }
        pattern {
            set unit [randomBytes [expr {1 + [number 70]}]]
            set data [string range [string repeat $unit [expr {$length / [string length $unit] + 1}]] 0 [expr {$length - 1}]]
        }
    }
    set path [file join $active data.bin]
    writeBytes $path $data
    dict set ::fuzz::current input [dict create mode $kind length $length fill $fill]
    set expected [referenceSha256 $path]
    need [expr {[$lib eval [list ::tclvenv::fileSha256 $path]] eq $expected}] "fileSha256 differs from sha256sum"
    # The same data fed in random pieces.
    set context [$lib eval ::tclvenv::sha256Init]
    set at 0
    set pieces 0
    while {$at < $length} {
        set size [pick [list 1 [number 64] 63 64 65 [number 5000] 65536]]
        if {$size == 0} { set size 1 }
        set context [$lib eval [list ::tclvenv::sha256Update $context [string range $data $at [expr {$at + $size - 1}]]]]
        incr at $size
        incr pieces
    }
    if {[number 4] == 0} { set context [$lib eval [list ::tclvenv::sha256Update $context ""]]; cover empty-update }
    need [expr {[$lib eval [list ::tclvenv::sha256Final $context]] eq $expected}] \
        "SHA-256 in $pieces pieces differs from sha256sum"
    # --sha256 spellings: any case is accepted, anything else refused.
    set spelling [pick {lower upper mixed short long space prefix nonhex}]
    cover spelling-$spelling
    set given $expected
    set valid 1
    switch -- $spelling {
        upper { set given [string toupper $expected] }
        mixed { set given [join [lmap c [split $expected ""] {expr {[number 2] ? [string toupper $c] : $c}}] ""] }
        short { set given [string range $expected 1 end]; set valid 0 }
        long { set given ${expected}0; set valid 0 }
        space { set given " $expected"; set valid 0 }
        prefix { set given 0x$expected; set valid 0 }
        nonhex { set given [string replace $expected 5 5 g]; set valid 0 }
    }
    set code [catch {$lib eval [list ::tclvenv::checkSha256 $path $given]} message]
    if {$valid} {
        need [expr {$code == 0 && $message eq $expected}] "checkSha256 refused a valid spelling: $message"
    } else {
        need [expr {$code == 1 && [string match "--sha256 must be*" $message]}] \
            "checkSha256 accepted or misreported an invalid spelling: $message"
    }
}

# --- urljoin -------------------------------------------------------------------

proc ::fuzz::scenario_urljoin {} {
    set lib [library]
    set host [pick {a example.org 127.0.0.1:8080 h:1}]
    set base [pick {http https HTTP}]://$host
    if {[number 5]} { append base [urlPath [number 5]] }
    if {[number 3] == 0} { append base ?[pick {q a=1 x/../y}] }
    lassign [relativeReference [pick {g other.example 127.0.0.1:9}]] kind reference
    cover kind-$kind
    dict set ::fuzz::current input [dict create mode $kind base $base reference $reference]
    set expected [rfcResolve $base $reference]
    set actual [$lib eval [list ::tclvenv::resolveUrl $base $reference]]
    need [expr {$actual eq $expected}] \
        "resolveUrl gives [list $actual] for [list $reference] against [list $base]; RFC 3986 gives [list $expected]"
}

# --- toolarchives --------------------------------------------------------------

# A file or directory name tools must carry through; newlines only where
# the format can hold them (tar).
proc ::fuzz::toolComponent {newlines} {
    set names [list a b data lib x.tcl "with space" -dash _under ~tilde .hidden été 中文 \
        {star*} {q?} {[br]} 0x10 007 1e3 [string repeat n [expr {90 + [number 110]}]] "semi;colon" {dollar$} "it's"]
    if {$newlines} { lappend names "new\nline" "tab\there" "end\n" }
    pick $names
}

# The tree under path as {relative {file BASE64} | {directory}}, a link
# read as the file it points to (what a tool following links stores).
proc ::fuzz::resolvedTree {path} {
    set result {}
    dict for {relative entry} [tree $path] {
        if {[lindex $entry 0] eq "link"} {
            set entry [list file [binary encode base64 [readBytes [joinUnder $path $relative]]]]
        }
        dict set result $relative $entry
    }
    return $result
}

# Writes a random package into directory; returns {files dirs execs links
# hardlinks}: relative paths of what it made.
proc ::fuzz::toolPackage {directory newlines} {
    file mkdir $directory
    writeText [file join $directory pkgIndex.tcl] "package ifneeded fz 1.0 {package provide fz 1.0}\n"
    set files [list pkgIndex.tcl]
    set dirs {}
    set execs {}
    for {set i 0; set n [number 7]} {$i < $n} {incr i} {
        set parts {}
        for {set j 0; set depth [expr {1 + [number 3]}]} {$j < $depth} {incr j} { lappend parts [toolComponent $newlines] }
        # No component may also be a file already made.
        set clash 0
        for {set k 1} {$k <= [llength $parts]} {incr k} {
            set prefix [join [lrange $parts 0 [expr {$k - 1}]] /]
            if {$prefix in $files || ($k == [llength $parts] && $prefix in $dirs)} { set clash 1 }
        }
        if {$clash} { continue }
        for {set k 1} {$k < [llength $parts]} {incr k} {
            set prefix [join [lrange $parts 0 [expr {$k - 1}]] /]
            if {$prefix ni $dirs} { lappend dirs $prefix }
        }
        set relative [join $parts /]
        set path [joinUnder $directory $relative]
        file mkdir [file dirname $path]
        writeBytes $path [randomBytes [pick [list 0 1 [number 600] [number 3000] 70000]]]
        lappend files $relative
        if {[number 4] == 0} {
            file attributes $path -permissions 0o755
            lappend execs $relative
        }
    }
    if {[number 3] == 0} {
        set empty [toolComponent $newlines]
        if {$empty ni $files && $empty ni $dirs} {
            file mkdir [joinUnder $directory $empty]
            lappend dirs $empty
            cover empty-directory
        }
    }
    list $files $dirs $execs
}

# Packs root (holding the package as described by layout) with tool into
# archive. Returns 0 if the tool refused (a name its format can't hold).
proc ::fuzz::packWith {tool options root members archive} {
    switch -- $tool {
        tar {
            lassign $options format compression
            set tarFile [expr {$compression eq "none" ? $archive : "$archive.tmp.tar"}]
            # gnu-incremental: tar -G, which fills in the old GNU header's
            # atime and ctime and writes dump directories (type D).
            set flags [expr {$format eq "gnu-incremental" ? {--format=gnu -G} : [list --format=$format]}]
            if {[catch {exec -- tar {*}$flags -C $root -cf $tarFile -- {*}$members 2>@1} message]} { return 0 }
            switch -- $compression {
                gzip { exec -- gzip -c -- $tarFile > $archive }
                gzip-n9 { exec -- gzip -n -9 -c -- $tarFile > $archive }
                members {
                    # Several gzip members, split at random points.
                    set data [readBytes $tarFile]
                    set cuts [lsort -integer [list [number [string length $data]] [number [string length $data]]]]
                    writeBytes $archive ""
                    set from 0
                    foreach cut [concat $cuts [string length $data]] {
                        set piece [file join [file dirname $archive] piece.bin]
                        writeBytes $piece [string range $data $from [expr {$cut - 1}]]
                        exec -- gzip -c -- $piece >> $archive
                        file delete -- $piece
                        set from $cut
                    }
                }
            }
            if {$compression ne "none"} { file delete -- $tarFile }
        }
        zip {
            lassign $options level dirs stream links
            set flags [list -q -r -$level]
            if {!$dirs} { lappend flags -D }
            if {$links} { lappend flags -y }
            if {$stream} {
                # Written to a pipe: sizes and CRCs go in data descriptors.
                inDirectory $root zip {*}$flags - {*}$members > $archive
            } else {
                inDirectory $root zip {*}$flags $archive {*}$members
            }
        }
        7z {
            lassign $options level
            inDirectory $root 7z a -bd -bso0 -tzip -mx=$level $archive {*}$members
        }
        python {
            lassign $options kind detail
            set script {
import os, sys, tarfile, zipfile
kind, detail, root, archive = sys.argv[1:5]
members = sys.argv[5:]
os.chdir(root)
def walk(member):
    yield member
    if os.path.isdir(member) and not os.path.islink(member):
        for r, ds, fs in os.walk(member):
            for d in sorted(ds): yield os.path.join(r, d)
            for f in sorted(fs): yield os.path.join(r, f)
if kind == 'zip':
    method = zipfile.ZIP_DEFLATED if detail.startswith('deflated') else zipfile.ZIP_STORED
    with zipfile.ZipFile(archive, 'w', method) as z:
        for m in members:
            for p in walk(m):
                p = os.path.normpath(p)
                if p == '.': continue
                if os.path.isdir(p):
                    if detail.endswith('dirs'): z.write(p, p + '/')
                else: z.write(p, p)
else:
    fmt = {'gnu': tarfile.GNU_FORMAT, 'pax': tarfile.PAX_FORMAT, 'ustar': tarfile.USTAR_FORMAT}[detail]
    mode = 'w:gz' if kind == 'tgz' else 'w'
    try:
        with tarfile.open(archive, mode, format=fmt) as t:
            for m in members: t.add(m)
    except ValueError:
        sys.exit(3)
}
            if {[catch {exec -- python3 -I -c $script $kind $detail $root $archive {*}$members 2>@1} message]} {
                if {[string match *exited*3* $::errorCode] || [lindex $::errorCode 2] == 3} { return 0 }
                error "python archiver failed: $message"
            }
        }
    }
    return 1
}

proc ::fuzz::scenario_toolarchives {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    set tmp [file join $active tmp]
    file mkdir $tmp
    set overrides [dict create TMPDIR $tmp]

    # The tool and its options.
    set choices {}
    if {[haveTool tar] && [haveTool gzip]} { lappend choices tar tar tar }
    if {[haveTool zip]} { lappend choices zip zip }
    if {[haveTool 7z]} { lappend choices 7z }
    if {[haveTool python3]} { lappend choices python python }
    if {![llength $choices]} { cover skipped-no-tools; return }
    set tool [pick $choices]
    switch -- $tool {
        tar {
            set options [list [pick {gnu oldgnu pax posix ustar gnu-incremental}] [pick {none gzip gzip-n9 members}]]
            set extension [expr {[lindex $options 1] eq "none" ? ".tar" : [pick {.tar.gz .tgz}]}]
        }
        zip { set options [list [pick {0 6 9}] [number 4] [expr {[number 4] == 0}] 0]; set extension .zip }
        7z { set options [list [pick {0 5 9}]]; set extension .zip }
        python {
            set options [pick {{zip stored} {zip deflated} {zip stored-dirs} {zip deflated-dirs}
                {tar gnu} {tar pax} {tar ustar} {tgz gnu} {tgz pax}}]
            set extension [expr {[lindex $options 0] eq "zip" ? ".zip" : [lindex $options 0] eq "tgz" ? ".tar.gz" : ".tar"}]
        }
    }
    set newlines [expr {($tool eq "tar" || ($tool eq "python" && [lindex $options 0] ne "zip")) && [number 3] == 0}]
    set layout [pick {top single nested}]
    set base fz[number 1000]-1.[number 10]
    set root [file join $active src]
    file mkdir $root
    switch -- $layout {
        top { set id $base; set package $root; set members [list .] }
        single {
            set id [pick [list pkg1.0 "with space" été ~tilde 007 [string repeat p 100]]]
            set package [joinUnder $root $id]
            set members [list $id]
        }
        nested {
            set id pkg[number 10]
            set package [file join $root release lib $id]
            file mkdir [file join $root release]
            writeText [file join $root release README] "not installed\n"
            set members [list release]
        }
    }
    if {$tool eq "zip" || $tool eq "7z"} {
        # Members as written: (a leading ~ or - would be an option or a home).
        set members [lmap m $members {expr {$m eq "." ? "." : "./$m"}}]
    }
    lassign [toolPackage $package $newlines] files dirs execs

    # Links: tar stores them (refused); zip follows them unless -y.
    set link ""
    if {[number 6] == 0 && $tool in {tar zip}} {
        set link [pick {symlink hardlink}]
        set relative [pick $files]
        set made [file join $package link-[number 100]]
        if {$link eq "symlink"} {
            # (A relative target, as packages ship them: libfoo.so -> libfoo.so.1.)
            exec -- ln -s -- $relative $made
        } else {
            exec -- ln -- [joinUnder $package $relative] $made
        }
        if {$tool eq "zip" && $link eq "symlink" && [number 2]} { lset options 3 1 }
        cover link-$link
    }
    set expectRefusal [expr {$link ne "" && ($tool eq "tar" || [lindex $options 3] == 1)}]
    set expected [resolvedTree $package]
    if {$tool eq "zip" && ![lindex $options 1] || ($tool eq "python" && ![string match *dirs [lindex $options 1]] && [lindex $options 0] eq "zip")} {
        # No directory entries: a directory with nothing in it is lost.
        set expected [dict filter $expected script {path entry} {
            expr {[lindex $entry 0] ne "directory" || [llength [dict filter $expected key [string map {* \\* ? \\? [ \\[ ] \\] \\ \\\\} $path]/*]] > 0}
        }]
        dict set expected "" directory
    }

    set archive [file join $active $base$extension]
    set variant "$tool [join $options /]"
    dict set current input [dict create mode $tool options $options layout $layout id $id link $link \
        newlines $newlines files $files]
    cover tool-$tool
    if {![packWith $tool $options $root $members $archive]} {
        cover tool-refused
        return
    }
    cover [string map {" " -} $variant]
    dict set current input archive [binary encode base64 [readBytes $archive]]

    set before [tree $envdir]
    set result [invoke manager [list install $envdir $archive --no-deps --no-check] $overrides]
    managerOutcome $result "install of a $tool archive"
    set left [entries $tmp]
    need [expr {![llength $left]}] "install left files in the temporary directory: $left"
    if {$expectRefusal} {
        need [expr {[dict get $result status] == 1}] "an archive holding a $link was installed"
        need [equalTree $before [tree $envdir]] "refused archive changed the environment"
        noStages
        cover refused-link
        return
    }
    need [expr {[dict get $result status] == 0}] \
        "a sound archive made by $variant was refused: [string trim [encoding convertfrom utf-8 [dict get $result stderr]]]"
    set records [readData [receiptPath]]
    need [expr {[dict size $records] == 1}] "installation did not add exactly one receipt"
    set actualId [lindex [dict keys $records] 0]
    need [expr {$actualId eq $id}] "installation ID [list $actualId] differs from the expected [list $id]"
    set installed [joinUnder $envdir [dict get $records $actualId target]]
    set actual [tree $installed]
    if {![equalTree $expected $actual]} {
        set diff [treeDiff $expected $actual]
        error "installed package differs from what $variant packed: added [list [dict get $diff added]],\
            missing [list [dict get $diff removed]], changed [list [dict get $diff changed]]"
    }
    if {$tool ne "7z"} {
        foreach path $files {
            if {$link eq "hardlink" && $tool eq "zip"} { break }
            set mode [file attributes [joinUnder $installed $path] -permissions]
            set wanted [expr {$path in $execs ? 0o755 : 0o644}]
            need [expr {($mode & 0o777) == $wanted}] "installed [list $path] has mode [format %o $mode], packed [format %o $wanted]"
        }
    }
    need [expr {[doctorAgrees $envdir] == 0}] "doctor rejects a freshly installed archive"
    set removed [invoke manager [list remove $envdir $actualId] $overrides]
    managerOutcome $removed "remove of an installed archive"
    need [expr {[dict get $removed status] == 0}] "installed archive could not be removed"
    need [equalTree $before [tree $envdir]] "install and remove did not restore the environment"
}

# --- downloads -----------------------------------------------------------------
#
# The server runs in the harness's own event loop, which turns while it
# waits for the manager. routes: request target -> response dict (status,
# headers {name value ...}, body, framing length|close|chunked, extra (bytes
# after a length-framed body), endless (keep sending until the client
# goes)). Requests are logged in order.

namespace eval ::fuzz::http {
    variable routes {}
    variable log {}
    variable listener ""
    variable sent 0
    variable buffers
    variable outgoing
}

proc ::fuzz::http::start {} {
    variable listener
    variable log
    variable sent
    set log {}
    set sent 0
    set listener [socket -server ::fuzz::http::accept -myaddr 127.0.0.1 0]
    lindex [fconfigure $listener -sockname] 2
}
proc ::fuzz::http::stop {} {
    variable listener
    variable buffers
    variable outgoing
    catch {close $listener}
    foreach ch [array names buffers] { catch {close $ch} }
    foreach ch [array names outgoing] { catch {close $ch} }
    array unset buffers
    array unset outgoing
}
proc ::fuzz::http::accept {ch host port} {
    variable buffers
    fconfigure $ch -blocking 0 -translation binary -buffering none
    set buffers($ch) ""
    fileevent $ch readable [list ::fuzz::http::readable $ch]
}
proc ::fuzz::http::finish {ch} {
    variable buffers
    variable outgoing
    unset -nocomplain buffers($ch) outgoing($ch)
    catch {close $ch}
}
proc ::fuzz::http::readable {ch} {
    variable buffers
    variable routes
    variable log
    if {[catch {read $ch} data]} { finish $ch; return }
    append buffers($ch) $data
    set end [string first "\r\n\r\n" $buffers($ch)]
    if {$end < 0} {
        if {[eof $ch] || [string length $buffers($ch)] > 65536} { finish $ch }
        return
    }
    fileevent $ch readable {}
    set lines [split [string range $buffers($ch) 0 [expr {$end - 1}]] \n]
    set target [lindex [split [string trimright [lindex $lines 0] \r] " "] 1]
    set headers {}
    foreach line [lrange $lines 1 end] {
        set line [string trimright $line \r]
        set colon [string first : $line]
        if {$colon > 0} { dict set headers [string tolower [string range $line 0 [expr {$colon - 1}]]] [string trim [string range $line $colon+1 end]] }
    }
    set version [lindex [split [string trimright [lindex $lines 0] \r] " "] 2]
    lappend log [dict create target $target headers $headers version $version]
    if {[dict exists $routes $target]} {
        set response [dict get $routes $target]
        # A server that compresses on request (nginx's gzip): only if asked.
        if {[dict exists $response compressible]} {
            set accepted [expr {[dict exists $headers accept-encoding] ? [dict get $headers accept-encoding] : ""}]
            if {[regexp -nocase {(^|[ ,])gzip($|[ ,;])} $accepted] && ![regexp -nocase {gzip;\s*q=0(\.0*)?($|[ ,])} $accepted]} {
                dict set response body [zlib gzip [dict get $response body]]
                dict lappend response headers Content-Encoding gzip
                ::fuzz::cover compressed-on-request
            }
        }
    } else {
        set response [dict create status 404 headers {} body "not here\n" framing length]
    }
    # HTTP/1.0 has no chunked transfer coding: a server closes instead.
    if {[dict get $response framing] eq "chunked" && $version ne "HTTP/1.1"} {
        dict set response framing close
        ::fuzz::cover chunked-as-close
    }
    respond $ch $response
}
proc ::fuzz::http::respond {ch response} {
    variable outgoing
    set status [dict get $response status]
    set head "HTTP/1.1 $status [dict get {200 OK 301 Moved 302 Found 303 {See Other} 307 Temporary 308 Permanent 300 Multiple 404 {Not Found} 500 Error} $status]\r\n"
    foreach {name value} [dict get $response headers] { append head "$name: $value\r\n" }
    set body [dict get $response body]
    switch -- [dict get $response framing] {
        length {
            append head "Content-Length: [string length $body]\r\n"
            if {[dict exists $response extra]} { append body [dict get $response extra] }
        }
        close { }
        chunked {
            append head "Transfer-Encoding: chunked\r\n"
            set chunked ""
            set at 0
            while {$at < [string length $body]} {
                set size [expr {1 + [::fuzz::number [pick {1 7 4096 70000}]]}]
                set piece [string range $body $at [expr {$at + $size - 1}]]
                append chunked [format %x [string length $piece]]
                if {[::fuzz::number 5] == 0} { append chunked ";ext=1" }
                append chunked \r\n $piece \r\n
                incr at $size
            }
            set body "${chunked}0\r\n\r\n"
        }
    }
    append head "Connection: close\r\n\r\n"
    set outgoing($ch) [dict create data $head$body endless [dict exists $response endless]]
    fileevent $ch writable [list ::fuzz::http::writable $ch]
}
proc ::fuzz::http::writable {ch} {
    variable outgoing
    variable sent
    set state $outgoing($ch)
    set data [dict get $state data]
    if {$data eq "" && [dict get $state endless]} {
        # Endless: more as long as the client reads, up to a bound.
        if {$sent > 64 * 1048576} { finish $ch; return }
        set data [string repeat x 65536]
    }
    if {$data eq ""} { finish $ch; return }
    set piece [string range $data 0 16383]
    if {[catch {puts -nonewline $ch $piece}]} { finish $ch; return }
    incr sent [string length $piece]
    dict set outgoing($ch) data [string range $data 16384 end]
}
proc ::fuzz::pick {items} { lindex $items [number [llength $items]] }
namespace eval ::fuzz::http { namespace path ::fuzz }

# The total size of the files under path.
proc ::fuzz::treeBytes {path} {
    set total 0
    foreach child [entries $path] {
        if {[file type $child] eq "directory"} {
            incr total [treeBytes $child]
        } elseif {[file type $child] eq "file"} {
            catch {incr total [file size $child]}
        }
    }
    return $total
}
proc ::fuzz::watchTemporary {path} {
    variable tmpPeak
    variable tmpWatch
    catch {set tmpPeak [expr {max($tmpPeak, [treeBytes $path])}]}
    set tmpWatch [after 5 [list ::fuzz::watchTemporary $path]]
}

proc ::fuzz::scenario_downloads {} {
    variable active
    variable envdir
    variable current
    variable tmpPeak
    variable tmpWatch
    if {![unixOnly]} { return }
    set tmp [file join $active tmp]
    file mkdir $tmp
    set overrides [dict create TMPDIR $tmp]

    # The resource: a .tar.gz, .zip or .tm package, by its URL's name.
    set kind [pick {tgz zip tm}]
    set base fzd[number 1000]-1.[number 10]
    set model [dict create pkgIndex.tcl [encoding convertto utf-8 "package ifneeded fzd 1.0 {package provide fzd 1.0}\n"] \
        data.bin [randomBytes [pick [list 10 [number 5000] 70000 [expr {200000 + [number 100000]}]]]]]
    switch -- $kind {
        tgz {
            set entries {}
            dict for {path data} $model { lappend entries [archiveEntry $path file $data] }
            set resource [zlib gzip [tarArchive $entries]]
            set name $base.tar.gz
            set id $base
        }
        zip {
            set entries {}
            dict for {path data} $model { lappend entries [archiveEntry $path file $data] }
            set resource [zipArchive $entries]
            set name $base.zip
            set id $base
        }
        tm {
            set version 1.[number 10]
            set resource [encoding convertto utf-8 "package provide fzd $version\n# [string repeat x [number 3000]]\n"]
            set name fzd-$version.tm
            set id fzd@$version
        }
    }
    set resourceFile [file join $active resource.bin]
    writeBytes $resourceFile $resource
    set sha [referenceSha256 $resourceFile]

    set port [http::start]
    set origin http://127.0.0.1:$port
    try {
        # The redirect chain: each hop a location of a random form, resolved
        # here by the RFC 3986 reference to the target the server expects.
        set hops [pick {0 0 1 1 2 3 5 6 7}]
        set url $origin/files/start/$name
        set first $url
        set routes {}
        set expectOk 1
        set why ""
        set targets {}
        # Requests the client should make: it stops after five redirects,
        # or at a redirect without a location.
        set stopsAt ""
        for {set hop 0} {$hop <= $hops} {incr hop} {
            regexp {^https?://[^/]+(/[^#]*)} $url -> target
            lappend targets $target
            if {$hop == $hops} { break }
            set form [pick {absolute absolute-path relative dots query network}]
            set next d$hop-[number 1000]
            switch -- $form {
                absolute { set location $origin/r/$next/$name }
                absolute-path { set location /r/$next/x/../$name }
                relative { set location $next/$name }
                dots { set location ../[pick {. a/..}]/$next/./$name }
                query { set location ?hop=$next }
                network { set location //127.0.0.1:$port/n/$next/$name }
            }
            if {[number 8] == 0} { append location #frag; cover location-fragment }
            cover location-$form
            set status [pick {301 302 303 307 308}]
            set header [pick {Location location LOCATION}]
            set response [dict create status $status headers [list $header $location] body "moved\n" framing length]
            if {[number 20] == 0} {
                dict set response headers {}
                if {$stopsAt eq ""} { set stopsAt $hop }
                if {$expectOk} { set why "a redirect without a location" }
                set expectOk 0
                cover redirect-no-location
            }
            dict set routes $target $response
            set url [rfcResolve $url $location]
        }
        if {$hops > 5} {
            if {$stopsAt eq "" || $stopsAt > 5} { set stopsAt 5 }
            if {$expectOk} { set why "more than five redirects" }
            set expectOk 0
            cover too-many-redirects
        }
        # The final response.
        set final [pick {plain plain close chunked compressible labelled deflate trailing short status oversized endless bomb}]
        cover final-$final
        set response [dict create status 200 headers {Content-Type application/octet-stream} body $resource framing length]
        set limit ""
        switch -- $final {
            close { dict set response framing close }
            chunked { dict set response framing chunked }
            compressible { dict set response compressible 1 }
            labelled {
                # Apache's AddEncoding: a .gz file labelled with its own
                # compression, sent as it is; curl and wget save it as it is.
                if {$kind ne "tgz"} { set final plain } else {
                    dict lappend response headers Content-Encoding [pick {gzip x-gzip}]
                }
            }
            deflate {
                # Asked or not, a deflate-encoded body that decodes to the
                # resource. (Accepted only when the client asked for it.)
                set final plain
            }
            trailing {
                dict set response extra [randomBytes [expr {1 + [number 3000]}]]
            }
            short {
                # Content-Length says more than arrives before the close.
                set cut [number [string length $resource]]
                dict set response framing close
                dict set response headers [list Content-Length [string length $resource]]
                dict set response body [string range $resource 0 [expr {$cut - 1}]]
                if {$expectOk} { set why "a body cut short" }
                set expectOk 0
            }
            status {
                dict set response status [pick {404 500 300}]
                if {$expectOk} { set why "status [dict get $response status]" }
                set expectOk 0
            }
            oversized {
                set limit [expr {[string length $resource] / 2 + 1}]
                dict set response framing [pick {length close chunked}]
                if {$expectOk} { set why "a body over the size limit" }
                set expectOk 0
            }
            endless {
                set limit [expr {64 * 1024 + [number 300000]}]
                dict set response framing close
                dict set response endless 1
                if {$expectOk} { set why "an endless body" }
                set expectOk 0
            }
            bomb {
                # Small on the wire, beyond the limit decoded.
                set limit [expr {64 * 1024 + [number 300000]}]
                dict set response body [zlib gzip [string repeat \0 [expr {8 * 1048576}]]]
                dict lappend response headers Content-Encoding gzip
                if {$expectOk} { set why "a body decoding beyond the size limit" }
                set expectOk 0
            }
        }
        dict set routes [lindex $targets end] $response
        set http::routes $routes
        if {$limit ne ""} { dict set overrides TCLVENV_ARCHIVE_LIMIT $limit }
        set shaGiven $sha
        if {[number 12] == 0} {
            set shaGiven [string replace $sha 0 0 [expr {[string index $sha 0] eq "0" ? 1 : 0}]]
            if {$expectOk} { set why "a wrong --sha256" }
            set expectOk 0
            cover wrong-sha
        }
        dict set current input [dict create mode $final kind $kind hops $hops url $first sha256 $shaGiven \
            limit $limit expected_targets $targets expect_ok $expectOk why $why \
            routes [dict map {k v} $routes { dict set v body [binary encode base64 [dict get $v body]] }]]

        set before [tree $envdir]
        set tmpPeak 0
        watchTemporary $tmp
        try {
            set result [invoke manager [list install $envdir $first --sha256 $shaGiven --no-deps --no-check] $overrides]
        } finally { after cancel $tmpWatch }
        dict set current requests $http::log
        managerOutcome $result "install from a URL"
        set left [entries $tmp]
        need [expr {![llength $left]}] "install left files in the temporary directory: $left"
        if {$limit ne ""} {
            # The download may overshoot by what one read brings in.
            need [expr {$tmpPeak <= $limit + 2 * 65536 + 16384}] \
                "the download put $tmpPeak bytes in the temporary directory, with a size limit of $limit"
        }
        set seen [lmap request $http::log {dict get $request target}]
        set wanted $targets
        if {$stopsAt ne ""} { set wanted [lrange $targets 0 $stopsAt] }
        if {$shaGiven eq $sha} {
            # Every hop requested as RFC 3986 resolves it.
            need [sameList $seen $wanted] "requests were [list $seen]; RFC 3986 resolution gives [list $wanted]"
        }
        if {!$expectOk} {
            need [expr {[dict get $result status] == 1}] "an install from a URL with $why succeeded"
            need [equalTree $before [tree $envdir]] "a refused download changed the environment"
            noStages
            cover refused
            return
        }
        need [expr {[dict get $result status] == 0}] \
            "a sound download ($final) was refused: [string trim [encoding convertfrom utf-8 [dict get $result stderr]]]"
        set records [readData [receiptPath]]
        need [expr {[dict size $records] == 1}] "installation did not add exactly one receipt"
        set actualId [lindex [dict keys $records] 0]
        need [expr {$actualId eq $id}] "installation ID [list $actualId] differs from the expected [list $id]"
        set record [dict get $records $actualId]
        need [expr {[dict get $record origin kind] eq "url" && [dict get $record origin url] eq $first &&
            [dict get $record origin sha256] eq $sha}] "the receipt's origin is [list [dict get $record origin]]"
        set installed [joinUnder $envdir [dict get $record target]]
        if {$kind eq "tm"} {
            need [expr {[readBytes $installed] eq $resource}] "the installed module differs from the resource"
        } else {
            set modelRoot [file join $active model]
            file mkdir $modelRoot
            dict for {path data} $model { writeBytes [joinUnder $modelRoot $path] $data }
            need [equalTree [tree $modelRoot] [tree $installed]] "installed package differs from the downloaded archive's"
        }
        cover installed
        set removed [invoke manager [list remove $envdir $actualId] $overrides]
        managerOutcome $removed "remove of a downloaded package"
        need [expr {[dict get $removed status] == 0}] "downloaded package could not be removed"
        need [equalTree $before [tree $envdir]] "install and remove did not restore the environment"
    } finally { http::stop }
}

# --- systemadd -----------------------------------------------------------------
#
# A random package tree on an extra --path: packages sa0..saN, each version
# in a directory of its own, as a module (some namespaced, ns::saK), inside a
# collection whose index sources its members' indexes (as Tcllib's does), or
# the same version in two directories; packages require later ones, some at
# a version. Every package file records its marker (name, version, which
# copy) and [info script]. Oracle: native tclsh with the same path loads the
# package; the environment, after add, must load the same versions and
# copies, from files inside the environment, and the receipts must be
# exactly the providers native Tcl used. A package registered from the
# path's root directory itself must be refused.

proc ::fuzz::systemProgram {resultPath name version} {
    set require [list package require $name]
    if {$version ne ""} { lappend require $version }
    format {
set ::sa_markers {}
set ::sa_scripts {}
set code [catch {%s} message]
set ch [open %s w]
fconfigure $ch -encoding utf-8 -translation lf
puts $ch [dict create code $code message $message markers $::sa_markers scripts $::sa_scripts]
close $ch
} $require [list $resultPath]
}

proc ::fuzz::scenario_systemadd {} {
    variable active
    variable envdir
    variable current
    if {![unixOnly]} { return }
    set tmp [file join $active tmp]
    file mkdir $tmp
    set overrides [dict create TMPDIR $tmp]
    set syslib [file join $active syslib]
    file mkdir $syslib

    set count [expr {1 + [number 5]}]
    set names {}
    for {set i 0} {$i < $count} {incr i} {
        lappend names [expr {[number 6] == 0 ? "ns::sa$i" : "sa$i"}]
    }
    set rootRegistered {}
    set rootIndex ""
    set layouts {}
    for {set i 0} {$i < $count} {incr i} {
        set name [lindex $names $i]
        set plain [namespace tail $name]
        set versions [lsort -unique [lmap x [lrepeat [expr {1 + [number 2]}] x] {string cat 1. [number 4]}]]
        # Requirements: later packages, sometimes at a version.
        set requires {}
        for {set j [expr {$i + 1}]} {$j < $count} {incr j} {
            if {[number 2]} {
                lappend requires [list [lindex $names $j] [expr {[number 3] == 0 ? "1.0-" : ""}]]
            }
        }
        set form [expr {[string match ns::* $name] ? "module" : [pick {dir dir dir module collection duplicate root}]}]
        if {$form eq "root" && $rootIndex ne ""} { set form dir }
        dict set layouts $name $form
        cover form-$form
        foreach version $versions {
            set body ""
            foreach requirement $requires {
                lassign $requirement dep constraint
                append body "package require [list $dep] $constraint\n"
            }
            set copies [expr {$form eq "duplicate" ? {a b} : {only}}]
            foreach copy $copies {
                set script $body
                append script "lappend ::sa_markers [list [list $name $version $copy]]\n"
                append script "lappend ::sa_scripts \[file normalize \[info script\]\]\n"
                append script "package provide [list $name] $version\n"
                switch -- $form {
                    module {
                        set file [file join $syslib {*}[lrange [split [string map {:: /} $name] /] 0 end-1] $plain-$version.tm]
                        file mkdir [file dirname $file]
                        writeText $file $script
                    }
                    dir - duplicate {
                        set dir [file join $syslib $plain-$version-$copy]
                        file mkdir $dir
                        writeText [file join $dir $plain.tcl] $script
                        writeText [file join $dir pkgIndex.tcl] \
                            "package ifneeded [list $name] $version \[list source \[file join \$dir [list $plain.tcl]\]\]\n"
                        if {[number 4] == 0} {
                            # A shared library's links, as system packages have.
                            writeBytes [file join $dir lib$plain.so.1] [randomBytes 100]
                            exec -- ln -s -- lib$plain.so.1 [file join $dir lib$plain.so]
                            cover symlink
                        }
                    }
                    collection {
                        set collection [file join $syslib coll]
                        set dir [file join $collection $plain-$version]
                        file mkdir $dir
                        writeText [file join $dir $plain.tcl] $script
                        writeText [file join $dir pkgIndex.tcl] \
                            "package ifneeded [list $name] $version \[list source \[file join \$dir [list $plain.tcl]\]\]\n"
                        set index [file join $collection pkgIndex.tcl]
                        set text [expr {[file exists $index] ? [encoding convertfrom utf-8 [readBytes $index]] : ""}]
                        append text "set maindir \$dir\nset dir \[file join \$maindir [list $plain-$version]\]\nsource \[file join \$dir pkgIndex.tcl\]\nset dir \$maindir\n"
                        writeText $index $text
                    }
                    root {
                        writeText [file join $syslib $plain-$version.tcl] $script
                        append rootIndex "package ifneeded [list $name] $version \[list source \[file join \$dir [list $plain-$version.tcl]\]\]\n"
                        lappend rootRegistered $name
                    }
                }
            }
        }
    }
    if {$rootIndex ne ""} { writeText [file join $syslib pkgIndex.tcl] $rootIndex }

    set root [lindex $names 0]
    set version [expr {[number 4] == 0 ? "1.0-" : ""}]
    dict set current input [dict create mode [dict get $layouts $root] names $names layouts $layouts \
        root $root version $version tree [tree $syslib]]

    # Native Tcl with the same path.
    set nativeResult [file join $active native.tcldata]
    set nativeScript [file join $active native.tcl]
    writeText $nativeScript "set ::auto_path \[linsert \$::auto_path 0 [list $syslib]\]\n::tcl::tm::path add [list $syslib]\n[systemProgram $nativeResult $root $version]"
    set native [run [list [info nameofexecutable] $nativeScript] $active]
    status $native 0 "native tclsh failed"
    set expected [readData $nativeResult]
    need [expr {[dict get $expected code] == 0}] "harness: native Tcl could not load $root: [dict get $expected message]"
    # Providers native Tcl used: the directory of each package file loaded
    # (a module is its own file).
    set loadedNames [lmap marker [dict get $expected markers] {lindex $marker 0}]
    set refused [expr {[llength [lmap n $loadedNames {if {$n ni $rootRegistered} continue; set n}]] > 0}]

    set before [tree $envdir]
    set arguments [list add $envdir $root {*}[expr {$version eq "" ? {} : [list $version]}] --path $syslib]
    set result [invoke manager $arguments $overrides]
    managerOutcome $result "add of a system package"
    need [expr {![llength [entries $tmp]]}] "add left files in the temporary directory"
    if {$refused} {
        need [expr {[dict get $result status] == 1}] "a package registered from the path's root was added"
        need [equalTree $before [tree $envdir]] "a refused add changed the environment"
        noStages
        cover refused-root
        return
    }
    need [expr {[dict get $result status] == 0}] \
        "add of a package native Tcl loads failed: [string trim [encoding convertfrom utf-8 [dict get $result stderr]]]"
    need [equalTree [dict get $current input tree] [tree $syslib]] "add changed the system packages"

    # The environment on its own, without the path.
    set envResult [file join $active env.tcldata]
    set envScript [file join $active inenv.tcl]
    writeText $envScript [systemProgram $envResult $root $version]
    set inside [invoke runtime [list -- $envScript]]
    status $inside 0 "the environment's Tcl failed"
    set actual [readData $envResult]
    need [expr {[dict get $actual code] == 0}] "the environment cannot load $root after add: [dict get $actual message]"
    need [expr {[lsort [dict get $actual markers]] eq [lsort [dict get $expected markers]]}] \
        "the environment loads [list [lsort [dict get $actual markers]]]; native Tcl loads [list [lsort [dict get $expected markers]]]"
    set envRoot [file normalize $envdir]
    foreach script [dict get $actual scripts] {
        need [string match [string map {* \\* ? \\? [ \\[ ] \\] \\ \\\\} $envRoot]/* $script] \
            "the environment loaded [list $script], outside itself"
    }
    set records [readData [receiptPath]]
    set providers [lsort -unique [lmap script [dict get $expected scripts] {
        expr {[string match *.tm $script] ? $script : [file dirname $script]}
    }]]
    set origins [lsort -unique [dict values [dict map {id record} $records {dict get $record origin path}]]]
    need [expr {$origins eq [lsort [lmap p $providers {file normalize $p}]]}] \
        "receipts come from [list $origins]; native Tcl loaded from [list $providers]"
    cover added-[llength $providers]
    need [expr {[doctorAgrees $envdir] == 0}] "doctor rejects an environment after add"
    foreach id [lreverse [dict keys $records]] {
        set removed [invoke manager [list remove $envdir $id] $overrides]
        managerOutcome $removed "remove of an added package"
        need [expr {[dict get $removed status] == 0}] "added package $id could not be removed"
    }
    need [equalTree $before [tree $envdir]] "add and remove did not restore the environment"
}
