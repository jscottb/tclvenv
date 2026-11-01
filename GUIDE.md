# tclvenv usage guide

This guide shows how to use tclvenv day to day. The first part explains
what an environment is. The second, the cookbook, gives one recipe per task,
each with commands you can copy. The last part covers error messages and
gives a command reference. The [README](../README.md) has the full details
of each behaviour.

Examples use the installed `tclvenv` command (see [Install](#install)).
From a checkout without installing, write `tclsh /path/to/tclvenv.tcl`
wherever this guide writes `tclvenv`. Output shown is real output, with
long paths shortened to `…`.

- [Install](#install)
- [How tclvenv works](#how-tclvenv-works)
- Cookbook
  1. [Start a project environment](#1-start-a-project-environment)
  2. [Choose the Tcl version, or use several](#2-choose-the-tcl-version-or-use-several)
  3. [Run code in the environment](#3-run-code-in-the-environment)
  4. [Activate it in your shell](#4-activate-it-in-your-shell)
  5. [Install your own package](#5-install-your-own-package)
  6. [Add packages already on your system](#6-add-packages-already-on-your-system)
  7. [Install from an archive or a URL](#7-install-from-an-archive-or-a-url)
  8. [Make an environment reproducible](#8-make-an-environment-reproducible)
  9. [Run tests, in make and in CI](#9-run-tests-in-make-and-in-ci)
  10. [Tk applications](#10-tk-applications)
  11. [Use everything installed on the system](#11-use-everything-installed-on-the-system)
  12. [Upgrade, replace or remove a package](#12-upgrade-replace-or-remove-a-package)
  13. [Check an environment and recover](#13-check-an-environment-and-recover)
  14. [Delete or move an environment](#14-delete-or-move-an-environment)
  15. [Windows](#15-windows)
- [Error messages](#error-messages)
- [Command reference](#command-reference)

## Install

```sh
git clone … tclvenv && cd tclvenv
sh install.sh            # asks where: ~/.local/bin, ~/bin, /usr/local, or a directory
tclvenv --version
```

`sh install.sh --user` installs without asking, and `sudo sh install.sh
--system` installs for every user. `sh install.sh --uninstall` removes it
again. You need Tcl 8.6 or newer (`sudo apt install tcl`, or `tcl9.0`,
on Debian and Ubuntu). The README's [Install](../README.md#install)
section lists every option.

## How tclvenv works

An environment is a directory, usually `.venv` in your project, that ties
one installed Tcl interpreter to its own set of packages:

```text
.venv/
  bin/tclsh            launcher: runs the chosen Tcl with this environment
  bin/activate         puts bin/ first on PATH (also Activate.ps1, activate.bat)
  bin/tclvenv          the manager, as the environment's own copy
  lib/                 packages with a pkgIndex.tcl, one directory each
  modules/             Tcl modules (NAME-VERSION.tm)
  metadata/            the runtime, receipts of what is installed, core module copies
  tclvenv.cfg          which Tcl, and whether system packages are visible
```

Three things to know:

- **Isolation.** Code run through the environment sees only its own `lib/`
  and `modules/`, plus Tcl's own library. It doesn't see packages
  installed elsewhere on the system, `TCLLIBPATH`, or `TCLx_y_TM_PATH`.
  Add what you need into the environment, or create it with
  `--system-packages` ([recipe 11](#11-use-everything-installed-on-the-system)).
- **Nothing is built or downloaded for you.** tclvenv copies packages: from
  your own directories, from what is already installed on this machine
  (`add`), and from archives and URLs you name. It reuses an installed Tcl
  and never builds one.
- **Receipts.** Every install is recorded with the SHA-256 of each file it
  copied. `list` shows installations, `remove` takes one out (only if its
  files are unchanged), and `doctor` checks them all.

## Cookbook

### 1. Start a project environment

```sh
cd ~/projects/report-tool
tclvenv create .venv
```
```text
Created …/report-tool/.venv (Tcl 9.0.4)
```

Without `--tcl`, the environment uses the Tcl that runs `tclvenv` (the
installer chose it: see `head ~/.local/bin/tclvenv`). Check what you got:

```sh
tclvenv info .venv
```
```text
Environment: …/report-tool/.venv
Tcl: 9.0.4
Executable: /usr/bin/tclsh9.0
Core library: /usr/lib/tcl9.0
Platform: Linux / x86_64
System packages: 0
Installed packages: 0
Pending removals: 0
```

Keep the environment out of version control. It holds absolute paths and
is quick to rebuild ([recipe 8](#8-make-an-environment-reproducible)):

```sh
echo '.venv/' >> .gitignore
```

### 2. Choose the Tcl version, or use several

`--tcl` takes a command on `PATH` or a path:

```sh
tclvenv create .venv86 --tcl tclsh8.6
tclvenv create .venv90 --tcl tclsh9.0
tclvenv create .venv-custom --tcl /opt/tcl9/bin/tclsh9.0
```

Each environment is tied to its interpreter. After an upgrade of that Tcl
(say 9.0.4 to 9.0.5), the environment refuses to start (`Tcl runtime
changed (version); recreate this environment`), so packages never run
under a runtime they weren't checked against. Recreate it with the same commands ([recipe 8](#8-make-an-environment-reproducible)).

To check a library on both major versions:

```sh
for v in 86 90; do
    .venv$v/bin/tclsh tests/all.tcl || exit 1
done
```

### 3. Run code in the environment

Four ways, all with the environment's packages and none of the system's:

```sh
.venv/bin/tclsh app.tcl arg1 arg2          # the launcher: like tclsh, signals go straight to Tcl
tclvenv run .venv -- app.tcl arg1 arg2     # through the manager (supervised child process)
.venv/bin/tclsh                            # a REPL when run on a terminal
printf 'puts [info patchlevel]\n' | .venv/bin/tclsh   # a script on stdin
```

The launcher accepts what native `tclsh` accepts. `-encoding NAME SCRIPT`
gives the script's encoding. A first argument starting with `-` means
"read stdin" (as in `tclsh`). To run a script whose name starts with `-`,
write `-- -script.tcl`. `--interactive` forces the REPL and `--stdin`
forces stdin mode:

```sh
tclvenv run .venv -- --interactive         # a REPL through the manager
```

**A script that always runs in its environment.** Put the launcher in the
shebang line:

```tcl
#!/home/me/projects/report-tool/.venv/bin/tclsh
package require greeter
puts [greeter::hi $argv]
```
```sh
chmod +x hi.tcl && ./hi.tcl there
```
```text
hi there
```

(Linux reads the shebang path up to the first space, so the path must not
contain spaces. For a portable script, use `#!/usr/bin/env tclsh`, and
activate the environment before running it.)

**Call it from elsewhere by a short name.** Link to the launcher. The link
finds its environment:

```sh
ln -s ~/projects/report-tool/.venv/bin/tclsh ~/.local/bin/report-tclsh
report-tclsh report.tcl
```

**Your program's subprocesses.** A program run through the environment has
`TCLVENV` set to the environment's path, and the environment's `bin/` first
on `PATH`. So a child started as plain `tclsh` runs in the same
environment:

```tcl
# parent.tcl, run as .venv/bin/tclsh parent.tcl
puts [exec tclsh worker.tcl]                              ;# found on PATH: .venv/bin/tclsh
puts [exec [file join $env(TCLVENV) bin tclsh] worker.tcl] ;# the same, spelled out
```

`info nameofexecutable` still names the base interpreter (for example
`/usr/bin/tclsh9.0`), and running that one bypasses the environment.

### 4. Activate it in your shell

Activation puts `.venv/bin` first on `PATH`, so `tclsh` (and `tclsh9.0`,
or `tclsh8.6`) runs the environment's launcher:

```sh
. .venv/bin/activate          # bash, zsh, dash, busybox sh, ksh
tclsh app.tcl
deactivate
```

While it is active, `TCLVENV` holds the environment's path, and the prompt
starts with `(.venv)`. `deactivate` restores `PATH`, `TCLVENV` and the
prompt exactly as they were. Sourcing another environment's `activate`
switches to that environment.

**Together with a Python venv.** Both define `deactivate`. If one already
exists when you activate, tclvenv leaves it alone and says so. Leave the
Tcl environment with `tclvenv_deactivate`, which is always defined:

```sh
. venv/bin/activate           # Python
. .venv/bin/activate          # Tcl
# tclvenv: deactivate belongs to another tool here; leave this environment with tclvenv_deactivate
tclvenv_deactivate            # leaves the Tcl environment
deactivate                    # leaves the Python venv
```

In a script, prefer the launcher path to activation. It works in any shell
and needs no cleanup.

PowerShell and cmd.exe: see [recipe 15](#15-windows).

### 5. Install your own package

**A package directory** (a directory with a `pkgIndex.tcl`):

```text
src/greeter/
  pkgIndex.tcl      package ifneeded greeter 0.2 [list source [file join $dir greeter.tcl]]
  greeter.tcl       … package provide greeter 0.2
```
```sh
tclvenv install .venv src/greeter
tclvenv list .venv
```
```text
Installed greeter
greeter	lib/greeter	installed
```

The installation ID is the directory's name (`greeter`). The files are
copied: later edits under `src/` don't reach the environment until you
reinstall.

**A module** (`NAME-VERSION.tm`, one file):

```sh
tclvenv install .venv examples/hello-1.0.tm
```
```text
Installed hello@1.0
```

`install` names a module after its file alone: `install ns/smod-1.0.tm`
installs `smod`, not `ns::smod`. For a module that lives in a namespace
directory, use `add` with the directory above the namespace. That keeps the
namespace:

```sh
tclvenv add .venv ns::smod --path .        # ./ns/smod-1.0.tm
```
```text
Installed ns::smod@1.0 (ns::smod 1.0 from …/ns/smod-1.0.tm)
Added ns::smod 1.0
```

**Check that it loads, and add what it requires.** Directory and module
installs copy files only, by default. `--check` loads the package in the
environment and undoes the install if that fails. `--deps` adds the
packages its Tcl files `package require` from the system, as `add` would:

```sh
tclvenv install .venv src/greeter --check --deps
```

**The edit, reinstall, test loop.** An installation is a copy, so after
editing the source:

```sh
tclvenv remove .venv greeter && tclvenv install .venv src/greeter
```

For quicker iteration, skip the install and point your test script at the
source directory itself (`lappend auto_path src`). Install it once it is
ready to be used like a dependency.

### 6. Add packages already on your system

`add` copies a package that is installed on this machine (Tcllib, a
distribution package, something under `/usr/local`), together with
everything it loads.

**Find it.** `available` lists what `add` can find, with a glob pattern:

```sh
tclvenv available .venv 'json*'
tclvenv available .venv 'sqlite*'
```
```text
json	1.3.6	/usr/share/tcltk/tcllib2.0/json
json::write	1.0.5	/usr/share/tcltk/tcllib2.0/json
sqlite3	3.53.4	/usr/lib/tcltk/sqlite3
sqlite3	3.54.1	/usr/local/lib/tcltk/sqlite3.54.1
```

**Add it:**

```sh
tclvenv add .venv json
tclvenv add .venv sqlite3
```
```text
Installed json (json 1.3.6 from /usr/share/tcltk/tcllib2.0/json)
Added json 1.3.6
Installed sqlite3.54.1 (sqlite3 3.54.1 from /usr/local/lib/tcltk/sqlite3.54.1)
Added sqlite3 3.54.1
```
```sh
echo 'package require json; puts [json::json2dict {{"a": [1, 2]}}]' | .venv/bin/tclsh
```
```text
a {1 2}
```

`add` loads the package in the environment's own Tcl and records every
`package require` it makes on the way. Exactly those packages, at the
versions that loaded, are copied, and each comes from its own directory.
So `add json` copies Tcllib's `json` directory, not all of Tcllib. A binary
package built for another Tcl version is never picked. After copying, the
package is loaded again inside the environment. If that fails, everything
the command copied is removed.

**Choose a version.** The optional VERSION is a Tcl requirement, as in
`package require`:

| VERSION | Means |
| --- | --- |
| `1.2` | 1.2 or newer, below 2 (Tcl picks the newest such) |
| `1.2-` | 1.2 or newer, any major version |
| `1.2-1.4` | at least 1.2, below 1.4 |
| `1.2.3-1.2.3` | exactly 1.2.3 |

```sh
tclvenv add .venv sqlite3 3.53      # the newest 3.x from 3.53 on: 3.54.1 here
```

**Packages from a directory of your own.** `--path DIR` (repeatable) adds
directories to the search, as if they were on `auto_path`:

```sh
tclvenv add .venv mypkg 1.2 --path ~/tcl/lib
```

**Only the named package.** `--no-deps` copies just that package and lists
what it requires but didn't copy. `--no-check` skips the loading check, for
a package that can't load without something you will add next.

**What isn't seen.** Requirements made later, inside procedures, after the
package has loaded, aren't seen while loading. If your program then fails
with `can't find package X`, add X too.

### 7. Install from an archive or a URL

**Archives** (`.zip`, `.tar`, `.tar.gz`/`.tgz`) are read by tclvenv itself,
with no external tools:

```sh
tclvenv install .venv ~/Downloads/greeter-0.2.tar.gz
tclvenv install .venv ~/Downloads/greeter-0.2.zip
```

The package is the archive's top level if that has a `pkgIndex.tcl`, or
else the only directory with one within three levels. When an archive holds
several packages, choose one:

```sh
tclvenv install .venv bundle.tar.gz
```
```text
tclvenv: the archive holds several packages; choose one with --subdir: top/a/pa, top/b/pb
```
```sh
tclvenv install .venv bundle.tar.gz --subdir top/a/pa
```

For archives, unlike directories, `--deps` and `--check` are on by default.
Turn them off with `--no-deps`/`--no-check`.

**URLs** need the archive's SHA-256, so a changed or tampered download is
refused before anything is unpacked:

```sh
sha256sum greeter-0.2.tar.gz        # on a copy you trust
tclvenv install .venv https://example.org/greeter-0.2.tar.gz \
    --sha256 9f7ccee31d15022230c2df453eeb307625e57e2f35d5442c44c481f39d8edb12
```

Without `--sha256`, or with a wrong one:

```text
tclvenv: installing from a URL needs --sha256 HEX (the archive's SHA-256), to verify the download
tclvenv: SHA-256 mismatch: expected 0000…, got 9f7ccee3…
```

`https` uses the `tls` package when it loads, or else `curl` or `wget`.
Up to five redirects are followed. A download that sends nothing for two
minutes, or takes more than ten minutes in all, is stopped.

### 8. Make an environment reproducible

tclvenv has no lock file. Keep the commands that build the environment in
a script in your repository, and rebuild instead of repairing:

```sh
#!/bin/sh
# tools/mkvenv.sh: rebuild this project's environment from scratch.
set -e
rm -rf .venv
tclvenv create .venv --tcl tclsh9.0
tclvenv add .venv json
tclvenv add .venv sqlite3 3.54-
tclvenv install .venv vendor/greeter
tclvenv install .venv https://example.org/csvx-1.1.zip --sha256 6c1f…
```

```sh
sh tools/mkvenv.sh && tclvenv list .venv
```
```text
json	lib/json	installed
sqlite3.54.1	lib/sqlite3.54.1	installed
greeter	lib/greeter	installed
```

Notes:

- `add` copies what this machine has, so the result follows the machine's
  installed versions. Pin a version where it matters (`sqlite3 3.54-`).
  For exact control, vendor the package into the repository
  (`vendor/greeter`) or install it from a URL with its SHA-256.
- `list` shows what is installed. `.venv/metadata/installed.tcldata` holds
  each receipt's origin (system path and version, archive and SHA-256, URL).
  Keep that file to see later where everything came from.

### 9. Run tests, in make and in CI

`tcltest` is part of every environment (it is one of the core modules
captured at creation):

```tcl
# tests/greeter.test
package require tcltest 2
namespace import ::tcltest::*
package require greeter
test hi-1 {greets} -body { greeter::hi you } -result {hi you}
cleanupTests
```
```sh
.venv/bin/tclsh tests/greeter.test
```
```text
greeter.test:	Total	1	Passed	1	Skipped	0	Failed	0
```

**A Makefile:**

```make
VENV := .venv
TCLSH := $(VENV)/bin/tclsh

$(VENV)/tclvenv.cfg: tools/mkvenv.sh
	sh tools/mkvenv.sh

test: $(VENV)/tclvenv.cfg
	$(TCLSH) tests/all.tcl

clean:
	rm -rf $(VENV)

.PHONY: test clean
```

The environment is rebuilt whenever `tools/mkvenv.sh` changes.

**GitHub Actions**, testing on Tcl 8.6 and 9.0:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        tcl: [tclsh8.6, tclsh9.0]
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y tcl8.6 tcl9.0 tcllib
      - run: git clone --depth 1 … /tmp/tclvenv && sh /tmp/tclvenv/install.sh --user --no-path
      - run: ~/.local/bin/tclvenv create .venv --tcl ${{ matrix.tcl }}
      - run: ~/.local/bin/tclvenv add .venv json
      - run: .venv/bin/tclsh tests/all.tcl
```

(Package names differ between distributions and releases: check
`apt-cache search tcl9` on your runner image.)

### 10. Tk applications

Tk is a package like any other:

```sh
tclvenv create .venv --tcl tclsh8.6
tclvenv add .venv Tk
```
```text
Installed tk8.6 (Tk 8.6.18 from /usr/lib/tcltk/x86_64-linux-gnu/tk8.6)
Added Tk 8.6.18
```

On Tcl 8.6, Tk's script library (on Debian, `/usr/share/tcltk/tk8.6`) is
copied in with it. On Tcl 9, it is inside Tk's shared library. Packages
built on Tk (`tablelist`, Tcllib's `map::slippy`, ...) bring Tk with them
when added. Run the application through the launcher as usual:

```sh
.venv/bin/tclsh gui.tcl
```

While adding, tclvenv loads Tk in helper interpreters that never show a
window. A display is still needed for Tk to load at all, so add Tk packages
in a desktop session, or with a virtual display (`xvfb-run tclvenv add
.venv Tk`) on a server.

### 11. Use everything installed on the system

For a scratch environment, or a tool that should see the system's
packages, create the environment with `--system-packages`:

```sh
tclvenv create .venv-sys --system-packages
echo 'puts [package require json]' | .venv-sys/bin/tclsh      # 1.3.6, from the system
```

Without the option, the same line fails: `can't find package json`.

The environment's packages don't hide the system's. `package require`
chooses among all of them by version, as Tcl always does, so the newest
copy wins wherever it is. With `json` 0.5 installed in the environment and
1.3.6 on the system, `package require json` loads 1.3.6. Pin a version in
your code when it matters, or don't use `--system-packages`.

### 12. Upgrade, replace or remove a package

Installations are never overwritten. Remove first, then install the new
version:

```sh
tclvenv list .venv
tclvenv remove .venv greeter
tclvenv install .venv src/greeter        # or: tclvenv add .venv json 1.4-
```

Remove by the ID in the first column of `list` (`greeter`, `hello@1.0`,
`sqlite3.54.1`). `add` may install several IDs for one package (its
dependencies). Removing one doesn't remove the others, and nothing stops
you removing a dependency others need. Check with a load afterwards, or
rebuild ([recipe 8](#8-make-an-environment-reproducible)).

Installing over an existing one is refused:

```text
tclvenv: package already installed or destination exists: greeter
```

### 13. Check an environment and recover

```sh
tclvenv doctor .venv
```
```text
Runtime and installed files: OK
Package paths: …/.venv/lib /usr/lib/tcl9.0
Module paths: …/.venv/modules …/.venv/metadata/core-modules
```

`doctor` checks the runtime, the environment's own files, and the SHA-256
of every installed file. It exits with status 1 and names what is wrong:

```text
tclvenv: installed files changed: greeter
```

**A package file was edited in place.** `remove` refuses changed packages,
so that it never deletes work:

```text
tclvenv: package files changed; refusing to remove greeter (remove --discard-changes deletes it as it is)
```

If the changes don't matter (a cache the package wrote into its own
directory, say), remove it as it is:

```sh
tclvenv remove .venv greeter --discard-changes
```

Copy your edits somewhere if you want them. Then put the original bytes
back (the check compares content, so the original file makes the package
unchanged again), and remove and reinstall:

```sh
cp src/greeter/greeter.tcl .venv/lib/greeter/greeter.tcl
tclvenv remove .venv greeter && tclvenv install .venv src/greeter
```

Or rebuild the environment: it is disposable.

**An interrupted install or removal.** A killed command can leave a lock
file and a staging directory. The next command that changes the
environment takes over a lock whose process is gone and finishes or undoes
the interrupted operation first; `recover` does just that:

```sh
tclvenv recover .venv
```
```text
tclvenv: warning: took over …/.venv/metadata/mutation.lock from process 4242, which no longer exists
Undid an interrupted install of greeter
Nothing left to recover in …/.venv
```

An install that hadn't written its receipt is undone; a removal whose
receipt still said `installed` puts the package back. A removal that was
already committed is finished with `remove` (`recover` says so). Anything
recovery can't account for (a file someone added to a staging directory, a
package changed since) is left in place and named. A lock held by a running
process, or written on another host sharing the filesystem, is never taken
over: check that no tclvenv command is running there before removing it.

**The Tcl installation changed.** After an upgrade of the environment's
Tcl, the launcher refuses to run (`Tcl runtime changed (version); recreate
this environment`). Recreate it.

### 14. Delete or move an environment

Delete it like any directory. Nothing outside it refers to it:

```sh
rm -rf .venv
```

Moving or renaming one isn't supported, because `bin/activate` records its
absolute path. Rebuild it at the new place instead
([recipe 8](#8-make-an-environment-reproducible)). (The `bin/tclsh` launcher
itself finds its environment from its own location, so it keeps working
after a move. Activation doesn't.)

A path that contains `:` is refused at creation, because `PATH` couldn't
hold its `bin` directory.

### 15. Windows

Create the environment with a native Tcl. Then:

```powershell
tclsh .\tclvenv.tcl create .venv --tcl 'C:/Tcl/bin/tclsh90.exe'
. .\.venv\bin\Activate.ps1          # PowerShell
tclsh app.tcl
deactivate
```
```bat
call .venv\bin\activate.bat
tclsh app.tcl
call .venv\bin\deactivate.bat
```

Without activation, use `.venv\bin\tclsh.cmd` or `.venv\bin\tclsh.ps1`.
PowerShell's execution policy applies to `.ps1` files. `install.sh` is for
POSIX systems: on Windows, run `tclvenv.tcl` from the checkout.

## Error messages

| Message | What to do |
| --- | --- |
| `destination already exists: PATH` | `create` never reuses a directory: pick another or delete it |
| `destination can't be activated (PATH can't hold a directory containing ":")` | create it at a path without `:` |
| `can't find package NAME` (from `add`) | `tclvenv available ENV 'NAME*'`; add `--path DIR` if it is installed somewhere unusual |
| `NAME does not load in the environment, so nothing was added: …` | the message after the colon is Tcl's: often a missing shared library, or one built for another Tcl |
| `this extension is compiled for Tcl 8.6` | that copy is for another Tcl version: choose another version, or create the environment with that Tcl |
| `package already installed or destination exists: ID` | `remove` it first ([recipe 12](#12-upgrade-replace-or-remove-a-package)) |
| `package is not installed: ID` | use an ID from the first column of `tclvenv list ENV` |
| `package files changed; refusing to remove ID` | keep your edits, or `remove ENV ID --discard-changes`: [recipe 13](#13-check-an-environment-and-recover) |
| `unfinished package operation: …; run: recover ENV` | `tclvenv recover ENV`: [recipe 13](#13-check-an-environment-and-recover) |
| `… could not be undone: ID (…)` | a rollback left ID installed: `remove ENV ID --discard-changes` |
| `installed files changed: ID` (from `doctor`) | the same |
| `installing from a URL needs --sha256 HEX …` | give the archive's SHA-256 |
| `SHA-256 mismatch: expected …, got …` | the download isn't the file you checked: don't install it |
| `the archive holds several packages; choose one with --subdir: …` | add `--subdir` with one of the paths listed |
| `--subdir names no package directory or module in the archive: …` | use one of the paths the previous message lists, exactly |
| `Tcl runtime changed (KEY); recreate this environment` | the environment's Tcl was upgraded or replaced: rebuild it ([recipe 8](#8-make-an-environment-reproducible)) |
| `could not run the environment's Tcl: …` | the interpreter didn't start or finish: run `tclvenv doctor ENV` |
| `environment creation is locked` / `environment is locked` / a lock reported by `doctor` | another tclvenv command is running, or one was killed on another host (a lock whose process is gone on this host is taken over by the next command): see [recipe 13](#13-check-an-environment-and-recover) |

## Command reference

```text
tclvenv create ENV [--tcl EXECUTABLE] [--system-packages]
tclvenv info ENV
tclvenv doctor ENV
tclvenv list ENV
tclvenv run ENV -- [SCRIPT [ARG ...]]          (--interactive / --stdin after --)
tclvenv install ENV SOURCE [--sha256 HEX] [--subdir PATH] [--deps|--no-deps]
                           [--check|--no-check] [--path DIR ...]
    SOURCE: a package directory, NAME-VERSION.tm, .zip/.tar/.tar.gz/.tgz,
            or an http(s) URL of one (with --sha256)
tclvenv add ENV PACKAGE [VERSION] [--path DIR ...] [--no-deps] [--no-check]
tclvenv available ENV [PATTERN] [--path DIR ...]
tclvenv remove ENV ID [--discard-changes]
tclvenv recover ENV
tclvenv --version | --help

ENV/bin/tclsh [-encoding NAME] [SCRIPT [ARG ...]]   (also --, --interactive, --stdin)
. ENV/bin/activate ... deactivate | tclvenv_deactivate
```

Environment variables:

| Variable | Effect |
| --- | --- |
| `TCLVENV` | set by activation to the active environment's path |
| `TCLVENV_TCLSH` | the interpreter the installed `tclvenv` command runs with, for one run |
| `TCLVENV_PROBE_TIMEOUT` | milliseconds to wait for the environment's Tcl (default 30000) |
| `TCLVENV_ARCHIVE_LIMIT` | largest archive or unpacked size in bytes (default 512 MiB) |
