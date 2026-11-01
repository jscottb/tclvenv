# Loaded by fuzz.tcl. Groups for the entry points around the environment:
# the shells that source bin/activate, the POSIX launchers, and the native
# tclsh command line the launchers stand in for.
#
#   activation       bin/activate sourced by dash, bash and busybox sh, with
#                    hostile environment names and random prior PATH, TCLVENV
#                    (unset, empty, set, unexported) and PS1, set -u/-e,
#                    activation of a second environment, a deactivate function
#                    that another tool defined; the shell itself records the
#                    state after every step
#   tclshargs        bin/tclsh and `run` against native tclsh: arguments
#                    starting with -, -encoding with 0-2 words, scripts that
#                    fail in a procedure, at top level, with custom errorinfo,
#                    by syntax, or exit; stdin always has a program
#   linkedlaunchers  bin/tclsh and bin/tclvenv reached through symbolic links
#                    (absolute, relative, chains, linked bin or environment
#                    directories, PATH lookup under another name)
#
# Oracles: the shell's own record of variable values and export status;
# the prompt as each shell displays it (bash's ${PS1@P}; for dash and
# busybox, PS1 expanded as those shells expand it); native tclsh with the same arguments and stdin; the same
# launcher invoked by its real path. Unix only: elsewhere a case passes,
# counted as skipped.

proc ::fuzz::shellsUnix {} {
    if {$::tcl_platform(platform) eq "unix"} { return 1 }
    cover skipped
    return 0
}

# --- activation ----------------------------------------------------------------

proc ::fuzz::activationShells {} {
    set shells {}
    foreach {label command} {dash dash bash bash busybox busybox} {
        set path [auto_execok $command]
        if {$path eq ""} { continue }
        switch -- $label {
            bash { lappend shells bash [list {*}$path --norc --noprofile] }
            busybox { lappend shells busybox [list {*}$path sh] }
            default { lappend shells $label $path }
        }
    }
    if {![llength $shells]} { lappend shells sh [list /bin/sh] }
    return $shells
}

# Environment names: prompt escapes, command substitutions that would
# create PWNED in the current directory, quotes, spaces, Unicode.
proc ::fuzz::activationName {} {
    set corpus [list plain env x {$(touch PWNED)} {`touch PWNED`} {${PWD}} {$HOME} \
        {\u} {\w} {\$} {\[} {\]} {\\} {!} {!!} {%d} {%} { } ' {"} \t \u00e9 \u2603 \
        {*} {?} {;} {&} {|} {<} {>} {#} {~} {=} {:}]
    set name [pick {e. env- x}]
    for {set i 0; set n [expr {1 + [number 5]}]} {$i < $n} {incr i} { append name [pick $corpus] }
    if {[number 6] == 0} { append name \n }
    return $name
}

proc ::fuzz::activationValue {var} {
    switch -- $var {
        PATH {
            set extra [pick [list "/fuzz dir" "/a:b" "" "." "/\u00e9" "/x'y" {/$(touch PWNED)}]]
            return [pick [list $::env(PATH) "$extra:$::env(PATH)" "$::env(PATH):$extra"]]
        }
        TCLVENV { return [pick [list before /old/env "" "two words" {$(touch PWNED)} "a\nb"]] }
        PS1 { return [pick [list {$ } {> } {\u@\h:\w\$ } {[\h] } "\u2603 " {%} {(x) } { }]] }
    }
}

# A shell script that sets the initial state, runs the steps, and records
# each variable (set, exported, hex value) after every step.
proc ::fuzz::activationScript {shell initial steps roots out foreign flags} {
    set od [lindex [auto_execok od] 0]
    set tr [lindex [auto_execok tr] 0]
    set text ""
    if {$flags ne ""} { append text "set $flags\n" }
    append text "_fz_out=[shellWord $out]\n"
    append text "_fz_hex () { printf '%s' \"\$1\" | [shellWord $od] -An -v -tx1 | [shellWord $tr] -d ' \\n'; }\n"
    append text "_fz_dump () {\n"
    append text "  printf '%s' \"\$1\" >> \"\$_fz_out\"\n"
    append text "  for _fz_v in PATH TCLVENV PS1 _TCLVENV_ACTIVE; do\n"
    append text "    eval \"_fz_set=\\\${\$_fz_v+x}\"\n"
    append text "    eval \"_fz_val=\\\${\$_fz_v-}\"\n"
    append text "    _fz_exp=\$(/bin/sh -c 'eval \"printf %s \\\"\\\${\$1+x}\\\"\"' sh \"\$_fz_v\")\n"
    append text "    printf ' %s {%s %s %s}' \"\$_fz_v\" \"\${_fz_set:-0}\" \"\${_fz_exp:-0}\" \"\$(_fz_hex \"\$_fz_val\")\" >> \"\$_fz_out\"\n"
    append text "  done\n"
    append text "  if command -v deactivate >/dev/null 2>&1; then _fz_d=1; else _fz_d=0; fi\n"
    append text "  if command -v tclvenv_deactivate >/dev/null 2>&1; then _fz_o=1; else _fz_o=0; fi\n"
    append text "  printf ' own %s' \"\$_fz_o\" >> \"\$_fz_out\"\n"
    append text "  _fz_t=\$(command -v tclsh 2>/dev/null || :)\n"
    append text "  printf ' deactivate %s tclsh {%s}' \"\$_fz_d\" \"\$(_fz_hex \"\$_fz_t\")\" >> \"\$_fz_out\"\n"
    # What the shell shows: bash's own prompt expansion; dash and busybox
    # expand parameters and command substitutions in PS1, as eval does here.
    if {$shell eq "bash"} {
        append text "  if \[ \"\${PS1+x}\" = x \]; then _fz_p=\${PS1@P}; printf ' prompt {%s}' \"\$(_fz_hex \"\$_fz_p\")\" >> \"\$_fz_out\"; fi\n"
    } else {
        append text "  if \[ \"\${PS1+x}\" = x \]; then eval \"_fz_p=\\\"\$PS1\\\"\"; printf ' prompt {%s}' \"\$(_fz_hex \"\$_fz_p\")\" >> \"\$_fz_out\"; fi\n"
    }
    append text "  printf '\\n' >> \"\$_fz_out\"\n"
    append text "}\n"
    if {$foreign} { append text "deactivate () { printf 'foreign\\n' >> \"\$_fz_out\"; }\n" }
    foreach var {PATH TCLVENV PS1} {
        lassign [dict get $initial $var] mode value
        append text "unset $var\n"
        switch -- $mode {
            unset {}
            empty { append text "$var=''\nexport $var\n" }
            set { append text "$var=[shellWord $value]\nexport $var\n" }
            unexported { append text "$var=[shellWord $value]\n" }
        }
    }
    append text "_fz_dump start\n"
    set i 0
    foreach step $steps {
        switch -- [lindex $step 0] {
            activate {
                set root [dict get $roots [lindex $step 1]]
                append text ". [shellWord [file join $root bin activate]]\n"
            }
            deactivate { append text "deactivate\n" }
            tclvenv_deactivate { append text "tclvenv_deactivate\n" }
        }
        append text "_fz_dump step-[incr i]\n"
    }
    return $text
}

proc ::fuzz::activationRecords {path} {
    set records {}
    set ch [open $path r]
    fconfigure $ch -encoding utf-8 -translation lf
    set lines [split [read $ch] \n]
    close $ch
    foreach line $lines {
        if {$line eq "" || $line eq "foreign"} { continue }
        set label [lindex $line 0]
        set data {}
        foreach {key value} [lrange $line 1 end] {
            switch -- $key {
                PATH - TCLVENV - PS1 - _TCLVENV_ACTIVE {
                    lassign $value isset exported hex
                    dict set data $key [list [expr {$isset eq "x"}] [expr {$exported eq "x"}] \
                        [encoding convertfrom utf-8 [binary decode hex $hex]]]
                }
                tclsh - prompt { dict set data $key [encoding convertfrom utf-8 [binary decode hex $value]] }
                default { dict set data $key $value }
            }
        }
        lappend records $label $data
    }
    return $records
}

proc ::fuzz::scenario_activation {} {
    variable active
    variable current
    if {![shellsUnix]} { return }
    set shells [activationShells]
    set shell [pick [dict keys $shells]]
    cover shell-$shell
    set parent [file join $active envs]
    file mkdir $parent
    set roots {}
    set refused 0
    foreach key {a b} {
        set name [activationName]
        set root [file join $parent $name]
        set result [invoke manager [list create $root --tcl [info nameofexecutable]]]
        if {[string first : $root] >= 0} {
            # PATH can't hold it: create must refuse, cleanly, creating nothing.
            status $result 1 "create accepted a destination PATH can't hold"
            cleanFailure $result "create"
            need [expr {![exists $root]}] "a refused create left its destination"
            cover colon-refused
            incr refused
            continue
        }
        status $result 0 "create failed for a name PATH can hold"
        dict set roots $key [file normalize $root]
    }
    if {![dict size $roots]} { cover create-refused; return }
    # Initial state; PATH empty or unset only rarely (activate needs basename).
    set initial {}
    foreach var {PATH TCLVENV PS1} {
        set modes [expr {$var eq "PATH" ? {set set set set set set set set set set set set empty unset} : {unset empty set set unexported}}]
        set mode [pick $modes]
        cover $var-$mode
        dict set initial $var [list $mode [activationValue $var]]
    }
    set flags [pick {"" "" -u -e -eu}]
    set foreign [expr {[number 5] == 0}]
    if {$foreign} { cover foreign-deactivate }
    set steps {}
    set state none
    for {set i 0; set n [expr {1 + [number 5]}]} {$i < $n} {incr i} {
        if {$state ne "none" && [number 2]} {
            lappend steps [expr {$foreign ? "tclvenv_deactivate" : [pick {deactivate tclvenv_deactivate}]}]
            set state none
        } else {
            set key [pick [dict keys $roots]]
            lappend steps [list activate $key]
            set state $key
        }
    }
    if {$state ne "none" && [number 4]} {
        lappend steps [expr {$foreign ? "tclvenv_deactivate" : [pick {deactivate tclvenv_deactivate}]}]
    }
    set cwd [file join $active cwd]
    file mkdir $cwd
    set out [file join $active activation.records]
    set script [file join $active activation.sh]
    writeText $script [activationScript $shell $initial $steps $roots $out $foreign $flags]
    dict set current input [dict create mode $shell flags $flags foreign $foreign initial $initial \
        steps $steps roots $roots]
    set result [run [list sh -c {cd "$1" && shift && exec "$@"} sh $cwd {*}[dict get $shells $shell] $script] $active]
    dict lappend current operations [dict create entry activation result $result]
    need [expr {![dict get $result timedout]}] "activation script did not finish"
    need [expr {[llength [glob -nocomplain -directory $cwd *PWNED*]] == 0}] \
        "sourcing activate or showing the prompt ran a command from the environment's name"
    status $result 0 "activation script failed: [string trim [dict get $result stderr]]"
    set diagnostics [string trim [dict get $result stderr]]
    if {$foreign} {
        # The one line activate prints when deactivate belongs to another tool.
        set note "tclvenv: deactivate belongs to another tool here; leave this environment with tclvenv_deactivate"
        set diagnostics [string trim [string map [list $note ""] $diagnostics]]
    }
    need [expr {$diagnostics eq ""}] \
        "activation printed diagnostics: [string trim [dict get $result stderr]]"
    set records [activationRecords $out]
    need [expr {[dict size $records] == [llength $steps] + 1}] "activation records are incomplete"
    set start [dict get $records start]
    set base $start
    set state none
    set i 0
    foreach step $steps {
        set got [dict get $records step-[incr i]]
        if {[lindex $step 0] eq "activate"} {
            set key [lindex $step 1]
            set root [dict get $roots $key]
            set state $key
            lassign [dict get $base PATH] pathSet - pathValue
            set path $root/bin
            if {$pathSet && $pathValue ne ""} { append path :$pathValue }
            need [expr {[dict get $got PATH] eq [list 1 1 $path]}] "activation set PATH wrongly"
            need [expr {[dict get $got TCLVENV] eq [list 1 1 $root]}] "activation set TCLVENV wrongly"
            lassign [dict get $base PS1] ps1Set ps1Exported ps1Value
            if {$ps1Set} {
                need [expr {[dict get $got prompt] eq "([file tail $root]) [dict get $start prompt]"}] \
                    "the shell shows a different name in the prompt than the environment's"
            } else {
                need [expr {![lindex [dict get $got PS1] 0]}] "activation set PS1 that was unset"
            }
            need [dict get $got own] "activation did not define tclvenv_deactivate"
            need [dict get $got deactivate] "activation did not leave a deactivate command"
            if {[string first : $root] >= 0} {
                need [expr {[dict get $got tclsh] eq "$root/bin/tclsh"}] "tclsh is not the environment's while it is active (its path holds ':')"
            }
            need [expr {[dict get $got tclsh] eq "$root/bin/tclsh"}] "tclsh is not the environment's while it is active"
        } else {
            set state none
            foreach var {PATH TCLVENV PS1} {
                need [expr {[dict get $got $var] eq [dict get $base $var]}] \
                    "deactivate did not restore $var (value, set and exported as before)"
            }
            need [expr {![lindex [dict get $got _TCLVENV_ACTIVE] 0]}] "deactivate left _TCLVENV_ACTIVE"
            need [expr {![dict get $got own]}] "deactivate left tclvenv_deactivate defined"
            need [expr {[dict get $got tclsh] eq [dict get $start tclsh]}] "tclsh still resolves to an environment after deactivate"
            if {$foreign} {
                need [dict get $got deactivate] "deactivate removed another tool's deactivate function"
            } else {
                need [expr {![dict get $got deactivate]}] "deactivate left its function defined"
            }
        }
    }
}

# --- tclshargs -----------------------------------------------------------------

proc ::fuzz::tclshScriptBody {kind} {
    set report {puts [list argc $argc argv $argv argv0 $argv0 script [info script] interactive $tcl_interactive]}
    switch -- $kind {
        ok { return "$report\n" }
        procerror { return "$report\nproc fuzz_failing {} { error \"failed here\" }\nfuzz_failing\n" }
        toperror { return "$report\nerror \"top level\\nsecond line\"\n" }
        returnerror { return "$report\nreturn -code error -errorinfo {custom info} value\n" }
        errorcode { return "$report\nreturn -code error -errorcode {FUZZ CODE} coded\n" }
        syntax { return "$report\nif \{1\} \{\n puts unfinished\n" }
        exit { return "$report\nexit [number 120]\n" }
        sourced {
            return "$report\nset fuzz_inner \[file join \[file dirname \[info script\]\] inner.tcl\]\nset ch \[open \$fuzz_inner w\]\nputs \$ch {error inner}\nclose \$ch\nsource \$fuzz_inner\n"
        }
    }
}

# script is a path; the arguments name it relative to its directory.
proc ::fuzz::tclshArguments {script} {
    set form [pick {script script dash-script dash-word lone-encoding encoding-one encoding-script encoding-bogus encoding-latin1}]
    switch -- $form {
        script { set arguments [list [file tail $script]] }
        dash-script {
            set dashed [file join [file dirname $script] -[file tail $script]]
            file copy -force -- $script $dashed
            set arguments [list -[file tail $script]]
        }
        dash-word { set arguments [list [pick {- -e -x -c -h -help --version --help -v -encodingx}]] }
        lone-encoding { set arguments [list -encoding] }
        encoding-one { set arguments [list -encoding [pick {utf-8 iso8859-1 bogus}]] }
        encoding-script { set arguments [list -encoding utf-8 [file tail $script]] }
        encoding-bogus { set arguments [list -encoding no-such-encoding [file tail $script]] }
        encoding-latin1 { set arguments [list -encoding iso8859-1 [file tail $script]] }
    }
    for {set i 0; set n [number 4]} {$i < $n} {incr i} { lappend arguments [word 1] }
    list $form $arguments
}

# Runs a command list through sh in directory, every word quoted (no exec
# grammar). run's own directory only holds its logs.
proc ::fuzz::shellRun {words directory input} {
    variable active
    variable serial
    set quoted [lmap word $words {shellWord $word}]
    set path [file join $active shellrun-[incr serial].sh]
    writeText $path "#!/bin/sh\ncd [shellWord $directory] || exit 125\nexec [join $quoted { }]\n"
    run [list sh $path] $directory $input
}

proc ::fuzz::scenario_tclshargs {} {
    variable active
    variable envdir
    variable current
    if {![shellsUnix]} { return }
    set kind [pick {ok ok procerror toperror returnerror errorcode syntax exit sourced}]
    set work [file join $active work]
    file mkdir $work
    set script [file join $work main.tcl]
    writeText $script [tclshScriptBody $kind]
    lassign [tclshArguments $script] form arguments
    set entry [pick {launcher launcher manager}]
    cover $form
    cover $kind
    set stdin "puts \[list STDIN argc \$argc argv \$argv argv0 \$argv0 interactive \$tcl_interactive script \[info script\]\]\n"
    dict set current input [dict create mode $form kind $kind entry $entry arguments $arguments]
    set tcl [info nameofexecutable]
    set native [shellRun [list $tcl {*}$arguments] $work $stdin]
    set launcher [file join $envdir bin tclsh]
    if {$entry eq "launcher"} {
        set isolated [shellRun [list $launcher {*}$arguments] $work $stdin]
    } else {
        variable project
        set isolated [shellRun [list $tcl [file join $project tclvenv.tcl] run $envdir -- {*}$arguments] $work $stdin]
    }
    dict lappend current operations [dict create entry native result $native]
    dict lappend current operations [dict create entry $entry result $isolated]
    need [expr {![dict get $native timedout] && ![dict get $isolated timedout]}] "a tclsh did not finish"
    # The interpreter's own path is the one thing allowed to differ: native
    # argv0 in stdin mode is the executable, the environment's its launcher.
    set clean {}
    foreach {label result path} [list native $native $tcl isolated $isolated $launcher] {
        set map [list [encoding convertto utf-8 $path] @TCLSH@]
        dict set clean $label [list [dict get $result status] \
            [string map $map [dict get $result output]] [string map $map [dict get $result stderr]]]
    }
    lassign [dict get $clean native] nStatus nOut nErr
    lassign [dict get $clean isolated] iStatus iOut iErr
    need [expr {$nStatus == $iStatus}] "exit status differs from native tclsh ($nStatus vs $iStatus)"
    need [expr {$nOut eq $iOut}] "stdout differs from native tclsh"
    if {$kind in {returnerror errorcode} && $form ni {dash-script dash-word lone-encoding encoding-one}} {
        # Known limit: native tclsh turns a top-level return -code error into
        # an error at interpreter level 0, adding "while executing" and the
        # file line; a sourced script can't. The message must agree, and no
        # launcher frame may show.
        need [expr {[lindex [split $nErr \n] 0] eq [lindex [split $iErr \n] 0]}] "stderr differs from native tclsh"
        need [expr {[string first tclvenv::runtime $iErr] < 0}] "stderr shows the launcher's frames"
        cover top-level-return-limit
    } else {
        need [expr {$nErr eq $iErr}] "stderr differs from native tclsh"
    }
}

# --- linkedlaunchers -------------------------------------------------------------

proc ::fuzz::scenario_linkedlaunchers {} {
    variable active
    variable envdir
    variable current
    if {![shellsUnix]} { return }
    # A package only the environment has.
    set source [file join $active envonly]
    file mkdir $source
    writeText [file join $source pkgIndex.tcl] {package ifneeded envonly 1.0 [list package provide envonly 1.0]}
    status [invoke manager [list install $envdir $source]] 0 "fixture package did not install"
    set work [file join $active work]
    file mkdir $work
    set app [file join $work app.tcl]
    writeText $app "puts \[list \[package require envonly\] \$argv \[info script\]\]\n"
    set arguments [list $app]
    for {set i 0; set n [number 3]} {$i < $n} {incr i} { lappend arguments [word 1] }
    set direct [shellRun [list [file join $envdir bin tclsh] {*}$arguments] $work ""]
    dict lappend current operations [dict create entry direct result $direct]
    status $direct 0 "the launcher failed by its own path"
    set links [file join $active [leaf links]]
    file mkdir $links
    set kind [pick {absolute relative chain bin-directory environment-directory path-lookup tclvenv}]
    cover $kind
    set name [pick [list tclsh mytclsh [leaf tcl]]]
    dict set current input [dict create mode $kind name $name arguments $arguments]
    set target [file join $envdir bin tclsh]
    set input ""
    switch -- $kind {
        absolute {
            file link -symbolic [file join $links $name] $target
            set command [list [file join $links $name] {*}$arguments]
        }
        relative {
            # links and env are both directly in the case directory.
            set made [run [list ln -s -- ../env/bin/tclsh [file join $links $name]] $active]
            status $made 0 "could not make a relative link"
            set command [list [file join $links $name] {*}$arguments]
        }
        chain {
            file link -symbolic [file join $links first] $target
            file link -symbolic [file join $links $name] [file join $links first]
            set command [list [file join $links $name] {*}$arguments]
        }
        bin-directory {
            file link -symbolic [file join $links bin] [file join $envdir bin]
            set command [list [file join $links bin tclsh] {*}$arguments]
        }
        environment-directory {
            file link -symbolic [file join $links env] $envdir
            set command [list [file join $links env bin tclsh] {*}$arguments]
        }
        path-lookup {
            set safe [string map {/ _ \n _ \0 _} $name]
            file link -symbolic [file join $links $safe] $target
            set command [list env PATH=$links:$::env(PATH) $safe {*}$arguments]
        }
        tclvenv {
            file link -symbolic [file join $links $name] [file join $envdir bin tclvenv]
            set command [list [file join $links $name] list $envdir]
            set expected [shellRun [list [file join $envdir bin tclvenv] list $envdir] $work ""]
            dict lappend current operations [dict create entry tclvenv-direct result $expected]
            status $expected 0 "bin/tclvenv failed by its own path"
            set direct $expected
        }
    }
    set linked [shellRun $command $work $input]
    dict lappend current operations [dict create entry linked result $linked]
    status $linked 0 "a launcher reached through a symbolic link failed: [string range [string trim [dict get $linked stderr]] 0 200]"
    need [expr {[dict get $linked output] eq [dict get $direct output]}] "a launcher reached through a symbolic link behaved differently"
}
