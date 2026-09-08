# Track 07 — Adversarial security & attack surface

- **Worker:** Claude Code · **Date:** 2026-08-21 UTC
- **SUT identity:** `documentdb-local@sha256:822903975b26…19ea` (`pg17-0.116.0`), amd64, PG 17.
  All testing confined to containers created for this run.
- **Result:** PARTIAL
- **Counts:** S1: 0 · S2: 0 · S3: 2 · S4: 0

## Summary

Two items were executed, both confirming seeds. **S-esc is confirmed**: the runtime
user `documentdb` holds passwordless full `sudo`, so anything achieving code execution
as that user is immediately root *inside the container*. **C9 is confirmed** (detailed
in Track 03): an undocumented `PGOPTIONS` env var reaches the backend server argv and
opens the internal PostgreSQL to all interfaces without the flag that is supposed to
gate it. Injection, DoS, pre-auth surface, secret leakage, filesystem permissions,
container hardening posture and the known engine-crasher files were **not tested**.

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | **In-container privilege escalation (S-esc)** | ❌ | **CONFIRMED** — see finding |
| 2 | Init-script trust boundary | ⛔ | Not tested |
| 3 | Injection via the wire protocol | ⛔ | Not tested |
| 4 | Secret leakage (`/proc`, logs, config) | ⛔ | Not tested |
| 5 | Filesystem & config permissions | ⛔ | Not tested |
| 6 | Denial of service | ⛔ | Not tested |
| 7 | Pre-auth surface | ⛔ | Not tested |
| 8 | **`--allow-external-connections` exposure** | ⚠️ | Baseline correct (PG on `localhost`); but reachable via `PGOPTIONS` — see C9 |
| 9 | Container hardening posture | ⛔ | Not tested |
| 10 | Resource-limit behaviour | ⛔ | Not tested |
| 11 | Known engine-crasher files | ⛔ | Not tested — see cross-track note |
| 12 | Default egress | ⛔ | Not tested (no `tcpdump`) |
| 13 | `PGOPTIONS` injection (C9) | ❌ | **CONFIRMED** — see finding |

## Findings

### [S3] Passwordless root inside the container

- **What:** The runtime user is in group `sudo` with a `NOPASSWD: ALL` rule.
- **Finding-seed:** S-esc — **CONFIRMED**
- **Repro / Observed:**
  ```
  $ docker exec -u documentdb ddb-smoke sudo -n id
  uid=0(root) gid=0(root) groups=0(root)

  $ docker exec ddb-smoke grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/
  /etc/sudoers.d/no-pass-ask:1:%sudo ALL=(ALL:ALL) NOPASSWD: ALL

  $ id documentdb
  uid=1000(documentdb) gid=1000(documentdb) groups=1000(documentdb),27(sudo)
  ```
- **Expected:** Runtime containers rarely need passwordless root. If it is build-time
  convenience, it should be dropped from the final stage.
- **Impact:** Defense-in-depth only — it does not cross the container boundary by
  itself. But it removes a layer: an attacker with code execution as `documentdb`
  (via a mounted init script, or a gateway RCE) becomes container-root for free, which
  materially eases any subsequent escape attempt.
- **Confidence:** high · **Suggested severity:** S3 (rated as defense-in-depth, not
  inflated — reachability requires prior code execution)

### [S3] `PGOPTIONS` reproduces `--allow-external-connections`

- **Finding-seed:** C9 — **CONFIRMED**. Full repro and evidence in
  `track-03-container-config-entrypoint.md`. Summary: `-e PGOPTIONS="-e"` alone flips
  `listen_addresses` to `*`, adds `host all all 0.0.0.0/0 scram-sha-256` to `pg_hba`,
  and makes the backend PostgreSQL reachable from outside the container — with no
  `--allow-external-connections` flag and no mention in `--help`.
- **Impact:** Auth still applies (`scram-sha-256`, not `trust`), so this is not an
  unauthenticated bypass. It is an unvalidated configuration channel that defeats any
  control which audits the documented flag surface.
- **Confidence:** high · **Suggested severity:** S3

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| S-esc | **CONFIRMED** | `sudo -n id` → root; `/etc/sudoers.d/no-pass-ask` |
| C9 | **CONFIRMED** | See Track 03 |

## Cross-track notes

- The release's allowlist deliberately **excludes four engine-crashing test files** —
  `setUnion_core`, `setUnion_type_dedup`, `stages_window`, `planCacheStats_type_errors`
  (stated in `allowlist.yml`'s header). These are known wire-reachable inputs that crash
  the engine and are excluded rather than fixed. **They were not run here** and are the
  single highest-value remaining item for this track: each should be characterised as
  pre-auth or post-auth reachable, and whether the crash takes down other clients' sessions.
- `functional_tests.yml` also documents a **known RUM dynamic-cursor race that segfaults
  the engine under parallel workers**. Not observed across 10,481 tests at `-n 12`, but
  it is an acknowledged crash path.

## Rules of engagement

All testing was confined to containers created for this run on the local host. No
external infrastructure was touched.
