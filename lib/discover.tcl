# Run by the manager inside an environment's Tcl, with the system's package
# paths (plus any --path), to find where packages come from:
#
#    tclsh discover.tcl REQUEST-FILE RESULT-FILE
#
# REQUEST-FILE holds a dictionary: mode (available or resolve), paths (extra
# package directories), and for resolve: name and version. It writes one
# dictionary to RESULT-FILE (not stdout, which packages may print to): roots (the package-path directories), packages (for available:
# name -> {version {kind path} ...}), and for resolve: closure, the loaded
# packages in load order, each {name version kind path} (kind dir, tm or
# core; core is part of this Tcl), or error.
namespace eval ::tclvenv::discover {
    variable registered {}
    variable scanning ""
    variable loads {}
}

proc ::tclvenv::discover::readData {path} {
    set ch [open $path r]
    try {
        fconfigure $ch -encoding utf-8 -translation lf
        return [read $ch]
    } finally { close $ch }
}

# Sources each pkgIndex.tcl on the package path (as Tcl's own search does,
# in each directory and one level down), recording each registration and
# the directory it comes from: the "dir" of the registering scope, so a
# collection's index that sources its modules' indexes (Tcllib) gives each
# module's own directory. Registrations are only recorded, not made: the
# load that follows goes through Tcl's own search, in its own order, so
# where a version is registered twice, Tcl picks as it would anywhere.
proc ::tclvenv::discover::scan {} {
    variable registered
    variable scanning
    rename ::package ::tclvenv::discover::realPackage
    proc ::package {args} {
        if {[lindex $args 0] eq "ifneeded" && [llength $args] == 4} {
            lassign $args - name version script
            set where $::tclvenv::discover::scanning
            if {[uplevel 1 {info exists dir}]} { set where [uplevel 1 {set dir}] }
            lappend ::tclvenv::discover::registered [list $name $version dir [file normalize $where] $script]
            return
        }
        # An index may provide a package itself (Tcllib's try/pkgIndex.tcl
        # provides file::home on Tcl 9): that directory is its provider, with
        # no ifneeded script, as [package ifneeded] then reports.
        if {[lindex $args 0] eq "provide" && [llength $args] == 3} {
            lassign $args - name version
            set where $::tclvenv::discover::scanning
            if {[uplevel 1 {info exists dir}]} { set where [uplevel 1 {set dir}] }
            lappend ::tclvenv::discover::registered [list $name $version dir [file normalize $where] ""]
        }
        uplevel 1 [list ::tclvenv::discover::realPackage {*}$args]
    }
    set seen {}
    foreach base $::auto_path {
        foreach index [concat [glob -nocomplain -directory $base -- pkgIndex.tcl] \
                              [glob -nocomplain -directory $base -- */pkgIndex.tcl]] {
            set normalized [file normalize $index]
            if {$normalized in $seen} { continue }
            lappend seen $normalized
            set scanning [file dirname $normalized]
            # As written, as Tcl's search sets it, so the scripts match.
            set dir [file dirname $index]
            catch {source $index}
        }
    }
    rename ::package {}
    rename ::tclvenv::discover::realPackage ::package
    # Modules: NAME-VERSION.tm, namespaces as directories (a/b-1.0.tm).
    foreach root [::tcl::tm::path list] {
        set queue [list [list $root {}]]
        for {set i 0} {$i < [llength $queue] && $i < 2000} {incr i} {
            lassign [lindex $queue $i] directory prefix
            foreach file [glob -nocomplain -types f -directory $directory -- *.tm] {
                if {[regexp {^([_[:alpha:]][:_[:alnum:]]*)-([[:digit:]][^/]*)\.tm$} [file tail $file] -> name version] &&
                    ![catch {package vcompare $version 0}]} {
                    lappend registered [list $prefix$name $version tm [file normalize $file] ""]
                }
            }
            foreach sub [glob -nocomplain -types d -directory $directory -- *] {
                lappend queue [list $sub $prefix[file tail $sub]::]
            }
        }
    }
}

# Whether path is this Tcl's own library or core modules.
proc ::tclvenv::discover::isCore {path} {
    set library [file split [file normalize [info library]]]
    set parts [file split $path]
    expr {[lrange $parts 0 [expr {[llength $library] - 1}]] eq $library}
}

# Loads name (and what it requires), tracing every package require: the
# packages and versions this Tcl actually loads, in load order.
proc ::tclvenv::discover::resolve {name version} {
    variable loads
    rename ::package ::tclvenv::discover::realPackage
    proc ::package {args} {
        if {[lindex $args 0] ne "require"} {
            return [uplevel 1 [list ::tclvenv::discover::realPackage {*}$args]]
        }
        set words [lrange $args 1 end]
        if {[lindex $words 0] eq "-exact"} { set words [lrange $words 1 end] }
        set wanted [lindex $words 0]
        lappend ::tclvenv::discover::requiring $wanted
        try {
            set got [uplevel 1 [list ::tclvenv::discover::realPackage {*}$args]]
        } finally {
            set ::tclvenv::discover::requiring [lrange $::tclvenv::discover::requiring 0 end-1]
        }
        # Tk creates its main window when it loads: withdraw it before the
        # event loop could show it (this interpreter only reads, and exits).
        if {[llength [info commands ::wm]]} { catch {::wm withdraw .} }
        if {[lsearch -exact -index 0 $::tclvenv::discover::loads $wanted] < 0} {
            lappend ::tclvenv::discover::loads [list $wanted $got]
        }
        return $got
    }
    # Script libraries an extension finds with tcl_findLibrary as it loads
    # (Tk 8.6's tk.tcl): they may be outside its index's directory.
    variable requiring {}
    variable libraries {}
    catch {auto_load tcl_findLibrary}
    if {[llength [info commands ::tcl_findLibrary]]} {
        trace add execution ::tcl_findLibrary leave ::tclvenv::discover::foundLibrary
    }
    try {
        package require $name {*}$version
    } finally {
        rename ::package {}
        rename ::tclvenv::discover::realPackage ::package
        catch {trace remove execution ::tcl_findLibrary leave ::tclvenv::discover::foundLibrary}
    }
    return $loads
}

# tcl_findLibrary sets the global varName to the directory it chose; record
# it for the package being required.
proc ::tclvenv::discover::foundLibrary {command code result op} {
    variable requiring
    variable libraries
    if {$code != 0 || [llength $command] != 7 || ![llength $requiring]} { return }
    lassign [lrange $command 1 end] basename version - - - varName
    upvar #0 $varName directory
    if {[info exists directory] && $directory ne ""} {
        lappend libraries [list [lindex $requiring end] $basename$version [file normalize $directory]]
    }
}

# Libraries found for name that its provider's directory doesn't hold:
# {NAME DIRECTORY ...}, NAME being what tcl_findLibrary looks for.
proc ::tclvenv::discover::librariesOf {name path} {
    variable libraries
    set result {}
    foreach entry $libraries {
        lassign $entry owner wanted directory
        if {$owner ne $name || [string match //zipfs:* $directory] || [isCore $directory]} { continue }
        if {$path ne "" && [file isdirectory $path]} {
            set inside [file split [file normalize $path]]
            if {[lrange [file split $directory] 0 [expr {[llength $inside] - 1}]] eq $inside} { continue }
        }
        if {![file isdirectory $directory] || [dict exists $result $wanted]} { continue }
        dict set result $wanted $directory
    }
    return $result
}

# Where name version came from: the registration whose script Tcl used
# (the last one with it), else a module, else the first registration.
proc ::tclvenv::discover::provider {name version} {
    variable registered
    set used [package ifneeded $name $version]
    set matches [lmap entry $registered {
        lassign $entry n v
        if {$n ne $name || [package vcompare $v $version]} continue
        set entry
    }]
    set chosen ""
    foreach entry [lreverse $matches] {
        if {[lindex $entry 2] eq "dir" && [lindex $entry 4] eq $used} { set chosen $entry; break }
    }
    if {$chosen eq ""} { set chosen [lsearch -inline -index 2 $matches tm] }
    if {$chosen eq ""} { set chosen [lindex $matches 0] }
    if {$chosen ne ""} {
        lassign $chosen - - kind path
        if {[isCore $path]} { return [list core $path] }
        return [list $kind $path]
    }
    # Provided without an index or module here: built into this Tcl.
    return [list core ""]
}

proc ::tclvenv::discover::main {requestFile} {
    variable registered
    set request [readData $requestFile]
    foreach path [lreverse [dict get $request paths]] {
        set ::auto_path [linsert $::auto_path 0 $path]
        if {[file isdirectory $path]} { catch {::tcl::tm::path add $path} }
    }
    set result [dict create roots [lsort -unique [lmap root $::auto_path {file normalize $root}]]]
    scan
    if {[dict get $request mode] eq "available"} {
        set packages {}
        foreach entry $registered {
            lassign $entry name version kind path
            if {[isCore $path]} { continue }
            dict lappend packages $name [list $version $kind $path]
        }
        dict set result packages $packages
        return $result
    }
    set version [dict get $request version]
    if {[catch {resolve [dict get $request name] $version} loads]} {
        dict set result error $loads
        return $result
    }
    set closure {}
    foreach load $loads {
        lassign $load name loaded
        set entry [list $name $loaded {*}[provider $name $loaded]]
        set found [librariesOf $name [lindex $entry 3]]
        if {[dict size $found]} { lappend entry [dict create libraries $found] }
        lappend closure $entry
    }
    dict set result closure $closure
    return $result
}

if {[catch {::tclvenv::discover::main [lindex $::argv 0]} result]} {
    set result [dict create error $result]
}
set ch [open [lindex $::argv 1] w]
fconfigure $ch -encoding utf-8 -translation lf
puts $ch $result
close $ch
# A package loaded above may have been Tk, whose main loop would otherwise
# keep this interpreter running after the script: the caller waits for exit.
exit 0
