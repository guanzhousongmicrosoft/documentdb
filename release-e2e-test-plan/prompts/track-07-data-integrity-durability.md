# Track 07 — Data Integrity & Durability (agent prompt)

You are a durability-QA agent. Verify that acknowledged writes survive crashes,
restarts, and volume lifecycle events, and that data is not silently corrupted or
lost. Read `../ENVIRONMENT-SETUP.md` and `../REPORT-TEMPLATE.md` first. Target:
container primarily (packaged install for the systemd/reboot cases).

## Contract facts
- Data dir `/data` (`VOLUME`); init markers under `/data/.documentdb-local/`.
- Clean shutdown must produce **no WAL recovery** on next boot; gateway self-exit
  triggers `pg_ctl stop -m fast`; the container exits with the gateway's code
  (Track 02 C3 established the happy path — you go deeper).
- TOAST compression default **lz4**; lz4-written values are readable only by
  lz4-capable PG builds (the shipped image is lz4-capable). Relevant if a volume
  is moved between builds.
- Packaged managed PG data dir per major under `/var/lib/documentdb-local/<N>/data`;
  units restart cleanly after reboot (persisted startup state).

## Test cases

### A. Acknowledged-write durability (the core promise)
1. Insert N docs with **`w:majority`/acknowledged** write concern, `fsync`/journal
   as available; hard-kill the container (`docker kill -s SIGKILL`) immediately
   after the ack; restart on the same volume; **every acked doc is present and
   correct**. Zero acked-but-lost is the bar; any loss is S1.
2. Repeat with an in-flight bulk write killed mid-batch: partial writes must be
   consistent (no torn documents, indexes match data). Unacked writes may be lost
   — that's fine; acked ones may not.
3. Update-heavy workload killed mid-update: no document left half-updated or with
   an index pointing at a stale value.

### B. Crash recovery / WAL
4. **Unclean crash → recovery on next boot** completes and the container becomes
   ready; data is intact; the log shows recovery ran (this is the *expected* path
   after SIGKILL — contrast with the clean-shutdown case where recovery must NOT
   run).
5. **Clean shutdown → no recovery** (re-confirm C3 at scale: shut down with a large
   dirty buffer pool and verify the next boot does no WAL replay).
6. Repeated crash-restart cycles (10×) under continuous writes — no cumulative
   corruption; `validate` on the collections passes each cycle.

### C. Volume lifecycle
7. **Persistence across `docker rm` + recreate** on the same named volume: data,
   indexes, and the admin user survive and authenticate.
8. **Fresh anonymous volume** (no `-v`) does NOT persist across `docker rm` —
   confirm the documented behavior and that the "ready" banner warns users to
   mount `-v` for persistence.
9. **Init-data idempotency:** `--init-data`/`--init-data-path` seed once per fresh
   volume (marker-guarded); a restart does not re-run or duplicate; a *failed*
   init is not retried and does not silently mark success. A fresh volume re-seeds.
10. Move a volume written by one build to another compatible build (same or newer
    PG major) and confirm it opens (watch for the lz4 TOAST caveat if the target
    lacks lz4).

### D. Concurrency & consistency
11. Concurrent writers to the same doc/collection: no lost updates beyond what the
    write concern allows; unique-index invariants hold under contention (no
    duplicate keys slip through).
12. Transaction atomicity: a committed txn is fully present after a crash; an
    aborted or crashed-before-commit txn leaves **nothing** partially applied.
13. Index/data agreement: after all the above, every index returns exactly the docs
    a collection scan would (`explain` index scan vs `COLLSCAN` parity) — a
    divergence means index corruption.

### E. Packaged / systemd durability
14. On a packaged install, `systemctl restart documentdb-local@<N>.target` and a
    full **VM/container reboot** (systemd as PID 1) bring PG + gateway back cleanly
    with data intact and no manual intervention (reuse
    `packaging/test_packages/systemd/test-systemd-lifecycle.sh`).
15. `documentdb-local-reset` / `documentdb-setup --restore` behave as documented
    (destroy vs detach) and never corrupt a surviving major's data (cross-ref
    Track 11 multimajor).

## How to break it
- Kill at the worst moment: during `initdb`, during index build, during `$out`/
  `$merge`, during checkpoint, during the admin-user creation — each restart must
  reach a consistent state or a clean failure, never a wedged half-state.
- Fill the volume to 100% mid-write (`--storage-opt` or a small tmpfs mount) —
  writes should fail cleanly with a disk-full error, and recovery after freeing
  space should succeed with no corruption.
- Yank the volume (unmount / `docker kill` the daemon) during a checkpoint.
- Clock skew: jump the container clock backward/forward during writes (TTL
  indexes, cursor timeouts) — no data loss or premature TTL purge of fresh data.
- Corrupt a WAL segment or a heap page on the volume (offline) and boot — PG
  should refuse/repair loudly, never serve silently-wrong data.
- Two containers pointed at the **same** volume simultaneously — the second must
  fail to start (lock), not double-mount and corrupt.
- Pull the power on a bulk `$out` that rewrites a collection — the target is either
  the old or the new collection, never a torn mix.

## Evidence to capture
For each durability case: the count of acked writes vs the count present after
recovery (must match); the recovery-vs-no-recovery log lines; `validate` output;
index-vs-collscan parity; `docker inspect` exit codes; disk-full and lock-conflict
error messages.

## Out of scope / hand-offs
Raw write correctness (non-crash) → 03. Perf of the write path → 08. Upgrade data
migration → 11.

Write your report to `../reports/TRACK-07-data-integrity-durability-report.md`.
