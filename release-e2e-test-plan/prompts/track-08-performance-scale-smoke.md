# Track 08 — Performance & Scale (smoke) (agent prompt)

You are a performance-QA agent. This is a **release smoke**, not a benchmark
competition: establish that the build performs within sane bounds, scales
predictably to its documented limits, and has no gross regressions, leaks, or
cliffs. Read `../ENVIRONMENT-SETUP.md` and `../REPORT-TEMPLATE.md` first. Target:
container on a host with known, recorded specs (CPU/RAM/disk — put them in the
report; numbers are meaningless without them).

## Contract facts that bound expectations
- `max_connections` from PG GUC (**fallback 25**); pool reserves 2 (system) + 5
  (auth); conn buffer 262144; idle 300s; lifetime 3600s.
- `maxWriteBatchSize` 100000; `maxBsonObjectSize` 16 MiB; stream buffers 8192.
- `AsyncRuntimeWorkerThreads` defaults to `available_parallelism()`.
- No built-in metrics endpoint — measure client-side latency/throughput and
  container-level CPU/RSS (`docker stats`), plus PG-side counters via SQL if needed.

## Test cases (record numbers as INFO; flag regressions/cliffs as S2/S3)

### A. Baseline latency & throughput
1. **Point ops:** single-threaded p50/p95/p99 latency for `insertOne`, `findOne`
   by `_id`, `updateOne`, `deleteOne` over a warmed collection. Record ops/sec.
2. **Bulk ingest:** throughput for `insertMany` at batch sizes 100 / 1000 / 10000
   / 100000 (the batch cap). Confirm 100000 works and 100001 is rejected cleanly.
3. **Query:** indexed-equality, range, sort-with-limit, and a `$lookup` join —
   latency and whether `explain` shows the expected index (a full COLLSCAN where an
   index exists is a perf finding).
4. **Aggregation:** a representative `$match→$group→$sort` over 1M docs — wall time
   and memory; confirm it doesn't spill to an error or OOM.

### B. Concurrency scaling
5. Ramp concurrent clients 1 → 8 → 32 → 100 (past `max_connections`=25). Plot
   throughput and latency. Expect throughput to rise then plateau, and connections
   past the limit to **queue or reject cleanly** — NOT collapse, error-storm, or
   deadlock. The 2+5 reserved pool slots must keep admin/system responsive at
   saturation.
6. Connection churn: rapid connect/auth/disconnect loops — the SCRAM handshake and
   pool (auth-reserved 5 slots) sustain it without leaking connections or fds.

### C. Scale / large data
7. Grow one collection to 10M+ docs: insert throughput stays roughly flat (no
   cliff), index build on a large collection completes in reasonable time and is
   non-blocking where documented (`compact mode:standard`, background unique index
   build), and query latency degrades gracefully.
8. Many collections/databases (e.g. 1000 collections): `listCollections`,
   catalog ops, and startup stay responsive.
9. Large documents near 16 MiB: insert/read latency and memory behavior.

### D. Stability over time (leaks)
10. **Soak:** run a mixed read/write workload for 30–60 min at moderate
    concurrency. RSS and connection count must **stabilize**, not grow unbounded
    (a steady climb = leak = S2). Cursor/txn reapers should keep those counts flat.
11. Cold-start time (container run → ready banner) and warm-restart time — record
    as INFO; a multi-minute cold start is a UX finding (Track 09).

### E. Resource efficiency
12. Idle footprint: RSS/CPU of an idle ready container. Image size on disk.
13. TOAST compression effect: insert large compressible docs with `lz4` vs `pglz`
    vs `default` — record size-on-disk and read latency deltas (lz4 is the default
    and should decompress faster for large docs).

## How to break it (find the cliff, don't just measure the smooth part)
- Push concurrency well past 25 and past 100 — where does it fall over, and does it
  recover when load drops (no permanent wedge)?
- Pathological queries: unindexed sort of a huge collection, cartesian `$lookup`,
  `$group` with millions of distinct keys, regex scans — do timeouts
  (`PostgresCommandTimeoutSecs` 120, txn 30s) bound them, or do they run the box
  out of memory?
- Hot-key contention: 100 writers to one document — throughput and error rate.
- A single connection issuing a huge (48 MB) message repeatedly — memory behavior.
- Mixed workload while a background index build runs — does foreground latency
  spike unacceptably?

## Evidence to capture
Host specs; a results table (op, concurrency, p50/p95/p99, ops/sec); throughput-vs-
concurrency and RSS-vs-time plots (or the raw CSVs); `explain` for any slow query;
`docker stats` samples; the soak-test start/end RSS + connection counts. Name the
tool (e.g. a pymongo driver harness, `mongoimport`, or a custom script under
`../reports/artifacts/`) and its parameters so numbers are reproducible.

## Out of scope / hand-offs
Correctness of results → 03. Durability under crash → 07. This track does NOT gate
the release on absolute numbers (no baseline exists yet) — it gates on **cliffs,
leaks, wedges, and gross regressions**. Record baselines as INFO for future
comparison.

Write your report to `../reports/TRACK-08-performance-scale-smoke-report.md`.
