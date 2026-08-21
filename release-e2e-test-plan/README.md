# DocumentDB v0.116-0 — Release E2E Test Plan (hand-off bundle)

This directory is a **hand-off bundle**: a set of instructions and self-contained
prompts so that *other agents* (or humans) can end-to-end test the built
**DocumentDB v0.116-0** release — the container image and the Tier-1 `.deb`/`.rpm`
packages — from every angle: functionality, protocol correctness, UX,
documentation fidelity, security, durability, performance, compatibility, and
upgrade. The explicit goal is to **try to break the product** before users do.

> This is a **plan, not a run**. Nothing here has been executed against the
> system under test (SUT). Each track prompt is written to be handed to a fresh
> agent that will do the actual work and write a report.

---

## 0. What is being tested (SUT at a glance)

- **Release:** `v0.116-0` (dashed tag) / `0.116.0` (dotted). CHANGELOG dates it
  **August 20, 2026**. (v0.115-0 was skipped; its changes fold into 0.116-0.)
- **Container image:** `ghcr.io/documentdb/documentdb/documentdb-local`
  tags `latest` (= pg17), `pg17-0.116.0`, `pg18-0.116.0`, `pg16-0.116.0`,
  `pg15-0.116.0`; multi-arch **amd64 + arm64**; cosign-signed.
- **Packages (22):** Ubuntu 24.04 `.deb` + RHEL/Rocky 9 `.rpm`, PostgreSQL **17
  and 18**, **amd64 + arm64**, plus the `documentdb-gateway` package and the
  standalone/meta packages.

Exact artifact names, digests, ports, defaults, and provenance are in
**[`ENVIRONMENT-SETUP.md`](ENVIRONMENT-SETUP.md)** — the single source of truth.
**Read it before starting any track**, starting with its **§0 "Before you
start"**: how to get the source at the release tag, which tools each track needs,
how to obtain the artifacts, and where your report goes. Do not hard-code values from memory; the
setup doc was regenerated from the actual build artifacts for this release.

---

## 1. How the work is structured

The plan is split into **16 tracks**. Each track is one self-contained prompt in
[`prompts/`](prompts/). A track owns a coherent slice of risk, sets up its own
SUT, runs its checks, and writes one report into [`reports/`](reports/).

| # | Track | SUT | Primary risk |
|---|-------|-----|--------------|
| 01 | [Image supply chain & provenance](prompts/track-01-image-supply-chain.md) | Image | Signatures, labels, multi-arch, tag hygiene |
| 02 | [Container lifecycle & durability](prompts/track-02-container-lifecycle-durability.md) | Image | Restart/crash/WAL, volume persistence, concurrent-container lock |
| 03 | [Container config & entrypoint hardening](prompts/track-03-container-config-entrypoint.md) | Image | Flag/env validation, port parsing, no-op settings |
| 04 | [Protocol & CRUD correctness](prompts/track-04-protocol-crud-correctness.md) | Image | Wire protocol, drivers, aggregation, indexes |
| 05 | [Authentication & authorization](prompts/track-05-auth.md) | Image | SCRAM, reserved roles, privilege boundaries |
| 06 | [TLS & transport security](prompts/track-06-tls-transport.md) | Image | TLS modes, auto-gen cert, plaintext acceptance |
| 07 | [Adversarial security & attack surface](prompts/track-07-adversarial-security.md) | Image | Injection, escalation, secret leakage, DoS |
| 08 | [DEB install/upgrade/remove (Ubuntu 24.04)](prompts/track-08-deb-packaging.md) | Packages | Dependencies, meta packages, lifecycle |
| 09 | [RPM install/upgrade/remove (RHEL/Rocky 9)](prompts/track-09-rpm-packaging.md) | Packages | Dependencies, co-install, lifecycle |
| 10 | [Packaged gateway & standalone setup](prompts/track-10-packaged-gateway-standalone.md) | Packages | systemd unit, helper scripts, local-PG-only limit |
| 11 | [Performance & load](prompts/track-11-performance-load.md) | Image | Throughput, concurrency, resource ceilings |
| 12 | [UX & documentation fidelity](prompts/track-12-ux-docs.md) | Both | Help text, error messages, docs vs reality |
| 13 | [Compatibility & interoperability](prompts/track-13-compatibility-interop.md) | Both | Driver matrix, tool clients, PG-version parity |
| 14 | [Upgrade & migration](prompts/track-14-upgrade-migration.md) | Both | Cross-version data & extension upgrade |
| 15 | [Data-plane feature matrix](prompts/track-15-data-plane-features.md) | Both | Vector, geo, text, collation, RBAC, sharding, admin cmds |
| 16 | [Index, storage & feature flags](prompts/track-16-index-storage-flags.md) | Image | RUM vacuum races, index integrity, GUC defaults, dump/restore |

Tracks 01–07, 11 and 16 need only a container runtime (Docker/Podman). Tracks
08–10 need Ubuntu 24.04 and RHEL/Rocky 9 hosts (or VMs/containers). Tracks 12–15
use whatever the track prompt specifies — Track 15 needs **both** a container and
a package-installed host, because two of its checks exist to catch a bad
PostGIS/pgvector dependency that Tracks 08/09 would not notice.

---

## 2. Execution model (4 phases)

A **coordinator** (the agent that owns this bundle) runs the phases. Individual
tracks are dispatched to **worker agents**, one per track, in parallel where the
infrastructure allows.

**Phase A — Smoke gate (serialize, ~30 min).** Before fanning out, one agent
runs [Track 04 §Smoke](prompts/track-04-protocol-crud-correctness.md) against
`pg17-0.116.0` and confirms: image pulls, container reaches the
`=== DocumentDB is ready ===` banner, and a single insert/find round-trips over
`mongosh`. If this fails, **stop** and file an S1 — the release is dead on
arrival and the other tracks would only produce noise.

**Phase B — Fan-out (parallel, in waves).** Dispatch each track to its own worker
agent with exactly its `prompts/track-NN-*.md` file plus `ENVIRONMENT-SETUP.md`
and `REPORT-TEMPLATE.md`. Workers do **not** coordinate with each other — the
**coordinator** owns the dependencies below and hands each worker an environment
that is already prepared. If a worker discovers something outside its track, it
records a *cross-track note* rather than chasing it.

Not every track can start at once; these edges are real, and a coordinator who
fans out all 16 at once will have several workers blocked on day one:

| Wave | Tracks | Prerequisite |
|------|--------|--------------|
| **B1** | 01, 02, 03, 04, 05, 06, 11, 12, 13, 16 | a container runtime — start immediately |
| **B2** | 08, 09 | Ubuntu 24.04 / Rocky 9 hosts **and** the package artifacts |
| **B3** | 10, 15 | a host where B2 left the extension installed (Track 15's container-side checks can run in B1 if you split it) |
| **B4** | 07, 14 | 07 wants the packaged gateway from Track 10; 14 needs a prior-release baseline, confirmed by its own Step 0 |

Rough budget: B1 is about a day of parallel agent time and B2–B4 another day.
Tracks 11 and 16 run longest — their sustained-load and churn windows are
measured in hours, so start them early even though they do not block anything.

**Reporting back.** Every worker returns its report file *and* one status line —
`TRACK NN — PASS | PASS-WITH-FINDINGS | FAIL | BLOCKED — S1:_ S2:_ S3:_ S4:_`.
The Phase-A smoke result comes back the same way, immediately, before that worker
continues into the rest of Track 04.

**Phase C — Rollup (serialize).** The coordinator collects all `reports/*.md`,
de-duplicates findings, and fills in
[`reports/00-ROLLUP.md`](reports/00-ROLLUP.md) with the consolidated severity
table and a single **GO / NO-GO / GO-WITH-CAVEATS** recommendation.

**Phase D — Fix verification (serialize, only if fixes land).** A release gate is
not done when it produces a verdict; it is done when the verdict is still true
after the fixes. For every finding that gets fixed, re-run **the exact repro from
the report** against the rebuilt artifact and record CONFIRMED-FIXED /
STILL-BROKEN / NOT-RETESTED in the rollup's fix-verification table. A fix that
was never re-tested against a real artifact does not clear an S1.

### If you cannot run all 16 tracks

Run them in this order and stop wherever the time runs out — the cut lines are
deliberate:

1. **Gate (hours).** Track 04 §Smoke, then the pinned functional suite
   (`ENVIRONMENT-SETUP §8`) against the published image, then Track 01
   (signatures) and Track 08 **or** 09 (does the package install at all). If
   these do not pass, nothing else matters.
2. **Ship-blocking (a day).** Tracks 02 (durability), 05 (auth), 06 (TLS), 16
   (index integrity), 14 (upgrade). These are the S1 generators: data loss, auth
   bypass, plaintext credentials, index corruption, upgrade data loss.
3. **Quality (a day).** Tracks 03, 07, 10, 12, 15.
4. **Breadth (as available).** Tracks 11, 13.

Whatever you skip, say so in the rollup. A silently-unrun track reads as a pass.

---

## 3. Rules every worker follows

1. **Verify, don't assume.** `ENVIRONMENT-SETUP.md` lists *finding-seeds* —
   suspected issues from a source read. They are **hypotheses to test live**, not
   facts to repeat. A finding is only real once you have reproduced it against
   the running SUT and captured the evidence. If a seed does not reproduce, say
   so — a disproved seed is a valuable result.
2. **Evidence or it didn't happen.** Every finding carries the exact command,
   the exact output (trimmed to the relevant lines), the image tag or package
   filename, the architecture, and the host OS. Paste real output; do not
   paraphrase it.
3. **Record the SUT identity.** Pin what you tested: image **digest** (not just
   tag — tags move), package filename + SHA256, arch, PG version, host.
4. **Isolate.** Fresh volume / fresh container / fresh VM per scenario unless the
   scenario *is* reuse. Never let one test's state leak into the next.
5. **Stay in your lane.** Do the track you were given. Note anything else in
   *Cross-track notes* and move on — do not start a rabbit-hole.
6. **Severity is defined for you.** Use the S1–S4 rubric in
   [`REPORT-TEMPLATE.md`](REPORT-TEMPLATE.md). Do not invent severities.
7. **Distinguish defect from design.** "MongoDB does X, DocumentDB does Y" is
   only a bug if DocumentDB *claims* X. When unsure, file it **S4 / Question**
   and describe both behaviors.
8. **Safety.** These tests target *your own* SUT instances. Do not attack
   infrastructure you were not handed. Adversarial tests (Track 07) are scoped to
   the container/host you spun up for the test.
9. **Check the functional gate first.** The release ships an **allowlist** of
   **10,481 must-pass** upstream functional tests (`ENVIRONMENT-SETUP.md §8`), plus
   four engine-crashing files it deliberately excludes. Before filing a missing or
   divergent feature, check whether the behaviour is inside or outside that
   contract — an excluded area is **known**, a failing allowlisted test is a
   **regression**. This is the data behind rule 7.
10. **Say what you did not test.** An unrun check is not a passing check. Mark it
    ⛔ blocked with the reason; the rollup depends on knowing the difference.

---

## 4. Deliverables

- One `reports/track-NN-*.md` per track (format: `REPORT-TEMPLATE.md`).
- One `reports/00-ROLLUP.md` with the consolidated verdict.
- Any captured artifacts (logs, pcaps, GIFs, SBOMs) referenced by path from the
  report and stored alongside it under `reports/artifacts/`.

## 5. Definition of done

- Every track has a report with a stated pass/fail per checklist item.
- Every filed finding is reproducible from the steps in the report.
- The rollup carries an explicit release recommendation with the S1/S2 list that
  drives it.
