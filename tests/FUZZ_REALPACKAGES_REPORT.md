# Real-package, isolation and REPL fuzzing report

The earlier `add` groups (`systemadd`, `sources`) build their own package
trees. This round tries `add` on the packages really installed on this
system, and probes three areas no group had covered: package isolation
against the environment variables native Tcl reads, the interactive REPL on
a terminal, and `install --subdir`.

| Check | Generates | Oracle |
| --- | --- | --- |
| `realpackages` (fuzz group, `tests/fuzz_system.tcl`) | 1-3 packages chosen at random from what `available` lists (here 481 names: about 450 from Tcllib, the rest from the distribution's binary package directories) added to one environment; then every installation removed in a random order | native `tclsh` with the same default package path: a package it loads must be added, load inside the environment at the same version, and leave `doctor` passing; one it can't load must be refused cleanly with nothing left; removing everything must empty `lib/` and `modules/` with `doctor` passing |
| `tests/sweep_packages.tcl` (exhaustive) | every package `available` lists, each added to a fresh environment | the same oracle, for every package |
| isolation (by hand) | packages planted where native Tcl looks: `TCLLIBPATH`, `TCL8_TM_PATH`, `TCL8_6_TM_PATH`, `TCL8_6_0_TM_PATH`, `TCL9_TM_PATH`, `TCL9_0_TM_PATH`, `TCL9_0_0_TM_PATH`; through `bin/tclsh` and `run`, default and `--system-packages` environments | the README: a default environment loads none of them; a `--system-packages` one loads what native Tcl loads |
| REPL (by hand) | a terminal session (`script`) with results, errors, `puts -nonewline`, a multi-line `proc`, an unbalanced command, `tcl_prompt1`, `info script`, `exit 3`, and scripts reading stdin themselves (`gets stdin`, `read stdin 3`, `fconfigure stdin -blocking`) in the REPL and in stdin mode | native `tclsh` on the same terminal input: identical bytes and exit status |
| `--subdir` (by hand) | tar and zip archives holding several packages; `--subdir` as written, with a trailing `/`, `./`, `//`, `..`, an absolute path, backslashes, other case, a file, an empty value | the named package installs alone; anything outside the archive or not a package directory is refused cleanly |

Campaign: the sweep over every listed package (480 on Tcl 8.6.18, 478 on
9.0.4 before the fixes; 481 on both after, `available` now also listing what
an index provides itself), and `realpackages`.

## Findings

### 1. A package an index provides itself is taken for part of Tcl and not copied

Tcllib's `try/pkgIndex.tcl` doesn't register `file::home` on Tcl 9; it
provides it while the index is read:

```tcl
if {[package vsatisfies [package provide Tcl] 9-]} {
    package provide file::home 1
    return
}
package ifneeded file::home 1 [list source [file join $dir fhome.tcl]]
```

`discover` recorded only `package ifneeded` calls. When the traced load
reached `file::home`, no registration matched, so `provider` decided it was
built into Tcl (`core`) and skipped it. The environment then lacked it, and
every package requiring it, directly or through others, was refused:

```text
$ tclsh9.0 tclvenv.tcl add ENV doctools::idx::export
Installed snit (snit 2.3.4 from /usr/share/tcltk/tcllib2.0/snit)
...
Removed snit
tclvenv: doctools::idx::export does not load in the environment, so nothing was added: can't find package file::home
$ echo 'puts [package require doctools::idx::export]' | tclsh9.0
0.2.2
```

Found by the sweep on Tcl 9.0: `doctools::idx::export`, `doctools::idx::import`,
`doctools::toc::export`, `doctools::toc::import` (through `pluginmgr`). Tcl 8.6
was unaffected (there the index registers `file::home` with `ifneeded`).
`available` didn't list `file::home` either.

### 2. A package that loads Tk opens a window and makes `add` wait 30 seconds

`discover` and the load check run the package in a helper `tclsh`
(`discover.tcl`, and `script.tcl` for the check). When the package loads Tk
(`Tk` itself, Tcllib's `map::slippy::*`, anything built on Tk), Tk creates
its main window and installs its main loop, so the helper doesn't exit after
writing its result. It shows a window titled `discover.tcl` (or `script.tcl`)
on the user's display and waits. The manager waits for the helper's output
to end, which happens only when someone closes the window, or at the 30 s
probe timeout:

```text
$ tclsh9.0 tclvenv.tcl add ENV Tk        # a window "discover.tcl" appears
tclvenv: could not run the environment's Tcl: Tcl runtime did not finish within 30.0 s: /usr/bin/tclsh9.0
```

Found because it made the sweep flaky: the same package failed in one run
and passed in another, depending on whether a window was closed before the
timeout (it was: the user reported the windows while the sweep ran). Checked
with `xwininfo` on the old and new code: before the fix every
Tk-loading `add` showed a `discover.tcl` window and failed at 30 s; after
it, no window, and `add Tk` takes 0.4 s.

### 3. Tk 8.6 can't be added: its script library isn't copied

On Debian (and other distributions that split Tk the same way), Tk 8.6's
index is in `/usr/lib/tcltk/x86_64-linux-gnu/tk8.6`, its script library
(`tk.tcl`, `ttk/`, ...) in `/usr/share/tcltk/tk8.6`. Tk finds the library
with `tcl_findLibrary`, which looks in `tk8.6` under each `auto_path`
directory: native Tcl finds `/usr/share/tcltk/tk8.6` that way. `add` copied
only the index's directory, and the environment's `auto_path` leaves the
system's out, so Tk failed to initialise there:

```text
$ tclsh8.6 tclvenv.tcl add ENV Tk
tclvenv: Tk does not load in the environment, so nothing was added: Can't find a usable tk.tcl in the following directories:
    ENV/lib/tk8.6 /usr/share/tcltk/tcl8.6/tk8.6 /usr/lib/tk8.6 /lib/tk8.6 /usr/library
```

So no Tk package could be added on Tcl 8.6 (on Tcl 9, Tk's library is
inside its shared library). Before the fix for finding 2, this was hidden:
`add` timed out in `discover` before the load check could report it. Found
once finding 2 was fixed (`map::slippy::cache` and `map::slippy::fetcher`
on Tcl 8.6).

### Minor: an unsafe `--subdir` is reported as an archive entry

`--subdir ../x` (or `/top/a`, `top\a`) is refused, correctly, but with
`unsafe archive entry name: ../x`: the value came from the command line, not
the archive. Not fixed; noted.

### Observation: `add` of a package with a large closure takes seconds

`add httpd` takes about 6 s on this machine, where native
`package require httpd` takes 0.15 s. The traced load reaches 3.7 MB of
files (Tcllib's `tcllibc` and `fileutil::magic`, `Trf`, `tcludp`, ...), and
each copied file is hashed once with the manager's SHA-256, written in Tcl
(about 1.3 s per MB). That is the cost of detecting deliberate changes
(hostile-input finding 10), not a defect. A faster hash (the `sha256`
package's C code when installed, or `sha256sum`) would help large closures.
The fuzz group allows a minute per command.

## Fixes

| # | Fix | Regression tests (`tests/discovery.test`) |
| --- | --- | --- |
| 1 | While `discover` reads indexes, a `package provide NAME VERSION` is recorded as a registration from that index's directory, with an empty script. `provider` already chooses the registration whose script is the one `package ifneeded` reports, which is empty for such a package, so the directory is copied. `available` lists it with its directory. | `provided-1.add` (a package requiring one an index provides), `provided-1.direct`, `provided-1.available`, `provided-1.remove` |
| 2 | Both helpers withdraw Tk's main window right after each `package require` when Tk has been loaded (Tk shows it only once the event loop runs), and end with `exit 0` after writing their result, so Tk's main loop never runs. A user's own script that loads Tk still enters the event loop, as under native `tclsh`. | `tk-2.add`, `tk-2.install` (both need a display where Tk loads; each checks that the command finishes before a 5 s probe timeout, which the old code never did, and, with `xwininfo` when available, that no `discover.tcl` or `script.tcl` window is left afterwards; the windows themselves were checked by watching `xwininfo` during the runs) |
| 3 | `discover` traces `tcl_findLibrary` during the load and records, for the package being required, the directory it chose (`tk_library`). A library outside that package's directory (not Tcl's own, not in a zipfs) is listed in its closure entry. `add` merges it into the copied directory when that directory has the name `tcl_findLibrary` looks for (`tk8.6`), under the same receipt, so removal and `doctor` cover it. Files of the index's directory win over the library's. A library that can't be merged is reported (`Not copied: ...`) and left to the load check. | `library-3.add` (a synthetic extension that calls `tcl_findLibrary` with its library in another directory, no display needed), `library-3.remove` |

Every test but `provided-1.remove` fails on the code before the fixes (7
of 8; `provided-1.remove` checks that removal still cleans up). The README
describes the provider rule, Tk's main window and the copied libraries.

After the fixes, on the final code: the sweep checked all 481 packages on
each of Tcl 8.6.18 and 9.0.4 with no problems, and `realpackages` passed 50
cases for each of seeds 1, 7 and 11 on Tcl 8.6 and seed 1 on Tcl 9.0 (200
cases). The Tcl 9.0 runs for seeds 7 and 11 were stopped unfinished to
close the round. An `xwininfo` monitor polling every 0.2 s through all of
these runs saw no window from a Tcl script. The full suite passes on both
versions.

## Not found

- `realpackages` and the sweep: apart from findings 1-3, every listed
  package met the oracle on both versions: what native Tcl loads was added,
  loaded in the environment at the native version, passed `doctor`, and was
  removed without leftovers (in random orders in `realpackages`); what
  native Tcl can't load was refused cleanly with nothing left behind.
- Isolation: a default environment loaded none of the planted packages
  through any variable or entry point; a `--system-packages` environment
  loaded exactly what native Tcl loaded (on Tcl 8.6 `plib` and `mtm86`, on
  9.0 `plib` and `mtm90`). Native Tcl 9 on this machine overwrites a global
  variable named `p` while it searches packages with `TCLLIBPATH` set (a
  quirk of the distribution's Tcl, seen only in the native run).
- REPL: identical to native `tclsh` on both versions, byte for byte,
  including prompts, results, errors, `tcl_prompt1`, an unbalanced command,
  scripts reading stdin while the REPL runs, and the exit status.
- `--subdir`: equivalent spellings (`top/a/pa`, `top/a/pa/`, `./top/a/pa`,
  `top//a/pa`) choose the same package in tar and zip; `..`, absolute paths,
  backslashes, a file, another case and a missing name are refused cleanly.
- Option parsing: there is no `--` to end options, so a pattern or source
  beginning with `--` can't be given (a `./` prefix works for paths).
  Conventional, not counted.

Replay a `realpackages` case with
`tclsh tests/fuzz.tcl --only realpackages --seed SEED --iterations N --case INDEX`.
The packages chosen depend on what is installed, so a case replays only on a
system with the same packages.
