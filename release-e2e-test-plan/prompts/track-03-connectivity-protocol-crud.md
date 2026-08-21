# Track 03 — Connectivity, Wire Protocol & CRUD/Aggregation (agent prompt)

You are a functional-QA agent. Verify the gateway speaks the MongoDB wire
protocol correctly: connect, CRUD, aggregation, indexes, cursors, transactions,
and that command **dispatch and error codes** match the contract. Read
`../ENVIRONMENT-SETUP.md` and `../REPORT-TEMPLATE.md` first. Assumes a live SUT
from Phase 1 (container is easiest).

## What to stand up
A running container on 10260 (see ENVIRONMENT-SETUP §2). Clients: the baked-in
`mongosh`, plus host `pymongo` and at least one other official driver
(Node/Go/Java/C#) for the compat cross-check (deep driver matrix is Track 10).
**Run the repo's own protocol suites first** — they are the executable spec:
- Rust integration tests need a live gateway on 10260:
  `pg_documentdb_gw/documentdb_tests/tests/` — `command_tests.rs`,
  `cursor_tests.rs`, `transaction_tests.rs`, `sessions_tests.rs`,
  `unsupported_commands_tests.rs`, `error_tests.rs`, `write_errors_tests.rs`,
  `response_length_tests.rs`. Run: `cd pg_documentdb_gw && cargo make test`.
- The large end-to-end wire suite: `documentdb-local/functional-tests/` under the
  xfail model — `./documentdb-local/functional-tests/scripts/run-functional-tests.sh
  gate` (or `smoke`). Report any new `failed`/`error` or `XPASS(strict)` — those
  are the real signals.

## Contract facts to assert (from the runtime map — do not re-derive)
- **hello/isMaster** advertises: `maxBsonObjectSize` **16 MiB (16777216)**,
  `maxMessageSizeBytes` **48000000**, `maxWriteBatchSize` (default 100000),
  `logicalSessionTimeoutMinutes` **30**, `maxWireVersion` **21** (serverVersion
  "7.0"), `minWireVersion` 0, `saslSupportedMechs: ["SCRAM-SHA-256"]`,
  `msg:"isdbgrid"`, `isWritablePrimary:true`. Sending `client` metadata **twice**
  on one connection → `ClientMetadataCannotBeMutated`.
- **buildInfo** returns `version` "7.0.0", `bits:64`, no `gitVersion`.
- **Wire opcodes accepted:** only **OP_MSG (2013), OP_QUERY (2004), OP_INSERT
  (2002)**. **OP_COMPRESSED (2012) is NOT supported** → `InternalError`
  "Unimplemented: 2012". (Implication: a driver negotiating wire compression
  (`compressors=snappy,zstd,zlib`) may break — test it, this is a real compat
  edge, see Track 10.)
- **Two distinct unknown-command failures** — assert BOTH:
  - Unrecognized name (e.g. `atlasVersion`) → **code 59 `CommandNotFound`**,
    "Command '…' not found."
  - Recognized but unimplemented (169-name list; e.g. `serverStatus`,
    `getLastError`, `mapReduce`) → **code 115 `CommandNotSupported`**,
    "Command '…' not supported."
- **`listCommands` advertises 69 commands** but that set diverges from what the
  dispatcher actually handles (it lists `authenticate`, `getLastError`,
  `serverStatus`, `getnonce`, `startSession` — all of which the dispatcher
  rejects). **Assert this divergence** — a client trusting `listCommands` will hit
  a wall.
- **Error wire shape:** `{ ok: 0.0, code: <int>, codeName: "<Name>", errmsg: "…" }`.

## Test cases

### A. Connect & handshake
1. Connect with mongosh + pymongo using the ground-truth URI; `db.hello()` returns
   the advertised fields above with the exact numeric limits.
2. `ping`, `buildInfo`, `whatsmyuri`, `hostInfo`, `getLog`, `connectionStatus`,
   `listDatabases`, `listCollections` all succeed post-auth.
3. `client` metadata sent twice → `ClientMetadataCannotBeMutated`.

### B. CRUD (correctness, not just "ok:1")
4. `insertOne`/`insertMany` (ordered + unordered); read back with `find`,
   `findOne`, projection, sort, skip, limit; `count`, `distinct`.
5. `updateOne`/`updateMany`/`replaceOne` with operators (`$set`,`$inc`,`$push`,
   `$pull`,`$addToSet`,`$rename`), `upsert:true`, arrayFilters; verify results and
   `matchedCount`/`modifiedCount`/`upsertedId`.
6. `findAndModify` (return new/old, upsert, remove).
7. `deleteOne`/`deleteMany`; `bulkWrite` mixed ops (ordered stops on error,
   unordered continues) — verify `writeErrors` shape and indexes.
8. **Duplicate key** on a unique index → **code 11000 `DuplicateKey`**.
9. BSON type fidelity round-trip: ObjectId, Date, Decimal128, Binary/UUID, Long,
   Int32, Double, arrays, nested docs, null, regex, `$numberDecimal` edge values.

### C. Aggregation (41 stages implemented)
10. Core pipeline: `$match`,`$project`,`$group`,`$sort`,`$limit`,`$skip`,
    `$unwind`,`$addFields`/`$set`,`$unset`,`$count`,`$sortByCount`.
11. Joins/reshaping: `$lookup` (incl. nested), `$graphLookup`, `$facet`,
    `$bucket`,`$bucketAuto`,`$replaceRoot`/`$replaceWith`,`$unionWith`.
12. Output stages: `$out`, `$merge` (verify they write and honor collision modes).
13. Windowing/misc: `$setWindowFields`, `$densify`, `$fill`, `$sample`, `$redact`.
14. Search/vector (feature surface): `$search`, `$searchMeta`, `$vectorSearch`,
    `$geoNear` — at minimum confirm they are recognized and behave/erroring
    coherently (deep correctness may exceed this pass — note gaps).
15. `explain` on find + aggregate returns a plan.

### D. Indexes
16. `createIndexes` (single, compound, unique, partial, TTL, text, 2dsphere,
    wildcard, vector), `listIndexes`, `dropIndexes`, `reIndex`. Verify a query
    uses the index via `explain`. `createSearchIndexes` recognized.
17. `collMod` (e.g. change TTL/validator), `renameCollection`, `compact`
    (`mode:standard` non-blocking vs `full`), `collStats`, `dbStats`, `validate`.

### E. Cursors
18. Large result set: `find` batch → `getMore` → exhaust; `killCursors` mid-stream
    → subsequent `getMore` → **code 43 `CursorNotFound`**. Idle cursor times out
    (default 60s; stateless 600s) — verify a timed-out cursor id is not found.
19. `aggregate` with a cursor; tailable behavior if `enableChangeStreams` (default
    off — expect change streams unsupported unless enabled).

### F. Transactions
20. Multi-statement txn via `lsid`+`txnNumber`+`startTransaction`; `commit` /
    `abort` / `prepare`. A txn command without a started txn → **code 251
    `NoSuchTransaction`**.
21. **DDL blocked inside a transaction** (assert it errors, not silently runs):
    `reIndex`, `createIndexes`, `dropIndexes`, `renameCollection`,
    `listCollections`, `drop`, `currentOp`, `killOp`, `moveCollection`.
22. Auto-abort on `WriteConflict` (112) and on any `find`/`aggregate` failure
    inside the txn. Transaction timeout default **30s** — an idle txn past that is
    aborted.
23. **`startSession` is NOT supported** — drivers must use client-generated lsids.
    Confirm the failure mode and that normal driver usage still works (drivers
    generate lsids client-side).

## How to break it
- Send **OP_COMPRESSED** (force a driver with `compressors=zstd`) and confirm the
  documented failure — then judge severity for real drivers (S2/S3 compat).
- Oversized document: exactly 16 MiB, 16 MiB+1 — expect a clean size error, not a
  crash or truncation (hand memory-DoS depth to Track 06).
- Deeply nested BSON (hundreds of levels), huge arrays, 100k-op `bulkWrite`
  (batch limit is 100000) — expect clean limits.
- Malformed BSON / truncated wire message / wrong `messageLength` — the gateway
  must reject without crashing the backend or leaking the connection.
- `getMore` with a fabricated cursor id; `killCursors` on someone else's cursor.
- A command recognized-but-unimplemented under load — confirm it returns 115 every
  time and doesn't wedge the connection.
- Send commands trusting `listCommands` (e.g. `serverStatus`) and document the
  divergence impact.
- Numeric edge values: `$numberDecimal` NaN/Infinity, Int32 overflow into Long,
  Date beyond range.

## Evidence to capture
mongosh/pymongo transcripts with the raw command replies (codes + codeNames); the
`cargo make test` and functional-tests `gate` summaries; explain outputs; the
exact error documents for each negative case.

## Out of scope / hand-offs
Auth mechanics → 04. TLS → 05. Resource-exhaustion depth & injection → 06.
Durability of writes → 07. Driver-version matrix → 10. Metrics → 12.

Write your report to `../reports/TRACK-03-connectivity-protocol-crud-report.md`.
