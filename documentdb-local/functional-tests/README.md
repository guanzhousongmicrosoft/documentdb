# DocumentDB functional tests

Runs the upstream `documentdb/functional-tests` wire-protocol suite against
DocumentDB under the **known-failures xfail model**, driven by
`.github/workflows/functional_tests.yml`.

There is **no allowlist**. The full suite runs under
`tools/conftest_known_failures.py`, which marks a per-gateway **failing** list as
`xfail(strict=True)` and a **flaky** list as `xfail(strict=False)`. The gate
fails on any residual `failed`/`error` — a real regression, or an `XPASS(strict)`
where a listed expected-failure now passes (the baseline must then be updated).
A third list, `config/ci_crash_tests.txt`, holds **engine-crasher** tests,
applied as `skip` (never executed): an xfailed crasher would still run, crash
the backend, and cascade connection errors onto every concurrent test. Unlike
the failing/flaky pair it is engine-level, not per-gateway — one list serves
every lane — and it also accepts file (`.py`) and directory (`/`) prefix
entries so it survives suite pin bumps.

## Layout

```
scripts/   docdb.sh: the entry point (test / suite / xfail / build / env /
           selftest); docdb_test_cmd.sh: the test command, sourced by it;
           run-functional-tests.sh: single-engine runner;
           run_pytest_split.sh: one CI matrix leg (slice + gate), used by
           .github/workflows/functional_tests.yml.
config/    Suite commit pin (image.yml); the OSS gateway's
           failing/flaky pair (oss_ci_failing_tests.txt, oss_ci_flaky_tests.txt),
           the engine-level crash skip list (ci_crash_tests.txt), and pytest
           args (oss_pytest.args).
tools/     conftest_known_failures.py (the xfail plugin) and functional_gate.py
           (report-failures / merge-reports / reconcile / split-collection /
           recover-and-gate / verify-split-universes / compare-engines).
tests/     Unit tests for functional_gate.py, the split runner's guard tests
           (test_run_pytest_split.sh), and docdb.sh's parity tests
           (test_docdb.sh).
```

`docdb.sh` is the one command to learn. It does not reimplement anything: it
delegates runs to `run-functional-tests.sh` and `run_pytest_split.sh`, list
maintenance to `functional_gate.py`, and packaging to `../../packaging/`, so
what it reports matches CI by construction. Those scripts remain usable on
their own, which is what CI does.

```bash
docdb=documentdb-local/functional-tests/scripts/docdb.sh

$docdb help              # all commands
$docdb test --help       # options for one command
```

The suite version is pinned by `source_sha` in `config/image.yml`, and both the
host checkout and the suite image are derived from it; see
[Update the baseline](#update-the-baseline-suite-version-bump-or-after-a-fix)
for how to move it. Each gateway maintains its own failing/flaky pair; the OSS
pair here is calibrated for the documentdb-local (OSS gateway) environment.

## The CI gate: full suite, split across matrix legs

The pinned suite is ~50k tests — too large for one CI job — so
`.github/workflows/functional_tests.yml` splits it ("split" = test splitting
across CI jobs, nothing to do with sharded collections):

- **Parallel legs** (`p0`..`pN`): each collects the non-`no_parallel` universe,
  runs its deterministic stride slice (`ids[SPLIT_ID::SPLIT_TOTAL]` of the
  sorted universe) with `-n auto`, then recovers transient crash-cascade
  victims by re-running the still-failing set serially and gates on the merged
  report (`functional_gate.py recover-and-gate`). `--expected-ids` makes green
  require a recorded outcome for every assigned test — lost xdist workers
  cannot silently drop coverage.
- **`no_parallel` leg** (`np`): every `no_parallel` test, serially
  (`-p no:xdist`), same recovery + gate.
- **`verify-splits` job**: asserts every parallel leg collected an IDENTICAL
  universe (each leg publishes a `universe.txt` fingerprint). Without this, a
  leg whose collection silently omitted a node would shift its stride and part
  of the suite would run on no leg while every leg scored green.

Each leg fails CLOSED on: a collection error (pytest exit ≠ 0/5), a
suspiciously small universe (`MIN_MANIFEST`), an empty slice, a missing
`report.json`, or fewer than half the assigned tests recording an outcome.

### What the test-results view shows

Each leg writes two JUnit files, and only one of them is the verdict:

| File | What it is |
|---|---|
| `results.xml` | pytest's own JUnit from the **main pass**. Kept in the artifact for debugging. **Not the verdict.** |
| `gate-results.xml` | the **gate's verdict** (`functional_gate.py emit-junit` over the post-recovery report). Read this one: it agrees with the leg's exit status by construction. |

They differ because recovery rewrites `report.json` *after* the main pass, so
`results.xml` disagrees with the verdict in both directions: a crash victim the
serial re-run rescued still reads `failed` there, and a test lost with a dying
xdist worker is simply **absent** while the gate fails the build for it.
Reading the main pass as the verdict would therefore report a rescued crash
victim as a failure, and say nothing at all about a test the gate failed the
run for.

`gate-results.xml` states the verdict per test, with the remediation in the
message:

| Verdict | Shown as | Message |
|---|---|---|
| passed | Passed | — |
| passed only after a serial re-run | Passed | `recovered: ... passed on sequential re-run N` |
| failed, and on the failing list | Skipped | `expected failure (strict xfail from ...)` |
| on the flaky list, either outcome | Skipped | `known flaky ...` |
| crash-listed, never executed | Skipped | `crash skip list: ... cascades onto every test sharing the run` |
| listed but now passes | **Failed** | `XPASS(strict): ... remove the entry` |
| residual failure | **Failed** | the real assertion |
| assigned but never reported | **Failed** | `no outcome recorded ... an xdist worker died with it queued` |

So "tests tab red" and "build red" are the same statement, and the `recovered`
count is a crash-rate signal that used to be invisible.

## Run locally

One command, whether or not an engine is already up:

```bash
docdb=documentdb-local/functional-tests/scripts/docdb.sh

# bring an engine up and run the full gate
$docdb test --all --build-and-start

# against an already-running engine
CONNECTION_STRING=... $docdb test --all

# just the area you changed
$docdb test --tests compatibility/tests/core/cursors

# what actually fails, ignoring the xfail lists
$docdb test --all --no-xfail

# reproduce the CI matrix shape locally
CONNECTION_STRING=... $docdb test --all --split-total ci
```

`--split-total ci` uses the width the workflow declares rather than a number
typed from memory. Use it for any run whose results will become a baseline: the
width sets how much of the suite shares one engine, so a different width fails a
different set of state-dependent tests.

`--all`, `--tests` or `--smoke` is required: there is no implicit default,
because running the whole suite by accident is expensive. Add `--dry-run` to
see what would run without starting anything.

The underlying runner is still available directly, and takes the same engine
options (`--build-and-start-documentdb`, `--use-existing-documentdb-image`,
`--workers`, ...):

```bash
./documentdb-local/functional-tests/scripts/run-functional-tests.sh gate --build-and-start-documentdb
```

Modes: `gate` (full suite under the xfail model — the CI gate), `single`
(one node ID), `smoke`, `full` (raw results, no gate). `--help` lists all options.

## Build the image and packages

```bash
$docdb build --target packages --os ubuntu22.04 --pg 16
$docdb build --target image
$docdb build --target both --os ubuntu22.04 --pg 16
```

`packages` wraps `packaging/build_packages.sh`; `image` builds the
documentdb-local container image through the runner.

## Check the harness itself

```bash
$docdb selftest
```

Runs `tests/test_docdb.sh` (which asserts that `docdb.sh` still matches
`.github/workflows/functional_tests.yml` and the real config files) and the
split runner's guard tests.

## Triage a gate failure

The gate prints the residual failures (`gate-failures.txt`). Each is either:

- **failed/error** — a real regression (or a new upstream test the engine
  doesn't pass yet): fix the engine, or add the node ID to the failing list.
- **XPASS(strict)** — a listed expected-failure now passes: remove it from the
  failing list (the baseline improved).

## Update the baseline (suite version bump or after a fix)

`config/image.yml` pins **one** thing: the suite commit. Both ways of running
the suite are derived from it, so they cannot name different versions.

| Derived | How | Used by |
|---|---|---|
| host checkout | `setup_functional_tests.sh` clones that commit | the split legs, and CI |
| suite image | `ghcr.io/documentdb/functional-tests:sha-<short7>` | `gate`, `full`, `single`, `smoke` |

`docdb suite pin` resolves the commit against the registry before writing,
because a commit upstream never published has no image and the single-engine
modes could not run. With `--ref` the commit is taken from the image's own
`org.opencontainers.image.revision` label rather than from the tag, because a
tag can be moved and the label cannot.

```bash
docdb=documentdb-local/functional-tests/scripts/docdb.sh

$docdb suite pin --ref main        # whatever upstream main publishes now
$docdb suite pin --sha <commit>    # a specific suite commit

$docdb suite update                # refresh the host checkout to match
$docdb suite status                # checkout matches, and an image exists
```

Then re-run the suite and fold the result back into the lists. Run it **twice**,
and pass both reports:

```bash
CONNECTION_STRING=... $docdb test --all --split-total ci --results-dir /tmp/run1
CONNECTION_STRING=... $docdb test --all --split-total ci --results-dir /tmp/run2
$docdb xfail reconcile --report /tmp/run1/report.json \
                       --report /tmp/run2/report.json --prune-uncollected
```

Both details matter, and skipping either produces a baseline that passes locally
and reds the gate:

- **`--split-total ci`** uses the width the workflow declares. The width decides
  how much of the suite shares one engine, so tests that read shared state (the
  set of databases, live connections, index counters) fail differently at a
  different width.
- **Two runs.** A strict entry asserts a test *always* fails, which one run
  cannot show. From a single report every test that failed once is asserted, and
  the first run that passes any of them is an `XPASS(strict)` that fails the
  gate. With two or more reports only consistent failures are asserted; whatever
  disagrees is moved to the flaky list, which accepts either outcome.

A CI run publishes one report per leg (`functional-test-results-<tag>`
artifacts). Combine each run's legs into one full-suite report first, because
`--prune-uncollected` is only valid on a full-suite report; on a single leg's
report it would prune every other leg's entries:

```bash
$docdb xfail combine --out run1.json p0/report.json p1/report.json ... np/report.json
$docdb xfail combine --out run2.json <the second run's legs>
$docdb xfail reconcile --report run1.json --report run2.json --prune-uncollected
```

Both wrap `tools/functional_gate.py` (`merge-reports` and `reconcile`), which
remains callable directly:

```bash
python3 documentdb-local/functional-tests/tools/functional_gate.py reconcile \
  --report combined.json \
  --failing config/oss_ci_failing_tests.txt \
  --flaky   config/oss_ci_flaky_tests.txt \
  --prune-uncollected
```

`reconcile` adds new failures, drops `XPASS(strict)` entries, prunes deleted
tests, preserves comments/prefix style, and flags anything needing a human
(listed tests that *errored*, failures already on the flaky list). Re-run the
gate afterward — strict xfail proves the list is exactly right (an over- or
under-edited list cannot pass).
