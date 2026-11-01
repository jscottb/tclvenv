# Loaded by fuzz.tcl. install.sh against generated homes.
#
#   installer  a private HOME whose ~/.profile, ~/.bashrc and ~/.zshrc are
#              each absent, empty, ordinary, without a final newline, with
#              CRLF line ends, a link into a dotfiles directory, a dangling
#              link, read-only, or holding a block an earlier install
#              wrote; a location (--user, --user-bin, --prefix, --bindir and
#              --datadir) with hostile directory names; --path or --no-path;
#              sometimes the directory already on PATH; then install,
#              sometimes a reinstall, and uninstall
#
# Oracle: stderr holds only install.sh's own messages; after install the
# command runs; each startup file it changed still runs in sh (bash for
# .bashrc), still does what it did, and puts the command's directory on
# PATH; uninstall leaves every startup file byte for byte as it was, and
# nothing of the install behind. Unix only (sh, bash for .bashrc).

proc ::fuzz::installerName {} {
    set corpus [list plain {my tools} ' {"} {$HOME} {`x`} {$(x)} é \t {*} {;} {&} {\\} {#} {~} {=}]
    set name t
    for {set i 0; set n [expr {1 + [number 4]}]} {$i < $n} {incr i} { append name [pick $corpus] }
    return $name
}

# A startup file's content: sets a sentinel variable, so we can tell that
# its own lines still run.
proc ::fuzz::installerStartup {home name state} {
    set path [file join $home $name]
    set sentinel "FUZZ_[string toupper [string map {. {}} $name]]=ran\nexport FUZZ_[string toupper [string map {. {}} $name]]\n"
    switch -- $state {
        absent { return }
        empty { writeBytes $path "" }
        ordinary { writeBytes $path "# $name\n$sentinel" }
        nonewline { writeBytes $path "# $name\n[string trimright $sentinel \n]" }
        crlf { writeBytes $path [string map [list \n \r\n] "# $name\n$sentinel"] }
        link {
            set target [file join $home dotfiles $name]
            file mkdir [file dirname $target]
            writeBytes $target "# linked $name\n$sentinel"
            file link -symbolic $path $target
        }
        dangling {
            # (Tcl's file link won't make a link to nothing.)
            variable active
            status [run [list ln -s -- [file join $home nowhere $name] $path] $active] 0 "could not make a dangling link"
        }
        readonly {
            writeBytes $path "# $name\n$sentinel"
            file attributes $path -permissions 0444
        }
        oldblock {
            writeBytes $path "# $name\n$sentinel# >>> tclvenv PATH >>>\nPATH=/old/bin:\$PATH\n# <<< tclvenv PATH <<<\n"
        }
    }
}

# Every file under home (links not followed): path -> content or link target.
proc ::fuzz::installerSnapshot {home} {
    set result {}
    set queue [list $home]
    while {[llength $queue]} {
        set queue [lassign $queue directory]
        foreach child [glob -nocomplain -directory $directory -- * .*] {
            if {[file tail $child] in {. ..}} continue
            set relative [string range $child [string length $home]+1 end]
            set type [file type $child]
            switch -- $type {
                link { dict set result $relative [list link [file readlink $child]] }
                directory { dict set result $relative directory; lappend queue $child }
                default { dict set result $relative [list file [binary encode base64 [readBytes $child]] [file attributes $child -permissions]] }
            }
        }
    }
    return $result
}

proc ::fuzz::installerRun {home arguments {pathValue ""}} {
    variable project
    variable active
    if {$pathValue eq ""} { set pathValue /usr/local/bin:/usr/bin:/bin }
    set words [list env -i HOME=$home PATH=$pathValue sh [file join $project install.sh] {*}$arguments]
    set result [run [list sh -c {exec "$@" </dev/null} sh {*}$words] $active "" {} 60000]
    dict lappend ::fuzz::current operations [dict create entry install.sh arguments $arguments result $result]
    need [expr {![dict get $result timedout]}] "install.sh did not finish"
    set errors [encoding convertfrom utf-8 [dict get $result stderr]]
    foreach line [split [string trimright $errors \n] \n] {
        if {$line eq ""} continue
        need [string match "install.sh: *" $line] "install.sh printed a shell error: $line"
    }
    return $result
}

# Sources a startup file with a minimal PATH: {status PATH sentinel}.
proc ::fuzz::installerSource {home name} {
    variable active
    set shell [expr {$name eq ".bashrc" ? "bash" : "sh"}]
    set var FUZZ_[string toupper [string map {. {}} $name]]
    set script ". \"\$HOME/$name\"; printf '%s\\n%s' \"\$PATH\" \"\${$var-}\""
    set result [run [list env -i HOME=$home PATH=/usr/bin:/bin $shell -c $script] $active "" {} 20000]
    set lines [split [encoding convertfrom utf-8 [dict get $result output]] \n]
    list [dict get $result status] [lindex $lines 0] [lindex $lines 1] [string trim [dict get $result stderr]]
}

proc ::fuzz::scenario_installer {} {
    variable active
    variable current
    if {$::tcl_platform(platform) ne "unix" || [auto_execok bash] eq ""} { cover skipped; return }
    set home [file join $active [installerName]-home]
    file mkdir $home
    set states {}
    foreach name {.profile .bashrc .zshrc} {
        set state [pick {absent empty ordinary ordinary nonewline crlf link dangling readonly oldblock}]
        dict set states $name $state
        cover $name-$state
        installerStartup $home $name $state
    }
    set place [pick {user user-bin prefix split}]
    set name [installerName]
    switch -- $place {
        user { set where --user; set bindir [file join $home .local bin]; set datadir [file join $home .local share tclvenv] }
        user-bin { set where --user-bin; set bindir [file join $home bin]; set datadir [file join $home .local share tclvenv] }
        prefix {
            set prefix [file join $home $name]
            set where [list --prefix $prefix]
            set bindir [file join $prefix bin]; set datadir [file join $prefix share tclvenv]
        }
        split {
            set bindir [file join $home $name b]; set datadir [file join $home $name-d data]
            set where [list --bindir $bindir --datadir $datadir]
        }
    }
    set pathMode [pick {--path --path --no-path}]
    set onPath [expr {[number 5] == 0}]
    set pathValue [expr {$onPath ? "$bindir:/usr/bin:/bin" : ""}]
    set reinstall [expr {[number 3] == 0}]
    dict set current input [dict create mode $place startup $states path $pathMode on_path $onPath \
        reinstall $reinstall bindir $bindir datadir $datadir]
    cover $place
    set before [installerSnapshot $home]
    # How each startup file behaves before the install (a CRLF file already
    # fails in sh): after it, it must behave the same, plus the PATH entry.
    set baseline {}
    foreach name {.profile .bashrc} { dict set baseline $name [installerSource $home $name] }
    set result [installerRun $home [list {*}$where $pathMode] $pathValue]
    status $result 0 "install failed: [string trim [dict get $result stderr]]"
    if {$reinstall} {
        status [installerRun $home [list {*}$where $pathMode] $pathValue] 0 "reinstall failed"
    }
    set command [file join $bindir tclvenv]
    set version [run [list $command --version] $active]
    status $version 0 "the installed command doesn't run"
    if {$pathMode eq "--path" && !$onPath} {
        foreach name {.profile .bashrc} {
            set state [dict get $states $name]
            # Files install.sh may not write (read-only, dangling, absent
            # .bashrc) are judged by what they still do, below.
            if {$state in {absent dangling} && $name ne ".profile"} continue
            lassign [installerSource $home $name] code path sentinel errors
            lassign [dict get $baseline $name] code0 - sentinel0 errors0
            if {$state eq "absent"} {
                # install.sh made the file: it must just run.
                need [expr {$code == 0 && $errors eq ""}] "the $name install.sh made doesn't run cleanly: $errors"
            } else {
                need [expr {$code == $code0 && $errors eq $errors0}] "$name runs differently after the install: $errors"
                need [expr {$sentinel eq $sentinel0}] "$name's own lines no longer run"
            }
            # A file that already stops before its end (a CRLF file in sh)
            # never reaches the block: nothing install.sh can change.
            if {$state ni {readonly dangling} && ($state eq "absent" || $code0 == 0)} {
                need [expr {$bindir in [split $path :]}] "$name doesn't put the command's directory on PATH"
            }
        }
    }
    status [installerRun $home [list {*}$where --uninstall]] 0 "uninstall failed"
    set after [installerSnapshot $home]
    foreach name {.profile .bashrc .zshrc} {
        set was [expr {[dict exists $before $name] ? [dict get $before $name] : "absent"}]
        set now [expr {[dict exists $after $name] ? [dict get $after $name] : "absent"}]
        if {[dict get $states $name] eq "absent" && $name eq ".profile" && $now ne "absent"} {
            # install.sh created ~/.profile for the PATH lines: what remains
            # must be empty.
            need [expr {[lindex $now 1] eq ""}] "uninstall left lines in the ~/.profile install.sh created"
            continue
        }
        need [expr {$was eq $now}] "uninstall left $name different from before the install"
    }
    foreach path [list $command $datadir] {
        need [expr {![exists $path]}] "uninstall left $path"
    }
    # Links' targets (dotfiles) too.
    dict for {path value} $before {
        if {![dict exists $after $path]} { error "uninstall removed $path, which was there before" }
        if {[string match dotfiles* $path] && [dict get $after $path] ne $value} { error "uninstall left $path changed" }
    }
}
