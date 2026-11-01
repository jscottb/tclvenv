package require tcltest 2
namespace import ::tcltest::*
set ch [file tempfile temporary]
close $ch
file delete -- $temporary
file mkdir $temporary
try {
    configure -testdir [file dirname [file normalize [info script]]] \
        -tmpdir $temporary -singleproc 1 {*}$argv
    set failed [runAllTests]
} finally {
    file delete -force -- $temporary
}
exit $failed
