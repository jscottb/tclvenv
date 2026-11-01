# Recovery fuzzing report

The error-path review found that an interrupted command (a killed process)
left an environment no tclvenv command could repair: a mutation lock every
later command refused, and a staging directory `doctor` reported forever. A
rollback that failed was reported as "nothing was installed", and cleanup
after a committed change could turn it into a reported failure. Those are
fixed (see the commit), with regression tests in `tests/recovery.test`. The
groups in `tests/fuzz_recovery.tcl` then tested the fixes:

| Group | What it does |
| --- | --- |
| `stalelocks` | a mutation or creation lock in one of 18 shapes (dead, live or own holder on this host, another host, the older `pid N` format, garbage, empty, extra keys, zero, negative, non-numeric and huge pids, oversized, a directory, a link) with a breaker that is absent, live, dead, garbage or a directory; or 2-4 installs at once against one stale lock |
| `crashrecovery` | install or remove of a package directory (names with `~` and spaces, small or 200-file packages) or a module (plain or namespaced), killed with `SIGKILL` at one of 12 cut points (copying, journal written, move marker written, published, temporary receipt file open, receipt written; for removal: journal written, marker written, detached, `removing` written, deleting, final receipt written) or at a random time; then recovered by `recover`, by the next install, by removing another package, by `doctor` then `recover`, or by a `recover` itself killed at 0-40 ms and run again |
| `rollbacks` | a package whose load check adds, appends to, deletes or chmods its own files and then fails (error, `exit`, a hang past `TCLVENV_PROBE_TIMEOUT`) or passes, installed as a directory or an archive; and `remove` of a package changed after installation (files added, modified, deleted, directories, read-only directories, links out of it) with and without `--discard-changes` |

Oracles, written apart from the manager's own checks:

- A lock is taken over exactly when it is a regular file recording this host
  and a pid with no process, and no live breaker; otherwise the command fails
  with a clean message and the lock, the breaker and the environment are
  unchanged byte for byte. Racing takeovers never lose a receipt: each
  package a successful process installed has its receipt, nothing in `lib/`
  lacks one, and no lock or breaker remains.
- After recovery, the interrupted package is all or nothing: installed byte
  for byte with its receipt, or absent with none. Committed operations (a
  written receipt, a `removing` receipt) keep their outcome; uncommitted ones
  are undone. No stage, temporary file, lock or breaker remains; `doctor`
  agrees with the independent check; the source and an unrelated installed
  package are unchanged; a second `recover` changes nothing; the package can
  then be installed or removed again.
- A failure saying "nothing was installed" leaves nothing installed; one
  naming what couldn't be undone leaves exactly that. A changed package is
  refused by `remove` (nothing changes) and removed by `remove
  --discard-changes`, which never follows a link out of it.

## Findings

Four defects in the new code, found before it was committed, and two older
ones. Each has a regression test in `tests/recovery.test`; the failing fuzz
cases that are deterministic are replayed there too.

### 1. A lock beside a name with glob characters broke (stalelocks 22)

After taking a lock, the manager looks for record files that killed
processes left beside it, and built that `glob` pattern from the lock's own
name. A destination such as `created-[>\~};?` made every creation fail:

```text
tclvenv: unmatched close-brace in file name
```

Fixed: the directory is listed with `*` and names are compared as strings.
Test: `lock-glob-characters`.

### 2. A process killed while creating its lock left an empty lock (crashrecovery 9)

A lock was created with `open ... EXCL` and then written. A `recover` killed
between the two left an empty `mutation.lock`. An empty lock names no holder,
so it can never be judged stale: every later command was refused, the state
the fix set out to remove.

Fixed: the record is written to a file of its own (`LOCK.PID-RANDOM`) and
hard-linked to the lock's name (a link fails if the name exists, so it is
still exclusive). A killed process leaves no lock or a complete one; its
record file is removed by the next lock taken there once its process is
gone. Where hard links aren't supported, the old way is used. Test:
`lock-killed-while-creating`.

### 3. The same for the breaker (crashrecovery 29 and 44, Tcl 9.0)

Taking over a stale lock is serialized by a second lock, `LOCK.break`,
created the same way, with the same window. A takeover killed in it left an
empty breaker, which blocks every later takeover. Fixed as in 2. Test:
`lock-breaker-killed-while-creating`.

### 4. A breaker left by a dead process failed the takeover once

A takeover killed after linking its breaker leaves a complete breaker naming
a dead process. The next takeover removed it but then reported the lock as
held, leaving the takeover to the command after it. Seen when `recover` was
killed at 2-4 ms and run again (crashrecovery 9 with seed 1 on Tcl 8.6, and
2 with seed 7 on Tcl 9.0; timing-dependent). Fixed: once a dead breaker is
removed, the takeover goes on. Test: `lock-breaker-dead`.

A remaining limit: two processes that both find the same dead breaker in the
same microseconds can both go on. They then re-read the lock, and only one
can create the new one (the creation is exclusive); in the narrowest
interleaving the second can remove the first's fresh lock. This needs a
breaker left by a killed takeover and two commands starting within
microseconds of each other.

### 5. Temporary files and move markers were named so no check saw them (older)

`file tempfile` places its random part before what it takes for an
extension: a template `.tclvenv-move-` gives `tcl_Ab3dEf.tclvenv-move-`, and
`.tclvenv-` gives `tcl_Ab3dEf.tclvenv-`. `doctor` looked for leftovers named
`.tclvenv-*`, so a temporary receipt or move marker left by a killed process
was never reported; a marker left inside a package made it "changed" with no
explanation. Fixed: these files are created with explicit names
(`.tclvenv-PID-RANDOM`, `.tclvenv-move-PID-RANDOM`, and
`.tclvenv-create-NAME.stage-RANDOM` for creation), and recovery and `doctor`
also recognize the old names. Tests: `recover-install-marker`,
`recover-remove-marker`, `recover-write-temp`.

### 6. A package that gained a link couldn't be discarded by name (older)

`remove` of a package with a symbolic link added inside it failed with the
inventory's message (`symlinks and special files are not supported`)
instead of saying the package changed and how to remove it anyway. Fixed:
any inventory failure is reported as a change, with the
`--discard-changes` hint. Found by `rollbacks`; test:
`remove-discard-changes`.

## Generator faults

`crashrecovery` 0 (a source named `~tilde` taken for a home directory by Tcl
8.6), 3 (the adversary ran `write-temp` as a removal) and 20 (the
`remove-delete` cut point assumes a package directory). They are replayed in
`tests/recovery.test`.

## Oracles changed

Two older oracles encoded the behaviour this work changes on purpose:

- `killpoints` expected a creation lock left by a killed `create` to block
  the next one. It now expects the lock to be taken over and the new
  environment to pass `doctor`.
- `fuzz-removal-5.late-file` expected a removal to fail when a file is added
  to its staging directory after the receipt is committed. The removal has
  happened; it now succeeds with a warning, and the added file is kept (as
  before).

## Campaign

Linux, Tcl 8.6.18 and 9.0.4, seeds 1, 7 and 11. Final runs, after every
fix above:

| Groups | Cases per seed and Tcl | Runs | Failures |
| --- | --- | --- | --- |
| `stalelocks`, `crashrecovery`, `killpoints` | 60 | 18 (1,080 cases) | 0 |
| `rollbacks` | 60 | 6 (360 cases) | 0 |
| `locks`, `crashes`, `limits`, `faults`, `recovery`, `concurrency`, `interleavings`, `paths`, `names`, `lifecycle` (seed 1) | 40 | 20 (800 cases) | 0 |

`rollbacks` and the older groups last ran before finding 4, whose fix
changes only how a dead breaker is handled; the groups that reach it
(`stalelocks`, `crashrecovery`, `killpoints`) ran again afterwards. Before
the fixes, the first campaign failed 1 `stalelocks` case (finding 1), 2
`crashrecovery` cases on Tcl 9.0 (finding 3) and 1 `killpoints` case (the
changed oracle); the second failed 2 `crashrecovery` cases (finding 4).

```sh
tclsh tests/fuzz.tcl --seed 1 --only stalelocks --iterations 60
tclsh9.0 tests/fuzz.tcl --seed 11 --only crashrecovery --iterations 60
tclsh tests/fuzz.tcl --seed 7 --only rollbacks --iterations 60
```
