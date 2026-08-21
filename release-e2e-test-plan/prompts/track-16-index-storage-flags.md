# Track 16 — Index, storage & feature-flag integrity

**You are** a storage engineer. Every other track drives the product through the
MongoDB endpoint and trusts the storage layer underneath. You do not. You go
under the gateway to the backend PostgreSQL, exercise the index access methods
and vacuum paths directly, and verify that what the index returns still matches
what the heap holds.

This track exists because of what actually changed in 0.116. The headline
bugfixes are **concurrency fixes in RUM vacuum page-pruning** — revalidating that
siblings still bracket the target after re-locking, because a concurrent
left-sibling split could otherwise drop pages out of the leaf chain — and a
cluster of **planner/index feature flags shipped enabled-by-default "pending
stabilization."** That is index-corruption-class change in the riskiest part of
the system, and no other track in this plan touches it. Track 02 proves the
*heap* survives a crash; nobody proves the *indexes* do.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 image, §7 fixed behaviors, §9 feature
flags and how to set them) and `REPORT-TEMPLATE.md`. **Write** to
`reports/track-16-index-storage-flags.md`.

## SUT
`documentdb-local:pg17-0.116.0` (repeat checks 3, 6 and 8 on `pg18-0.116.0`).
You need SQL access to the container's internal PostgreSQL — see
`ENVIRONMENT-SETUP §9`:
```bash
docker exec ddb psql -p 9712 -U documentdb -d postgres -X -c "SHOW documentdb.enable_group_by_dynamic_streaming;"
```
Confirm which database actually holds the DocumentDB catalog before assuming
`postgres`.

**Integrity oracle.** Wherever this track says "verify index integrity", it means
the same predicate answered two ways must agree:
```sql
SET enable_seqscan = off;  -- forces the index path
SET enable_seqscan = on; SET enable_indexscan = off; SET enable_bitmapscan = off;
```
Run the same query both ways and diff the row sets and counts. Add `amcheck`
(`bt_index_check`) for any btree involved. **A divergence is index corruption and
is S1**, full stop — capture the volume and the exact reproduction.

## What to test (checklist)

1. **GUC inventory and default state.** Enumerate every `documentdb.*` and
   `documentdb_rum.*` setting (`SELECT name, setting, boot_val FROM pg_settings
   WHERE name LIKE 'documentdb%'`). Cross-check each against what the CHANGELOG
   claims for this release — in particular the 0.116 flags shipped **enabled by
   default while pending stabilization** and the 0.115 flags shipped **disabled by
   default**. A flag whose real default contradicts the release notes is **S2**:
   the notes describe a product the user does not have. Record the full table as
   an artifact; it is the baseline for everything below.
2. **Flag-off fallback correctness.** For each flag the release ships **on**, run
   an identical query battery with the flag off and confirm **identical results**
   (plans may differ; results must not). At minimum:
   `documentdb.enable_group_by_dynamic_streaming`,
   `enableSortPushToAccumulatorWithPrefix`,
   `documentdb.enable_composite_reduced_correlated_bounds_planning`,
   `documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking`,
   `documentdb_rum.prune_rum_empty_pages`, `enable_min_max_skip_null_values`,
   `enableDollarSampleReservoirScan`, `enableSampleScanFixOnSharded`,
   `documentdb.enableNonBlockingUniqueIndexBuild`, and schema validation. The
   flag-off path is what users get if a default-on flag is rolled back after
   ship, so it has to be correct too. A results difference is **S1/S2** depending
   on which side is wrong — say which.
3. **RUM vacuum under concurrency (the 0.116 headline).** Build RUM-backed indexes
   on a collection, then run N concurrent writers doing insert/update/delete churn
   (enough deletion to empty leaf pages) while `VACUUM` runs against the backing
   table in a tight loop. Run the whole scenario twice, with
   `documentdb_rum.prune_rum_empty_pages` **on** and **off**. After each run,
   verify index integrity with the oracle above. Then repeat with concurrent
   `VACUUM` **and** a workload designed to force left-sibling splits (ascending
   key inserts alongside deletions) — that is the exact race the 0.116 fix
   addresses. Any lost or duplicated row through the index path is **S1**.
4. **Single-pass posting-tree vacuum.** `enable_single_pass_posting_tree_vacuum`
   and `enable_targeted_posting_tree_pruning` ship **disabled**. Turn each on and
   repeat check 3. These are opt-in, so a failure here is not a release blocker
   for the default configuration — but file it (S2/S3) and say clearly that it is
   off by default.
5. **Crash + vacuum interleaving.** `docker kill` the container while a `VACUUM`
   is mid-flight over an indexed, actively-written collection. Restart, let
   recovery finish, then verify index integrity. Track 02 covers heap durability;
   you cover the indexes. An index that survives recovery but no longer matches
   the heap is **S1** and is exactly the failure mode a user would not notice
   until wrong query results show up weeks later.
6. **`--disable-extended-rum`.** This flag is inventoried in
   `ENVIRONMENT-SETUP §2` and never exercised elsewhere. It drops the `-r`
   argument from the server start, so extended RUM is **on by default** in the
   image. Confirm: (a) the flag actually changes what is installed/loaded — the
   extension set and the index AM chosen for a new index observably differ;
   (b) the same query battery returns the same results either way; (c) a volume
   created **with** extended RUM starts cleanly when the container is later run
   **without** it, and the reverse. A volume that will not start after toggling is
   S2 (it is a one-way door for an operator); wrong results is S1.
7. **TTL indexes and background jobs.** Create TTL indexes, confirm expiry
   actually removes documents and the reclaimed index space is not leaked. Toggle
   `EnableDeadIndexEntryMarkingByTTLTask` and confirm dead-entry pruning on
   ordered TTL indexes behaves the same way for results. Then confirm the
   background worker is still alive after an extended run and after a backend
   crash (`pg_stat_activity`) — a silently-dead TTL worker means documents never
   expire and is **S2**.
8. **Background and concurrent index builds.** `createIndexes` with
   `background: true`, and the 0.114 non-blocking **unique** index build
   (`documentdb.enableNonBlockingUniqueIndexBuild`, `CREATE INDEX CONCURRENTLY`
   plus post-hoc exclusion-constraint registration and existing-row validation).
   The critical case: start a concurrent unique-index build **while duplicate keys
   are being inserted**. Exactly one of two things may happen — the build fails, or
   the duplicates are rejected. A unique index that ends up existing with
   duplicate rows behind it is **S1**. Also interrupt a background build (kill the
   session, kill the container) and confirm no `indisvalid = false` index is left
   stranded, or that it is cleaned up on restart.
9. **Composite and multikey metadata.** 0.116 rejects parallel arrays on
   metadata-backed composite indexes and fixes per-path multikey marking so an
   array ancestor marks every indexed descendant, **including fields absent from
   the document**. Build composite indexes over array-valued paths; confirm
   parallel arrays are rejected; confirm documents that omit an indexed
   descendant are still handled; and confirm index and sequential scans agree for
   every predicate shape. Then check the upgrade angle: an index **built on 0.114**
   whose metadata predates the fix — does it still return correct results on
   0.116, or does it need a rebuild nobody documented? (Coordinate with Track 14;
   a silently-wrong legacy index is **S1**.)
10. **TOAST compression.** `--toast-compression lz4|pglz|default`. Confirm the
    setting is genuinely applied (check the PG setting and the attribute storage,
    not just the absence of an error), that large documents round-trip byte-exact
    under each, and that switching a value on an existing volume is safe. The
    image writes its TOAST fragment as an include under `GATEWAY_HOME`, which is
    image-ephemeral: the entrypoint itself warns that after an image rollback the
    include line dangles and "rolling this volume back to an older image may fail
    to start." Reproduce that rollback and confirm the failure is clean and
    self-explanatory. Hand the result to Track 14 — it is a downgrade hazard.
11. **`pg_dump` / `pg_restore` round-trip.** Dump a populated DocumentDB database
    from the internal PG, restore it into a fresh instance, and confirm
    collections, **all index kinds** (RUM, composite, unique, TTL, vector, geo,
    text), validators, and data come back and queries still work *through the
    gateway*. Custom types plus custom index AMs are the classic restore
    breakage. This is also the backup path Track 14's rollback story silently
    assumes exists — if a dump cannot be restored, that story is fiction. S2, or
    S1 if the restore succeeds but returns wrong data.
12. **Sustained churn and bloat.** Run heavy insert/update/delete churn for an
    extended period with autovacuum enabled. Track index and table size over
    time. Confirm both plateau rather than growing without bound, and that query
    latency does not degrade monotonically. Unbounded index growth under normal
    churn is **S2**.

## Expected results
Real GUC defaults match the release notes; every default-on flag produces the
same results when turned off; RUM indexes stay consistent with the heap across
concurrent vacuum, forced splits, and crash recovery; unique-index builds never
admit duplicates; `--disable-extended-rum` is a safe two-way toggle; dump/restore
round-trips every index kind; churn is bounded.

## Report
`REPORT-TEMPLATE.md`. Attach the full GUC table and every integrity-check
transcript under `reports/artifacts/track-16-*`. State the exact concurrency,
duration, and row counts for each churn scenario — an integrity run without its
parameters cannot be reproduced. **Any index/heap divergence leads the report as
S1**, with the volume preserved.
