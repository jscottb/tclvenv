# Extended and adversarial fuzz results

Date: 2026-10-30. Linux, Tcl 8.6.18 and Tcl 9.0.4. Application revision: `3b4dff1`.
This report records baseline failures. The findings below are now fixed; see
[fix verification](FUZZ_FIX_REPORT.md) for changes and current results.

A subsequent [compatibility campaign](FUZZ_COMPAT_REPORT.md) adds two groups
and reports ordinary CLI failures in fresh environments, including reduced
examples for incorrect script exit status and accepted-but-unloadable modules.

**11000 cases: 9734 passed, 1266 property failures.** There were zero timeouts
and zero output-limit events across 35186 supervised target processes. The
failures repeat a small number of conditions; they are not 1266 distinct bugs.

The first expansion concentrated on normal operation sequences and known I/O
failures. It passed 8600 cases. After feedback that this was too conservative,
four additional groups challenged ownership, redirected filesystem paths,
uncoordinated filesystem changes, and hard process termination. These added
2400 cases and exposed the failures below.

## Conditions and interpretation

The static failures require a damaged or altered environment: symlinked
environment directories, contradictory inventory records, or a forged module
receipt. These are defensive validation and data-integrity gaps. They are not
failures demonstrated on a pristine environment with exclusively valid CLI
operations. Metadata is local data, and Tcl package isolation is not a filesystem
security sandbox.

The interleaving failures require a writer that ignores the mutation lock.
The README currently excludes this concurrency model. They demonstrate limits
of the current data-preservation strategy, rather than a violation of the
documented supported-writer contract. The symlink-deletion case nevertheless
shows that the cleanup implementation's "never follow symlinks" intent does not
hold across a directory replacement between its type check and traversal.

## Reproduced findings

1. **Redirected environment directories allow writes outside the environment.**
   Replace `lib`, `modules`, a module namespace directory, or `metadata` with a
   symlink into a sibling fixture. Installation proceeds and writes packages or
   receipt/journal data into that sibling tree. The entire sibling tree is
   compared before and after, so newly created files count as violations even
   when existing sentinel files survive. A directory swap immediately before
   publication reproduces the same external-write outcome under an
   uncoordinated writer. Relevant code: [install](../lib/manager.tcl#L505).

   ```sh
   tclsh tests/fuzz.tcl --seed 1 --only containment --case 2
   tclsh tests/fuzz.tcl --seed 1 --only interleavings --case 21
   ```

2. **Duplicate ownership receipts allow removal to strand another receipt.**
   Give two installation IDs the same target and inventory, including reordered
   records or a different source field. Removing one ID deletes the shared
   package and leaves the other receipt claiming absent files. The test requires
   refusal of ambiguous ownership before mutation. Relevant code:
   [installed](../lib/manager.tcl#L468), [remove](../lib/manager.tcl#L613).

   ```sh
   tclsh tests/fuzz.tcl --seed 1 --only ownership --case 1
   ```

3. **A forged module receipt can describe a directory and authorize its deletion.**
   Replace an installed `.tm` file with a directory containing unrelated data,
   then change its receipt to match that directory's inventory. Removal accepts
   it and recursively deletes the directory. The target-path validator checks
   the `.tm` extension but does not enforce the regular-file shape produced by
   module installation. This is a schema-hardening finding under receipt
   tampering, not authentication of arbitrary local metadata. Relevant code:
   [installed](../lib/manager.tcl#L468).

   ```sh
   tclsh tests/fuzz.tcl --seed 1 --only ownership --case 0
   ```

4. **Files added to a payload after validation are deleted.**
   Add an unrelated file at the boundary between staged-inventory validation and
   recursive payload deletion. Cleanup deletes it. This interleaving exceeds
   the supported mutation-lock contract. Relevant code:
   [remove](../lib/manager.tcl#L613), [deleteOwned](../lib/manager.tcl#L386).

   ```sh
   tclsh tests/fuzz.tcl --seed 1 --only interleavings --case 0
   ```

5. **A directory-to-symlink swap during deletion can delete external files.**
   After cleanup checks that a payload child is a directory, replace that child
   with a symlink to a sibling directory. Enumeration follows the link, and
   recursive cleanup deletes the sibling sentinel. The old child directory is
   parked separately, demonstrating that the deleted data came from the link
   target. This also requires an uncoordinated writer. Relevant code:
   [deleteOwned](../lib/manager.tcl#L386).

   ```sh
   tclsh tests/fuzz.tcl --seed 1 --only interleavings --case 8
   ```

All six commands above were replayed separately on both interpreters. Each
reproduces exactly one property failure and exits 1. Passing controls include
regular-file replacements, missing removal journals, and files added to the
staging directory after the final receipt update; the latter are preserved by
the existing nonrecursive staging cleanup.

## Campaign results

Three seeds (`1`, `42`, `20261030`) ran 100 cases per group per interpreter.
The first fourteen groups ran together. The four adversarial groups ran as
separate campaigns. Two additional lifecycle campaigns used seed `1337`, 100
cases, and 50 steps per case. These executions total **17200 generated lifecycle
steps**, including steps that correctly leave state unchanged.

| Group | Passed | Failed |
|---|---:|---:|
| argv | 600 | 0 |
| cli | 600 | 0 |
| config | 600 | 0 |
| inventory | 600 | 0 |
| packages | 600 | 0 |
| paths | 600 | 0 |
| stdin | 600 | 0 |
| ordering | 600 | 0 |
| lifecycle | 800 | 0 |
| recovery | 600 | 0 |
| faults | 600 | 0 |
| locks | 600 | 0 |
| modes | 600 | 0 |
| boundaries | 600 | 0 |
| containment | 260 | 340 |
| ownership | 108 | 492 |
| interleavings | 166 | 434 |
| crashes | 600 | 0 |

Both interpreters produced identical pass/failure counts for every seed.
Per interpreter, the adversarial groups produced:

| Seed | Containment failures | Ownership failures | Interleaving failures | Crash failures |
|---|---:|---:|---:|---:|
| 1 | 52 | 82 | 74 | 0 |
| 42 | 63 | 81 | 61 | 0 |
| 20261030 | 55 | 83 | 82 | 0 |

## What the extension exercises

This phase extended the runner to eighteen groups, deterministic replay with preserved
original case seeds, a bounded `--steps` setting, scenario counters, and separate
artifacts for failure variants. The new properties are implemented in
[fuzz_extended.tcl](fuzz_extended.tcl) and
[fuzz_adversarial.tcl](fuzz_adversarial.tcl).

Counters confirm all configured variants were exercised: six lifecycle actions,
13 recovery variants, eight injected I/O failures, six lock forms, seven script
modes, eight buffer-boundary sizes, seven redirected-directory forms, five
ownership variants, four interleavings, and eight hard-termination cut points.
These are scenario counters, not source-code branch coverage.

The 600 hard-termination cases use actual `SIGKILL` on Linux, after journal
creation, publication/detachment, receipt writes, or partial deletion. They check
retained journals and source/package bytes, valid atomic receipt data, stale-lock
reporting, and resumption of committed removals. Uncommitted or already-completed
transactions may still require the documented manual recovery; these tests do
not demand automatic recovery for every interrupted state.

## Verification and limits

The regular suite passes on each interpreter: **154 total, 150 passed, four
Windows/PowerShell tests skipped**. Twenty new harness tests protect seed
compatibility, sequence-length bounds and replay, symlink snapshots, new
scenario validity, positive adversarial controls, and hard termination.

Development runs caught harness errors involving Tcl caller scope, no-op empty
file mutation, NUL in OS arguments, source newline normalization, and Tcl 9
binary output. These were corrected and covered by integration checks before
the final campaigns. Preliminary runs, smoke cases, regular-suite cases, and
the separate single-case replay checks are excluded from the 11000-case total.

POSIX launchers and signals were exercised on Linux. Windows launchers,
activation, and the immediate-exit fallback still need a Windows campaign.
All generated filesystem mutations stay within disposable fixture trees.

## Reports and replay

Reports are transient files under `/tmp`. Each directory contains
`summary.txt`, `summary.tcldata`, and `failures.tcldata`. Failed-case artifacts
retain inputs, stdout/stderr, replay arguments, and the first workspace per
failure/variant. Retained environments and symlinks contain original absolute
paths; use replay commands rather than executing a relocated artifact.

- Workflow reports: `/tmp/tclvenv-fuzz-extended-final-ENGINE-seedSEED`, with
  `ENGINE` equal to `86` or `90`, and `SEED` equal to `1`, `42`, or `20261030`.
- Longer lifecycle reports: `/tmp/tclvenv-fuzz-extended-final-ENGINE-long`.
- Adversarial reports: `/tmp/tclvenv-fuzz-adversarial-ENGINE-GROUP-seedSEED`,
  where `GROUP` is `containment`, `ownership`, `interleavings`, or `crashes`.
- Examples: [namespace redirection](</tmp/tclvenv-fuzz-adversarial-86-containment-seed1/summary.txt>),
  [ownership failures](</tmp/tclvenv-fuzz-adversarial-86-ownership-seed1/summary.txt>),
  [filesystem interleavings](</tmp/tclvenv-fuzz-adversarial-86-interleavings-seed1/summary.txt>),
  [hard termination](</tmp/tclvenv-fuzz-adversarial-86-crashes-seed1/summary.txt>).

```sh
tclsh tests/fuzz.tcl --seed 1 --iterations 100
tclsh9.0 tests/fuzz.tcl --seed 42 --only crashes --iterations 100
tclsh tests/fuzz.tcl --seed 1337 --only lifecycle --iterations 100 --steps 50
```

Adversarial campaigns intentionally return nonzero while their properties remain
violated. Neither assertions nor application code were weakened to hide them.
