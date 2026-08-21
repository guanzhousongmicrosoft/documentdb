# 00 — Release E2E Rollup (v0.116-0)

**Coordinator:** <who> · **Compiled:** <UTC> · **Status:** DRAFT (fill after Phase C)

This is the consolidated verdict across all 16 tracks. Fill it in Phase C after the
per-track reports land. De-duplicate findings (the same issue may surface in
several tracks — record it once, list the tracks that hit it).

---

## Release recommendation

> **GO / NO-GO / GO-WITH-CAVEATS:** _<one word>_
>
> **One-paragraph justification:** _<what drives the call — the S1/S2 list below>_

**Decision rule:** any open **S1** ⇒ NO-GO. Open **S2** ⇒ GO-WITH-CAVEATS only if a
documented workaround exists and the release owner accepts it; otherwise NO-GO.
S3/S4 do not block but must be listed as known issues.

---

## SUT under test (pin exactly what was verified)

- Image: `ghcr.io/documentdb/documentdb/documentdb-local` — digests tested: _<list>_
- Packages: `documentdb-packages-0.116.0` (run 32413347757), SHA256SUMS: _<OK?>_
- Provenance note P1 (image revision `810cf2cc` ≠ tag `66e9e118`): _<confirmed?>_

---

## Consolidated findings

| ID | Sev | Title | Tracks | Finding-seed | Status | Workaround? |
|----|-----|-------|--------|--------------|--------|-------------|
| F-01 | S? | … | T0x | Cx | open/fixed | … |

---

## Severity totals

| | S1 | S2 | S3 | S4 |
|--|:--:|:--:|:--:|:--:|
| Count | 0 | 0 | 0 | 0 |

---

## Finding-seed disposition

For every seed in `ENVIRONMENT-SETUP.md §6`, the verdict from the owning track:

| Seed | Owner | Verdict (CONFIRMED / NOT-REPRODUCED / N-A) | Evidence (report §) |
|------|-------|--------------------------------------------|---------------------|
| P1 | T01 | | |
| C1 | T01/T02 | | |
| C2 | T01/T03 | | |
| C3 | T03/T05 | | |
| C4 | T03/T12 | | |
| C5 | T03/T12 | | |
| C6 | T04/T13 | | |
| C7 | T04 | | |
| C8 | T06/T12 | | |
| S-esc | T07 | | |
| PK1 | T09 | | |
| PK2 | T10/T12 | | |
| U1 | T12 | | |
| C9 | T03/T07 | | |
| C10 | T16 | | |
| FG1 | T16 | | |

---

## Fixed-in-0.116 regression checks (from §7)

| Item | Track | Still fixed? | Evidence |
|------|-------|--------------|----------|
| #43/#62 concurrent-container lock | T02 | | |
| #61 bare-positional spin | T03 | | |
| cosign legacy `.sig` | T01 | | |
| #650 backend-contract on getParameter | T04 | | |
| RUM vacuum page-pruning race | T16 | | |

---

## Track completion

| Track | Report | Result | S1 | S2 | S3 | S4 |
|-------|--------|--------|:--:|:--:|:--:|:--:|
| 01 Image supply chain | reports/track-01-*.md | | | | | |
| 02 Lifecycle & durability | reports/track-02-*.md | | | | | |
| 03 Config & entrypoint | reports/track-03-*.md | | | | | |
| 04 Protocol & CRUD | reports/track-04-*.md | | | | | |
| 05 Auth | reports/track-05-*.md | | | | | |
| 06 TLS & transport | reports/track-06-*.md | | | | | |
| 07 Adversarial security | reports/track-07-*.md | | | | | |
| 08 DEB packaging | reports/track-08-*.md | | | | | |
| 09 RPM packaging | reports/track-09-*.md | | | | | |
| 10 Packaged gateway | reports/track-10-*.md | | | | | |
| 11 Performance & load | reports/track-11-*.md | | | | | |
| 12 UX & docs | reports/track-12-*.md | | | | | |
| 13 Compatibility | reports/track-13-*.md | | | | | |
| 14 Upgrade & migration | reports/track-14-*.md | | | | | |
| 15 Data-plane features | reports/track-15-*.md | | | | | |
| 16 Index, storage & flags | reports/track-16-*.md | | | | | |

---

## Known-failure baseline (must be answered explicitly)

Per `ENVIRONMENT-SETUP.md §8`, the release ships against a curated baseline. The
release owner has to accept these knowingly — they are not test results:

| Item | At tag | Accepted for release? |
|------|-------:|----------------------|
| `oss_ci_failing_tests.txt` (known-failing) | 15,422 | |
| `oss_ci_flaky_tests.txt` (known-flaky) | 1,898 | |
| `ci_crash_tests.txt` (engine crashers, skipped) | 6 | |
| Functional-suite run vs baseline: new failures | _<n>_ | |
| Functional-suite run vs baseline: `XPASS(strict)` | _<n>_ | |

---

## Fix verification (Phase D)

For every finding that was fixed, re-run the report's own repro against the
**rebuilt** artifact. An unverified fix does not clear its finding.

| ID | Sev | Fix (PR/commit) | Re-tested on (digest / package) | Verdict |
|----|-----|-----------------|---------------------------------|---------|
| F-01 | S? | | | CONFIRMED-FIXED / STILL-BROKEN / NOT-RETESTED |

---

## Coverage actually achieved

Tracks not run, checks skipped, and platforms not covered — including whether
arm64 was native or emulated, and which PG majors got depth beyond a smoke slice
(`ENVIRONMENT-SETUP.md §10`). An unrun track reads as a pass unless it is listed
here.

---

## Open questions for the release owner
<Design-vs-defect calls the testers couldn't resolve; anything needing a product
decision before ship.>
