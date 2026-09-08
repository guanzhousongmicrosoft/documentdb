# Track 11 — Performance & load

**You are** a performance engineer. You establish that the release performs
reasonably under realistic and hostile load, find the cliffs, and catch any
regression versus the previous release. You are not chasing a benchmark number for
marketing — you are looking for **stalls, leaks, unfair degradation, and
correctness-under-load failures**.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 bring-up) and `REPORT-TEMPLATE.md`.
**Write** to `reports/track-11-performance-load.md`. Report the **methodology and
the SUT sizing** with every number — an unlabeled latency figure is useless.

## SUT
`documentdb-local:pg17-0.116.0` on a fixed, recorded host (CPU model, cores, RAM,
disk type, container `--cpus`/`--memory`). Keep the host constant across
comparisons. Use a real workload generator against the MongoDB endpoint
(`mongosh` loops are fine for smoke; prefer a driver-based harness or a MongoDB
load tool for real numbers).

## What to test (checklist)

1. **Baseline throughput/latency.** Single-client and N-client insert, point-read
   (by `_id` and by indexed field), update, and delete. Report ops/sec and p50/p95/
   p99 latency at each concurrency level (1, 8, 32, 128 clients). Identify where
   latency knees.
2. **Connection scaling.** Ramp concurrent connections until the gateway or backend
   PG refuses. Record the ceiling, the failure mode (clean rejection vs hang vs
   crash), and whether it recovers when load drops. A hang or crash under
   connection pressure is S2.
3. **Read/write mix under sustained load.** Run a mixed workload (e.g. 70/30
   read/write) for an extended period (≥30 min). Watch for: latency drift, memory
   growth (gateway and PG RSS), fd growth, connection leaks, autovacuum behavior,
   and log growth. A steady climb that doesn't plateau is a leak → S2/S3.
4. **Large documents & batches.** Insert documents near the max BSON size and large
   `insertMany` batches. Report throughput and confirm no corruption. Find the size
   at which behavior degrades sharply.
5. **Index build cost.** Build an index on a large populated collection. Measure
   duration and its impact on concurrent reads/writes. Confirm foreground vs
   background behavior matches docs.
6. **Aggregation-heavy load.** Run the expensive pipelines (large `$group`,
   `$lookup`, `$sort` spilling to disk) under concurrency. Confirm memory is bounded
   (spills rather than OOMs) and results stay correct under load. Exercise the 0.116
   streaming `$group`/`$sortGroup` pushdown paths — confirm they are faster **and**
   still correct vs a forced non-streaming plan.
7. **Correctness under contention.** Concurrent updates to the same documents;
   unique-index races (many clients inserting the same key — exactly one must win);
   concurrent create/drop index. No lost updates, no duplicate unique keys, no
   crash. A correctness failure under contention is S1.
8. **Resource-limit behavior.** Run under tight `--memory`; drive it toward the
   limit. Confirm the failure is graceful (query errors/rejections) and does **not**
   corrupt data on the next restart (coordinate with Track 02).
9. **Cold vs warm.** Time from container start to first-successful-query (cold),
   and steady-state after cache warm. Report both.
10. **Regression vs previous release (if feasible).** Run the same harness against
    a v0.114 container and 0.116. Flag any material throughput/latency regression
    (>~15% on a core op) as S3 with the numbers.

## Pass/fail thresholds (agree these before you start)

"Reasonable throughput" is not falsifiable, so fix the bar first and record it
in the report. These are the defaults; if the release owner sets different ones,
use theirs and say so.

| # | Criterion | Fail if |
|---|-----------|---------|
| 1 | Stability under sustained mixed load (≥30 min) | p99 latency drifts upward >25% from the first 5-minute window to the last, with no plateau |
| 2 | Memory | gateway or PG RSS grows monotonically with no plateau over the run |
| 3 | File descriptors / connections | count grows monotonically after load stabilises (leak) |
| 4 | Connection ceiling | the failure mode is a hang, a crash, or a state that does not recover when load drops (a clean rejection passes) |
| 5 | Correctness under contention | **any** lost update, duplicate unique key, or wrong count — S1 regardless of the perf numbers |
| 6 | Memory-bounded aggregation | a large `$group`/`$sort`/`$lookup` OOM-kills the backend instead of spilling |
| 7 | Regression vs the previous release | >15% throughput loss or >25% p99 increase on a core op, same host, same harness |
| 8 | Cold start | time to first successful query exceeds the value the docs/readiness guidance imply (record it either way) |

Criterion 7 needs a 0.114 baseline on the **same host**. If that baseline cannot
be obtained (see `ENVIRONMENT-SETUP §10`), mark it ⛔ rather than reporting
absolute numbers as though they were a comparison.

## Expected results
Reasonable, stable throughput; graceful degradation at the ceilings; no leaks over
sustained load; correctness holds under contention; 0.116 streaming paths correct.
Absolute numbers are context — the **shape** (stability, graceful limits, no
correctness loss) is the pass/fail.

## Report
`REPORT-TEMPLATE.md`. Every number carries its concurrency, host, and container
limits. Include the harness command/script under `reports/artifacts/track-11-*`.
Correctness-under-load failures are S1 regardless of the perf numbers.
