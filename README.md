# tclvenv

A Python-style virtual environment manager for Tcl 8.6 and newer, implemented
with Tcl core commands. Python, Tcllib, and a compiler are not required.
Small shell, batch, and PowerShell launchers connect it to the user's shell.

Each environment reuses one installed Tcl interpreter and has its own package
directories. Packages come from local directories and modules, from packages
already installed on the system (`add`), and from archives and URLs. There is
no package index: `add` finds what this machine has, and an archive's
requirements are added from there. It does not download interpreters or build
native extensions.

For task-by-task examples (projects, Tcl versions, shells, packages from
the system, archives and URLs, reproducible environments, tests and CI, Tk),
see the [usage guide](docs/GUIDE.md).

## Install

On Linux (and other POSIX systems), `install.sh` installs a `tclvenv`
command. Run from a terminal without options, it asks where:

```sh
sh install.sh                  # asks: ~/.local/bin, ~/bin, /usr/local, or a directory
sh install.sh --user           # ~/.local/bin/tclvenv, files in ~/.local/share/tclvenv
sh install.sh --user-bin       # ~/bin/tclvenv, files in ~/.local/share/tclvenv
sudo sh install.sh --system    # /usr/local/bin/tclvenv, files in /usr/local/share/tclvenv
sh install.sh --prefix ~/tools # ~/tools/bin/tclvenv, files in ~/tools/share/tclvenv
sh install.sh --venv           # run it inside its own tclvenv
```

`--bindir DIR` and `--datadir DIR` place the command and the files apart.
The command runs tclvenv with the first of `tclsh`, `tclsh9.0`, `tclsh8.6` on
`PATH` (Tcl 8.6 or newer), or the one given with `--tcl`; environments use
that interpreter unless created with `--tcl`, and `TCLVENV_TCLSH` overrides it
for one run. When the command's directory isn't on `PATH`, the installer asks
(or, with `--path`, doesn't ask) before adding it in `~/.profile`, and in
`~/.bashrc` and `~/.zshrc` if they exist, between marker lines naming the
directory (`# >>> tclvenv PATH /home/you/.local/bin >>>`), so installs in
different places keep their own lines. A file without a final newline gets
one first (removed again on uninstall). A file it can't change (read-only,
a dangling link) is skipped with a warning. `--no-path` only says what to
add. A system install edits no one's startup files.

To update, run `sh install.sh --upgrade` from a newer checkout. It finds the
install (the `tclvenv` on `PATH`, else `~/.local/bin`, `~/bin`, `/usr/local/bin`,
or the location you give), replaces only its files in one step, keeps its place,
its Tcl and its PATH lines, and asks nothing. It says so if nothing has changed,
and fails if there is nothing to upgrade. It refuses a version older than the one
installed unless given `--force`. Environments keep the version they were made
with. Running the installer without `--upgrade` is a full install: it chooses
place, Tcl and PATH lines afresh, and replaces what is at that location.

The installer refuses to overwrite a `tclvenv` command or directory it didn't
create (`--force` replaces such a command). `--dry-run` shows what would be done.
`sh install.sh --uninstall` finds an install the same way (on a terminal it asks
first; give a location to skip the search) and removes the command, the files and
the PATH lines; environments already created keep working, since each holds its
own copy of what it needs.

Each install, upgrade and reinstall appends to a log, `.install-log` in the files
directory, one line per file and action with the local time: `add`, `update`, `unchanged` and
`remove` for files, `path-add` and `path-skip` for startup files, between `begin` and
`end` lines naming the version, source, Tcl and user. A failure is a `failed` line. The
log goes when the install does, and an install that was up to date adds nothing, so
`--log FILE` also writes to a file of your choice, which `--uninstall` leaves, with what
it removed. `--dry-run` writes no log.

`--venv [DIR]` creates a tclvenv and runs the command inside it, so that the command
is pinned to one Tcl and sees only the packages in that environment. `DIR` defaults
to `venv` in the files directory. `--tclvenv CMD` (or `TCLVENV_TCLVENV`) names the tclvenv
command, or `tclvenv.tcl`, that creates it; the default is this checkout's own `tclvenv.tcl`. An environment
already at `DIR` is used as it is. From then on the install keeps its environment:
`--upgrade` and a reinstall leave it alone (and make it again if it has gone), asking
for another `DIR` is refused until you uninstall, and `--tcl` doesn't change it. If it
stops working because its Tcl was upgraded, remove the directory and run `--upgrade`.
`--uninstall` removes an environment it created or that sits in the files directory,
and leaves one that was there already. The command still works on your setup rather
than its own: `--tcl tclsh` finds the `tclsh` on your `PATH`, not the environment's.

`--dry-run` shows what would be done, for an install, an upgrade or an uninstall, and
changes nothing.

`install.sh` is the same in tclvenv and [tclpkg](../tclpkg), apart from the few
settings at its top.

## Quick start

From this checkout on Linux, macOS, or another POSIX system (or with an
installed `tclvenv` in place of `tclsh tclvenv.tcl`):

```sh
tclsh tclvenv.tcl create .venv --tcl /usr/bin/tclsh8.6
tclsh tclvenv.tcl install .venv examples/hello-1.0.tm
. .venv/bin/activate
tclsh examples/hello.tcl Tcl
deactivate
```

The `--tcl` option accepts an executable path or a command on `PATH`. Omit it to
use the interpreter running the manager. Creation and `doctor` run the
interpreter to read its identity; one that doesn't finish within 30 seconds
(`TCLVENV_PROBE_TIMEOUT`, in milliseconds) is stopped, with any processes it
started. Its output decides: stderr is quoted (its first line) only when the
output isn't a valid identity, and an interpreter that closes its output
but keeps running is stopped rather than waited for. Tcl 9.x is supported using the same
commands, for example `--tcl tclsh9.0`.

Activation is optional:

```sh
.venv/bin/tclsh app.tcl argument1
tclsh tclvenv.tcl run .venv -- app.tcl argument1
printf 'puts [info patchlevel]\n' | .venv/bin/tclsh
tclsh tclvenv.tcl run .venv -- --interactive
```

The POSIX `bin/tclsh` launcher automatically opens a REPL when it reads stdin
(no script) and stdin is a terminal. The manager's `run` command and the Windows
batch launcher use stdin mode unless given `--interactive`. `--stdin` explicitly
selects stdin mode. Multiline commands and event-loop operations such as `vwait`
work in the REPL. User `~/.tclshrc` files are not sourced. As in native
`tclsh`, input that can't be decoded (invalid UTF-8 on Tcl 9) ends stdin mode,
an unfinished command at the end of the input is dropped silently, and
`info script` is empty.

Script arguments, `argv0`, `argc`, the current directory, and script exit codes
are preserved. As in native `tclsh`, the first argument is a script only if
it doesn't start with `-` (`-encoding ENCODING SCRIPT` gives the script an
explicit encoding); otherwise stdin is read and every argument is in `argv`.
Use `-- SCRIPT` for a script whose name starts with `-`. A script's error
trace is printed as native `tclsh` prints it, except after a top-level
`return -code error`: native `tclsh` adds the `return` command and its file
line, which a launcher written in Tcl can't recover, so only the message is
printed. The launchers may be reached through symbolic links (for example
`ln -s "$PWD/.venv/bin/tclsh" ~/bin/projtclsh`).

`bin/activate` puts the environment's name in the prompt through a variable,
so shells never evaluate it, and runs no external command. `deactivate`
restores `PATH`, `TCLVENV` and `PS1`, including whether `TCLVENV` was
exported. When another tool (a Python venv, for example) already defined
`deactivate`, activation leaves it alone and says so: leave the environment
with `tclvenv_deactivate`, which is always defined. `bin/deactivate` does the
same when sourced (`. .venv/bin/deactivate`); it isn't executable, because a
child process can't change the shell. `create` refuses a
destination whose path contains the `PATH` separator (`:`; `;` on Windows),
since it could not be activated.
The POSIX launcher uses `exec` so the Tcl application receives process signals
directly. The manager's `run` command supervises a child process; use the direct
launcher when process identity or signal delivery matters.

## Windows

Create the environment with a native Tcl installation:

```powershell
tclsh .\tclvenv.tcl create .venv --tcl 'C:/Tcl/bin/tclsh90.exe'
. .\.venv\bin\Activate.ps1
tclsh app.tcl
deactivate
```

Without activation, invoke `.\.venv\bin\tclsh.cmd` or
`.\.venv\bin\tclsh.ps1`. In cmd.exe:

```bat
call .venv\bin\activate.bat
tclsh app.tcl
call .venv\bin\deactivate.bat
```

PowerShell's script execution policy applies to `.ps1` files. The batch
launchers provide an alternative. Native Windows execution is not yet verified
in this Linux development environment; the test suite contains Windows and
PowerShell cases that run when those platforms/tools are available.

## Install and remove local packages

Install an existing directory with a `pkgIndex.tcl` at its root, or a single
Tcl module:

```sh
tclsh tclvenv.tcl install .venv ../packages/greeting1.0
tclsh tclvenv.tcl install .venv ../packages/salute-1.0.tm
tclsh tclvenv.tcl list .venv
tclsh tclvenv.tcl remove .venv salute@1.0
```

Application code uses ordinary Tcl package loading:

```tcl
package require greeting 1.0
package require salute 1.0
```

`export` writes the packages as a requirements file, one `NAME==VERSION` per
line, which [tclpkg](../tclpkg) installs into another environment or folder:

```sh
tclsh tclvenv.tcl export .venv --output requirements.txt    # or to standard output
tclpkg install -r requirements.txt --venv other
```

It reads tclpkg's records, `add`'s and each index's text, and runs no package's
code. A package whose index computes its version is listed without one, and one
whose index declares no package plainly is only a comment, with a warning. It says
what is installed, not where it came from: a package from a local directory or a
URL is listed by name, and tclpkg looks for that name in its repositories.

Package directories retain their basename under `lib/`. Their installation ID
is that basename, as written (`~x` stays `~x` on Tcl 8.6 as on 9). Names
beginning with `.` are rejected: Tcl's package search never looks inside such
directories. Modules go under `modules/`; their IDs are `NAME@VERSION`.
On filesystems allowing colons, a module named `ns::example-1.0.tm` is installed
as `modules/ns/example-1.0.tm`. On Windows, namespaced packages can be supplied
as indexed package directories.
Empty or invalid namespace components are rejected before copying a module,
so an accepted name retains the spelling needed by `package require`.

Installation copies files, includes dotfiles and empty directories, and never
evaluates package indexes. Sources must be separate from the environment;
symlinks and special files are rejected. Existing destinations are never
overwritten. Removal refuses packages containing changed, missing, or added
files or directories. Remove an unchanged installation before replacing it.
Copied package directories are made writable by their owner so read-only source
trees can be staged and removed. Source directory permissions are unchanged.
Mutation commands require real environment directories and reject symlinked
`lib`, `modules`, or `metadata` paths. Receipts must have distinct targets and
the correct file/directory inventory shape.

Removal detaches a package, checks its files, and records a `removing` state
before deleting data. If deletion or the final inventory update fails, `list`
shows the pending removal and `doctor` explains how to retry it:

```sh
tclsh tclvenv.tcl remove .venv INSTALLATION-ID
```

The retry works when some files have already been deleted. It refuses added or
modified files in the retained staging tree, and never deletes a replacement
package at the original public path. All processes modifying package files
should coordinate with the environment's mutation lock; open file handles can
still modify detached files and are not a supported concurrent update mechanism.
Cleanup checks recorded file contents at deletion time and rechecks directory
identity before traversal. Added or modified payload data causes removal to stop
with its pending receipt and journal retained. These Tcl path checks do not
provide atomic filesystem isolation from writers ignoring the mutation lock.

File inventory records contain each file's size, CRC-32, SHA-256, and
modification time. The SHA-256 is what detects changed content: a deliberate
edit can keep a file's size and CRC-32, and a modification time can be set
back. Modification times are recorded for diagnosis but don't decide whether a
file changed, so writing a file's original bytes back makes it unchanged again.
Files of 1 MiB or more are hashed by `sha256sum` or `shasum` when the system
has one; smaller files, and every file where neither exists (Windows), are
hashed in core Tcl at roughly 1 MB/s. Installation, removal and `doctor` each
hash every file once. The
core-module snapshot, the tool's own copy, records CRC-32 only. These records
are local change detection, not source verification or a dependency lockfile. Native packages must already be built for the selected Tcl runtime,
operating system, architecture, and required external libraries. Tcl 8.6 and
9.x native packages are not assumed interchangeable.

## Add system packages, archives and URLs

`add` copies a package installed on this system, and the packages it
requires, into an environment. `available` lists what it can find:

```sh
tclsh tclvenv.tcl available .venv 'sqlite*'
tclsh tclvenv.tcl add .venv sqlite3
tclsh tclvenv.tcl add .venv json            # Tcllib's json, nothing else of Tcllib
tclsh tclvenv.tcl add .venv mypkg 1.2 --path ~/tcl/lib
```

The search runs in the environment's own interpreter, with that
interpreter's default package path (`TCLLIBPATH` and the environment's own
directories are left out) plus any `--path DIR`. The package is loaded there,
and every `package require` it makes along the way is traced: those packages,
at the versions that loaded, are what gets copied, dependencies first, each
from the directory whose `pkgIndex.tcl` registered it (so a Tcllib module
copies its own directory, not all of Tcllib). An index may also provide a
package itself while it is read (Tcllib's `try` directory provides
`file::home` that way on Tcl 9); that directory is then its provider. A
script library an extension finds with `tcl_findLibrary` outside its
directory (Tk 8.6's `/usr/share/tcltk/tk8.6` on Debian) is copied into that
directory, where `tcl_findLibrary` then finds it. When a package loads Tk,
the interpreters that search and check never show its main window. Packages of Tcl's own library
and ones the environment already has are skipped. A package registered
directly from a package-path root (the root itself would be copied) is
refused; install it from a directory or archive instead. A module keeps its
namespace: `ns::smod` from `ns/smod-1.0.tm` goes to `modules/ns/smod-1.0.tm`.
Where the same version is installed in two places, the copy is the one Tcl
itself loads. System packages
often contain symlinks (`libfoo.so -> libfoo8.6.so`): `add` copies each as the
regular file it points to; a link to anything else is refused.

Because the choice comes from loading, a binary built for another Tcl is not
picked even when it is installed (Tcl 9 skips 8.6's `sqlite3`). After copying,
the package is loaded again inside the environment; if that fails, everything
the command copied is removed and the loader's error is shown. `--no-check`
skips that check, `--no-deps` copies only the named package and lists what it
requires. Requirements made only later, inside procedures, aren't seen.

`install` also takes archives and URLs:

```sh
tclsh tclvenv.tcl install .venv ~/Downloads/tcllib-json-1.3.6.zip
tclsh tclvenv.tcl install .venv bundle.tar.gz --subdir lib/foo1.0
tclsh tclvenv.tcl install .venv https://example.org/foo-1.0.tar.gz --sha256 HEX
```

Archives are `.zip` (stored or deflated), `.tar`, and `.tar.gz`/`.tgz`
(including gzip files of several members), recognised by their contents and
read with core Tcl (no `zipfs` on 8.6, no external tools). Data is copied in
64 KiB pieces, so memory use stays small whatever the archive's size (a
`.tar.gz` is decompressed to a temporary file first). A tar must end with its
end-of-archive marker: one cut short is refused rather than partly
installed. A root entry (`./`, as `tar -C dir .` writes) is skipped. Names
are UTF-8 (pax names may hold newlines); a zip name without the UTF-8 flag
that isn't valid UTF-8 is CP 437, as the zip format says and Windows writes
it. GNU incremental archives (`tar -G`) install, their dump directories as
directories. The package is the archive's top level if it has a
`pkgIndex.tcl` (installed under the archive's name), else the only directory
with one within three levels, else the one named by `--subdir`; a top-level
`NAME-VERSION.tm` installs as a module. Archive entries are checked before
anything is written: only regular files and directories, relative names
without `..`, drive letters or backslashes, no duplicates, nothing that is
both a file and a directory; links, devices, encrypted entries and zip64 are
refused. Files are written without setuid bits, executable only if the
archive marks them so. Archives over 512 MiB, or expanding beyond that, are
refused (`TCLVENV_ARCHIVE_LIMIT`, in bytes). Extraction happens in a private
temporary directory, removed afterwards (also when data proves corrupt
partway); the package is then installed like a
local directory.

A URL needs `--sha256` with the archive's SHA-256 (or a `.tm`'s): the
download is checked before anything is extracted. Downloads use Tcl's `http`
(with the `tls` package for `https` when it loads, else `curl` or `wget`,
also when a redirect leads to `https`), follow up to five redirects
(relative ones resolved as RFC 3986 says) and stop at the size limit. A
download fails when no data arrives for 120 seconds or when it takes more
than 600 seconds in all, with any of the three tools (`curl` and `wget` are
stopped once their file passes the size limit). The
file is saved as the server sends it, as curl and wget save it: no
compression is asked for or decoded (a server may label a `.tar.gz` with
`Content-Encoding: gzip`), and nothing after `Content-Length` is kept. For archives and
URLs, requirements found in the package's Tcl files (literal
`package require NAME`) are added from the system as with `add`. These are
read, not traced, and may be optional, so one that isn't on the system or
can't be copied is reported and the package kept. The package must load (a load that ends or crashes the interpreter, or
passes `TCLVENV_PROBE_TIMEOUT`, fails the check too), and a failed check or
requirement step removes the package with every requirement it added;
`--no-deps` and `--no-check` turn these off, and
`--deps`/`--check` turn them on for directory and module installs.

Each receipt records where its package came from (`origin`: `system` with
name, version and directory; `archive` with path and SHA-256; `url` with URL
and SHA-256; `directory`).

## Isolation and diagnostics

By default, package discovery searches the environment's `lib/`, the selected
Tcl core library, the environment's `modules/`, and a snapshot of approved Tcl
core modules under `metadata/core-modules/`. Creation captures `msgcat`, `http`,
`platform`, `platform::shell`, and `tcltest` from the selected installation,
including standard sibling module directories. It copies module bytes inside
the selected interpreter, so ZipFS libraries are accessible too. Global package
directories and inherited module paths are excluded.
Launchers clear `TCL_LIBRARY` and `TK_LIBRARY` so a stale shell setting cannot
select another installation's core files. The selected installation must be
able to locate its own core without those settings.

To include normal system and inherited package paths, create an environment
with `--system-packages`:

```sh
tclsh tclvenv.tcl create .venv-system --system-packages
tclsh tclvenv.tcl info .venv
tclsh tclvenv.tcl doctor .venv
```

`info` reports runtime identity, installed package count, and pending removals.

When the manager's output can't be written (a full disk, or a reader that
stopped reading, as in `tclvenv list .venv | head -1`), a command that
changes the environment (`create`, `install`, `add`, `remove`) still
completes, exits 0, and says on stderr that its output was lost. A
read-only command exits 1, silently when the reader just stopped.
`doctor` verifies the runtime, required environment components, captured core
modules, and recorded installed files,
then prints the effective package and module paths. It does not load each
installed package or validate its native dependencies.

Applications and their subprocesses launched through the environment's
`tclsh` launcher receive its settings. `info nameofexecutable` still reports the
base Tcl executable; launching that executable bypasses the environment.
Embedded interpreters, `interp create`, and new thread interpreters are not
automatically bootstrapped. Package discovery isolation is not a filesystem or
security sandbox: application code can change paths or explicitly `source` and
`load` files.

Runtime version and platform identity are checked at startup. Recreate the
environment after changing its Tcl installation, rather than silently changing
the runtime under installed packages. Environments are disposable; keep source
packages and application code elsewhere. Moving environments is not supported,
because POSIX activation records an absolute path.

Environment creation and package mutations use exclusive lock files, each
recording the host and process that holds it. The record is written before
the lock exists under its name, so a killed process leaves no lock or a
complete one. A lock whose process no longer exists on this host is taken
over by the next command (with a warning); a lock from another host, a
running process, an older version or anything else unreadable is left,
and the command fails. Takeovers are serialized by a second lock file
(`LOCK.break`), so two commands can't both take over one stale lock.

An interrupted operation (a killed process) leaves its staging directory
and journal under `metadata/`. Every command that changes an environment
first brings each one to a safe end under the lock, and `tclvenv recover
ENV` does only that: an install without a receipt is undone, one whose
receipt was written is kept; a removal whose receipt still says
`installed` is undone (the package goes back), and one marked `removing`
is left for `remove` to finish, as before. Nothing is deleted unless it
matches the journal: a stage holding other files, or a published package
changed since, is left in place and reported. A creation killed partway
leaves a `.tclvenv-create-NAME.stage-*` directory beside the destination,
which the next creation of that destination removes. `doctor` reports
what remains and says to run `recover`.

Installation rolls back by moving its published tree back into private
staging and checking it before deletion. If another writer changed it or
blocked restoration, the tool preserves the files and reports the recovery
journal's location. A failed load or requirement check rolls back the
package and the requirements it added, discarding changes their own
loading made to their files; if something still can't be removed, the
message names it instead of saying nothing was installed.
Before resuming a removal, the manager checks that its journal matches the
package receipt and that the staging directory contains only the journal and
recorded payload. It preserves unexpected files. The journal remains available
if the final receipt update fails. Once that update succeeds, the removal
has happened: a failure to remove the journal or staging directory is a
warning (an install's likewise), and the leftover is recovered or reported
later. `remove ENV ID --discard-changes` removes a package whose files
changed since installation as it is (still detaching it first and never
following a link out of it).

## Layout and development

```text
tclvenv.tcl             CLI entry point
install.sh              Installs or removes the tclvenv command (POSIX sh)
docs/GUIDE.md           Usage guide with cookbook recipes
lib/manager.tcl         Creation, installation, inventory, diagnostics
lib/runtime.tcl         Environment bootstrap, script runner, REPL
lib/core.tcl            Core module capture inside the selected interpreter
lib/archive.tcl         tar, tar.gz and zip reading and checked extraction
lib/discover.tcl        System package search, run inside the selected interpreter
tests/                 Tcltest integration tests

.venv/
  tclvenv.cfg           Runtime identity and settings (Tcl dictionary data)
  bin/                 Launchers and activation scripts
  lib/                 Indexed packages
  modules/             Single-file modules
  metadata/            Copied manager/runtime and installed-file records
```

The copied manager makes an environment independent of this checkout:
`.venv/bin/tclvenv info .venv` works after the source checkout moves.
Recreate existing environments after updating this tool to pick up fixes in
their copied manager and runtime.
Configuration and inventory files are parsed as data, never sourced as code.
They are created with the umask's permissions, like every other file in the
environment, so an environment made by one user (or by root in a container
image) can be run by others; a rewritten file keeps its mode. Environments
made by earlier versions have `tclvenv.cfg` readable by their creator only:
`chmod a+r ENV/tclvenv.cfg` (or recreate them) to share one.
Manager commands and direct launchers both reject invalid boolean settings.
Inventory and runtime identity dictionaries are compared by field values rather
than key order. Startup supports literal glob characters in environment paths
while retaining module-path ancestry checks.
Script execution preserves native Tcl return levels, failure exit status, and
completion-code diagnostics through the manager and shell launchers.

Run the tests using the interpreters available on your system:

```sh
tclsh tests/all.tcl
tclsh9.0 tests/all.tcl
```

Integration tests create their prerequisites independently, so focused runs work
without running earlier cases:

```sh
tclsh tests/all.tcl -file tclvenv.test -match remove-5.1
tclsh9.0 tests/all.tcl -file tclvenv.test -match metadata-7.2
```

Tests create their own temporary directories and return a nonzero status on
failure. Fault-injection regressions exercise publication races, partial
deletion, failed inventory writes, and changes during removal. Delayed pipe I/O
tests use bounded child processes and assert blocking mode even when slow startup
prebuffers the input. Validation tests cover malformed and valid boolean values
through manager commands, the bootstrap, and shell launchers. The optional
inventory benchmark creates a flat tree, measures traversal, and removes its
temporary files:

```sh
tclsh tests/bench_inventory.tcl 6000
```

## Fuzz tests

The standalone Tcl harness uses seeded property, mutation, and differential
testing. Its thirty-two groups cover argument preservation, CLI validation,
config and inventory parsing, binary package trees, environment paths and
activation, stdin behavior, dictionary ordering, package-operation sequences,
interrupted removals, injected I/O failures, lock exclusion, script execution
modes, inventory buffer boundaries, redirected directories, contradictory
ownership records, filesystem interleavings, hard transaction interruptions,
module-name grammar, Tcl completion semantics, six hostile-input groups,
archives, and five groups judged against implementations outside tclvenv.

```sh
tclsh tests/fuzz.tcl --seed 1 --iterations 100
tclsh9.0 tests/fuzz.tcl --seed 42 --iterations 100
tclsh tests/fuzz.tcl --seed 20261030 --iterations 100 --report-dir ./fuzz-results
tclsh tests/fuzz.tcl --seed 1337 --only lifecycle --iterations 100 --steps 50
tclsh9.0 tests/fuzz.tcl --seed 42 --only faults --iterations 100
tclsh tests/fuzz.tcl --seed 1 --only containment --iterations 100
tclsh9.0 tests/fuzz.tcl --seed 42 --only crashes --iterations 100
tclsh tests/fuzz.tcl --seed 1 --only modulegrammar --iterations 200
tclsh9.0 tests/fuzz.tcl --seed 42 --only completions --iterations 200
```

`--iterations` is the number of cases **per group**: the default runs 2000 cases.
`--steps` controls each lifecycle case's generated sequence length (default 12,
range 1–200). Each step checks an independent model of installed packages,
modified files, receipts, and preserved source trees. Longer sequences retain
the same generated operation prefix. Existing groups retain their original
case seeds.
Each case has its own derived seed, environment, and protected sentinel files.
Inputs travel as data, so Tcl's process-launch syntax cannot interpret fuzzed
arguments such as `|` and `>file`. Unix runs also exercise POSIX launchers and
activation using literal shell quoting. Stdin programs use a bounded grammar
and compare stdout and stderr independently against native `tclsh`.

Recovery cases generate valid, partially deleted, empty, reordered, and corrupt
removal transactions. Fault workers inject one of eight copy, publication,
journal, receipt-write, or deletion failures, require the fault to fire, and
then check rollback or successful retry. Lock cases test existing regular-file,
directory, and symlink locks and retry after release. These exercise lock
exclusion deterministically; they do not simulate arbitrary process scheduling.
Script-mode cases cover exit statuses, errors, literal option arguments,
invalid options, and UTF-8/Latin-1/UTF-16 source encodings. Boundary cases mutate
binary files around 64 KiB and 128 KiB and check detection and data preservation.

Adversarial groups challenge ownership and recovery assumptions:

- `containment` replaces `lib`, `modules`, module namespace directories, or
  `metadata` with symlinks or unrelated files and checks the redirected tree
  for external writes or deletions.
- `ownership` supplies conflicting receipts, module receipts describing
  directories, and forged pending removals, requiring refusal without data loss.
- `interleavings` inserts files after validation and swaps destination or
  deletion directories for symlinks at selected filesystem boundaries.
- `crashes` sends the worker `SIGKILL` on Unix at eight transaction cut points
  (immediate `exit 97` on Windows), checks retained bytes/journals/receipts, and
  retries removals after committed state transitions.

These cases deliberately damage metadata and directory structure. Interleaving
cases model uncoordinated writers, which exceed the supported mutation-lock
contract described above; the report identifies that condition explicitly.
Regular tests include passing adversarial controls; campaign violations remain
failures until fixed. See [the extended report](tests/FUZZ_EXTENDED_REPORT.md).

The compatibility groups challenge ordinary CLI behavior in fresh environments.
`modulegrammar` generates names with ordinary, leading, trailing, single, and
repeated namespace separators. Noncanonical names may be rejected; successful
installation must produce a module the loader can actually require. Its module
bodies contain only a known `package provide`. `completions` compares generated
scripts with native `tclsh`, checking exit status, output, and diagnostics across
`return` levels, completion codes, nested procedures, and caught completions.
Stack-trace locations are excluded from diagnostic comparisons. See
[compatibility findings and reduced examples](tests/FUZZ_COMPAT_REPORT.md).
The [fix verification report](tests/FUZZ_FIX_REPORT.md) records the resolved
findings and the campaign matrix used to check the changes.

The hostile-input groups generate their inputs rather than choosing among
prepared cases, and judge outcomes with oracles written apart from the
production code, including an independent consistency check that `doctor`
must agree with whenever it passes:

- `names` installs and removes hostile package names, module filenames, and
  removal IDs (with `HOME` pointed at a guarded directory); an accepted name
  must keep its basename as its ID, load, and remove cleanly.
- `datafuzz` applies random structural and byte mutations to the persisted
  configuration and inventories, then runs a random command.
- `fakeruntime` creates environments with interpreters that hang, print
  garbage, warn on stderr, or report paths containing shell syntax.
- `concurrency` starts several manager processes on one environment at once.
- `killpoints` sends `SIGKILL` at a random moment during install, remove, or
  create, with delays calibrated to the operations' measured duration.
- `stdinmore` compares a wider stdin grammar (CRLF, missing final newline,
  invalid UTF-8, long lines, scripts reading their own stdin) with native Tcl.
- `archives` (`tests/fuzz_sources.tcl`) installs random tar, tar.gz and zip
  archives written by its own writers, in three layouts, with long and
  hostile-looking names, sometimes with a hostile entry (traversal, absolute,
  links, devices, duplicates, file/directory conflicts, encrypted or unknown
  compression), corrupted bytes, a size limit, a `./` root, a tar cut short
  before its end marker, or gzip data split into several members. A hostile,
  oversized or truncated archive must be refused with the environment
  unchanged; a sound one must install exactly its package directory and
  remove cleanly; nothing may be written to or left in the temporary
  directory.

```sh
tclsh tests/fuzz.tcl --seed 7 --only names --iterations 150
tclsh9.0 tests/fuzz.tcl --seed 11 --only killpoints --iterations 150
```

See [the hostile-input report](tests/FUZZ_HOSTILE_REPORT.md) for the
findings, their reduced examples and fixes, and the campaigns used;
`tests/hostile.test` holds a regression test for each.

The groups in `tests/fuzz_external.tcl` check the package sources against
implementations outside tclvenv; tools that are missing count as skipped:

- `sha256` compares the core-Tcl SHA-256 with `sha256sum` at block and
  64 KiB read boundaries, whole and in random pieces, and checks the
  `--sha256` spellings.
- `urljoin` compares `resolveUrl` with RFC 3986 section 5.2, written out in
  the harness, for relative references of every kind.
- `toolarchives` installs packages with hostile names archived by GNU tar
  (every format, `-G`, gzip, several members), Info-ZIP, 7-Zip and Python;
  a sound archive must install exactly the packed directory, executable
  bits included, and one holding a link must be refused.
- `downloads` installs URLs from a local HTTP server that redirects in
  every form, frames bodies by length, close or chunks, compresses,
  labels, truncates, overruns or never ends them; what is installed must be
  the resource's bytes, each request the target RFC 3986 resolves, and the
  temporary directory must stay within the size limit.
- `systemadd` runs `add` on random system package trees (dependencies,
  versions in several directories, namespaced modules, collection indexes,
  links); the environment must load what native `tclsh` loads, from its own
  files.

```sh
tclsh9.0 tests/fuzz.tcl --seed 1 --only downloads --iterations 150
tclsh tests/fuzz.tcl --seed 7 --only toolarchives --iterations 150
```

See [the external-oracle report](tests/FUZZ_EXTERNAL_REPORT.md) for the
findings, their reduced examples and fixes; `tests/external.test` holds a
regression test for each.

The groups in `tests/fuzz_recovery.tcl` check what an interrupted or failing
command leaves behind and how the next command deals with it:

- `stalelocks` puts a mutation or creation lock (and sometimes its breaker)
  in one of 18 shapes (a dead or live holder on this host, another host,
  older formats, garbage, odd pids, oversized files, directories, links), or
  starts several installs at once against one stale lock. A lock must be
  taken over exactly when its holder is provably gone, and otherwise left
  byte for byte; racing takeovers must never lose a receipt.
- `crashrecovery` kills install or remove (of a package directory or a
  module) with `SIGKILL` at one of 12 transaction cut points or a random
  time, then recovers with `recover`, with the next command, or with a
  `recover` that is itself killed. The package must end up all or nothing,
  committed operations keeping their outcome and uncommitted ones undone,
  with doctor agreeing, nothing left over, recovery idempotent, and an
  unrelated package untouched.
- `rollbacks` installs packages whose load check changes their own files and
  then fails (error, exit, a hang past the deadline) or passes, and removes
  changed packages with and without `--discard-changes`. A message saying
  nothing was installed must be true.

```sh
tclsh9.0 tests/fuzz.tcl --seed 11 --only crashrecovery --iterations 60
```

See [the recovery report](tests/FUZZ_RECOVERY_REPORT.md) for its findings;
`tests/recovery.test` holds a regression test for each.

Children have a five-second deadline and separate 64 KiB output limits. The
supervisor handles closed output descriptors and terminates descendants on
timeout. Windows uses `taskkill` for termination; Windows launcher/activation
coverage still requires a Windows run.

Reports default to a new temporary directory, printed at completion. An explicit
`--report-dir` must not exist. Reports contain `summary.txt`, `summary.tcldata`,
and `failures.tcldata`, plus inputs, logs, and workspaces for the first occurrence
of each failure type and scenario variant, up to 32 retained workspaces.
Remaining failures retain
their inputs and captured output in `failures.tcldata`. These are Tcl dictionary
data files; read them as data, rather than sourcing them. The summary also
counts exercised variants for each new group. Counts describe generated
scenarios and operations, rather than source-code branch coverage.

Replay a zero-based case independently of the preceding cases:

```sh
tclsh tests/fuzz.tcl --seed 1 --only inventory --case 0
tclsh tests/fuzz.tcl --seed 1 --only ordering --case 1
tclsh tests/fuzz.tcl --seed 1337 --only lifecycle --case 17 --steps 50
```

Exit status is 0 when all checked properties pass, 1 when fuzzing finds a
violation, and 2 for a harness/setup error. Findings remain visible; the harness
does not change application code. `tests/all.tcl` includes self-tests for the
fuzz harness's process controls, transport, and replay, while campaigns run
separately with the commands above.

Planned next steps are a project manifest and lockfile, reproducible
`sync`, package source adapters, native build recipes, and explicit Tk/`wish`
support.
