# Track 03 — Container config & entrypoint hardening

- **Worker:** Claude Code · **Date:** 2026-08-21 UTC
- **SUT identity:** `documentdb-local@sha256:822903975b26…19ea` (`pg17-0.116.0`), amd64, PG 17
  · Host: Windows 11, Docker 29.6.2
- **Result:** PARTIAL — FAIL on the password contract
- **Counts:** S1: 1 · S2: 0 · S3: 1 · S4: 0

## Summary

Three items were executed. The **#61 bare-positional regression stays fixed** — a
clean fast exit with the offending token named, no CPU spin. The **password contract
(C3) is broken and is the S1 of this run**: with no `--password` the container starts,
reports ready, and the created admin user authenticates with the hardcoded password
`Admin100`, while `--help` states the flag is REQUIRED. The new seed **C9 is also
confirmed**: an undocumented `PGOPTIONS` environment variable is forwarded into the
backend server's argv and reproduces the effect of the security-relevant
`--allow-external-connections` flag without that flag. Port/boolean fuzzing, `--log-level`
(C4), `--enable-telemetry` (C5), reserved usernames and `--disable-extended-rum` were
**not run**.

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | `--help` fidelity | ⚠️ | Flag inventory matches `ENVIRONMENT-SETUP §2` exactly; U1 wording confirmed by reading |
| 2 | **Password contract (C3)** | ❌ | **S1** — see finding |
| 3 | Port parsing | ⛔ | Not run |
| 4 | Boolean validation | ⛔ | Not run |
| 5 | `--log-level` effect (C4) | ⛔ | Not run |
| 6 | `--enable-telemetry` effect (C5) | ⛔ | Not run |
| 7 | **Bare-positional spin (#61)** | ✅ | **PASS** — see below |
| 8 | `--start-pg false` | ⛔ | Not run |
| 9 | `--allow-external-connections` | ✅ | Default keeps PG on `localhost`; verified as the C9 baseline |
| 10 | `--data-path` / `--owner` / reserved usernames | ⛔ | Not run |
| 11 | Combined-flag sanity | ⛔ | Not run |
| 12 | `--disable-extended-rum` | ⛔ | Not run |
| 13 | **`PGOPTIONS` back-door (C9)** | ❌ | **S3** — see finding |

## #61 — bare positional argument: PASS

```
docker run -d <img> --username u --password <pw> junk
after 12s: exited exit=1  cpu=0.00%  elapsed=13s
stderr   : Unexpected argument junk
```
Exits non-zero within seconds, names the offending token, and burns **0.00% CPU** —
the PID-1 spin is gone.

## Findings

### [S1] Container starts ready with a live hardcoded admin credential when `--password` is omitted

- **What:** `--help` says `--password … REQUIRED.` but omitting it starts a fully ready
  container whose admin user authenticates with `Admin100`.
- **Finding-seed:** C3
- **Repro:**
  ```bash
  docker run -d --name tc3 <img> --username docdb_admin       # no --password, no PASSWORD env
  docker logs tc3 | grep -c "=== DocumentDB is ready ==="      # -> 1
  docker exec tc3 mongosh localhost:10260 -u docdb_admin -p Admin100 \
    --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates \
    --quiet --eval 'print("AUTH_OK " + db.getSiblingDB("admin").runCommand({ping:1}).ok)'
  ```
- **Observed:**
  ```
  user=docdb_admin pw=Admin100     -> AUTH_OK 1
  user=docdb_admin pw=default_user -> MongoServerError: Invalid key
  user=docdb_admin pw=password     -> MongoServerError: Invalid key
  user=docdb_admin pw=<empty>      -> MongoServerError: Invalid key
  ```
  Roles created: `docdb_admin`, `documentdb`, `documentdb_bg_worker_role`,
  `documentdb_readwrite_role`.
- **Expected:** Either refuse to start (matching the documented REQUIRED contract), or
  generate a random password and print it once. Not a constant.
- **Impact:** The gateway binds `0.0.0.0:10260`. Anyone who runs the container without
  a password and publishes the port — the obvious first thing a new user does — exposes
  an admin account with a password that is a constant in the shipped image.
- **Confidence:** high · **Suggested severity:** S1

### [S3] Undocumented `PGOPTIONS` reaches the backend server argv

- **What:** The entrypoint reads `PGOPTIONS` from the environment and word-splits it
  into `start_oss_server.sh`'s arguments — the same channel it uses internally to pass
  `-e` for `--allow-external-connections`. It appears in no `--help` output and no
  validation path.
- **Finding-seed:** C9
- **Repro:**
  ```bash
  docker run -d --name pgo-base -p 19712:9712 <img> --username u1 --password <pw>
  docker run -d --name pgo-inj  -p 19713:9712 -e PGOPTIONS="-e" <img> --username u1 --password <pw>
  ```
- **Observed:**
  ```
  pgo-base  listen_addresses: localhost
  pgo-inj   listen_addresses: *

  pgo-base pg_hba tail : host all all 127.0.0.1/32 trust ; ::1/128 trust
  pgo-inj  pg_hba tail : host all all 0.0.0.0/0 scram-sha-256
                         host all all ::0/0      scram-sha-256

  reachability from outside the container:
    host port 19712 -> Is the server running on that host and accepting TCP/IP connections?  (closed)
    host port 19713 -> fe_sendauth: no password supplied                                     (REACHABLE)
  ```
- **Expected:** A security-relevant exposure should be reachable only through the
  validated flag it is documented behind.
- **Impact:** Not an authentication bypass — the exposed listener still requires
  `scram-sha-256`. But an undocumented, unvalidated env var reproduces a documented
  security flag's effect, which defeats any policy that audits the flag surface.
- **Confidence:** high · **Suggested severity:** S3

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| C3 | **CONFIRMED — S1** | `Admin100` authenticates (above) |
| C9 | **CONFIRMED — S3** | `listen_addresses=*` + permissive hba + externally reachable (above) |
| C4 | NOT-TESTED | — |
| C5 | NOT-TESTED | — |
| C10 | NOT-TESTED | — |
