# I/O-failure fuzzing report

Earlier groups killed the manager at random times (`killpoints`), broke its
output (`outputs`) and changed its files between commands. None made a
file operation fail in the middle of a command, which is where the error
handling (staging, rollback, removal journals, cleanup of temporary
directories) runs. The `limits` group (`tests/fuzz_limits.tcl`) does, with
real errors from the kernel:

| Fault | How | Error |
| --- | --- | --- |
| file-size limit | `ulimit -f N` (1 to about 1,200 blocks of 512 bytes), with `SIGXFSZ` ignored | a write past the limit fails with `EFBIG` |
| descriptor limit | `ulimit -n N`, N from 5 to 24 | an `open`, pipe or child process fails with `EMFILE` |
| read-only directory | the environment, its `lib/`, `modules/` or `metadata/`, the parent a new environment goes in, or `TMPDIR` | `EACCES` |

The operations are `create`, `install` of a multi-file package directory
(2-7 files of up to 120 KB), `install` of the same as a `.tar.gz`, `add
json`, and `remove`.

Oracle: an operation that succeeds under the fault leaves exactly what an
unlimited control run leaves. One that fails prints one `tclvenv:` message
(no stack trace), exits 1, and leaves the environment as it was (for
`create`: no destination, lock file or staging directory). With the fault
lifted, `doctor` passes, the same command succeeds with the control's
result, and the private temporary directory is empty.

Campaign: Tcl 8.6.18 and 9.0.4, 100 cases per seed, seeds 1, 7 and 11.
About half the cases fail under their fault (47 of 100 for seed 1 on Tcl
9.0). The rest succeed because the fault isn't reached (a limit above what
the operation writes or opens, a read-only directory it doesn't write). In
3 of those 100, `tclsh` itself couldn't start with so few descriptors, and
printed Tcl's own `init.tcl` message before tclvenv ran, as native `tclsh`
does. That is accepted when nothing changed.

## Findings

Every failure was handled: the environment was always left as it was,
`doctor` passed, a retry without the fault succeeded, and nothing was left
in the temporary directory. What was wrong was what three messages said.

### 1. A lock file that can't be created is reported as a lock held

The mutation lock and the creation lock are made with `open ... EXCL`, and
any failure was reported as a lock already there:

```text
$ chmod 555 ENV/metadata; tclvenv add ENV json
tclvenv: environment is locked: ENV/metadata/mutation.lock (remove a stale lock only after checking no installer is running)
$ chmod 555 parent; tclvenv create parent/env
tclvenv: environment creation is locked: parent/env.tclvenv-create.lock
```

Neither lock exists. The first message tells the user to remove a stale
lock that isn't there, and gives no hint of the permission problem.

### 2. A failed write names a channel, not the file

```text
$ (trap '' XFSZ; ulimit -f 100; tclvenv create env)
tclvenv: error writing "file5": file too large
```

`file5` is Tcl's internal channel name. The file was a core module being
copied into the new environment.

### Limitation: Tcl's `file copy` reports a failed write as "no such file or directory"

When a copy fails on a write (here `EFBIG`), Tcl 8.6 and 9.0 report the
destination as missing:

```text
$ (trap '' XFSZ; ulimit -f 100; tclvenv install ENV pkg)
tclvenv: error copying "…/pkg" to "…/metadata/stage-…/payload": "…/payload/sub/big.bin": no such file or directory
```

The same happens in plain `tclsh` (`file copy big.bin copy.bin` under the
limit gives `POSIX ENOENT`). tclvenv gets only that error from Tcl. Reporting
the real cause would mean replacing `file copy` with a copy of its own, so
this was left as it is. The install itself is undone correctly.

## Fixes

| # | Fix | Regression tests (`tests/limits.test`) |
| --- | --- | --- |
| 1 | `openLock` creates both lock files: only `EEXIST` means a lock is held. Any other failure gives `couldn't create the lock file PATH: REASON` (for example `permission denied`). | `lock-1.environment`, `lock-1.create`, `lock-1.held` (an existing lock is still reported as one) |
| 2 | `writeFile`, `writeData` and the core-module copies in `create` report `couldn't write PATH: REASON`, the reason taken from the POSIX error code. | `write-2.create` (also checks that the failed create left nothing in its parent) |

`lock-1.environment`, `lock-1.create` and `write-2.create` fail on the code
before the fixes; `lock-1.held` passes on both. The full suite passes on Tcl
8.6.18 and 9.0.4.

After the fixes, `limits` ran 100 cases for each of seeds 1, 7 and 11 on
Tcl 8.6.18 and 9.0.4 (600 cases) with no failures. The operation failed
under its fault in 270 of them (8.6: 53/48/38, 9.0: 47/47/37), and each of
those was handled as the oracle requires.

## Not found

- No fault left an environment different from before a failed operation,
  or half installed or half removed. No fault left a lock, a staging
  directory, a removal journal that a retry didn't finish, or a temporary
  directory.
- A failed `create` removed its staging directory and lock in every case,
  including a failed write in the middle of copying the core modules.
- `add` under a descriptor limit fails cleanly when it can't start the
  environment's Tcl (`couldn't create pipe: too many open files`), and
  succeeds when it can.
- A read-only `TMPDIR` affected none of the operations: directory and
  archive installs both completed (checked by hand for an archive too).
