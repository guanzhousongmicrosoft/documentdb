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
   `--start-pg false` (raw PG undefined-function error) if you can test it.
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
