# Optional benchmark; all generated files are temporary and owned by this run.
source [file join [file dirname [file dirname [file normalize [info script]]]] lib manager.tcl]
set count 6000
if {$argc == 1} { set count [lindex $argv 0] }
if {$argc > 1 || ![string is integer -strict $count] || $count < 1} {
    puts stderr "usage: tclsh tests/bench_inventory.tcl ?POSITIVE-FILE-COUNT?"
    exit 1
}
set ch [file tempfile directory]
close $ch
file delete -- $directory
file mkdir $directory
try {
    for {set i 0} {$i < $count} {incr i} {
        set ch [open [file join $directory file-$i] w]
        close $ch
    }
    set start [clock microseconds]
    set inventory [::tclvenv::inventory $directory]
    set elapsed [expr {([clock microseconds] - $start) / 1000.0}]
    if {[dict size $inventory] != $count + 1} { error "incomplete inventory" }
    puts "Tcl [info patchlevel]: $count files in [format %.1f $elapsed] ms"
} finally {
    ::tclvenv::deleteOwned $directory
}
