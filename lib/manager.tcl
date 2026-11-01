namespace eval ::tclvenv {
    variable version 0.1.0
    variable resources [file dirname [file normalize [info script]]]
    variable mutationRoot ""
    variable deletionRoot ""
    variable deletionFiles {}
    variable deletionParents {}
}
source [file join $::tclvenv::resources archive.tcl]

proc ::tclvenv::readData {path} {
    set ch [open $path r]
    try {
        fconfigure $ch -encoding utf-8 -translation lf
        set data [read $ch]
        dict size $data
        return $data
    } finally { close $ch }
}

# An I/O error on a channel names the channel ("file5"): name the file.
proc ::tclvenv::writeError {path message options} {
    set code [dict get $options -errorcode]
    if {[lindex $code 0] eq "POSIX"} { set message [lindex $code 2] }
    return -code error -errorcode $code "couldn't write $path: $message"
}

# A problem that doesn't change a command's outcome (it has done its work,
# or is failing for another reason): reported on stderr, never raised.
proc ::tclvenv::warn {message} {
    catch {puts stderr "tclvenv: warning: $message"}
}

# What a lock file records about its holder: this host and process.
proc ::tclvenv::lockRecord {} {
    list host [info hostname] pid [pid]
}

# Whether process pid exists on this host. Unknown counts as alive.
proc ::tclvenv::processAlive {pid} {
    if {$pid == [pid]} { return 1 }
    if {[file isdirectory /proc/self]} {
        if {![file exists /proc/$pid]} { return 0 }
        # A zombie (killed, not yet reaped by its parent) runs no code.
        # (The state follows the last ")": a process name may contain one.)
        if {![catch {readText /proc/$pid/stat 4096} stat] &&
            [string trimleft [string range $stat [string last ")" $stat]+1 end]] ne "" &&
            [string index [string trimleft [string range $stat [string last ")" $stat]+1 end]] 0] eq "Z"} { return 0 }
        return 1
    }
    if {![catch {exec -- env LC_ALL=C kill -0 $pid} message]} { return 1 }
    expr {![string match "*No such process*" $message]}
}

# Creates lock file path, recording its holder; an existing one is a lock
# held (or left behind); any other failure is reported as what it is. A
# lock left by a process that no longer exists on this host is taken over.
proc ::tclvenv::takeLock {path held} {
    for {set attempt 0} {$attempt < 2} {incr attempt} {
        if {[createLock $path]} { return }
        if {$attempt || ![breakStaleLock $path]} { break }
    }
    error $held
}

# Creates lock file path holding its record, or returns 0 if it exists.
# The record is written to a file of its own first, which is then linked
# to path (a hard link, which fails if path exists): a process killed at
# any moment leaves no lock or a complete one, never an empty lock that
# couldn't be told stale. Where hard links aren't supported, path is
# created exclusively and written (with that small window).
proc ::tclvenv::createLock {path} {
    set temporary $path.[pid]-[format %08x [expr {int(rand() * 0xffffffff)}]]
    if {[catch {open $temporary {WRONLY CREAT EXCL}} ch options]} {
        set code [dict get $options -errorcode]
        set reason [expr {[lindex $code 0] eq "POSIX" ? [lindex $code 2] : $ch}]
        error "couldn't create the lock file $path: $reason"
    }
    try {
        if {[catch {puts $ch [lockRecord]; close $ch} message options]} {
            catch {close $ch}
            writeError $path $message $options
        }
        if {![catch {file link -hard $path $temporary}]} {
            removeDeadLockTemporaries $path
            return 1
        }
        if {[pathExists $path]} { return 0 }
        # No hard links here: create it exclusively.
        if {[catch {open $path {WRONLY CREAT EXCL}} ch options]} {
            if {[lrange [dict get $options -errorcode] 0 1] eq {POSIX EEXIST}} { return 0 }
            set code [dict get $options -errorcode]
            set reason [expr {[lindex $code 0] eq "POSIX" ? [lindex $code 2] : $ch}]
            error "couldn't create the lock file $path: $reason"
        }
        if {[catch {puts $ch [lockRecord]; close $ch} message options]} {
            catch {close $ch}
            catch {file delete -- $path}
            writeError $path $message $options
        }
        return 1
    } finally {
        catch {file delete -- $temporary}
    }
}

# Record files (path.PID-RANDOM) of processes killed while creating path
# (they exist only for that moment): removed once their process is gone.
proc ::tclvenv::removeDeadLockTemporaries {path} {
    if {$::tcl_platform(platform) ne "unix"} { return }
    set prefix [file tail $path].
    # (Never a glob pattern made from the name, which may hold [ ] { } * ?)
    foreach name [glob -nocomplain -tails -directory [file dirname $path] -- *] {
        if {![regexp {^(\d+)-[0-9a-f]{8}$} [string range $name [string length $prefix] end] -> pid] ||
            ![string equal -length [string length $prefix] $prefix $name] ||
            $pid == [pid] || [processAlive $pid]} { continue }
        set leftover [file join [file dirname $path] $name]
        if {![catch {file lstat $leftover st}] && $st(type) eq "file"} { catch {file delete -- $leftover} }
    }
}

# The holder a lock file records, {host H pid N}, or "" if it isn't one
# this version wrote (older ones wrote only a pid; any other content, a
# directory or a link is never taken for a stale lock).
proc ::tclvenv::lockHolder {path} {
    if {[catch {file lstat $path st}] || $st(type) ne "file" || $st(size) > 4096 ||
        [catch {readText $path 4096} data] || [catch {dict size $data}] ||
        [dict size $data] != 2 || ![dict exists $data host] || ![dict exists $data pid] ||
        ![string is integer -strict [dict get $data pid]] || [dict get $data pid] <= 0 ||
        [dict get $data pid] > 0x7fffffff} {
        return ""
    }
    dict create host [dict get $data host] pid [dict get $data pid]
}

# Removes lock file path if the process that wrote it is gone: same host
# (a lock on a shared filesystem may belong to another machine), and no
# such process. Unix only. Breaking is serialized by a second lock, path.break,
# so two processes can't both judge a lock stale and one remove the
# other's fresh lock; the lock is read again under it. Returns whether
# the lock was removed.
proc ::tclvenv::breakStaleLock {path} {
    if {$::tcl_platform(platform) ne "unix"} { return 0 }
    set holder [lockHolder $path]
    if {$holder eq "" || [dict get $holder host] ne [info hostname] ||
        [processAlive [dict get $holder pid]]} { return 0 }
    set breaker $path.break
    # (Created like the lock itself, so a process killed while taking it
    # leaves no breaker or a complete one, never an empty one that would
    # block every later takeover.)
    for {set attempt 0} {1} {incr attempt} {
        if {![catch {createLock $breaker} created] && $created} { break }
        # A breaker whose process died while it held it is removed, and
        # breaking goes on (once: a breaker held by a live process, or one
        # that can't be read, means another takeover is under way).
        set other [lockHolder $breaker]
        if {$attempt || $other eq "" || [dict get $other host] ne [info hostname] ||
            [processAlive [dict get $other pid]] || [catch {file delete -- $breaker}]} { return 0 }
    }
    try {
        # Still the same dead holder's lock (nobody else broke and retook it).
        if {[lockHolder $path] ne $holder} { return 0 }
        file delete -- $path
        warn "took over $path from process [dict get $holder pid], which no longer exists"
        return 1
    } finally {
        catch {file delete -- $breaker}
    }
}

proc ::tclvenv::writeFile {path contents {executable 0}} {
    set ch [open $path {WRONLY CREAT EXCL}]
    try {
        fconfigure $ch -encoding utf-8 -translation lf
        puts -nonewline $ch $contents
        close $ch
        set ch ""
    } on error {message options} {
        writeError $path $message $options
    } finally { if {$ch ne ""} { catch {close $ch} } }
    if {$executable && $::tcl_platform(platform) eq "unix"} {
        file attributes $path -permissions 0755
    }
}

# Creates a new file in directory named PREFIX-PID-RANDOM (prefix being
# .tclvenv by default) and opens it for writing: exclusively, as open
# creates files, so its mode follows the umask (file tempfile makes every
# file 0600, which would make an environment's data unreadable to anyone
# else who uses it, and puts its random part before a template's
# "extension", so a name it makes doesn't start with the prefix). Returns
# the channel.
proc ::tclvenv::openTemporary {directory pathVar {prefix .tclvenv}} {
    upvar 1 $pathVar path
    for {set attempt 0} {$attempt < 100} {incr attempt} {
        set path [file join $directory $prefix-[pid]-[format %08x [expr {int(rand() * 0xffffffff)}]]]
        if {![catch {open $path {WRONLY CREAT EXCL}} ch options]} { return $ch }
        if {[lrange [dict get $options -errorcode] 0 1] ne {POSIX EEXIST}} {
            return -options $options $ch
        }
    }
    error "couldn't create a temporary file in $directory"
}

# Names of temporary files and move markers a killed process may leave:
# these, and those older versions made with file tempfile (tcl_XXXXXX.SUFFIX).
proc ::tclvenv::leftoverPatterns {kind} {
    switch -- $kind {
        temporary { list .tclvenv-* tcl_??????.tclvenv- }
        marker { list .tclvenv-move-* tcl_??????.tclvenv-move- }
    }
}

proc ::tclvenv::writeData {path data} {
    variable mutationRoot
    if {$mutationRoot ne ""} { requireDirectories $mutationRoot [file dirname $path] }
    set ch [openTemporary [file dirname $path] temporary]
    try {
        # A file being replaced keeps its mode (a deliberate chmod stays).
        if {$::tcl_platform(platform) eq "unix" &&
            ![catch {file lstat $path old}] && $old(type) eq "file"} {
            file attributes $temporary -permissions [format 0o%o [expr {$old(mode) & 0o7777}]]
        }
        fconfigure $ch -encoding utf-8 -translation lf
        if {[catch {puts $ch $data; close $ch} message options]} {
            catch {close $ch}
            set ch ""
            writeError $path $message $options
        }
        set ch ""
        file rename -force -- $temporary $path
    } finally {
        if {$ch ne ""} { catch {close $ch} }
        if {[pathExists $temporary]} { file delete -- $temporary }
    }
}

proc ::tclvenv::cleanRuntimeEnv {script {clearPackagePaths 0}} {
    set saved {}
    set keys {TCL_LIBRARY TK_LIBRARY TCLVENV_INTERACTIVE}
    if {$clearPackagePaths} { lappend keys TCLLIBPATH }
    foreach key $keys {
        if {[info exists ::env($key)]} {
            dict set saved $key $::env($key)
            unset ::env($key)
        }
    }
    try { uplevel 1 $script } finally {
        foreach key $keys {
            unset -nocomplain ::env($key)
            if {[dict exists $saved $key]} { set ::env($key) [dict get $saved $key] }
        }
    }
}

# Reads a probe's output until end of file, the deadline or the size limit.
proc ::tclvenv::probeRead {ch} {
    variable probe
    if {[catch {append probe(data) [read $ch]} message]} {
        set probe(error) $message
        set probe(done) error
    } elseif {[string length $probe(data)] > $probe(limit)} {
        set probe(done) toolarge
    } elseif {[eof $ch]} {
        set probe(done) eof
    }
}

# Kills processes and their descendants: a runtime that is a wrapper script
# (without exec) has the real interpreter as a child.
proc ::tclvenv::killProcesses {pids} {
    if {$::tcl_platform(platform) eq "windows"} {
        foreach pid $pids { catch {exec taskkill /F /T /PID $pid} }
        return
    }
    set all $pids
    if {![catch {exec ps -e -o pid= -o ppid=} table]} {
        set children {}
        foreach line [split $table \n] {
            if {[regexp {^\s*(\d+)\s+(\d+)\s*$} $line -> child parent]} {
                dict lappend children $parent $child
            }
        }
        for {set i 0} {$i < [llength $all]} {incr i} {
            if {[dict exists $children [lindex $all $i]]} {
                foreach child [dict get $children [lindex $all $i]] {
                    if {$child ni $all} { lappend all $child }
                }
            }
        }
    }
    foreach pid [lreverse $all] { catch {exec kill -KILL $pid} }
}

# Runs the selected Tcl on script (with its arguments) and returns its stdout
# if the command prefix valid accepts it. A runtime that never finishes is
# killed after the deadline (default 30 s, TCLVENV_PROBE_TIMEOUT in ms), and
# one producing more than 64 MiB is stopped; stderr goes to a file, so a
# warning there is not a failure, and messages quote at most the start of
# it, never the output.
proc ::tclvenv::runProbe {executable arguments valid} {
    variable probe
    set timeout 30000
    if {[info exists ::env(TCLVENV_PROBE_TIMEOUT)] &&
        [string is integer -strict $::env(TCLVENV_PROBE_TIMEOUT)] &&
        $::env(TCLVENV_PROBE_TIMEOUT) > 0} {
        set timeout $::env(TCLVENV_PROBE_TIMEOUT)
    }
    set errorChannel [file tempfile errors]
    close $errorChannel
    array unset probe
    array set probe [list data "" done "" limit [expr {64 * 1024 * 1024}] error ""]
    try {
        # Every word is an absolute path or generated script argument, so
        # none is taken for one of the pipeline's redirections.
        set ch [cleanRuntimeEnv {open |[concat [list $executable] $arguments [list 2> $errors]] r} 1]
        set pids [pid $ch]
        fconfigure $ch -blocking 0
        fileevent $ch readable [list ::tclvenv::probeRead $ch]
        set timer [after $timeout [list set ::tclvenv::probe(done) timeout]]
        vwait ::tclvenv::probe(done)
        after cancel $timer
        fileevent $ch readable {}
        set done $probe(done)
        if {$done ne "eof"} {
            killProcesses $pids
            # Don't wait for a process that may not exit.
            catch {close $ch}
            switch -- $done {
                timeout { error "Tcl runtime did not finish within [expr {$timeout / 1000.0}] s: $executable" }
                toolarge { error "Tcl runtime produced too much output: $executable" }
                default { error "could not read from Tcl runtime $executable: $probe(error)" }
            }
        }
        # End of output. The close doesn't wait for the process: one that
        # closed its stdout but keeps running would hang it. So the output
        # decides, not the exit status; a runtime whose output isn't valid is
        # killed first (its process can't have been reaped yet, so its PID
        # is still its own).
        if {![{*}$valid $probe(data)]} {
            killProcesses $pids
            catch {close $ch}
            set message "Tcl runtime did not report a valid identity: $executable"
            set detail [string trim [readText $errors 200]]
            if {$detail ne ""} { append message ": [lindex [split $detail \n] 0]" }
            error $message
        }
        catch {close $ch}
        return $probe(data)
    } finally {
        file delete -- $errors
    }
}

# At most limit characters of a text file.
proc ::tclvenv::readText {path limit} {
    set ch [open $path r]
    try { return [read $ch $limit] } finally { close $ch }
}

# Whether output is a runtime identity with these keys and a valid version.
proc ::tclvenv::validIdentity {keys output} {
    expr {![catch {dict size $output}] &&
        ![llength [lmap key $keys {if {[dict exists $output $key]} continue; set key}]] &&
        ![catch {package vcompare [dict get $output version] 0}]}
}

proc ::tclvenv::probe {executable {includeCore 0}} {
    variable resources
    set script {
        set result [dict create executable [info nameofexecutable] version [info patchlevel] library [info library]]
        foreach key {platform os machine pointerSize threaded} {
            dict set result $key [expr {[info exists ::tcl_platform($key)] ? $::tcl_platform($key) : 0}]
        }
        if {$argc} {
            source [lindex $argv 0]
            dict set result core_modules [::tclvenv::core::snapshot]
        }
        puts $result
    }
    # A script file, rather than stdin, also makes interpreter startup failures fatal.
    set ch [file tempfile path]
    try {
        puts $ch $script
        close $ch
        set ch ""
        set arguments [list $path]
        if {$includeCore} { lappend arguments [file join $resources core.tcl] }
        set keys {version library platform os machine pointerSize threaded}
        if {$includeCore} { lappend keys core_modules }
        set result [runProbe $executable $arguments [list ::tclvenv::validIdentity $keys]]
        if {![package vsatisfies [dict get $result version] 8.6-]} {
            error "Tcl 8.6 or newer is required"
        }
        return $result
    } finally {
        if {$ch ne ""} { close $ch }
        file delete -- $path
    }
}

proc ::tclvenv::resolveExecutable {name} {
    set command [auto_execok $name]
    if {[llength $command] != 1 || ![file isfile [lindex $command 0]]} {
        error "Tcl executable not found: $name"
    }
    return [file normalize [lindex $command 0]]
}

proc ::tclvenv::config {root} {
    set cfg [readData [file join $root tclvenv.cfg]]
    if {[dict get $cfg format] != 1} { error "unsupported environment format" }
    if {![string is boolean -strict [dict get $cfg system_packages]]} {
        error "invalid system_packages setting"
    }
    validateLayout $root
    return $cfg
}

proc ::tclvenv::shellQuote {value} {
    return [format {'%s'} [string map [list ' {'\''}] $value]]
}

proc ::tclvenv::psQuote {value} {
    return '[string map [list ' ''] $value]'
}

# Finds bin/ from $0, following links to the launcher itself (a link to
# bin/tclsh from elsewhere), so metadata/ is found beside the real file.
# The x keeps trailing newlines that command substitution would remove.
variable ::tclvenv::launcherResolve {TCLVENV_SELF=$0
TCLVENV_HOPS=0
while [ -h "$TCLVENV_SELF" ] && [ "$TCLVENV_HOPS" -lt 40 ]; do
    TCLVENV_LINK=$(readlink -- "$TCLVENV_SELF" && echo x) || exit 1
    TCLVENV_LINK=${TCLVENV_LINK%?x}
    case $TCLVENV_LINK in
        /*) TCLVENV_SELF=$TCLVENV_LINK ;;
        *) TCLVENV_SELF=$(dirname -- "$TCLVENV_SELF" && echo x) || exit 1
           TCLVENV_SELF=${TCLVENV_SELF%?x}/$TCLVENV_LINK ;;
    esac
    TCLVENV_HOPS=$((TCLVENV_HOPS + 1))
done
TCLVENV_DIR=$(dirname -- "$TCLVENV_SELF" && echo x) || exit 1
TCLVENV_BIN=$(CDPATH= cd -P -- "${TCLVENV_DIR%?x}" && pwd && echo x) || exit 1
TCLVENV_BIN=${TCLVENV_BIN%?x}
unset TCLVENV_SELF TCLVENV_HOPS TCLVENV_LINK TCLVENV_DIR}

proc ::tclvenv::launchers {root executable version} {
    variable launcherResolve
    set bin [file join $root bin]
    set quoted [shellQuote $executable]
    set posix {#!/bin/sh
@RESOLVE@
unset TCL_LIBRARY TK_LIBRARY
TCLVENV_INTERACTIVE=0
if [ -t 0 ]; then TCLVENV_INTERACTIVE=1; fi
export TCLVENV_INTERACTIVE
exec @TCL@ "$TCLVENV_BIN/../metadata/runtime.tcl" "$@"
}
    set posix [string map [list @TCL@ $quoted @RESOLVE@ $launcherResolve] $posix]
    writeFile [file join $bin tclsh] $posix 1
    set minor [join [lrange [split $version .] 0 1] .]
    writeFile [file join $bin tclsh$minor] $posix 1
    writeFile [file join $bin tclvenv] [string map [list @TCL@ $quoted @RESOLVE@ $launcherResolve] {#!/bin/sh
@RESOLVE@
unset TCL_LIBRARY TK_LIBRARY
exec @TCL@ "$TCLVENV_BIN/../metadata/manager-cli.tcl" "$@"
}] 1
    # Batch files use quoted paths, disable delayed expansion, and escape literal %.
    set batchTcl [string map [list % %%] $executable]
    foreach {name script} {tclsh runtime.tcl tclvenv manager-cli.tcl} {
        set batch [string map [list @TCL@ $batchTcl @SCRIPT@ $script] {@echo off
setlocal DisableDelayedExpansion
set "TCL_LIBRARY="
set "TK_LIBRARY="
set "TCLVENV_INTERACTIVE=0"
"@TCL@" "%~dp0..\metadata\@SCRIPT@" %*
exit /b %errorlevel%
}]
        writeFile [file join $bin $name.cmd] [string map [list \n \r\n] $batch]
        set ps [string map [list @TCL@ [psQuote $executable] @SCRIPT@ $script] {# Pass arguments through to the selected native Tcl executable.
$savedLibrary = $env:TCL_LIBRARY
$savedTkLibrary = $env:TK_LIBRARY
$savedInteractive = $env:TCLVENV_INTERACTIVE
try {
    Remove-Item Env:TCL_LIBRARY, Env:TK_LIBRARY -ErrorAction SilentlyContinue
    $env:TCLVENV_INTERACTIVE = '0'
    if (-not [Console]::IsInputRedirected) {
        $env:TCLVENV_INTERACTIVE = '1'
    }
    & @TCL@ (Join-Path $PSScriptRoot '../metadata/@SCRIPT@') @args
    $code = $LASTEXITCODE
} finally {
    $env:TCL_LIBRARY = $savedLibrary
    $env:TK_LIBRARY = $savedTkLibrary
    $env:TCLVENV_INTERACTIVE = $savedInteractive
}
exit $code
}]
        writeFile [file join $bin $name.ps1] $ps
    }
}

proc ::tclvenv::activation {root {activationRoot ""}} {
    set bin [file join $root bin]
    if {$activationRoot eq ""} { set activationRoot $root }
    # POSIX sh cannot discover the path of a sourced file portably. Embed the root.
    # The name reaches PS1 through _TCLVENV_PROMPT, never as text: shells
    # expand PS1 at every prompt, so a name such as $(cmd) would run.
    set activation [string map [list @ROOT@ [shellQuote $activationRoot]] {# Source this file: . /path/to/environment/bin/activate
# Leave with tclvenv_deactivate, or deactivate unless another tool (such as
# a Python venv) already defined that name.
if [ "${_TCLVENV_ACTIVE-}" = 1 ]; then
    if command -v tclvenv_deactivate >/dev/null 2>&1; then tclvenv_deactivate; else deactivate; fi
fi
_TCLVENV_ACTIVE=1
_TCLVENV_OLD_PATH=${PATH-}
_TCLVENV_PATH_SET=${PATH+x}
_TCLVENV_OLD_ROOT=${TCLVENV-}
_TCLVENV_ROOT_SET=${TCLVENV+x}
_TCLVENV_ROOT_EXPORTED=$(/bin/sh -c 'printf %s "${TCLVENV+x}"')
_TCLVENV_OLD_PS1=${PS1-}
_TCLVENV_PS1_SET=${PS1+x}
TCLVENV=@ROOT@
PATH="$TCLVENV/bin${PATH:+:$PATH}"
export TCLVENV PATH
if [ "${PS1+x}" = x ]; then
    _TCLVENV_PROMPT=${TCLVENV##*/}
    if [ -n "${ZSH_VERSION-}" ]; then
        # zsh reads % escapes after substitution, and $ only with PROMPT_SUBST.
        eval '_TCLVENV_PROMPT=${_TCLVENV_PROMPT//\%/%%}
            if [[ -o promptsubst ]]; then PS1="(\${_TCLVENV_PROMPT}) $PS1"; else PS1="($_TCLVENV_PROMPT) $PS1"; fi'
    elif [ -n "${BASH_VERSION-}" ] && ! shopt -q promptvars 2>/dev/null; then
        eval 'PS1="(${_TCLVENV_PROMPT//\\/\\\\}) $PS1"'
    else
        PS1='(${_TCLVENV_PROMPT}) '"$PS1"
    fi
fi
tclvenv_deactivate () {
    if [ "$_TCLVENV_PATH_SET" = x ]; then PATH=$_TCLVENV_OLD_PATH; export PATH; else unset PATH; fi
    unset TCLVENV
    if [ "$_TCLVENV_ROOT_SET" = x ]; then
        TCLVENV=$_TCLVENV_OLD_ROOT
        if [ "$_TCLVENV_ROOT_EXPORTED" = x ]; then export TCLVENV; fi
    fi
    if [ "$_TCLVENV_PS1_SET" = x ]; then PS1=$_TCLVENV_OLD_PS1; else unset PS1; fi
    if [ "${_TCLVENV_OWNS_DEACTIVATE-}" = 1 ]; then
        # Remove deactivate only if it is still ours (where the shell can tell).
        case $(typeset -f deactivate 2>/dev/null || :) in
            ''|*tclvenv_deactivate*) unset -f deactivate ;;
        esac
    fi
    unset _TCLVENV_ACTIVE _TCLVENV_OLD_PATH _TCLVENV_PATH_SET _TCLVENV_PROMPT
    unset _TCLVENV_OLD_ROOT _TCLVENV_ROOT_SET _TCLVENV_ROOT_EXPORTED
    unset _TCLVENV_OLD_PS1 _TCLVENV_PS1_SET _TCLVENV_OWNS_DEACTIVATE
    hash -r 2>/dev/null || :
    unset -f tclvenv_deactivate
}
if command -v deactivate >/dev/null 2>&1; then
    _TCLVENV_OWNS_DEACTIVATE=0
    echo "tclvenv: deactivate belongs to another tool here; leave this environment with tclvenv_deactivate" >&2
else
    _TCLVENV_OWNS_DEACTIVATE=1
    # A Python venv's activate calls "deactivate nondestructive" to clear
    # its own state: that must not leave this environment.
    deactivate () {
        if [ "${1-}" = nondestructive ]; then return 0; fi
        tclvenv_deactivate
    }
fi
hash -r 2>/dev/null || :
}]
    writeFile [file join $bin activate] $activation
    writeFile [file join $bin Activate.ps1] {# Dot-source this file: . ./bin/Activate.ps1
if (Get-Variable TclVenvSaved -Scope Global -ErrorAction SilentlyContinue) { deactivate }
$global:TclVenvSaved = @{
    Path = $env:PATH
    Root = $env:TCLVENV
    Prompt = $function:prompt
}
$env:TCLVENV = Split-Path $PSScriptRoot -Parent
$env:PATH = (Join-Path $env:TCLVENV 'bin') + [IO.Path]::PathSeparator + $env:PATH
function global:prompt { "($(Split-Path $env:TCLVENV -Leaf)) " + (& $global:TclVenvSaved.Prompt) }
function global:deactivate {
    $env:PATH = $global:TclVenvSaved.Path
    $env:TCLVENV = $global:TclVenvSaved.Root
    Set-Item Function:global:prompt $global:TclVenvSaved.Prompt
    Remove-Variable TclVenvSaved -Scope Global
    Remove-Item Function:global:deactivate
}
}
    # CALL makes batch activation persist in the caller's cmd.exe session.
    writeFile [file join $bin activate.bat] [string map [list \n \r\n] {@echo off
if defined _TCLVENV_ACTIVE call "%TCLVENV%\bin\deactivate.bat"
set "_TCLVENV_OLD_PATH=%PATH%"
set "_TCLVENV_OLD_ROOT=%TCLVENV%"
set "_TCLVENV_OLD_PROMPT=%PROMPT%"
set "_TCLVENV_ACTIVE=1"
for %%I in ("%~dp0..") do set "TCLVENV=%%~fI"
set "PATH=%TCLVENV%\bin;%PATH%"
set "PROMPT=(tclvenv) %PROMPT%"
}]
    writeFile [file join $bin deactivate.bat] [string map [list \n \r\n] {@echo off
if not defined _TCLVENV_ACTIVE exit /b 0
set "PATH=%_TCLVENV_OLD_PATH%"
set "TCLVENV=%_TCLVENV_OLD_ROOT%"
set "PROMPT=%_TCLVENV_OLD_PROMPT%"
set "_TCLVENV_ACTIVE="
set "_TCLVENV_OLD_PATH="
set "_TCLVENV_OLD_ROOT="
set "_TCLVENV_OLD_PROMPT="
}]
}

proc ::tclvenv::create {root executable systemPackages} {
    variable resources
    variable version
    set root [file normalize $root]
    # PATH can't hold a directory containing its separator: activation
    # would add two wrong directories and leave the system tclsh first.
    set separator [expr {$::tcl_platform(platform) eq "windows" ? ";" : ":"}]
    if {[string first $separator [file join $root bin]] >= 0} {
        error "destination can't be activated (PATH can't hold a directory containing \"$separator\"): $root"
    }
    if {[file exists $root] || ![catch {file lstat $root st}]} {
        error "destination already exists: $root"
    }
    set executable [resolveExecutable $executable]
    set runtime [probe $executable 1]
    set coreModules [dict get $runtime core_modules]
    dict unset runtime core_modules
    # Never accidentally bind a new environment to another environment's wrapper.
    set executable [file normalize [dict get $runtime executable]]
    dict unset runtime executable
    file mkdir [file dirname $root]
    set lock $root.tclvenv-create.lock
    takeLock $lock "environment creation is locked: $lock (remove a stale lock only after checking no creation is running)"
    set stage ""
    try {
        if {![catch {file lstat $root st}]} { error "destination already exists: $root" }
        # Named after the destination: a creation killed before it finished
        # leaves its stage, which the next creation of the same destination
        # (holding the same lock) removes. Others' stages are never touched.
        set prefix .tclvenv-create-[file tail $root].stage-
        foreach leftover [glob -nocomplain -tails -directory [file dirname $root] -- .tclvenv-create-*] {
            if {[string equal -length [string length $prefix] $prefix $leftover] &&
                [regexp {^[0-9a-f]{8}$} [string range $leftover [string length $prefix] end]]} {
                set leftover [file join [file dirname $root] $leftover]
                if {![catch {file lstat $leftover st}] && $st(type) eq "directory"} {
                    file delete -force -- $leftover
                    warn "removed $leftover, left by an interrupted creation"
                }
            }
        }
        # (Only creators of this destination use the name, and they hold
        # its lock: no other process can take it between the check and mkdir.)
        for {set attempt 0} {$attempt < 100} {incr attempt} {
            set stage [file join [file dirname $root] $prefix[format %08x [expr {int(rand() * 0xffffffff)}]]]
            if {![pathExists $stage]} { break }
        }
        file mkdir $stage
        foreach name {bin lib modules metadata} { file mkdir [file join $stage $name] }
        set cfg [dict create format 1 manager_version $version executable $executable \
            runtime $runtime system_packages $systemPackages]
        writeData [file join $stage tclvenv.cfg] $cfg
        writeData [file join $stage metadata installed.tcldata] {}
        set coreRoot [file join $stage metadata core-modules]
        file mkdir $coreRoot
        dict for {relative encoded} $coreModules {
            set target [file join $coreRoot $relative]
            file mkdir [file dirname $target]
            set ch [open $target wb]
            if {[catch {puts -nonewline $ch [binary decode base64 $encoded]; close $ch} message options]} {
                catch {close $ch}
                writeError $target $message $options
            }
        }
        # The snapshot is the tool's own copy, not package data: CRC-32 is
        # enough to notice damage, and hashing it would slow every doctor.
        writeData [file join $stage metadata core-files.tcldata] [inventory $coreRoot 0]
        file copy -- [file join $resources runtime.tcl] [file join $stage metadata runtime.tcl]
        file copy -- [file join $resources manager.tcl] [file join $stage metadata manager.tcl]
        file copy -- [file join $resources core.tcl] [file join $stage metadata core.tcl]
        file copy -- [file join $resources archive.tcl] [file join $stage metadata archive.tcl]
        file copy -- [file join $resources discover.tcl] [file join $stage metadata discover.tcl]
        writeFile [file join $stage metadata manager-cli.tcl] {
source [file join [file dirname [info script]] manager.tcl]
if {[catch {::tclvenv::main $argv} message options]} {
    ::tclvenv::reportError $message $options
}
}
        launchers $stage $executable [dict get $runtime version]
        activation $stage $root
        if {![catch {file lstat $root st}]} { error "destination already exists: $root" }
        file rename -- $stage $root
        # Tcl's rename moves into an existing directory. Detect an external
        # creator winning that final race, and remove only our staged directory.
        set nested [file join $root [file tail $stage]]
        if {[file exists $nested]} {
            file delete -force -- $nested
            error "destination appeared during creation: $root"
        }
    } finally {
        if {$stage ne "" && [file exists $stage]} { file delete -force -- $stage }
        if {[catch {file delete -- $lock} message]} { warn "couldn't remove the lock file $lock: $message" }
    }
    say "Created $root (Tcl [dict get $runtime version])"
}

proc ::tclvenv::within {parent path} {
    set a [file split [file normalize $parent]]
    set b [file split [file normalize $path]]
    if {$::tcl_platform(platform) eq "windows"} {
        set a [string tolower $a]
        set b [string tolower $b]
    }
    expr {[llength $b] >= [llength $a] && [lrange $b 0 [expr {[llength $a]-1}]] eq $a}
}

proc ::tclvenv::requireDirectories {root path {create 0}} {
    set base [file split $root]
    set parts [file split $path]
    if {[lrange $parts 0 [expr {[llength $base] - 1}]] ne $base} {
        error "directory is outside the environment: $path"
    }
    set current $root
    foreach part [linsert [lrange $parts [llength $base] end] 0 ""] {
        if {$part ne ""} { set current [file join $current $part] }
        if {$create && ![pathExists $current]} { file mkdir $current }
        if {![pathExists $current] || [file type $current] ne "directory"} {
            error "unsafe environment directory: $current"
        }
    }
}

proc ::tclvenv::validateLayout {root} {
    foreach relative {bin lib modules metadata} {
        requireDirectories $root [file join $root $relative]
    }
}

proc ::tclvenv::moduleRelative {name version} {
    set parts [split [string map {:: /} $name] /]
    foreach part $parts {
        if {![regexp {^[_[:alpha:]][:_[:alnum:]]*$} $part]} {
            error "invalid module name: $name"
        }
    }
    package vcompare $version 0
    return [file join modules {*}[lrange $parts 0 end-1] [lindex $parts end]-$version.tm]
}

# SHA-256 in core Tcl. The compression procedure is generated unrolled:
# message words and working variables are locals, and the working variables
# are renamed each round rather than copied.
proc ::tclvenv::generateSha256 {} {
    set K {
        0x428a2f98 0x71374491 0xb5c0fbcf 0xe9b5dba5 0x3956c25b 0x59f111f1 0x923f82a4 0xab1c5ed5
        0xd807aa98 0x12835b01 0x243185be 0x550c7dc3 0x72be5d74 0x80deb1fe 0x9bdc06a7 0xc19bf174
        0xe49b69c1 0xefbe4786 0x0fc19dc6 0x240ca1cc 0x2de92c6f 0x4a7484aa 0x5cb0a9dc 0x76f988da
        0x983e5152 0xa831c66d 0xb00327c8 0xbf597fc7 0xc6e00bf3 0xd5a79147 0x06ca6351 0x14292967
        0x27b70a85 0x2e1b2138 0x4d2c6dfc 0x53380d13 0x650a7354 0x766a0abb 0x81c2c92e 0x92722c85
        0xa2bfe8a1 0xa81a664b 0xc24b8b70 0xc76c51a3 0xd192e819 0xd6990624 0xf40e3585 0x106aa070
        0x19a4c116 0x1e376c08 0x2748774c 0x34b0bcb5 0x391c0cb3 0x4ed8aa4a 0x5b9cca4f 0x682e6ff3
        0x748f82ee 0x78a5636f 0x84c87814 0x8cc70208 0x90befffa 0xa4506ceb 0xbef9a3f7 0xc67178f2
    }
    # (The loop's braces are escaped: they balance in the generated text.)
    set body "lassign \$state h0 h1 h2 h3 h4 h5 h6 h7\n"
    append body "set n \[string length \$data\]\n"
    append body "for {set off 0} {\$off < \$n} {incr off 64} \{\n"
    append body "binary scan \$data @\${off}Iu16 block\n"
    append body "lassign \$block w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15\n"
    for {set t 16} {$t < 64} {incr t} {
        set x w[expr {$t - 15}]
        set y w[expr {$t - 2}]
        append body "set w$t \[expr {((\$$x >> 7 | \$$x << 25) ^ (\$$x >> 18 | \$$x << 14) ^ (\$$x >> 3)) + ((\$$y >> 17 | \$$y << 15) ^ (\$$y >> 19 | \$$y << 13) ^ (\$$y >> 10)) + \$w[expr {$t - 16}] + \$w[expr {$t - 7}] & 0xffffffff}\]\n"
    }
    append body "set a \$h0; set b \$h1; set c \$h2; set d \$h3; set e \$h4; set f \$h5; set g \$h6; set h \$h7\n"
    set vars {a b c d e f g h}
    for {set t 0} {$t < 64} {incr t} {
        lassign $vars a b c d e f g h
        append body "set t1 \[expr {\$$h + ((\$$e >> 6 | \$$e << 26) ^ (\$$e >> 11 | \$$e << 21) ^ (\$$e >> 25 | \$$e << 7)) + ((\$$e & \$$f) ^ (~\$$e & \$$g)) + [lindex $K $t] + \$w$t}\]\n"
        append body "set $d \[expr {(\$$d + \$t1) & 0xffffffff}\]\n"
        append body "set $h \[expr {(\$t1 + ((\$$a >> 2 | \$$a << 30) ^ (\$$a >> 13 | \$$a << 19) ^ (\$$a >> 22 | \$$a << 10)) + ((\$$a & \$$b) ^ (\$$a & \$$c) ^ (\$$b & \$$c))) & 0xffffffff}\]\n"
        set vars [list $h $a $b $c $d $e $f $g]
    }
    # After 64 rounds (a multiple of 8) the names are back in place.
    foreach i {0 1 2 3 4 5 6 7} v {a b c d e f g h} {
        append body "set h$i \[expr {(\$h$i + \$$v) & 0xffffffff}\]\n"
    }
    append body "\}\nlist \$h0 \$h1 \$h2 \$h3 \$h4 \$h5 \$h6 \$h7\n"
    proc ::tclvenv::sha256Blocks {state data} $body
}
::tclvenv::generateSha256

proc ::tclvenv::sha256Init {} {
    dict create state {0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a 0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19} \
        pending "" length 0
}

proc ::tclvenv::sha256Update {context data} {
    dict incr context length [string length $data]
    set data "[dict get $context pending]$data"
    set full [expr {[string length $data] - [string length $data] % 64}]
    dict set context state [sha256Blocks [dict get $context state] [string range $data 0 [expr {$full - 1}]]]
    dict set context pending [string range $data $full end]
    return $context
}

proc ::tclvenv::sha256Final {context} {
    set tail "[dict get $context pending]\x80"
    append tail [string repeat \0 [expr {(56 - [string length $tail] % 64) % 64}]]
    append tail [binary format W [expr {[dict get $context length] * 8}]]
    format [string repeat %08x 8] {*}[sha256Blocks [dict get $context state] $tail]
}

# Core Tcl hashes about 1 MB/s. Files at least this large are hashed by
# sha256sum or shasum when the system has one; smaller ones in Tcl, where
# starting a process would cost more than it saves.
variable ::tclvenv::externalHashMinimum 1048576

# The external SHA-256 command as a list, or {} (looked up once).
proc ::tclvenv::sha256Command {} {
    variable sha256Command
    if {![info exists sha256Command]} {
        set sha256Command {}
        if {$::tcl_platform(platform) eq "unix"} {
            foreach candidate {sha256sum {shasum -a 256}} {
                set found [auto_execok [lindex $candidate 0]]
                if {[llength $found] == 1} {
                    set sha256Command [list [lindex $found 0] {*}[lrange $candidate 1 end]]
                    break
                }
            }
        }
    }
    return $sha256Command
}

# path's SHA-256 from the external command, or "" when there is none or it
# fails (the caller then hashes in Tcl). The file is given as an open
# channel, so no name is ever parsed by exec or the command.
proc ::tclvenv::externalSha256 {path} {
    set command [sha256Command]
    if {![llength $command]} { return "" }
    set ch [open $path rb]
    try {
        if {[catch {exec -- {*}$command <@ $ch} output] ||
            ![regexp {^([0-9a-f]{64})\s} $output -> hash]} { return "" }
        return $hash
    } finally { close $ch }
}

# A path component as written: Tcl 8.6 returns a leading ~ as ./~.
proc ::tclvenv::plainName {name} {
    if {[string match ./~* $name]} { return [string range $name 2 end] }
    return $name
}

# A relative inventory path ("a/b/~c") as one Tcl can join: a component
# starting with ~ is written ./~, so Tcl 8.6 doesn't take it for a home
# directory.
proc ::tclvenv::protect {relative} {
    # (Not expr's ?:, which returns a name such as 007 or 0x10 as a number.)
    join [lmap part [split $relative /] {
        if {[string match ~* $part]} { string cat ./ $part } else { set part }
    }] /
}

proc ::tclvenv::children {directory} {
    set result {}
    foreach path [glob -nocomplain -directory $directory -- * .*] {
        if {[file tail $path] ni {. ..}} { lappend result $path }
    }
    return [lsort -unique $result]
}

# A file's record: size and CRC-32, its modification time, and (unless
# hash is 0) its SHA-256. The hash is what detects changed content; CRC-32
# can be kept by a deliberate change, and mtime can be set back. mtime is
# recorded for diagnostics: comparisons ignore its value, so writing the
# original bytes back makes a file unchanged again.
proc ::tclvenv::fileInfo {path {hash 1}} {
    variable externalHashMinimum
    file lstat $path st
    if {$st(type) ne "file"} { error "expected a regular file: $path" }
    # A large file's hash comes from the external command, if there is one.
    set inTcl [expr {$hash && ($st(size) < $externalHashMinimum || ![llength [sha256Command]])}]
    set ch [open $path rb]
    try {
        set crc 0
        set size 0
        set context [sha256Init]
        while {![eof $ch]} {
            set data [read $ch 65536]
            incr size [string length $data]
            set crc [zlib crc32 $data $crc]
            if {$inTcl} { set context [sha256Update $context $data] }
        }
    } on error {message options} {
        archive::nameChannel $ch $path $message $options
    } finally { close $ch }
    set result [dict create type file size $size crc32 [format %08x $crc] mtime $st(mtime)]
    if {$inTcl} {
        dict set result sha256 [sha256Final $context]
    } elseif {$hash} {
        dict set result sha256 [fileSha256 $path]
    }
    return $result
}

# Records of every file and directory under path, keyed by relative paths
# written with / and plain names (no ./ before a ~).
proc ::tclvenv::inventory {path {hash 1} {relative ""}} {
    switch -- [file type $path] {
        file { return [dict create $relative [fileInfo $path $hash]] }
        directory {
            set result [dict create $relative [dict create type directory]]
            foreach child [children $path] {
                set name [plainName [file tail $child]]
                # (Not expr's ?:, which returns a name such as 007 or 0x10
                # as a number: 7, 16.)
                if {$relative eq ""} { set sub $name } else { set sub $relative/$name }
                dict for {key value} [inventory $child $hash $sub] {
                    dict set result $key $value
                }
            }
            return $result
        }
        default { error "symlinks and special files are not supported: $path" }
    }
}

proc ::tclvenv::pathExists {path} {
    # Unlike file exists, lstat also notices dangling symlinks.
    expr {![catch {file lstat $path stat}]}
}

proc ::tclvenv::makeStage {root prefix} {
    requireDirectories $root [file join $root metadata]
    set ch [file tempfile path [file join $root metadata $prefix-]]
    close $ch
    file delete -- $path
    file mkdir $path
    return $path
}

proc ::tclvenv::makeWritable {path} {
    if {[file type $path] ne "directory"} { return }
    if {$::tcl_platform(platform) eq "unix"} {
        file attributes $path -permissions u+rwx
    }
}

proc ::tclvenv::sameNode {path expected} {
    if {[catch {file lstat $path actual}]} { return 0 }
    foreach key {type dev ino} {
        if {$actual($key) ne [dict get $expected $key]} { return 0 }
    }
    return 1
}

proc ::tclvenv::checkDeletionParents {} {
    variable deletionParents
    foreach parent $deletionParents {
        lassign $parent path identity
        if {![sameNode $path $identity]} { error "directory changed during cleanup: $path" }
    }
}

proc ::tclvenv::withDeletionPlan {root files script} {
    variable deletionRoot
    variable deletionFiles
    set saved [list $deletionRoot $deletionFiles]
    set deletionRoot $root
    set deletionFiles $files
    try { uplevel 1 $script } finally { lassign $saved deletionRoot deletionFiles }
}

proc ::tclvenv::deleteOwned {path} {
    variable mutationRoot
    variable deletionRoot
    variable deletionFiles
    variable deletionParents
    checkDeletionParents
    if {$mutationRoot ne ""} { requireDirectories $mutationRoot [file dirname $path] }
    if {![pathExists $path]} { return }
    file lstat $path st
    set identity [array get st]
    if {$deletionRoot ne ""} {
        set base [file split $deletionRoot]
        set parts [file split $path]
        if {[lrange $parts 0 [expr {[llength $base] - 1}]] ne $base} {
            error "cleanup escaped its recorded payload: $path"
        }
        set suffix [lmap part [lrange $parts [llength $base] end] {plainName $part}]
        set relative [join $suffix /]
        if {![dict exists $deletionFiles $relative] ||
            [dict get $deletionFiles $relative type] ne $st(type)} {
            error "unrecorded or changed staged file; refusing to delete: $path"
        }
        # The full comparison, hash included, has just been made; this
        # recheck at the moment of deletion compares size and CRC-32.
        if {$st(type) eq "file"} {
            set recorded [dict get $deletionFiles $relative]
            set now [fileInfo $path 0]
            foreach field {size crc32} {
                if {![dict exists $recorded $field] || [dict get $recorded $field] ne [dict get $now $field]} {
                    error "staged file changed during cleanup: $path"
                }
            }
        }
    }
    if {$st(type) eq "directory"} {
        makeWritable $path
        checkDeletionParents
        if {![sameNode $path $identity]} { error "directory changed during cleanup: $path" }
        lappend deletionParents [list $path $identity]
        try {
            foreach child [children $path] { deleteOwned $child }
        } finally { set deletionParents [lrange $deletionParents 0 end-1] }
    }
    checkDeletionParents
    if {![sameNode $path $identity]} { error "file changed during cleanup: $path" }
    if {$::tcl_platform(platform) eq "windows" && [file type $path] in {file directory}} {
        file attributes $path -readonly 0
    }
    file delete -- $path
}

proc ::tclvenv::moveExclusive {source destination} {
    variable mutationRoot
    if {$mutationRoot ne ""} {
        requireDirectories $mutationRoot [file dirname $source]
        requireDirectories $mutationRoot [file dirname $destination]
    }
    if {[pathExists $destination]} { error "destination already exists: $destination" }
    set kind [file type $source]
    set marker ""
    set markerPath ""
    if {$kind eq "directory"} {
        # A unique marker identifies the moved directory even on filesystems
        # whose Tcl stat implementation supplies no inode/file identifier.
        makeWritable $source
        set ch [openTemporary $source markerPath .tclvenv-move]
        close $ch
        set marker [file tail $markerPath]
    }
    try {
        if {$mutationRoot ne ""} {
            requireDirectories $mutationRoot [file dirname $source]
            requireDirectories $mutationRoot [file dirname $destination]
        }
        file rename -- $source $destination
        set nested [file join $destination [file tail $source]]
        if {$kind eq "directory"} {
            if {[pathExists [file join $destination $marker]]} {
                set markerPath [file join $destination $marker]
                return
            }
            set markerPath [file join $nested $marker]
        } elseif {[file type $destination] eq $kind} {
            return
        }
        # Tcl renamed into an independently created directory. Restore our
        # object, leaving that directory and every unrelated file untouched.
        if {[pathExists $source]} {
            error "destination changed; staged package retained at $nested"
        }
        file rename -- $nested $source
        if {$marker ne ""} { set markerPath [file join $source $marker] }
        error "destination appeared during move: $destination"
    } finally {
        if {$markerPath ne "" && [pathExists $markerPath]} { file delete -- $markerPath }
    }
}

proc ::tclvenv::sameInventory {expected actual {allowMissing 0}} {
    if {!$allowMissing && [dict size $expected] != [dict size $actual]} { return 0 }
    dict for {path info} $actual {
        if {![dict exists $expected $path]} { return 0 }
        set expectedInfo [dict get $expected $path]
        if {[dict size $expectedInfo] != [dict size $info]} { return 0 }
        dict for {field value} $info {
            if {![dict exists $expectedInfo $field]} { return 0 }
            # The content (size, CRC-32, SHA-256) decides; see fileInfo.
            if {$field ne "mtime" && [dict get $expectedInfo $field] ne $value} { return 0 }
        }
    }
    return 1
}

proc ::tclvenv::withLock {root script} {
    validateLayout $root
    variable mutationRoot
    set path [file join $root metadata mutation.lock]
    takeLock $path "environment is locked: $path (remove a stale lock only after checking no installer is running)"
    set previous $mutationRoot
    set mutationRoot $root
    try {
        # What an interrupted command left (its process killed) is finished
        # or undone first; what can't be is reported and left alone.
        foreach problem [recoverStages $root] { warn $problem }
        uplevel 1 $script
    } finally {
        try {
            releaseLock $root $path
        } on error {message} {
            # The command's work is done (or its own error is on its way): a
            # lock left behind is reported, not made the command's outcome.
            # A later command takes it over once this process has exited.
            warn "couldn't remove the lock file $path: $message"
        } finally { set mutationRoot $previous }
    }
}

proc ::tclvenv::releaseLock {root path} {
    requireDirectories $root [file join $root metadata]
    file delete -- $path
}

# --- Recovery of interrupted operations -------------------------------------
#
# Each operation stages its work in metadata/stage-* (install) or
# metadata/remove-* (removal) with a journal, transaction.tcldata, written
# before anything public changes. A process killed partway leaves the stage.
# Under the mutation lock no such process is running, so each stage is
# brought to a safe end: an install that wasn't committed (no receipt) is
# undone, one that was is kept; a removal that wasn't committed (receipt
# still "installed") is undone; a committed removal (receipt "removing") is
# left for "remove" to finish, as before. Nothing is deleted that isn't
# provably the operation's own: payload files must match the journal, and a
# stage holding anything else is left, with a message saying why.

# Recovers every stage; returns messages about what couldn't be recovered.
proc ::tclvenv::recoverStages {root} {
    set metadata [file join $root metadata]
    set problems {}
    # Temporary files writeData was writing when its process died (only the
    # lock holder writes here, and that is now this process).
    foreach leftover [glob -nocomplain -directory $metadata -- {*}[leftoverPatterns temporary]] {
        if {![catch {file lstat $leftover st}] && $st(type) eq "file"} { file delete -- $leftover }
    }
    set stages [glob -nocomplain -directory $metadata -- stage-* remove-*]
    if {![llength $stages]} { return {} }
    set records [installed $root]
    set pending {}
    dict for {id record} $records {
        if {[dict exists $record stage]} { lappend pending [dict get $record stage] }
    }
    foreach stage [lsort $stages] {
        if {[file tail $stage] in $pending} { continue }
        if {[catch {recoverStage $root $stage $records} message]} {
            lappend problems "couldn't recover the interrupted operation in $stage ($message); see doctor"
        } elseif {$message ne ""} {
            say $message
        }
        # A recovered install may have been undone: read the receipts again.
        set records [installed $root]
    }
    return $problems
}

# Brings one stage to a safe end; returns what was done ("" if nothing to
# report), or raises an error leaving the rest of the stage in place.
proc ::tclvenv::recoverStage {root stage records} {
    if {[catch {file lstat $stage st}] || $st(type) ne "directory"} { error "not a directory" }
    set install [string match stage-* [file tail $stage]]
    # Temporary files of the journal's own write.
    foreach leftover [glob -nocomplain -directory $stage -- {*}[leftoverPatterns temporary]] {
        if {![catch {file lstat $leftover st}] && $st(type) eq "file"} { file delete -- $leftover }
    }
    set journal [file join $stage transaction.tcldata]
    set payload [file join $stage payload]
    set contents [lmap child [children $stage] {file tail $child}]
    if {"transaction.tcldata" ni $contents} {
        # Killed before its journal: an install still copying its source
        # (only "payload", unrecorded), or a removal before it moved anything.
        if {![llength $contents]} {
            file delete -- $stage
            return ""
        }
        if {$install && $contents eq "payload"} {
            deleteOwned $payload
            file delete -- $stage
            return "Discarded an install interrupted while copying ([file tail $stage])"
        }
        error "it has no journal and holds unrecorded files: [join $contents {, }]"
    }
    foreach name $contents {
        if {$name ni {payload transaction.tcldata}} { error "unexpected file in the stage: $name" }
    }
    # An install's journal is {id target files}; a removal's is the receipt
    # as it was before the removal, which names its target, not its ID.
    if {[catch {
        set tx [readData $journal]
        set target [dict get $tx target]
        set id [expr {$install ? [dict get $tx id] : "journal"}]
        validateRecords $root [dict create $id $tx]
    }]} { error "invalid journal" }
    if {!$install} {
        set id ""
        dict for {key record} $records {
            if {[dict get $record target] eq $target} { set id $key }
        }
    }
    set destination [file join $root $target]
    if {$install} {
        set files [dict get $tx files]
        set committed [expr {[dict exists $records $id] && [dict get $records $id target] eq $target}]
        stripMoveMarkers $payload $files
        if {$committed} {
            stripMoveMarkers $destination [dict get $records $id files]
            if {[pathExists $payload]} { error "the package is installed and its staged copy remains" }
            set done ""
        } elseif {[pathExists $payload]} {
            # Never published (or already moved back).
            discardPayload $payload $files
            set done "Undid an interrupted install of $id"
        } elseif {[pathExists $destination]} {
            # Published, but killed before its receipt was written.
            stripMoveMarkers $destination $files
            if {[catch {inventory $destination} now] || ![sameInventory $files $now]} {
                error "$target is not what the interrupted install published; it was left in place"
            }
            moveExclusive $destination $payload
            discardPayload $payload $files
            set done "Undid an interrupted install of $id"
        } else {
            set done ""
        }
    } else {
        if {$id eq ""} {
            # The removal was committed and its payload deleted; only its
            # journal remained.
            if {[pathExists $payload]} { error "the package's receipt is gone but its staged files remain" }
            set done ""
        } else {
            set record [dict get $records $id]
            set files [dict get $record files]
            if {![sameInventory $files [dict get $tx files]]} { error "the journal doesn't match the receipt of $id" }
            stripMoveMarkers $payload $files
            stripMoveMarkers $destination $files
            if {[pathExists $payload]} {
                # Detached, but killed before the receipt said "removing":
                # the removal wasn't committed, so the package goes back.
                if {[pathExists $destination]} { error "both $target and its staged copy exist" }
                if {[catch {inventory $payload} now] || ![sameInventory $files $now]} { error "the staged files changed" }
                requireDirectories $root [file dirname $destination] 1
                moveExclusive $payload $destination
                set done "Restored $id after an interrupted removal"
            } else {
                set done ""
            }
        }
    }
    file delete -- $journal
    file delete -- $stage
    return $done
}

# Deletes payload, which must hold exactly the journal's files.
proc ::tclvenv::discardPayload {payload files} {
    if {[catch {inventory $payload} now] || ![sameInventory $files $now]} { error "the staged files changed" }
    withDeletionPlan $payload $files { deleteOwned $payload }
}

# moveExclusive leaves an empty .tclvenv-move-* marker in the directory it
# moves while it runs: a process killed then leaves it behind. Removes such
# markers at path's top level unless files records them.
proc ::tclvenv::stripMoveMarkers {path files} {
    if {[catch {file lstat $path st}] || $st(type) ne "directory"} { return }
    foreach marker [glob -nocomplain -directory $path -- {*}[leftoverPatterns marker]] {
        if {[dict exists $files [file tail $marker]]} { continue }
        if {![catch {file lstat $marker st}] && $st(type) eq "file" && $st(size) == 0} {
            file delete -- $marker
        }
    }
}

# recover ENV: finishes or undoes what interrupted commands left (any
# mutation command also does this first); fails if something couldn't be.
proc ::tclvenv::recover {root} {
    config $root
    set problems {}
    withLock $root {
        # (withLock has recovered already; check what remains.)
        set pending {}
        dict for {id record} [installed $root] {
            if {[dict exists $record stage]} {
                lappend pending [dict get $record stage]
                lappend problems "unfinished removal of $id: run remove [list $root] [list $id]"
            }
        }
        foreach stage [glob -nocomplain -directory [file join $root metadata] -- stage-* remove-*] {
            if {[file tail $stage] ni $pending} { lappend problems "left in place: $stage" }
        }
    }
    if {[llength $problems]} { error "not everything could be recovered: [join $problems {; }]" }
    say "Nothing left to recover in $root"
}

proc ::tclvenv::installed {root} {
    validateRecords $root [readData [file join $root metadata installed.tcldata]]
}

# Checks receipts (or a journal) before any operation trusts recorded paths.
proc ::tclvenv::validateRecords {root records} {
    set targets {}
    # Validate ownership boundaries before any operation trusts recorded paths.
    dict for {id record} $records {
        set target [dict get $record target]
        set parts [file split $target]
        if {[file pathtype $target] ne "relative" ||
            [lindex $parts 0] ni {lib modules} ||
            [llength $parts] < 2 || "." in $parts || ".." in $parts ||
            ([lindex $parts 0] eq "lib" && [llength $parts] != 2) ||
            ([lindex $parts 0] eq "modules" && [file extension $target] ne ".tm") ||
            ![within $root [file join $root $target]]} {
            error "invalid installed-package target: $target"
        }
        dict for {relative info} [dict get $record files] {
            set safe [protect $relative]
            if {[file pathtype $safe] ne "relative" || ".." in [split $relative /] ||
                ![within [file join $root $target] [file join $root $target $safe]]} {
                error "invalid installed-file path: $relative"
            }
        }
        if {[dict exists $record state] && [dict get $record state] ne "installed"} {
            if {[dict get $record state] ne "removing"} { error "invalid package state: $id" }
            set stage [dict get $record stage]
            if {[file pathtype $stage] ne "relative" || [llength [file split $stage]] != 1 ||
                ![string match remove-* $stage] ||
                ![within [file join $root metadata] [file join $root metadata $stage]]} {
                error "invalid removal staging path: $stage"
            }
            # One lstat: a removal finishing concurrently may delete it.
            if {![catch {file lstat [file join $root metadata $stage] stageStat}] &&
                $stageStat(type) ne "directory"} {
                error "invalid removal staging directory: $stage"
            }
        }
        set normalized [file normalize [file join $root $target]]
        if {$::tcl_platform(platform) eq "windows"} { set normalized [string tolower $normalized] }
        if {[dict exists $targets $normalized]} { error "multiple packages own the same target: $target" }
        dict set targets $normalized $id
        set files [dict get $record files]
        set kind [expr {[lindex $parts 0] eq "modules" ? "file" : "directory"}]
        if {![dict exists $files {} type] || [dict get $files {} type] ne $kind} {
            error "invalid installed-package inventory shape: $target"
        }
        if {$kind eq "file" && [dict size $files] != 1} { error "invalid module inventory: $target" }
        if {(![dict exists $record state] || [dict get $record state] eq "installed") &&
            [pathExists [file join $root $target]] && [file type [file join $root $target]] ne $kind} {
            error "installed-package type changed: $target"
        }
    }
    return $records
}

# Installs a directory with a pkgIndex.tcl or a NAME-VERSION.tm, copying it
# into the environment, and returns its installation ID. origin is recorded
# in the receipt; name, if given, replaces a directory's basename (an archive
# whose top level is the package).
proc ::tclvenv::installTree {root source {origin {}} {name {}}} {
    config $root
    if {[file type $source] eq "link"} { error "package source cannot be a symlink" }
    set source [file normalize $source]
    if {[within $root $source] || [within $source $root]} {
        error "package source and environment must be separate directories"
    }
    set tail [file tail $source]
    if {$name ne ""} { set tail $name }
    if {[file isdirectory $source]} {
        if {![file isfile [file join $source pkgIndex.tcl]]} {
            error "package directory must contain pkgIndex.tcl"
        }
        # The ID is the name as written (Tcl 8.6 writes ~x as ./~x).
        set id [plainName $tail]
        if {[string match .* $id]} {
            error "package directory names starting with \".\" are never found by Tcl's package search: $id"
        }
        set target [file join lib $tail]
    } elseif {[regexp {^([_[:alpha:]][:_[:alnum:]]*)-([[:digit:]].*)\.tm$} $tail -> name version]} {
        set id "$name@$version"
        set target [moduleRelative $name $version]
        if {[llength [file split $target]] < 2 || ".." in [file split $target]} {
            error "invalid module filename: $tail"
        }
    } else {
        error "expected a directory containing pkgIndex.tcl or a NAME-VERSION.tm file"
    }
    withLock $root {
        set records [installed $root]
        set destination [file join $root $target]
        if {[dict exists $records $id] || [pathExists $destination]} {
            error "package already installed or destination exists: $id"
        }
        # Validate the source tree before copying; indexes are never executed
        # here. (Only its shape: the copy's own records are the full ones.)
        inventory $source 0
        set stage [makeStage $root stage]
        set payload [file join $stage payload]
        set cleanup 1
        try {
            file copy -- $source $payload
            makeWritable $payload
            set files [inventory $payload]
            writeData [file join $stage transaction.tcldata] \
                [dict create id $id target $target files $files]
            requireDirectories $root [file dirname $destination] 1
            if {[catch {moveExclusive $payload $destination} message options]} {
                if {![pathExists $payload]} {
                    set cleanup 0
                    error "$message; recovery journal: $stage"
                }
                return -options $options $message
            }
            dict set records $id [dict create target $target source $source files $files state installed]
            if {[dict size $origin]} { dict set records $id origin $origin }
            try {
                writeData [file join $root metadata installed.tcldata] $records
            } on error {message options} {
                # Detach first; never recursively delete a public path. If it
                # changed, preserve it and the journal for explicit recovery.
                if {[catch {
                    moveExclusive $destination $payload
                    if {![sameInventory $files [inventory $payload]]} {
                        moveExclusive $payload $destination
                        error "published files changed"
                    }
                } rollback]} {
                    set cleanup 0
                    error "$message; rollback incomplete ($rollback); recovery journal: $stage"
                }
                return -options $options $message
            }
        } finally {
            # Tidying, after a commit or on the way out with another error:
            # its failure is reported, never made the outcome (an installed
            # package must not be reported as a failed install). The next
            # command's recovery deals with what remains.
            if {$cleanup && [catch {deleteOwned $stage} message]} {
                warn "couldn't remove the staging directory $stage: $message"
            }
        }
    }
    return $id
}

# --- Package sources: directories, archives, URLs, system packages ------------

# A new private directory outside any environment, for downloads and
# extracted archives.
proc ::tclvenv::privateDirectory {} {
    set ch [file tempfile path]
    close $ch
    file delete -- $path
    file mkdir $path
    if {$::tcl_platform(platform) eq "unix"} { file attributes $path -permissions 0700 }
    return $path
}

proc ::tclvenv::removePrivate {path} {
    if {![pathExists $path]} { return }
    if {[file type $path] eq "directory"} {
        makeWritable $path
        foreach child [children $path] { removePrivate $child }
    }
    file delete -- $path
}

proc ::tclvenv::fileSha256 {path} {
    variable externalHashMinimum
    if {[file size $path] >= $externalHashMinimum} {
        set hash [externalSha256 $path]
        if {$hash ne ""} { return $hash }
    }
    set ch [open $path rb]
    try {
        set context [sha256Init]
        while {![eof $ch]} { set context [sha256Update $context [read $ch 65536]] }
        return [sha256Final $context]
    } on error {message options} {
        archive::nameChannel $ch $path $message $options
    } finally { close $ch }
}

proc ::tclvenv::checkSha256 {path expected} {
    set expected [string tolower $expected]
    if {![regexp {^[0-9a-f]{64}$} $expected]} { error "--sha256 must be 64 hexadecimal digits" }
    set actual [fileSha256 $path]
    if {$actual ne $expected} { error "SHA-256 mismatch: expected $expected, got $actual" }
    return $actual
}

# A download fails when no data arrives for downloadIdle ms, or when it
# takes longer than downloadLimit ms in all (redirects included), whichever
# tool fetches it. curl is preferred to wget.
namespace eval ::tclvenv {
    variable downloadIdle 120000
    variable downloadLimit 600000
    variable externalTools {curl wget}
}

# Downloads url to file: Tcl's http (with TLS for https when the tls package
# loads), else curl or wget. Redirects (up to 5), the timeouts above and the
# archive size limit apply. The body is saved as sent, as curl and wget save it: a
# -handler reads it (so http asks for no compression, decodes none, and
# speaks HTTP/1.0), stopping at Content-Length. (With -channel, http
# decodes a Content-Encoding, which servers such as Apache's AddEncoding
# put on a .tar.gz itself, and copies on past Content-Length.)
proc ::tclvenv::download {url file} {
    variable downloadLimit
    variable downloadDeadline [expr {[clock milliseconds] + $downloadLimit}]
    try {
        downloadWithinDeadline $url $file
    } finally { unset -nocomplain downloadDeadline }
}

proc ::tclvenv::downloadWithinDeadline {url file} {
    variable downloadIdle
    variable downloadDeadline
    set limit [archive::limit]
    package require http
    if {![string match -nocase https://* $url] || [haveTls]} {
        for {set hops 0} {$hops < 6} {incr hops} {
            # A redirect may lead to https: without tls, curl or wget
            # takes it from here (following any further redirects).
            if {[string match -nocase https://* $url]} {
                if {![haveTls]} { return [downloadExternal $url $file $limit] }
                ::http::register https 443 [list ::tls::socket -autoservername 1]
            }
            variable downloadTooBig 0
            set ch [open $file wb]
            # (An error from the handler comes out of geturl itself.)
            # (http's -timeout covers the whole request; downloadBody
            # restarts it as data arrives, so it is an idle timeout.)
            set failed [catch {::http::geturl $url -binary 1 \
                -timeout [expr {max(1, min($downloadIdle, $downloadDeadline - [clock milliseconds]))}] \
                -handler [list ::tclvenv::downloadBody $ch $limit]} token]
            # A write the handler made fails at the latest when the file closes.
            if {[catch {close $ch} message options]} { archive::nameChannel $ch $file $message $options }
            if {$failed} { set token [string map [list "\"$ch\"" "\"$file\""] $token] }
            if {$downloadTooBig} { error "download exceeds the size limit: $url" }
            if {$failed} { error "download failed ($token): $url" }
            try {
                set status [::http::status $token]
                set code [::http::ncode $token]
                set meta [::http::meta $token]
            } finally { ::http::cleanup $token }
            if {$downloadTooBig || [file size $file] > $limit} {
                error "download exceeds the size limit: $url"
            }
            if {$status ne "ok"} { error "download failed ($status): $url" }
            if {$code in {301 302 303 307 308}} {
                set location ""
                dict for {key value} $meta {
                    if {[string equal -nocase $key location]} { set location $value }
                }
                if {$location eq ""} { error "redirect without a location: $url" }
                set url [resolveUrl $url $location]
                if {![regexp -nocase {^https?://} $url]} { error "redirect to an unsupported URL: $url" }
                continue
            }
            if {$code != 200} { error "download failed (HTTP $code): $url" }
            return
        }
        error "too many redirects: $url"
    }
    downloadExternal $url $file $limit
}

# Whether https can be fetched with Tcl's http (the tls package loads).
proc ::tclvenv::haveTls {} {
    expr {![catch {package require tls}]}
}

# location (a redirect's Location) resolved against url: absolute,
# protocol-relative (//host/path), absolute-path (/path), relative, a query
# (?q) or a fragment (#f, which keeps the query), with "." and ".."
# segments removed (RFC 3986).
proc ::tclvenv::resolveUrl {url location} {
    if {[regexp -nocase {^[a-z][a-z0-9+.-]*:} $location]} { return $location }
    if {![regexp {^([^:/?#]+:)(//[^/?#]*)?([^?#]*)(\?[^#]*)?} $url -> scheme authority path query]} { return $location }
    if {[string match #* $location]} { return $scheme$authority$path$query$location }
    if {[string match {[?]*} $location]} { return $scheme$authority$path$location }
    if {[string match //* $location]} {
        # Another host: its path (if any) has its dot segments removed too.
        regexp {^(//[^/?#]*)(.*)$} $location -> authority location
    } elseif {![string match /* $location]} {
        set location [string range $path 0 [string last / $path]]$location
        if {![string match /* $location]} { set location /$location }
    }
    regexp {^([^?#]*)(.*)$} $location -> target suffix
    if {$target eq ""} { return $scheme$authority$suffix }
    set segments {}
    set parts [split $target /]
    foreach part [lrange $parts 1 end] {
        if {$part eq ".."} {
            set segments [lrange $segments 0 end-1]
        } elseif {$part ne "."} {
            lappend segments $part
        }
    }
    # A path ending in . or .. names a directory.
    if {[lindex $parts end] in {. ..}} { lappend segments "" }
    return $scheme$authority/[join $segments /]$suffix
}

# Downloads url with curl or wget, which follow redirects themselves. The
# tool runs under watch: it is stopped once the file passes the size limit
# or the overall deadline passes (wget has neither limit of its own).
proc ::tclvenv::downloadExternal {url file limit} {
    variable downloadIdle
    variable downloadLimit
    variable downloadDeadline
    variable externalTools
    # (Set by download; a direct call gets a deadline of its own.)
    if {![info exists downloadDeadline]} {
        set downloadDeadline [expr {[clock milliseconds] + $downloadLimit}]
        try {
            return [downloadExternal $url $file $limit]
        } finally { unset -nocomplain downloadDeadline }
    }
    set seconds [expr {max(1, $downloadIdle / 1000)}]
    set command ""
    foreach tool $externalTools {
        if {[auto_execok $tool] eq ""} { continue }
        switch -- $tool {
            curl {
                set left [expr {max(1, ($downloadDeadline - [clock milliseconds] + 999) / 1000)}]
                set command [list curl -fsSL --max-redirs 5 --max-time $left --max-filesize $limit \
                    --speed-limit 1 --speed-time $seconds -o $file -- $url]
            }
            wget { set command [list wget -q --max-redirect=5 -T $seconds -O $file -- $url] }
        }
        break
    }
    if {$command eq ""} { error "https needs the tls package, curl or wget: $url" }
    set status [watchDownload $command $file $limit $url]
    if {[file size $file] > $limit || ([lindex $command 0] eq "curl" && $status == 63)} {
        error "download exceeds the size limit: $url"
    }
    if {[lindex $command 0] eq "curl" && $status == 28} { error "download took longer than allowed: $url" }
    if {$status != 0} { error "download failed ([lindex $command 0] exit status $status): $url" }
}

# Runs a download command (its output discarded), stopping it when file
# grows past limit or the download deadline passes; returns its exit status.
proc ::tclvenv::watchDownload {command file limit url} {
    variable downloadDeadline
    variable watch
    array unset watch
    array set watch {done ""}
    set ch [open |[concat $command [list 2>@1]] r]
    set pids [pid $ch]
    fconfigure $ch -blocking 0 -translation binary
    fileevent $ch readable [list ::tclvenv::watchRead $ch]
    watchPoll $file $limit
    vwait ::tclvenv::watch(done)
    after cancel $watch(timer)
    fileevent $ch readable {}
    if {$watch(done) ne "eof"} {
        killProcesses $pids
        catch {close $ch}
        if {$watch(done) eq "toolarge"} { error "download exceeds the size limit: $url" }
        error "download took longer than allowed: $url"
    }
    # Its output has ended: wait for its exit status.
    fconfigure $ch -blocking 1
    if {[catch {close $ch} message options]} {
        set code [dict get $options -errorcode]
        if {[lindex $code 0] eq "CHILDSTATUS"} { return [lindex $code 2] }
        return -options $options $message
    }
    return 0
}

proc ::tclvenv::watchRead {ch} {
    variable watch
    if {[catch {read $ch}] || [eof $ch]} { set watch(done) eof }
}

proc ::tclvenv::watchPoll {file limit} {
    variable watch
    variable downloadDeadline
    if {$watch(done) ne ""} { return }
    if {![catch {file size $file} size] && $size > $limit} {
        set watch(done) toolarge
    } elseif {[clock milliseconds] > $downloadDeadline} {
        set watch(done) timeout
    } else {
        set watch(timer) [after 100 [list ::tclvenv::watchPoll $file $limit]]
        return
    }
    set watch(timer) ""
}

# http's -handler: reads the next piece of the body from sock to out, no
# further than Content-Length; returns the bytes read. Over the limit (or
# announced as over it) it stops the transfer with an error.
proc ::tclvenv::downloadBody {out limit sock token} {
    variable downloadTooBig
    variable downloadIdle
    variable downloadDeadline
    upvar #0 $token state
    set size 65536
    if {$state(totalsize) > 0} {
        set size [expr {min($size, $state(totalsize) - $state(currentsize))}]
    }
    set data [read $sock $size]
    if {$state(totalsize) > $limit || $state(currentsize) + [string length $data] > $limit} {
        set downloadTooBig 1
        error "download exceeds the size limit"
    }
    puts -nonewline $out $data
    # Data arrived: restart http's timer, never past the overall deadline.
    set left [expr {$downloadDeadline - [clock milliseconds]}]
    if {$left <= 0} { error "download took longer than allowed" }
    if {[info exists state(after)]} {
        after cancel $state(after)
        set state(after) [after [expr {min($downloadIdle, $left)}] [list ::http::reset $token timeout]]
    }
    string length $data
}

# The package in an extracted archive: {path name}, where name is set when
# the archive's top level is the package (named after the archive).
proc ::tclvenv::packageIn {directory archiveName subdir} {
    set base [regsub -nocase {(\.tar\.gz|\.tgz|\.tar|\.zip)$} $archiveName ""]
    if {$subdir ne ""} {
        set path [file join $directory {*}[archive::components $subdir]]
        if {![file isfile [file join $path pkgIndex.tcl]] && ![string match *.tm $path]} {
            error "--subdir names no package directory or module in the archive: $subdir"
        }
        return [list $path ""]
    }
    if {[file isfile [file join $directory pkgIndex.tcl]]} { return [list $directory $base] }
    set candidates {}
    set queue [list [list $directory 0]]
    for {set i 0} {$i < [llength $queue]} {incr i} {
        lassign [lindex $queue $i] dir depth
        foreach child [children $dir] {
            if {[file type $child] eq "directory"} {
                if {[file isfile [file join $child pkgIndex.tcl]]} {
                    lappend candidates $child
                } elseif {$depth < 2} {
                    lappend queue [list $child [expr {$depth + 1}]]
                }
            } elseif {$depth == 0 && [string match *.tm $child]} {
                lappend candidates $child
            }
        }
    }
    if {[llength $candidates] == 1} { return [list [lindex $candidates 0] ""] }
    if {![llength $candidates]} { error "no package directory (with pkgIndex.tcl) or module in the archive" }
    set names [lmap c $candidates {string range $c [string length $directory]+1 end}]
    error "the archive holds several packages; choose one with --subdir: [join $names {, }]"
}

# Package names a directory or module registers or provides (read, never
# run): package ifneeded in pkgIndex.tcl; for a module, its name, with the
# namespace its place under modules/ gives (relative: its receipt target).
proc ::tclvenv::providedNames {path {relative ""}} {
    set names {}
    if {[regexp {^modules/(.+)-[[:digit:]][^/]*\.tm$} $relative -> stem]} {
        return [list [string map {/ ::} $stem]]
    }
    if {[file isdirectory $path]} {
        set index [file join $path pkgIndex.tcl]
        if {[file isfile $index]} {
            foreach {- name} [regexp -all -inline {package\s+ifneeded\s+([[:alpha:]_][[:alnum:]_:]*)} [readText $index 1048576]] {
                lappend names $name
            }
        }
    } elseif {[regexp {^([_[:alpha:]][:_[:alnum:]]*)-[[:digit:]].*\.tm$} [file tail $path] -> name]} {
        lappend names $name
    }
    lsort -unique $names
}

# Package names the Tcl files under path require (read, never run): literal
# names after package require. Lazy or computed requires aren't seen.
proc ::tclvenv::requiredNames {path} {
    set names {}
    set queue [list $path]
    for {set i 0} {$i < [llength $queue]} {incr i} {
        set item [lindex $queue $i]
        if {[file isdirectory $item]} {
            lappend queue {*}[children $item]
        } elseif {[regexp {\.(tcl|tm)$} $item] && [file size $item] < 4194304} {
            set text [readText $item 4194304]
            foreach {- name} [regexp -all -inline {package\s+require\s+(?:-exact\s+)?([[:alpha:]_][[:alnum:]_:]*)} $text] {
                lappend names $name
            }
        }
    }
    lsort -unique $names
}

# Runs a script inside the environment (its runtime and isolation) and
# returns the dictionary it stores with ::result. data is passed to the
# script as ::request. (A file, not stdout: packages may print as they load.)
proc ::tclvenv::inEnvironment {root script data} {
    set cfg [config $root]
    set work [privateDirectory]
    try {
        set requestPath [file join $work request.tcldata]
        set resultPath [file join $work result.tcldata]
        set scriptPath [file join $work script.tcl]
        writeFile $requestPath $data\n
        writeFile $scriptPath [string cat \
            "set ::request \[::tclvenv::runtime::readData [list $requestPath]\]\n" \
            "proc ::result {data} {set ch \[open [list $resultPath] w\]; fconfigure \$ch -encoding utf-8 -translation lf; puts \$ch \$data; close \$ch}\n" \
            $script \
            "\n# A loaded Tk would keep its main loop running after the script.\nexit 0\n"]
        runResult [dict get $cfg executable] [list [file join $root metadata runtime.tcl] $scriptPath] $resultPath
    } finally { removePrivate $work }
}

# Runs a Tcl script that writes a dictionary to resultPath, and returns it.
proc ::tclvenv::runResult {executable arguments resultPath} {
    if {[catch {runProbe $executable $arguments [list ::tclvenv::resultReady $resultPath]} message]} {
        # (runProbe's wording is about identities; keep only the detail.)
        regsub {^Tcl runtime did not report a valid identity: } $message "" message
        error "could not run the environment's Tcl: $message"
    }
    readData $resultPath
}

proc ::tclvenv::resultReady {path output} {
    expr {[file isfile $path] && ![catch {dict size [readData $path]}]}
}

# Loads each {name version} in the environment: name -> {0 version} or
# {1 message}. With coreOnly, only this Tcl's own library and modules are
# searched (so no installed package's index is run).
proc ::tclvenv::loadInEnvironment {root packages {coreOnly 0}} {
    inEnvironment $root {
        if {[dict get $::request coreOnly]} { set ::auto_path [list [info library]] }
        set result {}
        foreach {name version} [dict get $::request packages] {
            dict set result $name [list [catch {package require $name {*}$version} message] $message]
            # A package that loads Tk must not show its main window here.
            if {[llength [info commands ::wm]]} { catch {::wm withdraw .} }
        }
        ::result $result
    } [dict create packages $packages coreOnly $coreOnly]
}

# Runs discover.tcl in the environment's Tcl with the system's package
# paths (not the environment's) and the extra paths.
proc ::tclvenv::discover {root request} {
    variable resources
    set cfg [config $root]
    set work [privateDirectory]
    try {
        set requestPath [file join $work request.tcldata]
        set resultPath [file join $work result.tcldata]
        writeFile $requestPath $request\n
        set result [runResult [dict get $cfg executable] \
            [list [file join $resources discover.tcl] $requestPath $resultPath] $resultPath]
    } finally { removePrivate $work }
    if {[dict exists $result error]} { error "[dict get $result error]" }
    return $result
}

# Names the environment provides without the given new installations: what
# its other receipts register, and (checked by loading) its Tcl's own.
proc ::tclvenv::providedByEnvironment {root names skipIds} {
    set provided {}
    dict for {id record} [installed $root] {
        if {$id in $skipIds} { continue }
        foreach name [providedNames [file join $root [dict get $record target]] [dict get $record target]] {
            dict set provided $name 1
        }
    }
    set unknown [lmap name $names {if {[dict exists $provided $name]} continue; set name}]
    if {[llength $unknown]} {
        set packages {}
        foreach name $unknown { lappend packages $name {} }
        dict for {name outcome} [loadInEnvironment $root $packages 1] {
            if {![lindex $outcome 0]} { dict set provided $name 1 }
        }
    }
    dict keys $provided
}

# System packages often hold symlinks (libfoo.so -> libfoo.so.1), which
# installation refuses. Returns {path ""} when path has none, else a private
# copy with each link replaced by the regular file it points to: {copy work},
# work to be removed afterwards. A link to anything but a regular file is
# an error.
proc ::tclvenv::systemCopy {path} {
    set links 0
    set queue [list $path]
    for {set i 0} {$i < [llength $queue]} {incr i} {
        set item [lindex $queue $i]
        switch -- [file type $item] {
            link { set links 1; break }
            directory { lappend queue {*}[children $item] }
        }
    }
    if {!$links} { return [list $path ""] }
    set work [privateDirectory]
    try {
        set copy [file join $work [file tail $path]]
        copyResolved $path $copy
    } on error {message options} {
        removePrivate $work
        return -options $options $message
    }
    list $copy $work
}

proc ::tclvenv::copyResolved {source destination} {
    set type [file type $source]
    if {$type eq "link"} {
        # (file normalize keeps a link in the last component: follow it.)
        set target $source
        for {set hops 0} {$hops < 20 && [file type $target] eq "link"} {incr hops} {
            set target [file join [file dirname $target] [file readlink $target]]
        }
        if {[catch {file type $target} type] || $type ne "file"} {
            error "symlink to something other than a regular file: $source"
        }
        file copy -- $target $destination
    } elseif {$type eq "directory"} {
        file mkdir $destination
        foreach child [children $source] {
            set name [file tail $child]
            if {[string match ./~* $name]} { set name [string range $name 2 end] }
            copyResolved $child [file join $destination ./$name]
        }
    } elseif {$type eq "file"} {
        file copy -- $source $destination
    } else {
        error "special file in a package: $source"
    }
}

# Removes the given installations, newest first, after a failure.
# Returns what couldn't be removed, as "ID (reason)" items. These are the
# command's own new installations: changes their own loading made to their
# files (a cache, say) are discarded with them.
proc ::tclvenv::rollBack {root ids} {
    set left {}
    foreach id [lreverse $ids] {
        if {[catch {remove $root $id 1} message]} { lappend left "$id ($message)" }
    }
    return $left
}

# Rolls back ids and says how that went, to end a failure message.
proc ::tclvenv::rollBackOutcome {root ids done} {
    set left [rollBack $root $ids]
    if {![llength $left]} { return "so nothing was $done" }
    return "and these could not be undone: [join $left {; }] (see remove --discard-changes)"
}

# Rolls back ids after an error, adding to its message what couldn't be.
proc ::tclvenv::rollBackAfter {root ids message options} {
    set left [rollBack $root $ids]
    if {[llength $left]} {
        append message "; these could not be undone: [join $left {; }] (see remove --discard-changes)"
    }
    return -options $options $message
}

# Installs the system packages in a discovered closure (dependencies first),
# skipping what the environment already provides; returns the new IDs.
proc ::tclvenv::installClosure {root result} {
    set ids {}
    try {
        installClosureInto $root $result ids
    } on error {message options} {
        rollBackAfter $root $ids $message $options
    }
    return $ids
}

proc ::tclvenv::installClosureInto {root result idsVar} {
    upvar 1 $idsVar ids
    set roots [dict get $result roots]
    set done {}
    set provided [providedByEnvironment $root [lmap entry [dict get $result closure] {lindex $entry 0}] {}]
    foreach entry [dict get $result closure] {
        lassign $entry name version kind path
        if {$kind eq "core" || $name in $provided} { continue }
        if {$path in $done} { continue }
        if {[file normalize $path] in $roots} {
            error "$name $version is registered from a package-path root ($path), not a directory of its own; install it from a directory or archive instead"
        }
        set receipt [lsearch -exact -inline -index 1 [lmap {id record} [installed $root] {
            list $id [expr {[dict exists $record origin path] ? [dict get $record origin path] : ""}]
        }] $path]
        if {[llength $receipt]} {
            lappend done $path
            continue
        }
        # A module goes in under its package name: ns::smod from
        # ns/smod-1.0.tm is modules/ns/smod-1.0.tm, as the loader looks.
        set tail [file tail $path]
        if {$kind eq "tm" && [regexp -- {-([[:digit:]][^/]*)\.tm$} $tail -> fileVersion]} {
            set tail $name-$fileVersion.tm
        }
        # A script library it found outside its directory (Tk 8.6's, in
        # /usr/share/tcltk/tk8.6): tcl_findLibrary looks in lib/NAME, so one
        # whose NAME is the package's directory is merged into it.
        set libraries [expr {[dict exists [lindex $entry 4] libraries] ? [dict get [lindex $entry 4] libraries] : {}}]
        set separate {}
        if {[dict exists $libraries $tail] && $kind eq "dir"} {
            set work [privateDirectory]
            set copy [file join $work $tail]
            try {
                copyResolved $path $copy
                set library [dict get $libraries $tail]
                foreach child [children $library] {
                    set target [file join $copy [file tail $child]]
                    if {![pathExists $target]} { copyResolved $child $target }
                }
            } on error {message options} {
                removePrivate $work
                return -options $options $message
            }
            dict unset libraries $tail
        } else {
            lassign [systemCopy $path] copy work
        }
        try {
            set id [installTree $root $copy [dict create kind system name $name version $version path $path] $tail]
        } finally { if {$work ne ""} { removePrivate $work } }
        lappend ids $id
        lappend done $path
        say "Installed $id ($name $version from $path)"
        dict for {wanted library} $libraries {
            say "Not copied: $name's script library $library (it would have to be lib/$wanted)"
        }
    }
}

# add ENV PACKAGE ?VERSION?: a package installed on this system, with what
# it requires, found and loaded by the environment's own Tcl.
proc ::tclvenv::add {root name version options} {
    set options [dict merge {paths {} deps 1 check 1} $options]
    config $root
    set result [discover $root [dict create mode resolve paths [dict get $options paths] \
        name $name version $version]]
    set closure [dict get $result closure]
    if {![dict get $options deps]} {
        set closure [lsearch -all -inline -exact -index 0 $closure $name]
        set others [lmap entry [dict get $result closure] {
            if {[lindex $entry 0] eq $name || [lindex $entry 2] eq "core"} continue
            lindex $entry 0
        }]
        if {[llength $others]} { say "Not adding what $name requires (--no-deps): [join $others {, }]" }
        dict set result closure $closure
    }
    set ids [installClosure $root $result]
    if {[dict get $options check]} {
        set loaded [lsearch -inline -exact -index 0 [dict get $result closure] $name]
        # A load that ends the interpreter (exit, a crash, the deadline)
        # leaves no outcome: that is a failed check too.
        if {[catch {loadInEnvironment $root [list $name [lindex $loaded 1]]} outcomes]} {
            error "loading $name in the environment failed, [rollBackOutcome $root $ids added]: $outcomes"
        }
        set outcome [dict get $outcomes $name]
        if {[lindex $outcome 0]} {
            error "$name does not load in the environment, [rollBackOutcome $root $ids added]: [lindex $outcome 1]"
        }
    }
    say "Added $name [lindex [lsearch -inline -exact -index 0 [dict get $result closure] $name] 1]"
    return $ids
}

# available ENV ?PATTERN?: system packages add can find for this Tcl.
proc ::tclvenv::available {root pattern paths} {
    set result [discover $root [dict create mode available paths $paths]]
    foreach name [lsort -dictionary [dict keys [dict get $result packages]]] {
        if {$pattern ne "" && ![string match -nocase $pattern $name]} { continue }
        foreach entry [lsort -unique [dict get $result packages $name]] {
            lassign $entry version kind path
            say "$name\t$version\t$path"
        }
    }
}

# Adds what an installed package requires (by a static scan of its Tcl
# files) from the system, appending each new ID to the caller's idsVar as
# soon as it is installed (so a later failure can roll them back); what
# can't be found is reported.
proc ::tclvenv::addRequirements {root id paths idsVar} {
    upvar 1 $idsVar ids
    set relative [dict get [installed $root] $id target]
    set target [file join $root $relative]
    set needed [lmap name [requiredNames $target] {
        if {$name in [concat Tcl Tk [providedNames $target $relative]]} continue
        set name
    }]
    if {![llength $needed]} { return }
    set provided [providedByEnvironment $root $needed [list $id]]
    foreach name $needed {
        if {$name in $provided} { continue }
        if {[catch {discover $root [dict create mode resolve paths $paths name $name version {}]} result]} {
            say "Requires $name, which isn't installed on this system: add it yourself if it's needed"
            continue
        }
        # Found by reading, not loading: it may be optional, so a failure
        # is reported and the package kept.
        say "Adding $name, which $id requires:"
        if {[catch {installClosure $root $result} added]} {
            say "Could not add $name ($added); add it yourself if it's needed"
            continue
        }
        lappend ids {*}$added
        set provided [providedByEnvironment $root $needed {}]
    }
}

# install ENV SOURCE: a directory or module (as before), an archive (.zip,
# .tar, .tar.gz, .tgz), or an http(s) URL of one (--sha256 required).
# deps and check default to on for archives and URLs, off for directories
# and modules (as before: nothing in them is run unless asked).
proc ::tclvenv::install {root source {options {}}} {
    set options [dict merge {sha256 {} subdir {} deps {} check {} paths {}} $options]
    set remote [regexp -nocase {^https?://} $source]
    set archive [expr {!$remote && [file isfile $source] && ![string match *.tm $source] && [archive::kind $source] ne ""}]
    foreach key {deps check} {
        if {[dict get $options $key] eq ""} { dict set options $key [expr {$remote || $archive}] }
    }
    if {[regexp -nocase {^https?://} $source]} {
        if {[dict get $options sha256] eq ""} {
            error "installing from a URL needs --sha256 HEX (the archive's SHA-256), to verify the download"
        }
        config $root
        set work [privateDirectory]
        try {
            set name [file tail [lindex [split [lindex [split $source ?] 0] #] 0]]
            if {$name eq "" || ![regexp {^[[:alnum:]._+-]+$} $name]} { set name download }
            set file [file join $work $name]
            download $source $file
            set sha [checkSha256 $file [dict get $options sha256]]
            set origin [dict create kind url url $source sha256 $sha]
            if {[string match *.tm $name]} {
                set id [installTree $root $file $origin]
                say "Installed $id"
                return [finishInstall $root [list $id] $options]
            }
            return [installArchive $root $file $origin $options]
        } finally { removePrivate $work }
    }
    if {$archive} {
        if {[dict get $options sha256] eq ""} {
            set sha [fileSha256 $source]
        } else {
            set sha [checkSha256 $source [dict get $options sha256]]
        }
        return [installArchive $root $source [dict create kind archive path [file normalize $source] sha256 $sha] $options]
    }
    if {[dict get $options sha256] ne "" || [dict get $options subdir] ne ""} {
        error "--sha256 and --subdir apply to archives and URLs"
    }
    set ids [list [installTree $root $source [dict create kind directory path [file normalize $source]]]]
    say "Installed [lindex $ids 0]"
    finishInstall $root $ids $options
}

proc ::tclvenv::installArchive {root file origin options} {
    config $root
    set work [privateDirectory]
    try {
        set extracted [file join $work archive]
        file mkdir $extracted
        archive::extract $file $extracted
        lassign [packageIn $extracted [file tail $file] [dict get $options subdir]] path name
        set ids [list [installTree $root $path $origin $name]]
        say "Installed [lindex $ids 0]"
    } finally { removePrivate $work }
    finishInstall $root $ids $options
}

# Requirements and the optional load check after an install.
proc ::tclvenv::finishInstall {root ids options} {
    set id [lindex $ids 0]
    if {[dict get $options deps]} {
        if {[catch {addRequirements $root $id [dict get $options paths] ids} message options2]} {
            rollBackAfter $root $ids $message $options2
        }
    }
    if {[dict get $options check]} {
        set relative [dict get [installed $root] $id target]
        set packages {}
        foreach name [providedNames [file join $root $relative] $relative] { lappend packages $name {} }
        # A load that ends the interpreter (exit, a crash, the deadline)
        # leaves no outcome: that is a failed check too.
        if {[catch {loadInEnvironment $root $packages} outcomes]} {
            error "loading [join [dict keys $packages] {, }] in the environment failed, [rollBackOutcome $root $ids installed]: $outcomes"
        }
        dict for {name outcome} $outcomes {
            if {[lindex $outcome 0]} {
                error "$name does not load in the environment, [rollBackOutcome $root $ids installed]: [lindex $outcome 1]"
            }
        }
    }
    return $ids
}

proc ::tclvenv::validateRemovalStage {stage record} {
    set journal [file join $stage transaction.tcldata]
    if {![pathExists $journal] || [file type $journal] ne "file"} {
        error "missing or invalid removal journal: $journal"
    }
    set original [readData $journal]
    if {[dict exists $original stage] ||
        ([dict exists $original state] && [dict get $original state] ne "installed")} {
        error "invalid removal journal: $journal"
    }
    # The journal records the receipt before its transition to 'removing'.
    # Compare fields as data, including the complete original file inventory.
    dict unset original state
    dict unset record state
    dict unset record stage
    if {[dict size $original] != [dict size $record]} {
        error "removal journal does not match package receipt: $journal"
    }
    dict for {key value} $record {
        if {![dict exists $original $key]} {
            error "removal journal does not match package receipt: $journal"
        }
        if {$key eq "files"} {
            set equal [sameInventory $value [dict get $original $key]]
        } else { set equal [expr {$value eq [dict get $original $key]}] }
        if {!$equal} { error "removal journal does not match package receipt: $journal" }
    }
    foreach child [children $stage] {
        if {[file tail $child] ni {payload transaction.tcldata}} {
            error "unexpected removal staging file; refusing to remove: $child"
        }
    }
}

# remove ENV ID ?--discard-changes?: discard, for a package whose files
# changed after it was installed (its own loading wrote into it, say),
# deletes it as it is instead of refusing. It still detaches the package
# first and never follows links out of it.
proc ::tclvenv::remove {root id {discard 0}} {
    config $root
    withLock $root {
        set records [installed $root]
        if {![dict exists $records $id]} { error "package is not installed: $id" }
        set record [dict get $records $id]
        # Whether the payload's full inventory was just compared.
        set verified 0
        if {![dict exists $record state] || [dict get $record state] eq "installed"} {
            set target [file join $root [dict get $record target]]
            set stage [makeStage $root remove]
            set payload [file join $stage payload]
            try {
                writeData [file join $stage transaction.tcldata] $record
                moveExclusive $target $payload
                # (A file that became a link or special file is a change too.)
                if {!$discard && ([catch {inventory $payload} now] ||
                                  ![sameInventory [dict get $record files] $now])} {
                    error "package files changed; refusing to remove $id (remove --discard-changes deletes it as it is)"
                }
                dict set record state removing
                dict set record stage [file tail $stage]
                dict set records $id $record
                writeData [file join $root metadata installed.tcldata] $records
                set verified 1
            } on error {message options} {
                if {[pathExists $payload]} {
                    if {[catch {moveExclusive $payload $target} restore]} {
                        error "$message; restore incomplete ($restore); package retained at $payload"
                    }
                }
                deleteOwned $stage
                return -options $options $message
            }
        }
        set stage [file join $root metadata [dict get $record stage]]
        set payload [file join $stage payload]
        if {[pathExists $stage]} { validateRemovalStage $stage $record }
        # A resumed deletion may have removed some files already. Never remove
        # added or modified data from a pending transaction.
        if {[pathExists $payload]} {
            # A resumed removal checks the staged files again (hashes
            # included); one that has just compared them doesn't repeat it.
            # Either way deleteOwned rechecks each file's size and CRC-32
            # as it deletes it.
            if {$discard} {
                deleteOwned $payload
            } else {
                if {!$verified && ([catch {inventory $payload} now] ||
                                   ![sameInventory [dict get $record files] $now 1])} {
                    error "staged package files changed; refusing to resume removal of $id ($payload; remove --discard-changes deletes it as it is)"
                }
                withDeletionPlan $payload [dict get $record files] { deleteOwned $payload }
            }
        }
        # Retain the journal until the final metadata write succeeds, so a
        # retry can verify ownership even after the payload has been deleted.
        dict unset records $id
        writeData [file join $root metadata installed.tcldata] $records
        # The removal is committed: what follows is tidying, whose failure
        # is reported, not made the outcome (the next command's recovery
        # finishes it, or doctor names what is left).
        if {[catch {
            if {[pathExists $stage]} {
                file delete -- [file join $stage transaction.tcldata]
                # Never recursively delete the staging directory: preserve files
                # added since validation, reporting the leftover for recovery.
                file delete -- $stage
            }
        } message]} { warn "couldn't remove the staging directory $stage: $message" }
        # A namespaced module's directories (modules/ns/...), now empty.
        set parts [file split [dict get $record target]]
        if {[lindex $parts 0] eq "modules"} {
            for {set n [expr {[llength $parts] - 1}]} {$n > 1} {incr n -1} {
                set directory [file join $root {*}[lrange $parts 0 [expr {$n - 1}]]]
                if {[catch {file lstat $directory st}] || $st(type) ne "directory" ||
                    [llength [children $directory]]} { break }
                if {[catch {file delete -- $directory} message]} {
                    warn "couldn't remove the empty directory $directory: $message"
                    break
                }
            }
        }
    }
    say "Removed $id"
}

proc ::tclvenv::run {root arguments} {
    set cfg [config $root]
    # Tcl exec parses redirections even in list-expanded arguments. Transfer user
    # arguments as data, so values like |, >file, and 2>@1 remain literal.
    set ch [file tempfile path]
    try {
        fconfigure $ch -encoding utf-8 -translation lf
        puts $ch [dict create arguments $arguments]
        close $ch
        set ch ""
        set command [list exec -- [dict get $cfg executable] \
            [file join $root metadata runtime.tcl] --tclvenv-arguments-file $path <@stdin >@stdout 2>@stderr]
        cleanRuntimeEnv {uplevel #0 $command}
    } finally {
        if {$ch ne ""} { close $ch }
        file delete -- $path
    }
}

# Writes a line of the command's output. Output is never what a command
# does: a write that fails (a full disk, a reader that stopped reading) is
# remembered, the rest of the output skipped, and the command completes;
# main then reports it once.
proc ::tclvenv::say {args} {
    variable outputError
    if {[info exists outputError]} { return }
    if {[catch {puts {*}$args; flush stdout} message options]} {
        set outputError [list $message [lrange [dict get $options -errorcode] 0 1]]
    }
}

proc ::tclvenv::reportError {message options} {
    if {[dict exists $options -errorcode] && [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS"} {
        exit [lindex [dict get $options -errorcode] 2]
    }
    catch {puts stderr "tclvenv: $message"}
    exit 1
}

proc ::tclvenv::infoCommand {root} {
    set cfg [config $root]
    say "Environment: $root"
    say "Tcl: [dict get $cfg runtime version]"
    say "Executable: [dict get $cfg executable]"
    say "Core library: [dict get $cfg runtime library]"
    say "Platform: [dict get $cfg runtime os] / [dict get $cfg runtime machine]"
    say "System packages: [dict get $cfg system_packages]"
    set installedCount 0
    set pending 0
    dict for {id record} [installed $root] {
        if {[dict exists $record state] && [dict get $record state] eq "removing"} {
            incr pending
        } else { incr installedCount }
    }
    say "Installed packages: $installedCount"
    say "Pending removals: $pending"
}

proc ::tclvenv::doctor {root} {
    set cfg [config $root]
    set actual [probe [dict get $cfg executable]]
    dict unset actual executable
    set expected [dict get $cfg runtime]
    if {[dict size $actual] != [dict size $expected]} {
        error "Tcl runtime changed; recreate this environment"
    }
    dict for {key value} $actual {
        if {![dict exists $expected $key] || [dict get $expected $key] ne $value} {
            error "Tcl runtime changed ($key); recreate this environment"
        }
    }
    foreach relative {bin/tclsh metadata/runtime.tcl metadata/manager.tcl metadata/manager-cli.tcl metadata/core.tcl metadata/archive.tcl metadata/discover.tcl metadata/core-modules lib modules} {
        if {![file exists [file join $root $relative]]} { error "missing environment component: $relative" }
    }
    if {![sameInventory [readData [file join $root metadata core-files.tcldata]] \
        [inventory [file join $root metadata core-modules] 0]]} { error "core module snapshot changed" }
    dict for {id record} [installed $root] {
        if {[dict exists $record state] && [dict get $record state] eq "removing"} {
            error "unfinished removal of $id; retry: remove [list $root] [list $id]"
        }
        if {![sameInventory [dict get $record files] [inventory [file join $root [dict get $record target]]]]} {
            error "installed files changed: $id"
        }
    }
    set lock [file join $root metadata mutation.lock]
    if {[pathExists $lock]} {
        set holder [lockHolder $lock]
        if {$::tcl_platform(platform) eq "unix" && $holder ne "" &&
            [dict get $holder host] eq [info hostname] && ![processAlive [dict get $holder pid]]} {
            error "environment has an installation lock left by process [dict get $holder pid], which no longer exists; run: recover [list $root]"
        }
        error "environment has an installation lock"
    }
    foreach leftover [glob -nocomplain -directory [file join $root metadata] -- stage-* remove-* {*}[leftoverPatterns temporary]] {
        error "unfinished package operation: $leftover; run: recover [list $root]"
    }
    say "Runtime and installed files: OK"
    # Read in the environment, printed here: a child writing to this
    # process's stdout would fail on its own when the output can't be written.
    set paths [inEnvironment $root {::result [dict create packages $::auto_path modules [::tcl::tm::path list]]} {}]
    say "Package paths: [dict get $paths packages]"
    say "Module paths: [dict get $paths modules]"
}

proc ::tclvenv::help {} {
    say {Usage: tclsh tclvenv.tcl COMMAND ...

  create ENV ?--tcl EXECUTABLE? ?--system-packages?
  run ENV -- ?SCRIPT ?ARG ...??
  info ENV
  doctor ENV
  install ENV SOURCE ?--sha256 HEX? ?--subdir PATH? ?--(no-)deps? ?--(no-)check? ?--path DIR ...?
      SOURCE: a directory with pkgIndex.tcl, a NAME-VERSION.tm, an archive
      (.zip .tar .tar.gz .tgz), or an http(s) URL of one (--sha256 required).
      Archives and URLs add requirements from the system and check that the
      package loads (--no-deps, --no-check); directories and modules only
      with --deps, --check
  add ENV PACKAGE ?VERSION? ?--path DIR ...? ?--no-deps? ?--no-check?
      a package installed on this system, with what it requires
  available ENV ?PATTERN? ?--path DIR ...?
  list ENV
  remove ENV INSTALLATION-ID ?--discard-changes?
      --discard-changes: remove a package whose files changed since it was
      installed, as it is (otherwise refused)
  recover ENV
      finish or undo what an interrupted command left (every command that
      changes an environment does this first; a lock left by a process
      that no longer exists is taken over)
  --version

Activate with: . ENV/bin/activate                       (POSIX sh/bash/zsh)
               . ENV/bin/Activate.ps1                   (PowerShell)
               call ENV\bin\activate.bat                (cmd.exe)

Run without activation: ENV/bin/tclsh SCRIPT ?ARG ...?
Use --interactive for a REPL, or --stdin for piped input via `run`.
Environments reuse an installed Tcl; packages are copied, never built.}
}

# Splits arguments into words and options: spec maps each option to 1 if it
# takes a value. Returns {words options}, options mapping an option to its
# values (a list, as one may be repeated).
proc ::tclvenv::parseOptions {arguments spec} {
    set words {}
    set options {}
    for {set i 0} {$i < [llength $arguments]} {incr i} {
        set word [lindex $arguments $i]
        if {[dict exists $spec $word]} {
            if {[dict get $spec $word]} {
                incr i
                if {$i == [llength $arguments]} { error "$word requires a value" }
                dict lappend options $word [lindex $arguments $i]
            } else {
                dict set options $word {}
            }
        } elseif {[string match --* $word]} {
            error "unknown option: $word"
        } else {
            lappend words $word
        }
    }
    list $words $options
}

proc ::tclvenv::optionValue {options name} {
    if {![dict exists $options $name]} { return "" }
    if {[llength [dict get $options $name]] > 1} { error "$name given more than once" }
    lindex [dict get $options $name] 0
}

proc ::tclvenv::optionValues {options name} {
    if {![dict exists $options $name]} { return {} }
    lmap path [dict get $options $name] { file normalize $path }
}

proc ::tclvenv::main {arguments} {
    variable outputError
    unset -nocomplain outputError
    dispatch $arguments
    if {![info exists outputError]} { return }
    lassign $outputError message code
    # A command that changes the environment has done so: say that the
    # output was lost, and succeed. For the others the output was the result:
    # fail, quietly when the reader just stopped reading (tclvenv list | head).
    if {[lindex $arguments 0] in {create install add remove recover}} {
        catch {puts stderr "tclvenv: the command completed, but its output couldn't be written ($message)"}
        return
    }
    if {$code eq {POSIX EPIPE}} { exit 1 }
    error "couldn't write the output: $message"
}

proc ::tclvenv::dispatch {arguments} {
    variable version
    if {![package vsatisfies [info patchlevel] 8.6-]} { error "Tcl 8.6 or newer is required" }
    if {![llength $arguments]} { help; return }
    set command [lindex $arguments 0]
    set arguments [lrange $arguments 1 end]
    switch -- $command {
        help - --help - -h { help }
        --version { say $version }
        create {
            if {![llength $arguments]} { error "usage: create ENV ?--tcl EXECUTABLE? ?--system-packages?" }
            set root [lindex $arguments 0]
            set executable [info nameofexecutable]
            set systemPackages 0
            for {set i 1} {$i < [llength $arguments]} {incr i} {
                switch -- [lindex $arguments $i] {
                    --tcl {
                        incr i
                        if {$i == [llength $arguments]} { error "--tcl requires an executable" }
                        set executable [lindex $arguments $i]
                    }
                    --system-packages { set systemPackages 1 }
                    default { error "unknown create option: [lindex $arguments $i]" }
                }
            }
            create $root $executable $systemPackages
        }
        run {
            if {[llength $arguments] < 2 || [lindex $arguments 1] ne "--"} {
                error "usage: run ENV -- ?SCRIPT ?ARG ...??"
            }
            run [file normalize [lindex $arguments 0]] [lrange $arguments 2 end]
        }
        info - doctor - list {
            if {[llength $arguments] != 1} { error "usage: $command ENV" }
            set root [file normalize [lindex $arguments 0]]
            switch -- $command {
                info { infoCommand $root }
                doctor { doctor $root }
                list {
                    config $root
                    dict for {id record} [installed $root] {
                        set state [expr {[dict exists $record state] ? [dict get $record state] : "installed"}]
                        say "$id\t[dict get $record target]\t$state"
                    }
                }
            }
        }
        remove {
            set discard [expr {[llength $arguments] == 3 && [lindex $arguments 2] eq "--discard-changes"}]
            if {[llength $arguments] != 2 && !$discard} { error "usage: remove ENV INSTALLATION-ID ?--discard-changes?" }
            remove [file normalize [lindex $arguments 0]] [lindex $arguments 1] $discard
        }
        recover {
            if {[llength $arguments] != 1} { error "usage: recover ENV" }
            recover [file normalize [lindex $arguments 0]]
        }
        install {
            lassign [parseOptions $arguments {--sha256 1 --subdir 1 --path 1 --deps 0 --no-deps 0 --check 0 --no-check 0}] words options
            if {[llength $words] != 2} { error "usage: install ENV SOURCE ?--sha256 HEX? ?--subdir PATH? ?--(no-)deps? ?--(no-)check? ?--path DIR ...?" }
            set chosen [dict create sha256 [optionValue $options --sha256] subdir [optionValue $options --subdir] \
                paths [optionValues $options --path]]
            foreach key {deps check} {
                if {[dict exists $options --$key] && [dict exists $options --no-$key]} { error "--$key and --no-$key together" }
                if {[dict exists $options --$key]} { dict set chosen $key 1 }
                if {[dict exists $options --no-$key]} { dict set chosen $key 0 }
            }
            install [file normalize [lindex $words 0]] [lindex $words 1] $chosen
        }
        add {
            lassign [parseOptions $arguments {--path 1 --no-deps 0 --no-check 0}] words options
            if {[llength $words] < 2 || [llength $words] > 3} { error "usage: add ENV PACKAGE ?VERSION? ?--path DIR ...? ?--no-deps? ?--no-check?" }
            add [file normalize [lindex $words 0]] [lindex $words 1] [lrange $words 2 2] [dict create \
                paths [optionValues $options --path] deps [expr {![dict exists $options --no-deps]}] \
                check [expr {![dict exists $options --no-check]}]]
        }
        available {
            lassign [parseOptions $arguments {--path 1}] words options
            if {[llength $words] < 1 || [llength $words] > 2} { error "usage: available ENV ?PATTERN? ?--path DIR ...?" }
            available [file normalize [lindex $words 0]] [lindex $words 1] [optionValues $options --path]
        }
        default { error "unknown command: $command (use --help)" }
    }
}
