# Track 02 — Container lifecycle & data durability

- **Worker:** Claude Code · **Date:** 2026-08-21 UTC
- **SUT identity:** `documentdb-local@sha256:822903975b26…19ea` (`pg17-0.116.0`), amd64, PG 17,
  named volume `ddb-smoke-vol` · Host: Windows 11, Docker 29.6.2
- **Result:** PARTIAL — only the concurrency check was run
- **Counts:** S1: 0 · S2: 0 · S3: 0 · S4: 0

## Summary

Only checklist item 5 (the #43/#62 concurrent-container data-directory lock) was
executed. **It passes cleanly and is the strongest single durability result in this
run:** a second container on a live volume refuses to start with an accurate,
actionable message, and the container already serving that volume is unaffected —
still running and still answering queries. The rest of this track (clean-stop WAL
behaviour, `docker rm` persistence, SIGKILL recovery, SIGTERM propagation, stale
`postmaster.pid`, restart policy, disk-full, init hooks) was **not run**.

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | Clean start/stop, no recovery on restart | ⛔ | Not run |
| 2 | Persistence across `docker rm` | ⛔ | Not run |
| 3 | Hard kill / crash recovery | ⛔ | Not run |
| 4 | SIGTERM propagation (PID 1) | ⛔ | Not run |
| 5 | **Concurrent-container lock (#43/#62)** | ✅ | **PASS** — see below |
| 6 | Stale `postmaster.pid` | ⛔ | Not run |
| 7 | Restart policy & long-run | ⛔ | Not run |
| 8 | Disk-full behaviour | ⛔ | Not run |
| 9 | Init hooks lifecycle | ⛔ | Not run |
| 10 | Readiness signal usability | ✅ | Cold start to `=== DocumentDB is ready ===` measured at **8 s** |

## #43 / #62 — concurrent-container lock: PASS

**Repro**
```bash
# A already running on volume ddb-smoke-vol
docker run -d --name ddb-B -v ddb-smoke-vol:/data <img> --username docdb_admin --password <pw>
```

**Observed**
```
B state : exited exit=1
B says  : Error: another DocumentDB container is already using the data directory /data.
          Refusing to start: two PostgreSQL instances on one data directory would corrupt it,
          and taking it over would shut the running container's database down too.
          Give this container its own volume, or stop the container already serving /data.

A state : running Running=true
A still serves queries? A_OK docs=2
```

All three required properties hold: B exits non-zero naming the conflict, A stays
`Running=true`, and A still serves (the document count matches what the smoke test
left behind). The old failure mode — B deleting A's live lock and taking both down
while both reported `Running=true` — did not occur. The message is specific and tells
the user what to do.

**Not verified:** that the `flock` is released when A dies (killing A and re-taking the
volume with a fresh container), and that a *stale* `postmaster.pid` does not block a
start. Both remain open.

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| C1 | **CONFIRMED** (owned by T01) | No HEALTHCHECK; readiness must be obtained by polling logs for the ready banner — measured 8 s cold |

## Cross-track notes

Readiness has no machine-readable signal, so every automated test in this run had to
poll `docker logs` for the banner. That is the practical cost of C1.
