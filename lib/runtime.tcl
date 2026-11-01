# Copied into each environment. No dependencies outside the Tcl core.
namespace eval ::tclvenv::runtime {
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable pending ""
    variable done 0
}

proc ::tclvenv::runtime::readData {path} {
    set ch [open $path r]
    try {
        fconfigure $ch -encoding utf-8 -translation lf
        set data [read $ch]
        dict size $data
        return $data
    } finally { close $ch }
}

proc ::tclvenv::runtime::identity {} {
    set result [dict create version [info patchlevel] library [info library]]
    foreach key {platform os machine pointerSize threaded} {
        dict set result $key [expr {[info exists ::tcl_platform($key)] ? $::tcl_platform($key) : 0}]
    }
    return $result
}

proc ::tclvenv::runtime::addModulePath {path} {
    set old [::tcl::tm::path list]
    if {$path eq "" || $path in $old} { return }
    # Tcl 8.6/9.0 use unescaped glob patterns for ancestry checks. Validate
    # literal components first: glob characters can also hide real conflicts.
    set parts [file split [file normalize $path]]
    if {$::tcl_platform(platform) eq "windows"} { set parts [string tolower $parts] }
    foreach existing $old {
        set other [file split [file normalize $existing]]
        if {$::tcl_platform(platform) eq "windows"} { set other [string tolower $other] }
        set common [expr {min([llength $parts], [llength $other]) - 1}]
        if {[lrange $parts 0 $common] eq [lrange $other 0 $common]} {
            error "module paths overlap: $path and $existing"
        }
    }
    if {![catch {::tcl::tm::path add $path} message options]} { return }
    # Both supported core implementations store the search list here. Check
    # that it still matches the public API before using this compatibility
    # fallback for a false conflict; unfamiliar implementations keep their
    # original error.
    if {![info exists ::tcl::tm::paths] || $::tcl::tm::paths ne $old} {
        return -options $options $message
    }
    set ::tcl::tm::paths [linsert $old 0 $path]
}

proc ::tclvenv::runtime::initialize {} {
    variable root
    set cfg [readData [file join $root tclvenv.cfg]]
    if {[dict get $cfg format] != 1} { error "unsupported environment format" }
    set systemPackages [dict get $cfg system_packages]
    if {![string is boolean -strict $systemPackages]} {
        error "invalid system_packages setting"
    }
    set actual [identity]
    foreach key [dict keys $actual] {
        if {[dict get $actual $key] ne [dict get $cfg runtime $key]} {
            error "Tcl runtime changed ($key); recreate this environment"
        }
    }
    set ::env(TCLVENV) $root
    set bindir [file join $root bin]
    set separator $::tcl_platform(pathSeparator)
    set paths {}
    if {[info exists ::env(PATH)]} { set paths [split $::env(PATH) $separator] }
    if {[lindex $paths 0] ne $bindir} {
        set ::env(PATH) [join [linsert $paths 0 $bindir] $separator]
    }
    if {!$systemPackages} {
        # Keep the runtime itself, not its parent (which often exposes /usr/lib).
        set ::auto_path [list [file join $root lib] [info library]]
        # Clear inherited tm settings before its lazy initialization; invalid
        # or overlapping inherited roots must not break an isolated startup.
        foreach key [array names ::env] {
            if {[regexp {^TCL[0-9]+[_.][0-9]+_TM_PATH$} $key]} {
                unset ::env($key)
            }
        }
        # Initialize tm after restricting auto_path, so its loader is core-only.
        set old [::tcl::tm::path list]
        if {[llength $old]} { ::tcl::tm::path remove {*}$old }
        addModulePath [file join $root metadata core-modules]
        set ::env(TCLLIBPATH) [list [file join $root lib]]
    } else {
        set ::auto_path [linsert $::auto_path 0 [file join $root lib]]
    }
    addModulePath [file join $root modules]
}

proc ::tclvenv::runtime::prompt {} {
    variable pending
    if {!$::tcl_interactive} { return }
    set name [expr {$pending eq "" ? "tcl_prompt1" : "tcl_prompt2"}]
    if {[info exists ::$name]} {
        if {[catch {uplevel #0 [set ::$name]} message]} { puts stderr $message }
    } elseif {$pending eq ""} {
        puts -nonewline stdout "% "
    }
    flush stdout
}

proc ::tclvenv::runtime::readCommand {} {
    variable pending
    variable done
    # As in native tclsh: input that can't be decoded (invalid UTF-8 on
    # Tcl 9) ends it, and an unfinished command at the end is dropped
    # silently.
    if {[catch {gets stdin line} count] || ($count < 0 && [eof stdin])} {
        fileevent stdin readable {}
        set done 1
        return
    }
    if {$count < 0} { return }
    append pending $line \n
    if {![info complete $pending]} { prompt; return }
    set command $pending
    set pending ""
    # Disable the handler while user code runs an event loop (e.g. vwait).
    fileevent stdin readable {}
    set blocking [fconfigure stdin -blocking]
    fconfigure stdin -blocking 1
    try {
        set code [catch {uplevel #0 $command} result options]
    } finally {
        if {"stdin" in [chan names]} { fconfigure stdin -blocking $blocking }
    }
    if {$code == 2 && [dict get $options -code] == 0} { set code 0 }
    switch -- $code {
        0 { if {$::tcl_interactive && $result ne ""} { puts stdout $result } }
        3 { puts stderr {invoked "break" outside of a loop} }
        4 { puts stderr {invoked "continue" outside of a loop} }
        default { puts stderr $result }
    }
    if {"stdin" ni [chan names]} {
        set done 1
        return
    }
    fileevent stdin readable ::tclvenv::runtime::onReadable
    prompt
}

proc ::tclvenv::runtime::onReadable {} {
    variable done
    variable inputError
    if {[catch {readCommand} message options]} {
        if {"stdin" in [chan names]} { catch {fileevent stdin readable {}} }
        set inputError [list $message $options]
        set done 1
    }
}

proc ::tclvenv::runtime::main {arguments} {
    initialize
    if {[lindex $arguments 0] eq "--tclvenv-arguments-file"} {
        if {[llength $arguments] != 2} { error "invalid launcher arguments" }
        set arguments [dict get [readData [lindex $arguments 1]] arguments]
    }
    set interactive 0
    if {[info exists ::env(TCLVENV_INTERACTIVE)]} {
        set interactive [string is true -strict $::env(TCLVENV_INTERACTIVE)]
        unset ::env(TCLVENV_INTERACTIVE)
    }
    set encoding ""
    set script 0
    # As Tcl_Main: the first argument is a script unless it starts with -;
    # -encoding NAME SCRIPT names one only when SCRIPT doesn't. Otherwise
    # stdin is read and every argument is in argv. --, --interactive and
    # --stdin are the launcher's own.
    if {[lindex $arguments 0] eq "--interactive"} {
        set interactive 1
        set arguments [lrange $arguments 1 end]
        if {[llength $arguments]} { error "--interactive takes no script arguments" }
    } elseif {[lindex $arguments 0] eq "--stdin"} {
        set interactive 0
        if {[llength $arguments] != 1} { error "--stdin takes no script arguments" }
        set arguments {}
    } elseif {[lindex $arguments 0] eq "--"} {
        set arguments [lrange $arguments 1 end]
        set script [expr {[llength $arguments] > 0}]
    } elseif {[llength $arguments] >= 3 && [lindex $arguments 0] eq "-encoding" &&
              ![string match -* [lindex $arguments 2]]} {
        set encoding [lindex $arguments 1]
        set arguments [lrange $arguments 2 end]
        set script 1
    } elseif {[llength $arguments] && ![string match -* [lindex $arguments 0]]} {
        set script 1
    }
    if {$script} {
        set ::tcl_interactive 0
        set ::argv0 [lindex $arguments 0]
        set ::argv [lrange $arguments 1 end]
        set ::argc [llength $::argv]
        set command [list source]
        if {$encoding ne ""} { lappend command -encoding $encoding }
        lappend command $::argv0
        # Evaluate at the file's global entry point, outside this procedure.
        # A procedure boundary consumes return levels and can hide a failure.
        variable scriptCommand $command
    } else {
        variable root
        variable done
        set ::argv0 [file join $root bin tclsh]
        set ::argv $arguments
        set ::argc [llength $arguments]
        set ::tcl_interactive $interactive
        # Commands read from stdin have no script, as in native tclsh.
        info script ""
        fconfigure stdin -blocking 0
        fileevent stdin readable ::tclvenv::runtime::onReadable
        prompt
        vwait ::tclvenv::runtime::done
        variable inputError
        if {[info exists inputError]} {
            lassign $inputError message options
            return -options $options $message
        }
    }
}

if {[catch {::tclvenv::runtime::main $::argv} ::tclvenv::runtime::message ::tclvenv::runtime::options]} {
    if {[dict exists $::tclvenv::runtime::options -errorinfo]} {
        puts stderr [dict get $::tclvenv::runtime::options -errorinfo]
    } else {
        puts stderr $::tclvenv::runtime::message
    }
    exit 1
}

# errorInfo as Tcl_Main prints it: without the frames of the source and
# uplevel below, which native tclsh doesn't have.
proc ::tclvenv::runtime::scriptErrorInfo {text} {
    set tail "\n    (\"uplevel\" body line 1)\n    invoked from within\n\"uplevel #0 \$::tclvenv::runtime::scriptCommand\""
    set start [expr {[string length $text] - [string length $tail]}]
    if {$start < 0 || [string range $text $start end] ne $tail} { return $text }
    set text [string range $text 0 [expr {$start - 1}]]
    set frame -1
    foreach marker [list "\n    invoked from within\n\"" "\n    while executing\n\""] {
        set frame [expr {max($frame, [string last $marker $text])}]
    }
    if {$frame < 0} { return $text }
    return [string range $text 0 [expr {$frame - 1}]]
}

if {[info exists ::tclvenv::runtime::scriptCommand]} {
    set ::tclvenv::runtime::completion [catch {uplevel #0 $::tclvenv::runtime::scriptCommand} \
        ::tclvenv::runtime::message ::tclvenv::runtime::options]
    switch -- $::tclvenv::runtime::completion {
        0 {}
        1 {
            if {[dict exists $::tclvenv::runtime::options -errorinfo]} {
                puts stderr [::tclvenv::runtime::scriptErrorInfo [dict get $::tclvenv::runtime::options -errorinfo]]
            } else { puts stderr $::tclvenv::runtime::message }
            exit 1
        }
        3 { puts stderr {invoked "break" outside of a loop}; exit 1 }
        4 { puts stderr {invoked "continue" outside of a loop}; exit 1 }
        default { puts stderr "command returned bad code: $::tclvenv::runtime::completion"; exit 1 }
    }
}
