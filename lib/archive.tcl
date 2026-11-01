# Reading package archives with core Tcl only (8.6 has no zipfs): tar,
# gzip-compressed tar (one or more gzip members), and zip (stored and
# deflated entries). Entries are checked before anything is written: only
# regular files and directories, relative paths without "..", drive letters
# or backslashes, no duplicates, and limits on the entry count and the total
# size. Data is copied in 64 KiB pieces, never held whole in memory: a
# gzip-compressed tar is first decompressed to a temporary file.
namespace eval ::tclvenv::archive {
    # Limits (TCLVENV_ARCHIVE_LIMIT, in bytes, sets maxBytes).
    variable maxEntries 100000
    variable maxBytes [expr {512 * 1024 * 1024}]
}

# Rethrows an I/O error with the channel it names ("file7") replaced by
# what the channel is (a path), so a full disk says where it is.
proc ::tclvenv::archive::nameChannel {ch path message options} {
    return -options $options [string map [list "\"$ch\"" "\"$path\""] $message]
}

proc ::tclvenv::archive::limit {} {
    variable maxBytes
    if {[info exists ::env(TCLVENV_ARCHIVE_LIMIT)] &&
        [string is wideinteger -strict $::env(TCLVENV_ARCHIVE_LIMIT)] &&
        $::env(TCLVENV_ARCHIVE_LIMIT) > 0} {
        return $::env(TCLVENV_ARCHIVE_LIMIT)
    }
    return $maxBytes
}

# The kind of archive at path, from its first bytes: zip, gzip or tar.
proc ::tclvenv::archive::kind {path} {
    set ch [open $path rb]
    try { set head [read $ch 512] } finally { close $ch }
    if {[string range $head 0 3] eq "PK\x03\x04" || [string range $head 0 3] eq "PK\x05\x06"} { return zip }
    if {[string range $head 0 1] eq "\x1f\x8b"} { return gzip }
    if {[string length $head] == 512 && [string range $head 257 261] eq "ustar"} { return tar }
    return ""
}

# An entry's name as path components, or an error: relative, no "..", no
# drive letters, backslashes or NULs. "." components are dropped.
proc ::tclvenv::archive::components {name} {
    if {$name eq "" || [string first "\\" $name] >= 0 || [string first \0 $name] >= 0 ||
        [string match /* $name] || [regexp {^[A-Za-z]:} $name]} {
        error "unsafe archive entry name: [list $name]"
    }
    set parts {}
    foreach part [split $name /] {
        if {$part in {"" .}} { continue }
        if {$part eq ".."} { error "unsafe archive entry name: [list $name]" }
        lappend parts $part
    }
    if {![llength $parts]} { error "unsafe archive entry name: [list $name]" }
    return $parts
}

# Whether name is the archive's root itself (".", "./", "./."), as archives
# made with "tar -C dir ." start with.
proc ::tclvenv::archive::isRoot {name} {
    regexp {^\.(/+\.?)*/*$} $name
}

# A name from an archive (bytes) as a string: UTF-8, as tar and zip tools
# write it now; bytes that aren't valid UTF-8 are taken in the fallback
# encoding: Latin-1 for tar, which has none, CP 437 for a zip name without
# the UTF-8 flag (as APPNOTE says, Python and 7-Zip read it, and Windows
# writes it; Info-ZIP on Unix writes UTF-8 without the flag).
proc ::tclvenv::archive::decodeName {bytes {fallback iso8859-1}} {
    # (Tcl 9 raises an error on invalid UTF-8; 8.6 substitutes.)
    if {![catch {encoding convertfrom utf-8 $bytes} text] &&
        [encoding convertto utf-8 $text] eq $bytes} { return $text }
    encoding convertfrom $fallback $bytes
}

# The path= value of a pax extended header, or "". Records are
# "LENGTH key=value\n", LENGTH counting the whole record, so a value may
# hold newlines.
proc ::tclvenv::archive::paxPath {body} {
    set path ""
    set at 0
    while {$at < [string length $body]} {
        # (Some writers pad the data with NULs.)
        if {[string trim [string range $body $at end] \0] eq ""} { break }
        set space [string first " " $body $at]
        if {$space < 0 || ![regexp {^[0-9]{1,9}$} [string range $body $at [expr {$space - 1}]] digits]} {
            error "corrupt tar header (bad pax record)"
        }
        set end [expr {$at + [scan $digits %d] - 1}]
        if {$end <= $space || $end >= [string length $body] || [string index $body $end] ne "\n"} {
            error "corrupt tar header (bad pax record)"
        }
        set record [string range $body [expr {$space + 1}] [expr {$end - 1}]]
        if {[string match path=* $record]} { set path [string range $record 5 end] }
        set at [expr {$end + 1}]
    }
    return $path
}

# Whether buffer and the rest of the channel hold only zero bytes (padding
# some tools leave after gzip data).
proc ::tclvenv::archive::onlyZeros {buffer ch} {
    while 1 {
        if {[string trim $buffer \0] ne ""} { return 0 }
        if {[eof $ch]} { return 1 }
        set buffer [read $ch 65536]
    }
}

# Decompresses the gzip file at path to the channel out, member after
# member (a gzip file may be several concatenated), at most limit bytes.
# A member ends where zlib reports it; the next one starts after the
# member's trailer (its CRC-32 and size), found in the bytes fed last.
proc ::tclvenv::archive::gunzipTo {path out limit} {
    set in [open $path rb]
    try {
        set total 0
        set members 0
        set buffer ""
        while 1 {
            while {[string length $buffer] < 2 && ![eof $in]} { append buffer [read $in 65536] }
            if {$buffer eq ""} { break }
            if {[string range $buffer 0 1] ne "\x1f\x8b"} {
                if {$members && [onlyZeros $buffer $in]} { break }
                if {$members} { error "corrupt compressed data: data after the gzip data" }
                error "corrupt compressed data: not gzip data"
            }
            incr members
            set stream [zlib stream gunzip]
            try {
                set crc 0
                set size 0
                set tail ""
                while 1 {
                    if {$buffer eq ""} {
                        if {[eof $in]} { error "corrupt compressed data: truncated" }
                        set buffer [read $in 65536]
                        continue
                    }
                    set chunk $buffer
                    set buffer ""
                    if {[catch {$stream put $chunk} message]} { error "corrupt compressed data: $message" }
                    while 1 {
                        if {[catch {$stream get 65536} piece]} { error "corrupt compressed data: $piece" }
                        if {$piece eq ""} { break }
                        incr total [string length $piece]
                        if {$total > $limit} { error "archive expands beyond the size limit" }
                        set crc [zlib crc32 $piece $crc]
                        incr size [string length $piece]
                        puts -nonewline $out $piece
                    }
                    if {[$stream eof]} {
                        set trailer [binary format ii $crc [expr {$size & 0xffffffff}]]
                        set fed $tail$chunk
                        set at [string first $trailer $fed]
                        if {$at < 0} { error "corrupt compressed data: no member trailer" }
                        set buffer [string range $fed [expr {$at + 8}] end]
                        break
                    }
                    set tail [string range $tail$chunk end-7 end]
                }
            } finally { $stream close }
        }
        if {!$members} { error "corrupt compressed data: empty" }
    } finally { close $in }
}

proc ::tclvenv::archive::octal {field} {
    set text [string trim [string map [list \0 " "] $field]]
    if {$text eq ""} { return 0 }
    if {![regexp {^[0-7]+$} $text]} { error "corrupt tar header (bad number)" }
    scan $text %llo value
    return $value
}

# Reads n bytes at offset; an error if fewer are there.
proc ::tclvenv::archive::readAt {ch offset n what} {
    seek $ch $offset
    set data [read $ch $n]
    if {[string length $data] != $n} { error "truncated $what" }
    return $data
}

# Entries of the tar file at path, from its headers alone: dictionaries
# with name, kind, mode, offset and size. The archive must end with its
# end-of-archive marker: one cut short at an entry boundary looks complete.
proc ::tclvenv::archive::tarScan {path} {
    variable maxEntries
    set size [file size $path]
    set ch [open $path rb]
    try {
        set entries {}
        set longName ""
        set paxPath ""
        set ended 0
        for {set at 0} {$at + 512 <= $size} {} {
            set header [readAt $ch $at 512 "tar archive"]
            if {$header eq [string repeat \0 512]} { set ended 1; break }
            binary scan $header cu* bytes
            set sum 0
            set i 0
            foreach byte $bytes {
                incr sum [expr {$i >= 148 && $i < 156 ? 32 : $byte}]
                incr i
            }
            if {[octal [string range $header 148 155]] != $sum} { error "corrupt tar header (checksum)" }
            set name [lindex [split [string range $header 0 99] \0] 0]
            set length [octal [string range $header 124 135]]
            set mode [octal [string range $header 100 107]]
            set type [string index $header 156]
            # The prefix field is POSIX's (magic "ustar\0"); in the old GNU
            # format (magic "ustar  \0") those bytes hold times.
            if {[string range $header 257 262] eq "ustar\0"} {
                set prefix [lindex [split [string range $header 345 499] \0] 0]
                if {$prefix ne ""} { set name $prefix/$name }
            }
            set start [expr {$at + 512}]
            if {$start + $length > $size} { error "truncated tar archive" }
            set at [expr {$start + ($length + 511) / 512 * 512}]
            switch -- $type {
                L - x {
                    if {$length > 1048576} { error "corrupt tar header (oversized name record)" }
                    set body [readAt $ch $start $length "tar archive"]
                    if {$type eq "L"} {
                        set longName [lindex [split $body \0] 0]
                    } else {
                        set paxPath [paxPath $body]
                    }
                    continue
                }
                g { continue }
            }
            if {$paxPath ne ""} { set name $paxPath } elseif {$longName ne ""} { set name $longName }
            set name [decodeName $name]
            set paxPath ""
            set longName ""
            switch -- $type {
                0 - \0 - 7 { set kind file }
                5 - D {
                    # (D: a GNU dump directory, from tar -G, which lists its
                    # entries as data; GNU tar extracts it as a directory.)
                    set kind directory
                }
                default { error "unsupported tar entry (links and special files are refused): [list $name]" }
            }
            if {[llength $entries] >= $maxEntries} { error "archive has too many entries" }
            lappend entries [dict create name $name kind $kind mode $mode offset $start size $length]
        }
        if {!$ended} { error "truncated tar archive (no end-of-archive marker)" }
        return $entries
    } finally { close $ch }
}

# Entries of the zip file at path, from its central directory: dictionaries
# with name, kind, mode, offset, size, and for files csize, method and crc.
proc ::tclvenv::archive::zipScan {path} {
    variable maxEntries
    set size [file size $path]
    set ch [open $path rb]
    try {
        # The end record is in the last 22 + 65535 (comment) bytes.
        set from [expr {max(0, $size - 65557)}]
        set tail [readAt $ch $from [expr {$size - $from}] "zip archive"]
        set end [string last "PK\x05\x06" $tail]
        if {$end < 0 || $end + 22 > [string length $tail]} { error "not a zip archive (no central directory)" }
        binary scan [string range $tail $end [expr {$end + 21}]] a4susususuiuiusu - disk cdDisk countHere count cdSize cdOffset commentLength
        if {$count == 0xffff || $cdOffset == 0xffffffff || $cdSize == 0xffffffff} {
            error "zip64 archives are not supported"
        }
        if {$disk != 0 || $cdDisk != 0 || $countHere != $count} { error "multi-part zip archives are not supported" }
        if {$count > $maxEntries} { error "archive has too many entries" }
        if {$cdOffset + $cdSize > $size} { error "corrupt zip central directory" }
        set directory [readAt $ch $cdOffset $cdSize "zip archive"]
        set entries {}
        set total 0
        set at 0
        for {set i 0} {$i < $count} {incr i} {
            if {$at + 46 > $cdSize || [string range $directory $at [expr {$at + 3}]] ne "PK\x01\x02"} {
                error "corrupt zip central directory"
            }
            binary scan [string range $directory $at [expr {$at + 45}]] {a4 cu cu su su su su su iu iu iu su su su su su iu iu} \
                - madeVersion madeSystem needed flags method time date crc csize usize \
                nameLength extraLength commentLength2 diskStart internal external localOffset
            set name [decodeName [string range $directory [expr {$at + 46}] [expr {$at + 45 + $nameLength}]] \
                [expr {$flags & 0x800 ? "iso8859-1" : "cp437"}]]
            set at [expr {$at + 46 + $nameLength + $extraLength + $commentLength2}]
            if {$csize == 0xffffffff || $usize == 0xffffffff || $localOffset == 0xffffffff} {
                error "zip64 archives are not supported"
            }
            if {$flags & 1} { error "encrypted zip entries are not supported: [list $name]" }
            set unixMode [expr {($external >> 16) & 0xffff}]
            set fileType [expr {$unixMode & 0xf000}]
            if {$madeSystem == 3 && $fileType != 0 && $fileType != 0x8000 && $fileType != 0x4000} {
                error "unsupported zip entry (links and special files are refused): [list $name]"
            }
            if {[string match */ $name]} {
                lappend entries [dict create name $name kind directory mode [expr {$unixMode & 0o777}] offset 0 size 0]
                continue
            }
            if {$method ni {0 8}} { error "unsupported zip compression method $method: [list $name]" }
            incr total $usize
            if {$total > [limit]} { error "archive expands beyond the size limit" }
            set local [readAt $ch $localOffset 30 "zip archive"]
            if {[string range $local 0 3] ne "PK\x03\x04"} { error "corrupt zip local header: [list $name]" }
            binary scan [string range $local 26 29] susu localName localExtra
            set start [expr {$localOffset + 30 + $localName + $localExtra}]
            if {$start + $csize > $size} { error "truncated zip archive" }
            lappend entries [dict create name $name kind file mode [expr {$unixMode & 0o777}] \
                offset $start size $usize csize $csize method $method crc $crc]
        }
        return $entries
    } finally { close $ch }
}

# Copies a zip entry's data from in to out, checking its size and CRC.
proc ::tclvenv::archive::zipCopy {in out entry} {
    set name [dict get $entry name]
    set left [dict get $entry csize]
    set expected [dict get $entry size]
    seek $in [dict get $entry offset]
    set crc 0
    set written 0
    set stream ""
    if {[dict get $entry method] == 8} { set stream [zlib stream inflate] }
    try {
        while {$left > 0} {
            set chunk [read $in [expr {min($left, 65536)}]]
            if {$chunk eq ""} { error "truncated zip archive" }
            incr left -[string length $chunk]
            if {$stream eq ""} {
                set pieces [list $chunk]
            } else {
                if {[catch {$stream put $chunk} message]} { error "corrupt zip entry ($message): [list $name]" }
                set pieces {}
                while 1 {
                    if {[catch {$stream get 65536} piece]} { error "corrupt zip entry ($piece): [list $name]" }
                    if {$piece eq ""} { break }
                    lappend pieces $piece
                }
            }
            foreach piece $pieces {
                incr written [string length $piece]
                # More than declared is corruption (or a bomb): stop here.
                if {$written > $expected} { error "corrupt zip entry (size): [list $name]" }
                set crc [zlib crc32 $piece $crc]
                puts -nonewline $out $piece
            }
        }
    } finally { if {$stream ne ""} { $stream close } }
    if {$written != $expected} { error "corrupt zip entry (size): [list $name]" }
    if {$crc != [dict get $entry crc]} { error "corrupt zip entry (CRC): [list $name]" }
}

# Runs script in the caller with format (tar or zip), source (the file
# holding the entries' data) and entries set; a gzip-compressed tar is
# decompressed to a temporary file first, removed afterwards.
proc ::tclvenv::archive::withEntries {path script} {
    upvar 1 format format source source entries entries
    if {[file size $path] > [limit]} { error "archive is larger than the size limit" }
    set temporary ""
    try {
        switch -- [kind $path] {
            zip { set format zip; set source $path; set entries [zipScan $path] }
            tar { set format tar; set source $path; set entries [tarScan $path] }
            gzip {
                set ch [file tempfile temporary]
                if {[catch {
                    fconfigure $ch -translation binary
                    gunzipTo $path $ch [limit]
                    close $ch
                } message options]} {
                    catch {close $ch}
                    if {[string first "\"$ch\"" $message] >= 0} {
                        set message "couldn't decompress $path: [string map [list "\"$ch\"" "\"$temporary\""] $message]"
                    }
                    return -options $options $message
                }
                set format tar
                set source $temporary
                set entries [tarScan $temporary]
            }
            default { error "not a zip, tar or gzip-compressed tar archive: $path" }
        }
        uplevel 1 $script
    } finally {
        if {$temporary ne ""} { file delete -- $temporary }
    }
}

# The archive's entries as {name kind size} (a root entry left out).
proc ::tclvenv::archive::entries {path} {
    withEntries $path {
        set result {}
        foreach entry $entries {
            if {[dict get $entry kind] eq "directory" && [isRoot [dict get $entry name]]} { continue }
            lappend result [list [dict get $entry name] [dict get $entry kind] [dict get $entry size]]
        }
    }
    return $result
}

# Writes the archive's entries under destination (an empty directory).
# Every name is checked before anything is written; if copying fails
# (corrupt data found on the way), what was written is removed.
proc ::tclvenv::archive::extract {path destination} {
    withEntries $path {
        set checked {}
        set seen {}
        set total 0
        foreach entry $entries {
            set name [dict get $entry name]
            set kind [dict get $entry kind]
            # The root itself ("./"): nothing to write.
            if {$kind eq "directory" && [isRoot $name]} { continue }
            set parts [components $name]
            set key [join $parts /]
            if {[dict exists $seen $key]} { error "duplicate archive entry: [list $name]" }
            dict set seen $key $kind
            incr total [dict get $entry size]
            if {$total > [limit]} { error "archive expands beyond the size limit" }
            dict set entry parts $parts
            lappend checked $entry
        }
        # A file must not also be a directory of another entry.
        dict for {key kind} $seen {
            set parts [split $key /]
            for {set i 1} {$i < [llength $parts]} {incr i} {
                set parent [join [lrange $parts 0 [expr {$i - 1}]] /]
                if {[dict exists $seen $parent] && [dict get $seen $parent] ne "directory"} {
                    error "archive entry is both a file and a directory: [list $parent]"
                }
            }
        }
        set created {}
        set in [open $source rb]
        try {
            foreach entry $checked {
                set parts [dict get $entry parts]
                if {[lindex $parts 0] ni $created} { lappend created [lindex $parts 0] }
                # (Components starting with ~ are joined as ./~: Tcl 8.6
                # would take them for a home directory.)
                set target [file join $destination {*}[lmap part $parts {
                    if {[string match ~* $part]} { string cat ./ $part } else { set part }
                }]]
                if {[dict get $entry kind] eq "directory"} {
                    file mkdir $target
                    continue
                }
                file mkdir [file dirname $target]
                set out [open $target {WRONLY CREAT EXCL BINARY}]
                if {[catch {
                    if {$format eq "zip"} {
                        zipCopy $in $out $entry
                    } else {
                        seek $in [dict get $entry offset]
                        if {[fcopy $in $out -size [dict get $entry size]] != [dict get $entry size]} {
                            error "truncated tar archive"
                        }
                    }
                    close $out
                } message options]} {
                    catch {close $out}
                    nameChannel $out $target $message $options
                }
                if {$::tcl_platform(platform) eq "unix"} {
                    # Executable if the archive says so; never setuid or setgid.
                    file attributes $target -permissions [expr {[dict get $entry mode] & 0o111 ? 0o755 : 0o644}]
                }
            }
        } on error {message options} {
            foreach top $created {
                if {[string match ~* $top]} { set top ./$top }
                catch {file delete -force -- [file join $destination $top]}
            }
            nameChannel $in $source $message $options
        } finally { close $in }
    }
}
