# Native Tcl compatibility fuzzing

Date: 2026-10-30. Linux. Tcl 8.6.18 and 9.0.4. Application revision `3b4dff1`.
This is the baseline report. The findings below are now fixed; see
[fix verification](FUZZ_FIX_REPORT.md) for changes and current results.

The earlier generators constrained package names and did not explore Tcl's
completion protocol. This phase adds two black-box properties in
[fuzz_compat.tcl](fuzz_compat.tcl). They exercise the normal CLI in fresh
environments, with no forged receipts, filesystem redirection, injected app
failures, or concurrent writer.

## Reduced findings

### Script failure becomes successful process exit

The complete script can be one line:

```tcl
return -level 2 marker
```

Baseline observations before the fix:

| Entry point | Exit status |
|---|---:|
| Native `tclsh script.tcl` | 1 |
| Environment runtime | 0 |
| Manager `run ENV -- script.tcl` | 0 |
| Environment shell launcher | 0 |

Native Tcl reports `command returned bad code: 2`. The extra procedure boundary
around script execution changes how the return level is consumed, allowing the
environment to signal success. Nested procedures and custom completion codes
produce related mismatches. Relevant code:
[runtime main](../lib/runtime.tcl#L158).

This reduced script was run through all four entry points on both interpreters,
with the statuses above. The generated case below also reproduces the exit
status difference on both versions:

```sh
tclsh tests/fuzz.tcl --seed 1 --only completions --case 55
```

### Installer accepts module names the module loader cannot find

These two separate module files reduce the namespace failure cases:

```tcl
# File: demo::::leaf-1.0.tm
package provide demo::::leaf 1.0
```

```tcl
# File: demo::-1.0.tm
package provide demo:: 1.0
```

On both interpreters, each file can be sourced directly and provides its stated
package. The manager accepts each installation with exit status 0. Requiring
that package through the environment fails with exit status 1.

The installer maps `::` to filesystem separators without rejecting empty
namespace components. Filesystem normalization and Tcl's module filename
grammar then lose or reject information in the requested package name. The
installer should either reject a name it cannot represent or preserve a name
that the loader can resolve. The property permits rejection of noncanonical
names; it requires successful installations to be loadable. Ordinary names
and canonical namespace names remain positive controls. Relevant code:
[module installation](../lib/manager.tcl#L505).

```sh
tclsh tests/fuzz.tcl --seed 1 --only modulegrammar --case 0
tclsh tests/fuzz.tcl --seed 1 --only modulegrammar --case 5
```

### Custom completion diagnostics lose the actual error category

```tcl
return -code 7 marker
```

Native Tcl exits 1 and reports `command returned bad code: 7`. The environment
also exits 1, but prints only `marker`. Both interpreters reproduce this reduced
example. Higher return levels and nested procedures expose related lost
completion diagnostics. The comparator deliberately ignores differing stack
frames and compares diagnostic categories or first message lines.

```sh
tclsh tests/fuzz.tcl --seed 1 --only completions --case 17
```

## Campaign results

Three seeds ran 200 cases per group per interpreter: **2400 cases, 1820 passed,
580 property failures**, with zero timeouts and zero output-limit events across
6476 supervised target processes. These failures repeat the behaviors above;
they are not hundreds of distinct bugs. The two interpreters produced identical
counts for every seed.

| Tcl | Seed | Module cases | Module failures | Script cases | Script failures |
|---|---:|---:|---:|---:|---:|
| 8.6.18 | 1 | 200 | 44 | 200 | 59 |
| 8.6.18 | 42 | 200 | 56 | 200 | 45 |
| 8.6.18 | 20261030 | 200 | 37 | 200 | 49 |
| 9.0.4 | 1 | 200 | 44 | 200 | 59 |
| 9.0.4 | 42 | 200 | 56 | 200 | 45 |
| 9.0.4 | 20261030 | 200 | 37 | 200 | 49 |

Failure categories: 274 accepted-but-unloadable modules, 68 differing exit
statuses, and 238 differing diagnostics. Assertions check status before
diagnostics, so these categories count failed cases without double counting.

The module generator covers eight name forms: plain, canonical, leading,
trailing, repeated, single, mixed namespace separators, and Unicode names.
Generated files contain only `package provide`, avoiding arbitrary package
implementation failures as an explanation for loader errors. Versions are
compared with Tcl version semantics rather than raw spelling.

The script generator covers normal commands, `break`, `continue`, errors,
returns, custom completion codes, nested procedures, and caught completions.
Native `tclsh` running the identical script provides the oracle for exit status,
stdout, and normalized stderr. Environment entry points are selected among the
manager, bootstrap, and POSIX launcher. No source-code branch coverage is
claimed.

## Validation and evidence

The regular suite passes on each interpreter: **156 total, 152 passed, four
Windows/PowerShell tests skipped**. New positive controls check canonical module
installation and ordinary script execution. Failing compatibility properties
remain separate fuzz failures; their expectations were not relaxed.

Reduced example files and captured outputs are retained under
`/tmp/tclvenv-minimal-compatibility-86` and
`/tmp/tclvenv-minimal-compatibility-90`. Each contains `results.tcldata`, the
one-line scripts, module source files, and child logs. The custom-code example
has additional `native-code7` and `isolated-code7` log directories.

Full campaign reports follow
`/tmp/tclvenv-fuzz-compat-ENGINE-GROUP-seedSEED`, where `ENGINE` is `86` or `90`,
`GROUP` is `modulegrammar` or `completions`, and `SEED` is `1`, `42`, or
`20261030`. Examples:

- [Module failures on Tcl 8.6](</tmp/tclvenv-fuzz-compat-86-modulegrammar-seed1/summary.txt>)
- [Completion failures on Tcl 8.6](</tmp/tclvenv-fuzz-compat-86-completions-seed1/summary.txt>)
- [Module failures on Tcl 9.0](</tmp/tclvenv-fuzz-compat-90-modulegrammar-seed1/summary.txt>)
- [Completion failures on Tcl 9.0](</tmp/tclvenv-fuzz-compat-90-completions-seed1/summary.txt>)

Preliminary smoke runs, positive controls, and reduced example checks are
excluded from the 2400-case campaign total. These campaigns supplement the
earlier [workflow and adversarial results](FUZZ_EXTENDED_REPORT.md); the runner
now exposes twenty groups. No application fixes or commits were made in this
baseline phase. The replay commands now pass after the fixes.
