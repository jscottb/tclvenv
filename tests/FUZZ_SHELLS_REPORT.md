# Shell, launcher and command-line fuzzing report

The earlier groups test the manager, the package sources and the runtime
behind the launchers. The `paths` group sources `bin/activate` once, with
`sh`, and checks only that `PATH` and `TCLVENV` come back. The `argv` and
`completions` groups pass every script after `--` and compare only the first
line of an error. The groups in `tests/fuzz_shells.tcl` test what surrounds
the environment: the shells that source `bin/activate`, the POSIX launchers
reached in the ways users reach them, and the native `tclsh` command line
that `bin/tclsh` stands in for.

| Group | Generates | Oracle |
| --- | --- | --- |
| `activation` | one or two environments created with hostile names (`$(touch PWNED)`, backquotes, `\u`, `\w`, `\$`, `!`, `%`, quotes, spaces, tabs, `:`, Unicode, a trailing newline); `PATH`, `TCLVENV` and `PS1` each unset, empty, set or set but not exported; `set -u`/`-e`/`-eu`; 1-6 steps activating either environment or deactivating; sometimes a `deactivate` function defined beforehand by "another tool"; run by dash, bash (`--norc --noprofile`) and busybox `sh` | the shell's own record after every step: each variable's value (hex), whether it is set, whether a child process sees it (exported), `command -v tclsh`, whether `deactivate` exists, and in bash `${PS1@P}`. While active: `PATH` is `ENV/bin` before the old value, `TCLVENV` is the root, `PS1` is `(NAME) ` before the old prompt and displays as such, `tclsh` is the environment's. After `deactivate`: everything as before activation, including export status and another tool's `deactivate`. Nothing named `PWNED` is ever created, and nothing is printed on stderr |
| `tclshargs` | first argument `-`, `-e`, `-x`, `-c`, `-h`, `-help`, `--help`, `--version`, `-v`, `-encodingx`, a script named `-main.tcl`, `-encoding` alone, with one word, with a script (`utf-8`, `iso8859-1`, unknown); then 0-3 hostile words. Scripts that print their arguments and then fail in a procedure, at top level, with `return -code error -errorinfo`, with `-errorcode`, by a syntax error, inside a sourced file, or `exit N`. Stdin always holds a program. Through `bin/tclsh` and `run ENV --` | native `tclsh` with the same words and stdin, in the same directory: exit status, stdout and stderr byte for byte, after replacing each interpreter's own path with a placeholder. `--`, `--interactive` and `--stdin` are documented launcher options and never generated first |
| `linkedlaunchers` | `bin/tclsh` reached through an absolute or relative symbolic link, a chain of two, a link to `bin/`, a link to the environment, a link found by `PATH` under another name (`tclsh`, `mytclsh`, hostile names); `bin/tclvenv` through a link | the same launcher run by its real path: it loads a package only the environment has, with the same arguments and output |

Campaign: Tcl 8.6.18 and 9.0.4, 150 cases per group, seeds 1, 7 and 11.

Each Tcl version found the same failures in the same cases:

| Group | Failures (seeds 1/7/11), per Tcl version | Findings |
| --- | --- | --- |
| `activation` | 88/85/87 | 1, 3, 4, 5, 6 |
| `tclshargs` | 119/131/128 | 8, 9 |
| `linkedlaunchers` | 114/109/108 | 2 |

The rates are high because each finding lies on a common path: every link
kind except linked directories fails, every script error's trace differs,
and 1 in 5 activation cases defines another tool's `deactivate`. Failures
per finding over the three seeds (the same on each Tcl version): 1, 39
commands run and 38 prompts shown wrongly; 2, 331; 3, 48; 4, 68; 5, 34; 6,
33; 8, 200; 9, 178. A case counts under its first failed check, and
`tclshargs` cases are counted by generated form (forms starting with `-` or
`-encoding` with fewer than three words under 8, the rest under 9), so the
8 and 9 counts are approximate.

`ENV` is an environment created with the manager. Each finding has a reduced
reproduction.

## Findings

### 1. Shells run commands in the environment's name every time they show the prompt

`activate` puts the directory name into `PS1` as it is:
`PS1="($(basename -- "$TCLVENV")) $PS1"`. bash (with `promptvars`, the
default) expands parameters, command substitutions and backslash escapes in
`PS1` before every prompt. Interactive dash and busybox `sh` expand
parameters and command substitutions in it too (checked through a
pseudo-terminal while fixing: `PS1='($(echo CMD))'` shows `(CMD)`), and
zsh does with `PROMPT_SUBST`. The campaign's oracle checked only bash's
prompt; dash and busybox were found while fixing. A directory name is
therefore code that runs each time the prompt is shown, as long as the
environment is active:

```sh
tclsh tclvenv.tcl create '$(touch PWNED)x'
bash -c 'PS1="> "; . "./\$(touch PWNED)x/bin/activate"; echo "${PS1@P}"'
# (x) >          and ./PWNED now exists
tclsh tclvenv.tcl create 'env\u'
bash -c 'PS1="$ "; . "./env\u/bin/activate"; echo "${PS1@P}"'
# (envscott) $
```

The name can come from a cloned repository, an unpacked archive or a shared
directory that someone else named, so activating it in an interactive bash
runs that person's command. (The suggestion below was written before the
fix; see Fixes.) A fix escapes the name for the prompt: in bash
and zsh, put it in a variable and reference the variable from `PS1`
(`_TCLVENV_PROMPT=$(basename …)`, `PS1='(${_TCLVENV_PROMPT}) '"$PS1"`), which
the prompt expands without re-evaluating it; or replace `\`, `$` and `` ` ``
with escaped forms.

### 2. A symbolic link to `bin/tclsh` or `bin/tclvenv` can't find the environment

The launchers find the environment from `dirname "$0"`. `cd -P` resolves
links in that directory, not a link to the launcher itself, so a link
elsewhere looks for `metadata/` beside the link:

```sh
mkdir -p ~/bin && ln -s "$PWD/ENV/bin/tclsh" ~/bin/projtclsh
echo 'puts ok' | ~/bin/projtclsh
# couldn't read file "/home/u/bin/../metadata/runtime.tcl": no such file or directory
```

Absolute, relative and chained links all fail, as does a link found through
`PATH`. Links to the `bin` or environment directory work. A Python venv's
`bin/python` works through a link, so users expect this to work too. A fix resolves `$0`
before taking its directory (a `readlink` loop; `readlink` without `-f` is
in POSIX.1-2024 and in every current Linux, BSD and macOS), or falls back to the root recorded at creation as
`activate` does.

### 3. `deactivate` deletes another tool's `deactivate`

Python's venv and others use the same function name. Activating a tclvenv
inside an active Python venv replaces Python's `deactivate`, and tclvenv's
`deactivate` ends with `unset -f deactivate`, so the Python venv can no longer
be deactivated:

```sh
python3 -m venv pyv
bash -c '. pyv/bin/activate; . ENV/bin/activate; deactivate; type deactivate'
# bash: type: deactivate: not found        (VIRTUAL_ENV still set, pyv/bin still on PATH)
```

In the other order, Python's `activate` starts with `deactivate nondestructive`
(its own, just defined) and then replaces tclvenv's. TCLVENV and `ENV/bin`
then stay set with no way to remove them. POSIX sh can't save and restore a function, so
a portable fix is a name only tclvenv uses (for example `tclvenv_deactivate`,
also defined as `deactivate` only if no `deactivate` exists), or refusing to
activate over an existing `deactivate` with a message.

### 4. `deactivate` exports variables that weren't exported

`deactivate` restores `PATH` and `TCLVENV` with `export`, whatever they were
before. A shell variable `TCLVENV` that was never exported is passed to
every program started after `deactivate`:

```sh
dash -c 'TCLVENV=mine; . ENV/bin/activate; deactivate; sh -c "echo \${TCLVENV-unset}"'
# mine        (before activation a child saw: unset)
```

A child process that sees `TCLVENV` (a later activation, or a script
checking whether it runs in an environment) then gets a stale value. The fix
records whether each variable was exported (`_TCLVENV_ROOT_EXPORTED=$(sh -c
'printf %s "${TCLVENV+x}"')`, or `export -p` parsing) and exports only then.

### 5. With `PATH` empty or unset, activation fails, and under `set -e` kills the shell

The prompt needs the external `basename`. With `PATH` empty (or unset; dash,
bash and busybox all fail to find it then), and `PS1` set:

```sh
dash -c 'PS1="$ "; PATH=; . ./ENV/bin/activate; echo "$PS1"'
# dash: 13: ./ENV/bin/activate: basename: not found
# () $
dash -c 'set -e; PS1="$ "; PATH=; . ./ENV/bin/activate; echo still-running'; echo $?
# dash: 13: ./ENV/bin/activate: basename: not found
# 127
```

Under `set -e`, the failed command substitution in the `PS1` assignment exits
the shell that sourced `activate`, which may be a provisioning or CI script.
Using `${TCLVENV##*/}` (the root has no trailing slash) avoids running any
command at all.

### 6. An environment whose path holds `:` activates without effect

`PATH` can't hold a directory whose name contains `:`, so `ENV/bin` is split
in two, and the system `tclsh` stays first. Nothing reports this:

```sh
tclsh tclvenv.tcl create 'a:b'
dash -c '. ./a:b/bin/activate; command -v tclsh; echo $TCLVENV'
# /usr/bin/tclsh
# /…/a:b
```

`create` could refuse such a destination, or warn that it can't be
activated (it can still be used through `ENV/bin/tclsh` and `run`).

### Minor: a name ending in a newline loses it in the prompt

`$(basename …)` removes trailing newlines. That only affects the prompt
text, and the oracle accepts it. The fix suggested for 5 keeps the name as
it is.

### 8. Arguments starting with `-` are taken as a script, not passed to stdin mode

Native `tclsh` treats its first argument as a script only if it doesn't
start with `-`, or after `-encoding NAME`. Otherwise it reads stdin and
puts every argument in `argv`. `bin/tclsh` and `run` source any first
argument other than `--`, `--interactive` and `--stdin`, and `-encoding`
with fewer than three words is an error:

```sh
echo 'puts $argv' | tclsh9.0 - x          # - x
echo 'puts $argv' | ENV/bin/tclsh - x     # couldn't read file "-": no such file or directory … exit 1
echo 'puts $argv' | tclsh9.0 -encoding    # -encoding
echo 'puts $argv' | ENV/bin/tclsh -encoding
# expected -encoding ENCODING SCRIPT ?ARG ...?  (with a stack trace) exit 1
printf 'puts sourced\n' > ./-x.tcl
echo 'puts stdin' | tclsh9.0 -x.tcl       # stdin
echo 'puts stdin' | ENV/bin/tclsh -x.tcl  # sourced
```

Found in every seed (`dash-word`, `dash-script`, `lone-encoding`,
`encoding-one`). The README says arguments are preserved "as in native
`tclsh`" and only documents `--`, `--interactive` and `--stdin` as options
of the launcher's own. The fix follows `Tcl_Main`: a first argument starting with `-`
(other than those three, and `-encoding` with at least two more words) means
stdin mode with all the arguments in `argv`. The `-- SCRIPT` form already
covers scripts whose names start with `-`.

### 9. Script errors carry six lines of launcher frames; a top-level `return -code error` loses its file line

The runtime sources the script through `uplevel #0 $::tclvenv::runtime::scriptCommand`
and prints the resulting `errorInfo`:

```text
$ printf 'proc f {} { error boom }\nf\n' > e.tcl
$ tclsh9.0 e.tcl                       $ ENV/bin/tclsh e.tcl
boom                                    boom
    while executing                         while executing
"error boom "                           "error boom "
    (procedure "f" line 1)                  (procedure "f" line 1)
    invoked from within                     invoked from within
"f"                                     "f"
    (file "e.tcl" line 2)                   (file "e.tcl" line 2)
                                            invoked from within
                                        "source e.tcl"
                                            ("uplevel" body line 1)
                                            invoked from within
                                        "uplevel #0 $::tclvenv::runtime::scriptCommand"
```

A missing script or an unknown `-encoding` also gets the frames
(`couldn't read file "x.tcl"` is one line in native Tcl). Editors and test
runners that read the last frame are led to the launcher. The `completions`
group compares only the first line ("stack frames necessarily differ").
They don't have to differ: removing the launcher's fixed suffix from the
end of `errorInfo` (`invoked from within` or `while executing`, `"source …"`,
`("uplevel" body line 1)`, `invoked from within`, `"uplevel #0
$::tclvenv::runtime::scriptCommand"`) gives native output byte for byte
for an error in a procedure, a top-level `error`, a syntax error, an error
in a file the script sources, and a missing script (checked by hand on Tcl
9.0.4).

A top-level `return -code error` loses frames as well. Native Tcl prints

```text
coded
    while executing
"return -code error -errorcode {A B} coded"
    (file "errorcode.tcl" line 1)
```

(with `-errorinfo custom`: `custom` and `(file "r.tcl" line 1)`). The
environment prints `coded` (or `custom`) followed by only the launcher
frames. `Tcl_Main` evaluates the file itself and turns the return code into
an error with the file line; the runtime's `source` returns the code to
`uplevel`, which turns it into an error without the frames. Restoring these
needs the runtime to add the native frames itself for this completion.

## Fixes

| # | Fix | Regression tests (`tests/shells.test`) |
| --- | --- | --- |
| 1 | `activate` stores the name in `_TCLVENV_PROMPT` and puts `${_TCLVENV_PROMPT}` in `PS1`: bash, dash and busybox expand the reference at each prompt without evaluating its value. bash with `promptvars` off gets the name with `\` doubled; zsh gets `%` doubled, and the reference only with `PROMPT_SUBST` (the literal name otherwise, which zsh then doesn't evaluate). `deactivate` unsets the variable. | `prompt-1.dash`, `prompt-1.bash`, `prompt-1.busybox`, `prompt-1.escapes`, `prompt-1.restored` |
| 2 | The POSIX launchers (`bin/tclsh`, `bin/tclsh8.6`/`9.0`, `bin/tclvenv`) follow links to themselves with a `readlink` loop (at most 40 hops; relative targets taken from the link's directory; trailing newlines kept) before finding `bin/`. | `launcher-2.absolute`, `.relative`, `.chain`, `.path`, `.tclvenv` |
| 3 | `activate` always defines `tclvenv_deactivate`, and defines `deactivate` only when no command of that name exists; otherwise it says, on stderr, to use `tclvenv_deactivate`. Its `deactivate` ignores `deactivate nondestructive` (what a Python venv's `activate` calls to reset its own state). `tclvenv_deactivate` removes `deactivate` only if it defined it, and, where the shell can show a function's body (bash, zsh, ksh), only while it is still its own. Re-activation calls `tclvenv_deactivate` (or `deactivate` for an environment made before this change). | `deactivate-3.foreign`, `.own`, `.python-inside`, `.python-outside` |
| 4 | `activate` records whether a child process sees `TCLVENV` (`/bin/sh -c 'printf %s "${TCLVENV+x}"'`); `deactivate` unsets it and, when it was set, sets it again and exports it only if it was exported. | `export-4.unexported`, `export-4.exported` |
| 5 | The name comes from `${TCLVENV##*/}` (the root never ends in `/`): activation runs no external command, so an empty or unset `PATH` works, with or without `set -e`. | `path-5.empty`, `path-5.unset` |
| 6 | `create` refuses a destination whose path (with `bin`) contains the `PATH` separator, `:` (`;` on Windows), before doing anything else. | `create-6.colon`, `create-6.parent` |
| 8 | The runtime parses arguments as `Tcl_Main` does: a first argument is a script unless it starts with `-`; `-encoding NAME SCRIPT` needs at least three words and a `SCRIPT` that doesn't start with `-`; otherwise stdin is read with every argument in `argv`. `--`, `--interactive` and `--stdin` keep their meaning. The POSIX launcher marks stdin interactive whenever it is a terminal (the runtime ignores that for scripts), so `bin/tclsh -x` on a terminal opens the REPL as native `tclsh` does; `tclsh.ps1` does the same. | `args-8.dash`, `.dash-script`, `.option`, `.lone-encoding`, `.encoding-name`, `.encoding-dash`, `.encoding-unknown`, and `.script`, `.encoding-script`, `.double-dash` (kept working) |
| 9 | Before printing a script's `errorInfo`, the runtime removes its own fixed suffix (`("uplevel" body line 1)`, `invoked from within`, `"uplevel #0 $::tclvenv::runtime::scriptCommand"`) and the `source` frame before it. This gives native output byte for byte for every error except a top-level `return -code error`, where only the message is printed (no launcher frames). `Tcl_Main` handles that return at interpreter level 0, where Tcl turns it into an error that names the `return` command and its line. A script run by `source` never reaches level 0, and the command and line aren't in the error's options. An execution trace on `return` could record them, but would slow down every `return` in every procedure, so this case is documented as a limit (README) instead. | `trace-9.procerror`, `.toperror`, `.syntax`, `.sourced`, `.missing`, `.top-level-return` |

30 of the 36 regression tests fail on the code before the fixes (checked by
running `tests/shells.test` against the previous commit's `lib/`). The other
six guard behaviour that has to keep working: `prompt-1.restored`,
`deactivate-3.own`, `export-4.exported`, `args-8.script`,
`args-8.encoding-script` and `args-8.double-dash`. The full suite passes on Tcl 8.6.18
and 9.0.4.

The fuzz groups changed with the fixes:

- `activation` checks the prompt as every shell shows it, not only bash's:
  for dash and busybox, `PS1` is expanded with `eval` (parameters and
  command substitutions, as those shells expand it), so the old text-in-`PS1`
  form now also fails there. It requires `create` to refuse names holding
  `:`. It leaves with `deactivate` or `tclvenv_deactivate` at random, and
  with `tclvenv_deactivate` when another tool's `deactivate` exists (whose
  one-line note is then expected on stderr). It checks that
  `tclvenv_deactivate` exists only while active. The "PATH set but not
  exported" initial state was dropped: a child shell can't tell an
  unexported `PATH` from a missing one (shells give `PATH` a default), so
  `activate` can't record it, and `deactivate` exports `PATH` as before.
- `tclshargs`: for a top-level `return -code error` (the `returnerror` and
  `errorcode` scripts run as a script), the first line of stderr must agree
  with native `tclsh` and no launcher frame may appear, instead of the whole
  stderr.
- The older `modes` group expected `bin/tclsh -encoding utf-8` to fail; it
  now expects stdin mode, as native `tclsh`.

After the fixes, `activation`, `tclshargs` and `linkedlaunchers` were rerun
with 150 cases per group, seeds 1, 7 and 11, on Tcl 8.6.18 and 9.0.4: no
failures. One `activation` case first failed on Tcl 8.6 only: its starting
prompt held bash's `\t` (the time), which had moved on by a second between
two records. The corpus now uses `\h` there, and `activation` was rerun
for every seed on both versions. The earlier groups that run the
launchers (`argv`, `paths`, `stdin`, `modes`, `completions`, `stdinmore`,
`cli`, `fakeruntime`, `names`) pass, `modes` with 100 cases per version.

## Not found

- `activation`: with a usable `PATH`, a set `PS1` and no other tool's
  `deactivate`, every sequence of activations of one or two environments,
  including re-activation and switching, set and restored `PATH`, `TCLVENV`
  and `PS1` to the byte (including values with newlines, quotes and `:`),
  removed `_TCLVENV_*` and `deactivate`, and `hash -r` made `tclsh` resolve
  correctly after each step, in all three shells, under `set -u`. Apart from
  bash's prompt expansion (finding 1), no name was ever evaluated, by
  `activate` or `deactivate`.
- `tclshargs`: scripts named normally, with or without `-encoding utf-8`
  or `iso8859-1`, produced native output, `argv`, `argv0`, `info script`
  and exit status (including `exit N`) in every case. Only stderr differed,
  as in finding 9.
- `linkedlaunchers`: links to `bin/` and to the environment directory work
  for every name.
- `add ENV PACKAGE VERSION` (tried by hand while choosing groups): every
  requirement form (`2`, `2-`, `1-2`, `3a0-`, `2-1`, malformed ones, several
  words in one argument) resolved or failed exactly as native
  `package require` does.

## Limits

- PowerShell and cmd.exe activation scripts are not run (no `pwsh` or
  Windows here); `Activate.ps1` puts the leaf name in the prompt through a
  string, not code, so finding 1 is not expected there. `Activate.ps1`
  also defines a global `deactivate`, as a Python venv's does, so finding 3
  probably applies to PowerShell too. It was left unchanged because it
  can't be tested here. The one-line change to `tclsh.ps1` (interactive
  whenever stdin is not redirected) is also untested.
- zsh and ksh were not installed; zsh with `PROMPT_SUBST` would be affected
  by finding 1 as bash is.
- The campaign ran into this machine's per-user `/tmp` quota (other
  projects' temporary files fill most of it). The runs were repeated one at
  a time, deleting failure artifacts after each run but keeping the failure
  lists and summaries. In one such run the harness's own temporary
  directory disappeared partway through (Tcl 9.0, seed 7, `activation` and
  `tclshargs`); those two were rerun, and gave the same counts as Tcl 8.6.

Replay any case with
`tclsh tests/fuzz.tcl --only GROUP --seed SEED --iterations N --case INDEX`.
