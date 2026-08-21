# Track 05 — Authentication & authorization

- **Worker:** Claude Code · **Date:** 2026-08-21 UTC
- **SUT identity:** `documentdb-local@sha256:822903975b26…19ea` (`pg17-0.116.0`), amd64, PG 17
- **Result:** PARTIAL — FAIL on checklist item 10
- **Counts:** S1: 1 (shared with Track 03) · S2: 0 · S3: 0 · S4: 0

## Summary

Only the default-credential path (item 10, seed C3) was executed, and it fails. From
the auth side this confirms Track 03's finding: a container started with no
`--password` creates admin user `docdb_admin` and that user **successfully
authenticates over SCRAM-SHA-256 with the hardcoded password `Admin100`**. Per the
track prompt, "a live, guessable admin credential is **S1**". The happy path also
works (a supplied password authenticates and queries correctly, verified during the
Phase-A smoke). Mechanism downgrade, special-character passwords, reserved usernames,
authorization boundaries, cross-database isolation and PG-superuser pivot were **not
tested**.

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | Happy path | ✅ | SCRAM-SHA-256 with a supplied password authenticates and queries (Phase-A smoke) |
| 2 | Wrong credentials | ⚠️ | Three wrong passwords all rejected with `MongoServerError: Invalid key` (same message — no user-existence leak observed) |
| 3 | Mechanism downgrade | ⛔ | Not tested |
| 4 | Special-character passwords | ⛔ | Not tested |
| 5 | Reserved / blocked usernames | ⛔ | Not tested |
| 6 | Authorization boundaries | ⛔ | Not tested |
| 7 | Cross-database isolation | ⛔ | Not tested |
| 8 | Backend PG credential exposure | ⚠️ | Partially, via Track 03 C9: the exposed backend requires `scram-sha-256`, not `trust` |
| 9 | Session / credential lifetime | ⛔ | Not tested |
| 10 | **Default-password check (C3)** | ❌ | **S1 — the default authenticates** |

## Findings

### [S1] A live default admin credential authenticates when no password is supplied

- **What:** From the auth side, `Admin100` is not merely a fallback string — it is a
  working credential for the admin user on a container that reported ready.
- **Finding-seed:** C3 (shared with Track 03; single finding F-02 in the rollup)
- **Repro / Observed:**
  ```
  docker run -d --name tc3 <img> --username docdb_admin     # no --password, no PASSWORD env
  -> reaches "=== DocumentDB is ready ==="

  user=docdb_admin pw=Admin100     -> AUTH_OK 1
  user=docdb_admin pw=<empty>      -> MongoServerError: Invalid key
  ```
  Login roles present: `docdb_admin`, `documentdb`, `documentdb_bg_worker_role`,
  `documentdb_readwrite_role`.
- **Expected:** `--help` documents `--password` as **REQUIRED**; the container should
  enforce that contract or generate and print a random password.
- **Impact:** The gateway listens on `0.0.0.0:10260`. Publishing the port on a
  no-password container exposes a working admin login whose password is a constant in
  the shipped image. Under `allowTLS` (the default) that credential can also be sent
  in cleartext — see Track 06.
- **Confidence:** high · **Suggested severity:** S1

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| C3 | **CONFIRMED — S1** | `Admin100` authenticates against a no-password container |

## Cross-track notes

Wrong-username and wrong-password both return the identical `Invalid key` error in the
cases observed, which is the preferred behaviour (no user-existence oracle). This was
incidental to the C3 work and deserves a deliberate test.
