# DocumentDB Release E2E Test Plan — Coordinator & Agent Hand-off

**Purpose.** You (a human or a coordinating agent) have a **built release**: the
`documentdb-local` container image and the Tier-1 `.deb`/`.rpm` package set
(version **0.118**). This bundle tells other agents exactly **what to test, what
to expect, and how to report** — across functionality, UX, security, durability,
performance, compatibility, and "everything we can think of to break it."

**This is a plan, not a run.** Nothing here has been executed against the SUT.
Each track file is a **self-contained prompt** you paste to a fresh agent. The
agents do the testing and write reports; the coordinator rolls them up into a
GO/NO-GO.

## How to use this bundle
1. **Read `ENVIRONMENT-SETUP.md` first** — it is the shared ground truth (ports,
   creds, defaults, config, exact artifact names). Every track depends on it.
   Fill in the **Artifact Inventory** below with the concrete filenames/tag of
   the artifacts you actually built.
2. **Dispatch tracks.** Each `prompts/track-NN-*.md` is a complete agent brief.
   Give the agent: (a) that track file, (b) `ENVIRONMENT-SETUP.md`, (c)
   `REPORT-TEMPLATE.md`, and (d) the filled-in Artifact Inventory. Run
   independent tracks in parallel; respect the phase ordering below.
3. **Collect reports** into `reports/` and produce `reports/00-ROLLUP.md`.

## Artifact Inventory (COORDINATOR: fill this in before dispatch)
> Paste the real values from your build host. Placeholders shown are the expected
> shape for 0.118.

- **Container image under test:** `__________` (tag), digest `__________`,
  bundled PG major `__________` (from `/version.txt`), arch `__________`.
- **Package set under test:** built from tree state `__________`
  (commit / dirty? — note the `documentdb.spec` libbson caveat in ENVIRONMENT-SETUP),
  located at `__________`.
  - DEB (Ubuntu 24.04, PG 17+18, amd64+arm64): 11 files — confirm all present.
  - RPM (RHEL/Rocky 9, PG 17+18): 11 files — confirm gateway/extension carry
    `.el9` and the 5 noarch extras are `-1.noarch.rpm`.
  - Bundle: 22 packages + `SHA256SUMS` + `manifest.txt` = **24 assets**; verify
    `sha256sum -c SHA256SUMS`.
- **Host(s) available for testing:** `__________` (must be Linux/Docker; note
  which arches you can actually run — arm64 coverage is a common gap).

## The 12 tracks

| # | Track | Targets | Primary lens | Parallel group |
|---|-------|---------|--------------|----------------|
| 01 | Install & Packaging | packages | packaging, functional | Phase 1 |
| 02 | Container Lifecycle & Emulator | image | functional, ux, durability | Phase 1 |
| 03 | Connectivity, Wire Protocol & CRUD/Aggregation | image (+pkg) | functional | Phase 2 (needs a live SUT from P1) |
| 04 | AuthN / AuthZ / User Management | image + pkg | security | Phase 2 |
| 05 | TLS & Transport Security | image + pkg | security | Phase 2 |
| 06 | Adversarial Security & Hardening | image + pkg | security | Phase 3 (after 03–05 map the surface) |
| 07 | Data Integrity & Durability | image + pkg | durability | Phase 2 |
| 08 | Performance & Scale (smoke) | image | perf | Phase 3 |
| 09 | UX, Docs & First-Run Fidelity | image + pkg + README | ux, docs | Phase 2 |
| 10 | Compatibility & Ecosystem | image | compat | Phase 2 |
| 11 | Upgrade / Migration / Uninstall | pkg | packaging, durability | Phase 3 |
| 12 | Observability & Telemetry | image + pkg | observability, security | Phase 2 |

### Execution phases (dependency-driven, not rigid)
- **Phase 1 — stand up the SUT & prove the happy path:** Tracks **01** (install
  the packages, start via systemd) and **02** (run the container). If either
  fails its documented happy path, that is an immediate **NO-GO** signal — flag
  it before spending effort on deeper tracks.
- **Phase 2 — exercise the surface against a live SUT:** Tracks **03, 04, 05,
  07, 09, 10, 12** run in parallel against the container (and packaged install
  where noted).
- **Phase 3 — stress, adversarial, and change-over-time:** Tracks **06**
  (adversarial — informed by the surface map from 03–05), **08** (perf), **11**
  (upgrade/uninstall). These can start once Phase 2 has confirmed baseline
  behavior.

A single coordinator agent may run several tracks sequentially; a fleet may take
one each. Either way, every agent uses the same report format.

## Global rules for every agent (summary — full text in REPORT-TEMPLATE.md)
- **No PASS without observation.** Blocked check ⇒ SKIP + reason, never PASS.
- **Every finding is reproducible** from a clean SUT and cites evidence.
- **Credential hygiene:** generate secrets at runtime; never write a real
  credential into any saved file; use the positive-control pattern when asserting
  a secret does *not* leak.
- **Authorized scope:** create/destroy disposable containers, volumes, and
  package installs inside throwaway Linux containers or a dedicated test VM. Do
  **not** mutate shared/production hosts, push images, publish packages, or send
  SUT data to external services. Blocked-by-scope ⇒ report it, don't work around.
- **Leave it clean.** Remove what you created; list anything you couldn't.
- **Reuse the repo's existing harness.** `packaging/test_packages/*.sh`,
  `documentdb-local/functional-tests/`, and the built test images already encode
  hard-won rigor (positive controls, honest skips). Run and extend them rather
  than reinventing — and read their comments; they document real past bugs.

## What "break the product" means here (idea seeds, not limits)
Each track has a **"How to break it"** section. Across the suite, deliberately
attack: the internal PG port being reachable from outside; wrong-credential and
reserved-name auth; plaintext against `requireTLS`; oversized / deeply-nested /
malformed BSON; connection and memory exhaustion; secrets in `ps`/logs/env;
crash-during-write and volume-yank durability; unclean shutdown → WAL recovery;
upgrade across majors and downgrade; the `documentdb`-user `sudo NOPASSWD`
posture; telemetry actually staying off; and every documented flag/env fed a
hostile value. If you find a new way to break it that no track named, that is
exactly the point — file it.
