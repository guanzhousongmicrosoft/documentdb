# Track 04 — Protocol & CRUD correctness

- **Worker:** Claude Code
- **Date:** 2026-08-21 UTC
- **SUT identity:** `ghcr.io/documentdb/documentdb/documentdb-local@sha256:822903975b26…19ea`
  (tag `pg17-0.116.0`), amd64, PG 17 · Host: Windows 11, Docker 29.6.2
- **Result:** PASS
- **Counts:** S1: 0 · S2: 0 · S3: 1 · S4: 1

## Summary

**Phase-A smoke: PASS**, and the full PR-gate allowlist passes against the
**published** image: **10,481 tests collected, 10,481 passed, 0 failed, 0 skipped.**
This is the strongest protocol result available for this release and it is clean.
Two process-level findings came out of running it. First, `ENVIRONMENT-SETUP §8`
described the wrong test model — the known-failures xfail lists it cited **do not
exist at the release commit**; the release uses an allowlist gate of 10,481
must-pass tests, and §8 has been corrected. Second, the release's own *local*
runner (`run-functional-tests.sh allowlist`) cannot execute at this commit: the
shipped allowlist contains a `no_parallel`-marked test and the allowlist plugin
raises an unconditional `UsageError` before any test runs. CI is unaffected because
it takes a different, sharded path.

## Phase-A smoke gate

Container reached `=== DocumentDB is ready ===` in **8 s**.

```
insertOne  : true
insertMany : ok
count      : 4
find n=42  : {"ok":1,"n":42,"s":"hello"}
update     : 1
findAfter  : {"ok":1,"n":42,"s":"world"}
delete     : 2
countAfter : 2
buildInfo  : 7.0.0
```

**Verdict: PASS** — fan-out authorised.

## The allowlist gate (the headline result)

Reproduced the CI path (`functional_tests.yml` job 3): shard the allowlist into
explicit node IDs, then run them against the published image.

```bash
python3 functional_gate.py --image config/image.yml --allowlist config/allowlist.yml \
  --engine-name documentdb shard-allowlist --num-shards 8 --shard-id N \
  --prefix documentdb_tests/ --output ids_N.txt

docker run --rm --network host -v .:/results --entrypoint sh \
  ghcr.io/documentdb/functional-tests@sha256:79ed3d43… -c \
  "cd /app && exec pytest --rootdir documentdb_tests \$(cat /results/ids_N.txt) \
     --engine-name documentdb --connection-string '<uri>' -n 12 --json-report …"
```

| Shard | Tests | Result |
|------:|------:|--------|
| 0 | 1311 | passed |
| 1–4, 6, 7 | 1310 each | passed |
| 5 | 1310 | passed |
| **Total** | **10,481** | **10,481 passed / 0 failed / 0 skipped** |

Aggregated from the eight `report.json` files:
`{'passed': 10481, 'total': 10481, 'collected': 10481}`, zero non-passed outcomes.

Two harness bugs of my own were found and fixed en route, neither a product issue:
`--engine-name oss` (the correct value is `documentdb`) deselected everything, and
`functional_gate.py` writes CRLF on Windows so pytest folded a trailing `\r` into
every node ID and collected nothing.

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| — | Phase-A smoke | ✅ | 8 s to ready, full CRUD round-trip correct |
| — | Full allowlist gate | ✅ | **10,481/10,481** against the published image |
| 1 | Handshake / discovery | ✅ | Covered by the gate; `buildInfo` = 7.0.0 |
| 2 | `getParameter` backend-contract (#650, C7) | ✅ | Gate includes the discovery path; no backend-contract SQLSTATE observed |
| 3 | CRUD matrix | ✅ | Covered by the gate plus the smoke battery |
| 4–7, 9–11 | BSON fidelity, aggregation, indexes, `$jsonSchema`, cursors, transactions, errors | ✅ | Covered by the gate's 10,481 tests |
| 8 | Wire compression (C6) | ⛔ | Not tested — no driver run with `compressors=` |
| 12 | Drivers other than mongosh | ⚠️ | The suite drives pymongo internally; no standalone Node/Go run |

## Findings

### [S3] The release's own local functional-gate runner cannot run

- **What:** `run-functional-tests.sh allowlist` aborts before executing any test.
- **Finding-seed:** new
- **Repro:** run the allowlist mode (or the equivalent plugin invocation) at `684ac162`.
- **Observed:**
  ```
  ERROR: [ALLOWLISTED_NO_PARALLEL] allowlist.yml contains 1 tests marked no_parallel,
  but the Phase 1 PR gate runs with parallel workers and has no sequential phase:
    compatibility/tests/core/sessions/commands/killSessions/test_smoke_killSessions.py::test_smoke_killSessions
  ```
- **Expected:** The shipped runner should run the shipped allowlist against the
  pinned suite image.
- **Impact:** The documented *local* reproduction path is broken for developers and
  for anyone validating a release by hand. The guard in
  `tools/conftest_allowlist.py:198-205` is unconditional — there is no bypass flag.
  **CI is unaffected**: `functional_tests.yml` shards explicit node IDs and never
  loads the plugin.
- **Confidence:** high · **Suggested severity:** S3

### [S4] Normal client disconnects are logged at ERROR

- **What:** A routine connection close is logged as `ERROR`.
- **Observed:**
  ```
  INFO  … Accepted new TCP connection activity_id="db25f4d1-…"
  ERROR … Failed to accept a TCP connection (IPv6): Request failed with kind Gateway,
          code InternalError, error_message_internal: Connection closed.
  ```
- **Impact:** Log noise at ERROR severity for an expected event trains operators to
  ignore real errors and can trip alerting.
- **Confidence:** medium (observed on every container start; not traced to a cause)
- **Suggested severity:** S4

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| C6 | **N-A / not tested** | No `compressors=` driver run |
| C7 | **NOT-REPRODUCED** | Full gate incl. discovery passed; no disallowed backend SQLSTATE seen |

## Cross-track notes

- **`ENVIRONMENT-SETUP §8` was factually wrong** and has been corrected: the 15,422 /
  1,898 / 6 known-failure numbers come from a downstream fork's `main`, not from the
  release. At `684ac162` the config directory contains only `allowlist.yml` and
  `image.yml`. The real model is an allowlist of 10,481 must-pass tests, with four
  engine-crashing files (`setUnion_core`, `setUnion_type_dedup`, `stages_window`,
  `planCacheStats_type_errors`) excluded from the allowlist rather than xfailed.
- `functional_tests.yml` documents a **known RUM dynamic-cursor race that segfaults
  the engine under `-n4`**, and re-runs each shard's failures sequentially to absorb
  it. I saw no such crash at `-n 12` across 10,481 tests, but Track 16 should chase it.

## Evidence

`art/ft2/report_0..7.json`, `art/ft2/shard_0..7.log` in the session scratchpad.
