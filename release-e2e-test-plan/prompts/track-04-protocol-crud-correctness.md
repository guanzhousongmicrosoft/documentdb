# Track 04 — Protocol & CRUD correctness

**You are** a MongoDB-API correctness tester. You drive the gateway with real
drivers and `mongosh`, exercise CRUD / aggregation / indexing / transactions, and
look for wire-protocol gaps, wrong results, and silent tolerations of backend
errors.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 bring-up, §6 C6/C7, §7 #650) and
`REPORT-TEMPLATE.md`. **Write** to `reports/track-04-protocol-crud-correctness.md`.

## SUT
`documentdb-local:pg17-0.116.0` (repeat the smoke + a representative CRUD slice on
pg15/16/18 to catch PG-version drift — coordinate scope with Track 13). Connect
per `ENVIRONMENT-SETUP §2` (`--tls --tlsAllowInvalidCertificates`,
`--authenticationMechanism SCRAM-SHA-256`).

## PHASE-A SMOKE (this is the Phase-A gate for the whole plan)
Do this first and report the result immediately, before the rest of the track:
1. Pull `pg17-0.116.0`, start a container with a generated password, wait for
   `=== DocumentDB is ready ===`.
2. `insertOne` + `countDocuments` + `find` round-trip over `mongosh`.
3. Report PASS/FAIL. **If FAIL, this is an S1 and the coordinator halts the fan-out.**

## PHASE-A2 — the pinned functional suite (do this before the checklist)

This is the highest-value protocol result the plan can produce, and it is
already built: `documentdb-local/functional-tests/` runs the pinned upstream
wire-protocol suite (**~50k tests**) under a known-failures xfail model. Run it
against the **published** image — not a locally built one:

```bash
documentdb-local/functional-tests/scripts/run-functional-tests.sh \
  --use-existing-documentdb-image ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.116.0 \
  --engine-name oss --results-dir ./ft-results
```

Take the baseline lists **from the release tag** (`ENVIRONMENT-SETUP §8`), not
from `main` — they were refreshed after the tag. Report the **diff**, which is
the actual deliverable:

- **Residual `failed`/`error`** (not on the failing list) — a regression. S1/S2.
- **`XPASS(strict)`** — a listed known-failure that now passes. Not a defect, but
  the baseline is stale and the gate will fail; report the list.
- **Skipped engine-crashers** — confirm the 6 entries in `ci_crash_tests.txt` are
  still skipped and hand them to Track 07 as a known crash surface.

If the suite cannot be run (no runner, no network, suite image unavailable), say
so explicitly and mark it ⛔ — do not silently substitute the hand-written
checklist for 50k tests.

**Everything below is the supplement, not the substitute.** It targets the
0.116-specific changes and driver behavior the suite does not cover. Before
filing any gap found by hand, grep the failing list: if it is listed, it is
known — write "known, on the baseline" and move on.

## What to test (checklist)

1. **Handshake / discovery.** Capture the connect sequence a driver issues
   (`hello`/`isMaster`, `buildInfo`, `getParameter`, `ping`). Confirm each returns
   a well-formed response. Confirm `hello` advertises sane `maxWireVersion`,
   `maxBsonObjectSize`, `maxMessageSizeBytes`, `maxWriteBatchSize`.
2. **`getParameter` backend-contract — #650 (finding-seed C7).** On connect,
   `mongosh` probes `getParameter`. Confirm the gateway's response does **not** ride
   on a disallowed backend SQLSTATE (the release ships a `backend_contract.py`
   deny-list gate for exactly this). Scan container logs during a normal session
   for backend-contract errors; any disallowed SQLSTATE on the discovery path is
   S2 (it is the class of bug #650 was about). Note the documented difference under
   `--start-pg false` (raw PG undefined-function error) if you can test it. The
   deny-list itself and its unit tests live in
   `documentdb-local/scripts/documentdb_local_tests/backend_contract.py`; the
   sibling `catalog_contract.py` covers the catalog contract — run both against
   the published image rather than re-deriving them.
3. **CRUD matrix.** For a representative collection: `insertOne`/`insertMany`,
   `find` with operators (`$eq/$gt/$in/$regex/$exists/$elemMatch`),
   `updateOne/Many` (`$set/$inc/$push/$pull/$addToSet`), `replaceOne`, upserts,
   `deleteOne/Many`, `findAndModify`, bulk writes (ordered + unordered, with a
   deliberate mid-batch failure to check partial-failure semantics). Verify results
   and counts exactly. Wrong result or wrong count = S2.
4. **BSON type fidelity.** Round-trip every BSON type: double, string, object,
   array, binary (all subtypes incl. UUID), ObjectId, bool, date, null, regex,
   int32, int64, decimal128, timestamp, min/max key, long strings, deeply nested
   docs, large arrays. Confirm no silent coercion/loss (esp. decimal128, int64
   precision, binary subtypes, dates pre-1970 and far-future).
5. **Aggregation pipeline.** `$match/$project/$group/$sort/$limit/$skip/$unwind/
   $lookup/$facet/$addFields/$count/$sample/$bucket`. Include the 0.116 changelog
   items: `$sample` size coercion/validation, `$sortGroup` suffix-sort-key
   pushdown, sorted `GroupAggregate` streaming for `$group`. Verify correctness and
   that `$sample` reports the renamed EXPLAIN metric `Sample Heap Fetches` (was
   `Sample Heap Skips`).
6. **Indexes.** Create single-field, compound, multikey, text, `2dsphere` (if
   supported), TTL, partial, and unique indexes. Confirm `createIndex`,
   `listIndexes`, `dropIndex`. Verify **unique** enforcement (duplicate insert
   rejected) and TTL expiry actually removes docs. Check the 0.116 items:
   `$jsonSchema` `enum`/`oneOf` keywords; parallel-array rejection on
   metadata-backed composite indexes; per-path multikey metadata correctness.
   Verify `explain()` shows an index scan where one should be used.
7. **`$jsonSchema` validation.** Create a collection with a validator using `enum`
   and `oneOf` (new in 0.116) at both top level and per-property. Confirm
   conforming docs insert and violating docs are rejected with a useful error.
8. **Wire compression (finding-seed C6).** Connect a driver with
   `compressors=snappy,zstd,zlib` (e.g. pymongo `MongoClient(..., compressors=...)`).
   Determine: does the gateway negotiate `OP_COMPRESSED`, silently fall back to
   uncompressed, or **fail the connection**? A hard failure when a common driver
   option is set is S2; a silent ignore is at least S4/doc. Capture the negotiated
   compressor (driver debug / packet capture).
9. **Cursors & batching.** Large result sets across multiple `getMore` batches;
   `batchSize`; cursor timeout; `killCursors`. Confirm no lost/duplicated docs
   across batch boundaries.
10. **Transactions & sessions.** If multi-document transactions are advertised,
    test commit/abort, write conflict, and read-your-writes within a session. If
    **not** supported, confirm the driver gets a clear "not supported" error rather
    than silent wrong behavior.
11. **Error surface.** Duplicate key, invalid BSON, unknown operator, oversized
    document (> max BSON), write to a nonexistent DB/collection. Confirm error
    codes/`codeName` are MongoDB-compatible enough for drivers to branch on.
12. **Drivers, not just mongosh.** Repeat a CRUD slice with **pymongo** and the
    **Node `mongodb`** driver (connection string
    `mongodb://user:pw@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256`).
    Driver-specific breakage that `mongosh` hides is common — this is where it shows.

## Expected results
CRUD/aggregation/index results match MongoDB semantics for supported features;
unsupported features fail cleanly, not silently wrong; no disallowed backend
SQLSTATE on discovery; C6 compression behavior characterized definitively.

## Report
`REPORT-TEMPLATE.md`. Drive verdicts for C6, C7. For every "not supported"
outcome, state whether the failure was *clean* (good) or *silent-wrong* (bug).
Keep a machine-checkable count for each CRUD assertion.
