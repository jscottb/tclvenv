# Fuzz finding fixes and verification

Date: 2026-10-30. Linux, Tcl 8.6.18 and 9.0.4. Baseline revision: `3b4dff1`.
The outstanding findings in the extended and compatibility reports are fixed.

## Changes

- User scripts execute at global scope after bootstrap argument processing.
  The bootstrap no longer consumes a return level in its procedure frame.
  Unresolved returns, custom completion codes, `break`, and `continue` preserve
  native failure status and diagnostic categories through every entry point.
- Completion bookkeeping uses the runtime namespace. It does not overwrite or
  trigger traces on application globals named `message`, `options`, or
  `completion`.
- Module installation validates each mapped namespace component. Names such
  as `demo::::leaf` and `demo::` are refused before copying; canonical names,
  supported single-colon spellings, and Unicode names continue to work.
- Mutation commands validate physical environment directories before taking a
  lock, creating stages, publishing files, or writing receipts. Symlinked
  environment roots or namespace directories are refused. The reproduced
  parent-directory swap is detected before publication.
- Inventory validation rejects duplicate target ownership, incorrect root
  inventory types, module inventories containing directory trees, and changed
  installed target types before destructive work starts.
- Removal carries its recorded inventory into recursive deletion. Every file
  must still have the recorded type, size, and checksum. Unrecorded or changed
  payload data stops deletion and retains the pending receipt and journal.
- Cleanup records directory identity and rechecks it and its ancestor chain
  around traversal. The reproduced directory-to-symlink swap is refused before
  enumerating the external directory. Final directory deletion is nonrecursive.
- I/O fault workers preserve saved Tcl procedures in their original namespace,
  so namespace variable bindings survive instrumentation. Every injected fault
  must actually fire; all eight fault types have regular regression coverage.

Production changes are in [manager.tcl](../lib/manager.tcl) and
[runtime.tcl](../lib/runtime.tcl). The added
[fuzz_fixes.test](fuzz_fixes.test) contains 43 regression tests, including fixed
previously failing inputs, reduced native-Tcl comparisons on all launch paths,
application-global write traces, and a changed-file deletion/retry case.
The expanded fuzz generators and their independent assertions are committed
with the fixes; assertions were not relaxed to hide baseline failures.

## Validation

All final campaigns pass: **14600 case executions, zero failures, zero timeouts,
zero output-limit events**, across 43628 supervised target processes.

| Matrix, per interpreter | Seeds | Cases |
|---|---|---:|
| All 20 groups, 100 cases per group | 1, 42, 20261030 | 6000 |
| Module grammar and script completions, 200 cases per group | 1, 42, 20261030 | 1200 |
| Lifecycle, 100 sequences of 50 steps | 1337 | 100 |
| Total per interpreter | | 7300 |

The deeper compatibility campaigns deliberately repeat the first 100 cases and
extend them to 200. These totals count executions, not unique inputs or bugs.
They include 600 hard-termination cases using actual `SIGKILL`, 600 containment
cases, 600 contradictory-ownership cases, and 600 scheduled filesystem
interleavings. Baseline preliminary and smoke runs are excluded.

The final regular suite passes on both interpreters: **199 total, 195 passed,
four Windows/PowerShell tests skipped**. It was rerun after isolating completion
bookkeeping, including the fixed fuzz replays and the new application-global
trace regressions. The final campaign assertions and native-Tcl oracles remain
intact.

Reports are retained under `/tmp` using these directory patterns:

- `/tmp/tclvenv-fix-final-full-ENGINE-seedSEED`
- `/tmp/tclvenv-fix-final-compat-ENGINE-GROUP-seedSEED`
- `/tmp/tclvenv-fix-final-ENGINE-long`

`ENGINE` is `86` or `90`, `SEED` is `1`, `42`, or `20261030`, and compatibility
`GROUP` is `modulegrammar` or `completions`. Each directory contains
`summary.txt`, `summary.tcldata`, and `failures.tcldata`.

## Practical limits

These fixes preserve data at the reproduced adversarial cut points. Tcl's
path-based filesystem APIs do not provide atomic isolation against a writer
ignoring the mutation lock. Cooperative locking remains the supported mutation
contract; no arbitrary hostile-writer safety guarantee is claimed. Windows
launchers, permissions, and filesystem behavior still need Windows validation.

Recreate existing environments to pick up their copied manager and runtime.
