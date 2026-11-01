# Fuzz campaign results

Date: 2026-10-30. Platform: Linux. Baseline revision: `6faee3e`.
The harness is [fuzz.tcl](/home/scott/work/tclvenv/tests/fuzz.tcl).

Later, broader campaigns and unfixed adversarial findings are recorded in
[FUZZ_EXTENDED_REPORT.md](FUZZ_EXTENDED_REPORT.md).
Those later findings are resolved in [fix verification](FUZZ_FIX_REPORT.md).

## Fix verification

All three defects below are fixed. The same six campaigns now pass **4800 of 4800 cases**, with **zero failures, timeouts, or output-limit events**.

| Tcl | Seed | Cases | Passed | Violations |
|---|---:|---:|---:|---:|
| 8.6.18 | 1 | 800 | 800 | 0 |
| 8.6.18 | 42 | 800 | 800 | 0 |
| 8.6.18 | 20261030 | 800 | 800 | 0 |
| 9.0.4 | 1 | 800 | 800 | 0 |
| 9.0.4 | 42 | 800 | 800 | 0 |
| 9.0.4 | 20261030 | 800 | 800 | 0 |

Removal verifies a regular transaction journal against the complete receipt before deleting staged files. It rejects unexpected staging entries, retains the journal through the final receipt update, and removes the staging directory nonrecursively. If cleanup fails after the receipt update, `doctor` reports the retained operation for manual cleanup. Reordered journal dictionaries and legacy receipts without a state field remain supported.

`doctor` compares runtime identity by key and value, retaining checks for missing, extra, or changed fields. Startup checks literal ancestry using normalized path components, then uses the normal module-path API. When Tcl's glob-based ancestry check rejects a legal literal path, a guarded fallback updates the core search list. Actual ancestry conflicts remain errors, including paths where glob characters would hide a real conflict from Tcl's checks.

The regular suite now has **134 tests: 130 passed, four Windows/PowerShell tests skipped**, on each interpreter. The 28 new regressions cover journal ownership and corruption, preservation of unrelated files, symlink journals, reordered/legacy receipts, runtime identity ordering and mutations, and module loading through glob-containing environment names with and without system packages. Existing fault-injection coverage also verifies that a failed final receipt update retains its journal for retry.

Verification reports:

- [Tcl 8.6.18, seed 1](/tmp/tclvenv-fuzz-final-86-seed1/summary.txt)
- [Tcl 8.6.18, seed 42](/tmp/tclvenv-fuzz-final-86-seed42/summary.txt)
- [Tcl 8.6.18, seed 20261030](/tmp/tclvenv-fuzz-final-86-seed20261030/summary.txt)
- [Tcl 9.0.4, seed 1](/tmp/tclvenv-fuzz-final-90-seed1/summary.txt)
- [Tcl 9.0.4, seed 42](/tmp/tclvenv-fuzz-final-90-seed42/summary.txt)
- [Tcl 9.0.4, seed 20261030](/tmp/tclvenv-fuzz-final-90-seed20261030/summary.txt)

## Baseline campaigns

The application source was unchanged during the initial campaigns at revision `6faee3e`.

Six campaigns ran eight groups with 100 cases per group: **4800 cases, 4412 passes, 388 property violations**. The violations represent three distinct defect types. There were 0 timeouts and 0 output-limit events across 8240 supervised target processes.

| Tcl | Seed | Cases | Passed | Violations |
|---|---:|---:|---:|---:|
| 8.6.18 | 1 | 800 | 736 | 64 |
| 8.6.18 | 42 | 800 | 740 | 60 |
| 8.6.18 | 20261030 | 800 | 730 | 70 |
| 9.0.4 | 1 | 800 | 736 | 64 |
| 9.0.4 | 42 | 800 | 740 | 60 |
| 9.0.4 | 20261030 | 800 | 730 | 70 |

| Group | Passed | Violations |
|---|---:|---:|
| argv | 600 | 0 |
| cli | 600 | 0 |
| config | 600 | 0 |
| inventory | 520 | 80 |
| packages | 600 | 0 |
| paths | 596 | 4 |
| stdin | 600 | 0 |
| ordering | 296 | 304 |

## Baseline defects

1. **Unrelated staging files could be deleted by a forged pending-removal record.** A valid package receipt is mutated to `state removing` with `stage remove-unrelated`. That staging directory contains a protected sentinel and no transaction journal. At baseline, `remove` skipped the public package, deleted the unrelated directory, and removed the receipt. The original package remained installed without its receipt. This was a data-integrity failure under inventory corruption. Fixed by [validateRemovalStage](/home/scott/work/tclvenv/lib/manager.tcl:579).

   ```sh
   tclsh tests/fuzz.tcl --seed 1 --only inventory --case 0
   ```

2. **Equivalent runtime dictionaries failed `doctor`.** The fuzzer permutes dictionary keys while retaining every key and value. At baseline, `doctor` compared the runtime dictionary as serialized text and reported a changed runtime. The runtime identity was unchanged. Fixed in [doctor](/home/scott/work/tclvenv/lib/manager.tcl:714).

   ```sh
   tclsh tests/fuzz.tcl --seed 1 --only ordering --case 1
   ```

3. **Some legal Unix environment names prevented startup.** Seed 42, path case 93 creates an environment whose name is `environment-é;*["-x`. At baseline, creation succeeded, then bootstrap failed while adding the module path: Tcl reported that the `modules` directory was an ancestor of its sibling `metadata/core-modules`. The Tcl module-path implementation uses glob matching for ancestor checks, so the literal `*[` in the path produced a false relationship. Fixed by [addModulePath](/home/scott/work/tclvenv/lib/runtime.tcl:26).

   ```sh
   tclsh tests/fuzz.tcl --seed 42 --only paths --case 93
   ```

All three replay commands reproduced a violated property with status 1 on both interpreters at baseline. They now pass with status 0. Failed inputs, expected data, child status, stdout/stderr, and the first workspace for each failure type are retained in the baseline campaign reports. Reports contain temporary filesystem paths; regenerate cases with their replay command rather than running a relocated retained environment.

## Baseline validation

The regular suite, including nine fuzz-harness self-tests, passes on each interpreter: **102 passed, four Windows/PowerShell tests skipped**. Harness self-tests cover exit codes, separate stdout/stderr, deadlines after output closure, process-tree termination, both output caps, Unicode/metacharacter transport, input half-close, deterministic replay, and dictionary-mutation integrity. Campaign properties cover generated valid and invalid CLI/config inputs, byte-exact arguments, package trees and modules, rejection of symlinks and invalid module names, protected files, shell restoration, and bounded differential stdin behavior.

Campaign tests are separate from the regular suite. The harness continues to return a nonzero status for property violations; its assertions were unchanged for fix verification.

## Detailed baseline reports

- [Tcl 8.6.18, seed 1](/tmp/tclvenv-fuzz-86-seed1/summary.txt)
- [Tcl 8.6.18, seed 42](/tmp/tclvenv-fuzz-86-seed42/summary.txt)
- [Tcl 8.6.18, seed 20261030](/tmp/tclvenv-fuzz-86-seed20261030/summary.txt)
- [Tcl 9.0.4, seed 1](/tmp/tclvenv-fuzz-90-seed1/summary.txt)
- [Tcl 9.0.4, seed 42](/tmp/tclvenv-fuzz-90-seed42/summary.txt)
- [Tcl 9.0.4, seed 20261030](/tmp/tclvenv-fuzz-90-seed20261030/summary.txt)
