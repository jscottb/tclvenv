package require hello 1.0
set name world
if {$argc > 0} { set name [lindex $argv 0] }
puts [::hello::greet $name]
