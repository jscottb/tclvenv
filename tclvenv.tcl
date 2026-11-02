#!/usr/bin/env tclsh
# Tcl 8.6+; this entry point and the environment manager use only Tcl core.
# Installed with install.sh --venv: the launcher saved what the caller had, before the
# command's private environment replaced it. A tool's work is for the caller's setup.
if {[info exists ::env(INSTALL_SH_SAVED)]} {
    unset ::env(INSTALL_SH_SAVED)
    foreach ::installSaved {TCLVENV TCLLIBPATH PATH} {
        if {[info exists ::env(INSTALL_SH_$::installSaved)]} {
            set ::env($::installSaved) $::env(INSTALL_SH_$::installSaved)
            unset ::env(INSTALL_SH_$::installSaved)
        } else {
            unset -nocomplain ::env($::installSaved)
        }
    }
    unset ::installSaved
}
set tclvenv_home [file dirname [file normalize [info script]]]
source [file join $tclvenv_home lib manager.tcl]
if {[catch {::tclvenv::main $argv} message options]} {
    ::tclvenv::reportError $message $options
}
