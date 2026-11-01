# Hostile-input fuzzing report

The earlier groups mostly choose among hand-written cases whose outcomes are
decided in advance. The groups in `tests/fuzz_hostile.tcl` generate their
inputs instead, and check outcomes against oracles written apart from the
production code:

| Group | Generates | Oracle |
| --- | --- | --- |
| `names` | package directory names, module filenames and removal IDs from a hostile alphabet (`~`, leading `.` and `-`, glob characters, newlines, 255/256-byte names, decomposed Unicode, versions such as `01`, `1..0`, `١`); `HOME` points at a guarded directory | a clean `tclvenv:` rejection with nothing changed, or: ID equals the basename, the tree is copied exactly to `lib/NAME`, the package loads, `doctor` passes, and removal by the listed ID restores the environment |
| `datafuzz` | 1-4 random structural (dictionary) or byte mutations of `tclvenv.cfg`, `installed.tcldata` or `core-files.tcldata`, then a random command | clean exit; read-only commands change nothing; an install or removal touches only its own package; whenever `doctor` passes, an independent consistency check agrees |
| `fakeruntime` | `create --tcl` with executables that hang, print garbage or 20 MB, report unsupported versions, fail, warn on stderr, or report a path containing shell syntax | terminates; a failure leaves no destination, lock or staging directory; nothing in a reported path is ever run |
| `concurrency` | 2-7 manager processes started together on one environment (install, remove, list, info, doctor), no hooks | only known failure messages; afterwards no lock or staging, receipts match the files, nothing unreceipted in `lib`, and `doctor` passes |
| `killpoints` | `SIGKILL` at a random time during install, remove or create of a 200-file package, with delays calibrated to the operations' measured duration | the source is untouched; a receipted package is complete (or complete in a removal journal's payload); pending removals resume; `doctor` never passes an inconsistent environment |
| `stdinmore` | stdin programs with CRLF endings, no final newline, backslash continuations, invalid UTF-8, 60-80 KB lines, scripts reading their own stdin, `exit` partway through, an unbalanced brace at EOF | exit status, stdout and stderr equal native `tclsh` reading the same bytes |

Campaign: Tcl 8.6.18 and 9.0.4, 150 cases per group (seeds 1, 7 and 11);
`killpoints` reached 25 killed installs and 55 killed removals per 150 cases,
43 of them resumed. `datafuzz` reached successful installs and removals on
mutated data as well as rejections.

## Findings

Each has a reduced reproduction. `ENV` is an environment created with the
manager.

### 1. `create` hangs on an interpreter that never exits

`probe` runs the selected executable with `exec` and no deadline. The same
applies to `doctor`, which probes the recorded runtime.

```sh
printf '#!/bin/sh\nexec sleep 3600\n' > hang-tcl; chmod +x hang-tcl
tclsh tclvenv.tcl create env --tcl ./hang-tcl    # never returns
```

### 2. One stderr line from the interpreter fails creation and dumps 450 KB

`exec` treats any stderr output as failure, so an interpreter that works but
prints a warning can't be used. The error message then includes the whole
probe output, base64-encoded core modules included (453 KB on Tcl 9.0.4).

```sh
printf '#!/bin/sh\necho warning >&2\nexec tclsh9.0 "$@"\n' > noisy-tcl; chmod +x noisy-tcl
tclsh tclvenv.tcl create env --tcl ./noisy-tcl   # exit 1, 453 KB on stderr
```

### 3. Invalid UTF-8 on stdin ends the REPL with a stack trace (Tcl 9)

Native `tclsh9.0` reads the same input.

```sh
printf 'puts \xff\xfe\n' | ENV/bin/tclsh
# error reading "stdin": invalid or incomplete multibyte or wide character
#     while executing "gets stdin line" ...
```

### 4. `info script` in stdin mode is the runtime's own path

Native `tclsh` returns an empty string; the environment returns
`ENV/bin/../metadata/runtime.tcl`.

```sh
echo 'puts [info script]' | ENV/bin/tclsh
```

### 5. An unfinished command at EOF prints a diagnostic native Tcl doesn't

`readCommand` prints `incomplete command at end of input`; native `tclsh`
silently ignores it. This looks deliberate, but the README describes stdin
behavior as matching native Tcl. Either the difference should be documented,
or removed.

```sh
printf 'puts before\nset x {\n' | ENV/bin/tclsh
```

### 6. A package directory named with a leading dot installs but can never load

Tcl's package search globs `*/pkgIndex.tcl`, which skips names beginning with
`.`. `install` accepts them, `doctor` passes, and `package require` fails.

```sh
mkdir .hidden; echo 'package ifneeded hp 1.0 {package provide hp 1.0}' > .hidden/pkgIndex.tcl
tclsh tclvenv.tcl install ENV .hidden
echo 'package require hp' | ENV/bin/tclsh       # can't find package hp
```

### 7. On Tcl 8.6, a directory named `~x` gets the ID `./~x`

Tcl 8.6's `file tail` protects a leading tilde. The package stays inside the
environment, but its ID isn't its basename (as the README says it is): `list`
shows `./~x`, and `remove ENV ~x` reports that it isn't installed. Tcl 9 gives
`~x`.

```sh
mkdir '~x'; echo '' > '~x/pkgIndex.tcl'
tclsh8.6 tclvenv.tcl install ENV '~x'            # Installed ./~x
```

### 8. Removing a namespaced module leaves its namespace directory

Installing `a::b-1.0.tm` creates `modules/a/`; removal deletes the module but
leaves the empty `modules/a/`, so install/remove cycles accumulate empty
directories.

### 9. `list` and `info` can fail while a removal finishes

`installed` checks a pending removal's staging directory with `pathExists`,
then calls `file type` on it; a concurrent removal can delete it in between:

```text
tclvenv: could not read "ENV/metadata/remove-_O1VSlQ": no such file or directory
```

Seen once in 150 concurrency cases. Read-only commands don't take the
mutation lock, so they should tolerate a staging directory disappearing.

### 10. Size and CRC-32 don't detect a deliberate change

CRC-32 is affine, so after any edit four compensating bytes restore the
original CRC with the size unchanged. `doctor` then reports the package
unchanged and `remove` deletes the modified data. The README says the
records weren't cryptographic, but also that removal refuses changed files.
Found by hand rather than by a fuzz group: `hash-10.forged` builds such a
change. `mtime` alone would catch ordinary edits but not one that sets the time
back, so the fix is a content hash (SHA-256, written in core Tcl, which has
none), with `mtime` recorded alongside.

## Fixes

| # | Fix | Regression tests (`tests/hostile.test`) |
| --- | --- | --- |
| 1 | The probe runs the interpreter through a pipe with a deadline (30 s, `TCLVENV_PROBE_TIMEOUT`) and kills it and its descendants after; output over 64 MiB also stops it. After end of output it doesn't wait for the process to exit (one that closed its output and kept running hung the close): the output decides, and an interpreter whose output isn't a valid identity is killed. | `probe-1.1` to `probe-1.4` |
| 2 | stderr goes to a file and is ignored unless the interpreter fails; messages quote at most the first line of stderr, never the output, and invalid output is reported as such. | `probe-2.1` to `probe-2.3` |
| 3 | A stdin read that fails to decode ends the input, as in native `tclsh`. | `stdin-3.invalid-utf8` |
| 4 | `info script` is cleared before the REPL starts. | `stdin-3.info-script` |
| 5 | An unfinished command at the end of stdin is dropped silently, as in native `tclsh`. | `stdin-3.unfinished-*` |
| 6 | Package directory names beginning with `.` are rejected with an explanation. | `names-6.1` |
| 7 | IDs and inventory keys use names as written (Tcl 8.6's `./~x` becomes `~x`), and components starting with `~` are joined as `./~x`, so they never mean a home directory. | `names-7.1`, `names-7.2` |
| 8 | Removing a module also removes the namespace directories it leaves empty. | `modules-8.1` |
| 9 | `installed` checks a pending removal's staging directory with one `lstat`. | `race-9.1` |
| 10 | Every file record adds a SHA-256 (core Tcl, unrolled) and its mtime. The hash decides whether content changed; mtime is recorded for diagnosis only, so writing the original bytes back makes a file unchanged again. The core-module snapshot and the per-file recheck just before deletion use CRC-32 only, after the full comparison. | `hash-10.*` |

A later review found that fix 7 had introduced a bug: inventory keys for
top-level entries were built with `expr`'s `?:`, which returns a name that
looks like a number as the number (`007` as `7`, `0x10` as `16`). Install and
`doctor` agreed with each other, but removal derives keys from the real paths,
so a package with such an entry was refused and left pending. Fixed with `if`;
`names-7.3` covers it, and `names` now also puts hostile names (these
included) inside package directories, where it found the bug on the previous
code in 31 of 150 cases.

The same groups and seeds, rerun after the fixes on Tcl 8.6.18 and 9.0.4,
report no violations (150 cases per group). `fakeruntime` now sets
`TCLVENV_PROBE_TIMEOUT` to one second, so a hanging runtime is stopped by the
probe's own deadline, inside the harness's.

## Not found

- `datafuzz`: no crash, traceback, out-of-environment write, or unexpected
  deletion from any mutation of the persisted data, and `doctor` never passed
  an environment the independent check found inconsistent.
- `killpoints`: no data loss at any kill time; every pending removal resumed.
- `fakeruntime`: no shell injection through a reported executable path.
