#!/usr/bin/env tclsh
# Tcl 8.6+; this entry point and the environment manager use only Tcl core.
set tclvenv_home [file dirname [file normalize [info script]]]
source [file join $tclvenv_home lib manager.tcl]
if {[catch {::tclvenv::main $argv} message options]} {
    ::tclvenv::reportError $message $options
}
