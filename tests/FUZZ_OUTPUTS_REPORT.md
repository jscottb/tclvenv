# Output-failure and installer fuzzing report

Two areas no earlier group covered:

- What the manager does when its output can't be written. Earlier groups
  always gave it a working stdout. The bug that prompted this round:
  `tclvenv doctor ENV | head -1` printed a stack trace.
- `install.sh`, which had only its own regression tests. Its riskiest part
  edits the user's shell startup files.

| Group | Generates | Oracle |
| --- | --- | --- |
| `outputs` (`tests/fuzz_outputs.tcl`) | one manager command (`create`, `install` of a directory with `--check --deps`, of a module, of an archive, `add`, `remove`, `run`, `info`, `list`, `doctor`, `available`, `--help`) with stdout full (`/dev/full`), a pipe whose reader stops after 0-400 bytes, or closed; stderr sometimes full too | the same command on an identical copy with stdout and stderr to files (the control). A command that changes the environment makes exactly the control's change and exits as the control did. A read-only command whose output couldn't be written exits 1. No stack trace (for `run`, none of the launcher's frames). `doctor` passes afterwards |
| `installer` (`tests/fuzz_installer.tcl`) | a private HOME whose `.profile`, `.bashrc` and `.zshrc` are each absent, empty, ordinary, without a final newline, CRLF, a link into a dotfiles directory, a dangling link, read-only, or holding another install's block; `--user`, `--user-bin`, `--prefix` or `--bindir`/`--datadir` with hostile names (spaces, quotes, `$HOME`, backquotes, `$(x)`, tabs, `;`, `&`, `\`, `#`, `~`, `=`, Unicode); `--path`/`--no-path`; sometimes the directory already on `PATH`; install, sometimes reinstall, uninstall | stderr holds only `install.sh:` messages; the installed command runs; each startup file still runs as it did before (same status, errors and own effects) and puts the command on `PATH`; uninstall leaves every startup file and link target byte for byte as before, and nothing of the install |

Campaign before the fixes (Tcl 9.0.4, seed 1): `outputs` failed 8 of 40
cases, `installer` 36 of 60. Some of those 36 were harness problems: Tcl's
`file link` can't make a dangling link, and a CRLF startup file already
fails in `sh` before any install. The harness now uses `ln -s`, and
compares each file with how it ran before the install.

## Findings

### 1. Whether a command reports success depends on its progress output

The manager printed progress with plain `puts`, so a write that failed
(full disk, a closed pipe) raised an error in the middle of the command:

```text
$ tclvenv create e >/dev/full; echo $?
tclvenv: error writing "stdout": no space left on device
1                                    # but e was created: a retry says "destination already exists"
$ tclvenv install e greeter >/dev/full; echo $?
1                                    # installed
$ tclvenv remove e greeter >/dev/full; echo $?
1                                    # removed
$ tclvenv add e httpd | head -1
Installed uri (uri 1.2.8 from …)
tclvenv: could not roll back log: error writing "stdout": broken pipe
tclvenv: could not roll back uri: error writing "stdout": broken pipe
```

`add` rolled back everything it had copied, then said it couldn't roll
back, because the rollback's own "Removed" line failed too (the rollback
had in fact worked). `install --deps` (directories and archives) installed
the package, then stopped at "Adding json, which … requires:": the package
was kept without its requirement, and the command failed. Found by
`outputs` (`create`, `install-module`, `remove`, `add`, `install-dir`,
`install-archive`).

### 2. `doctor` into a closed pipe prints a stack trace

`doctor` printed its last two lines from a child interpreter writing to
the manager's stdout. When the reader had stopped, the child failed on its
own and printed its trace:

```text
$ tclvenv doctor ENV | head -1
Runtime and installed files: OK
error writing "stdout": broken pipe
    while executing
"puts "Package paths: $::auto_path""
    (file "/tmp/tcl_FUS9xj" line 1)
```

### 3. `install.sh` corrupts a startup file without a final newline

The PATH block was appended as is, so its first line joined the file's
last line, and `sh` read the rest as redirections:

```text
$ printf 'export FOO=1' > ~/.profile; sh install.sh --user --path
$ sh -c '. ~/.profile'
… Syntax error: redirection unexpected      # (bash: syntax error near unexpected token `>')
```

Uninstall then couldn't find the block (its first line no longer matched),
so the file stayed broken. Found by `installer` (`nonewline`).

### 4. `install.sh` stops halfway at a startup file it can't write

A read-only `~/.bashrc` (or `~/.zshrc`, or a `~/.profile` that is a
dangling link into a dotfiles directory not checked out yet) made the
append fail under `set -e`. That happened after the command and files were
installed and `~/.profile` changed. It printed a raw shell error and exited
2, and the manifest listed the file as changed:

```text
install.sh: 349: cannot create /home/u/.bashrc: Permission denied
```

### 5. Two installs share, and remove, one PATH block

The PATH block's marker lines were the same for every install. A second
install elsewhere (say `--prefix ~/tools` after `--user`) replaced the
first install's block, so the first command dropped off `PATH`. Uninstalling
either install removed the other's lines. Found by `installer` (`oldblock`:
a block another install wrote, replaced or removed).

## Fixes

| # | Fix | Regression tests |
| --- | --- | --- |
| 1 | Every line of manager output goes through `say`, which never raises: a failed write is remembered, the rest of the output skipped, and the command completes. Afterwards, a command that changes the environment (`create`, `install`, `add`, `remove`) succeeds and prints one line on stderr (`the command completed, but its output couldn't be written (...)`). A read-only one exits 1 with `couldn't write the output: ...`, or with no message when the reader just stopped (`tclvenv list ENV \| head -1`), as Unix tools do. | `tests/outputs.test`: `change-1.create`, `.install`, `.remove`, `.add` (kept, no false "could not roll back"), `.deps` (the requirement is added), `read-2.full`, `read-2.list` |
| 2 | `doctor` reads the paths in the environment through a result file and prints them itself. Error messages to stderr are written under `catch`, so a full stderr can't produce a trace either. | `read-2.pipe`, `read-2.doctor-output` (kept working) |
| 3 | Before appending to a file without a final newline, `install.sh` adds one and records it in the manifest (`startup-newline FILE`). Uninstall removes the block and that newline, but only if the block is still the last thing in the file, so lines added later are untouched. | `tests/install.test`: `newline-1`, `newline-1.later-lines` |
| 4 | Each startup file is checked first: a read-only file, a dangling link, a directory, or a file whose directory isn't writable is skipped with one `install.sh:` warning, isn't recorded, and the install completes. Nothing is created at a link's target. The files are walked without a pipeline subshell, so no failure can abort halfway. | `readonly-2`, `dangling-2` |
| 5 | Each block's marker lines name the command's directory (`# >>> tclvenv PATH /home/u/.local/bin >>>`). An install replaces only its own block, and uninstall (which reads the directory from the manifest) removes only its own. Removal matches the marker lines exactly, through `awk`'s `ENVIRON` (not `-v`, which would interpret backslashes in paths). Directory names containing a newline are refused. | `two-installs-3` |

Each regression test fails on the code before the fixes, except
`read-2.doctor-output`, which checks that `doctor` still prints its paths.
`install.sh` had never been committed, so the old version was rebuilt by
reversing this round's edits, and the new tests were run against it: all 5
new installer tests failed, and the 17 earlier ones passed.

After the fixes, `outputs` and `installer` ran 100 cases each for seeds 1,
7 and 11 on Tcl 8.6.18 and 9.0.4 (1,200 cases): no failures. The full
suite passes on both versions.

## Not found

- `outputs`: with output closed (`>&-`), Tcl gives the manager a working
  `stdout` that discards what is written, and no data file is written to
  by mistake: every command behaved as with normal output. Scripts run
  through `run` or the launcher report a failed `puts` exactly as native
  `tclsh` does.
- `installer`: blocks written into files reached through links went into
  the link's target, and were removed from there; hostile directory names
  (quotes, `$`, backquotes, `$(...)`, `\`, tabs) were quoted correctly in
  the PATH line, the wrapper and the manifest; reinstalls kept exactly one
  block and the newline records; `--no-path` and an already-present `PATH`
  entry changed no file.
