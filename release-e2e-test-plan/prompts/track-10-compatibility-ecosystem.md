# Track 10 — Compatibility & Ecosystem (agent prompt)

You are a compatibility-QA agent. Verify that real MongoDB drivers, shells, and
tools work against DocumentDB, and map where compatibility ends. Read
`../ENVIRONMENT-SETUP.md` and `../REPORT-TEMPLATE.md` first. Target: a running
container on 10260.

## Contract facts that predict compatibility edges (from the runtime map)
- Server advertises **serverVersion "7.0"**, **maxWireVersion 21**,
  **maxBsonObjectSize 16 MiB**, **maxWriteBatchSize 100000**,
  **logicalSessionTimeoutMinutes 30**, `saslSupportedMechs:["SCRAM-SHA-256"]`,
  `msg:"isdbgrid"` (drivers may treat it as mongos/sharded).
- **OP_COMPRESSED (2012) is NOT supported.** A driver that negotiates wire
  compression (`compressors=snappy|zstd|zlib`) may fail. **This is the #1
  compat risk — test it explicitly per driver.**
- **`startSession` is NOT supported**; drivers must use client-generated lsids
  (implicit sessions). Most modern drivers do this transparently — verify.
- **`serverStatus`, `getLastError`, `mapReduce`, `authenticate`, `getnonce`** are
  unsupported (115) even though some appear in `listCommands`. Tools/ORMs that
  call them (health pollers, legacy write-concern paths) will break.
- Only SCRAM-SHA-256 / MONGODB-OIDC auth; **PLAIN unsupported**.

## Test cases

### A. Driver matrix (the core)
Pick a spread of official drivers and, for **each**, run the same smoke: connect
(TLS + auth) → insert → find → update → delete → aggregate → index → transaction →
disconnect. Record driver name + version + result.
1. **pymongo** (Python) — the README's reference client.
2. **mongosh** — both the baked-in 8.0 and a host-installed current version.
3. **Node.js** `mongodb` driver.
4. **Go** `mongo-driver`.
5. **Java** `mongodb-driver-sync`.
6. At least one of **C#/.NET**, **Rust**, **PHP** if time permits.
For each driver test **both** with default settings and with an explicit
`compressors=` to expose the OP_COMPRESSED gap.

### B. Compression negotiation (expected breakage — classify severity)
7. For each driver, set `compressors=zstd` (and `snappy`, `zlib`) in the URI and
   see what happens: clean fallback to uncompressed, a hard error, or a hang.
   Document per driver — this determines whether users must disable compression,
   and whether the server should negotiate it away gracefully instead of erroring.

### C. Sessions & transactions across drivers
8. Implicit sessions (client-generated lsids) work for normal operations even
   though `startSession` is unsupported — confirm each driver doesn't choke.
9. Driver-native transaction API (`session.withTransaction`) works or fails
   coherently; retryable-writes behavior (drivers set `retryWrites=true` by
   default) — does the server tolerate the retry metadata?

### D. Command-line tools
10. `mongoimport` / `mongoexport` (JSON + CSV), `mongodump` / `mongorestore`
    round-trip a dataset; verify data + indexes survive the round-trip.
11. `mongostat` / `mongotop` (these poll `serverStatus`) — expect failure/limited
    output; document the impact for ops users.

### E. GUI & higher-level tools
12. **MongoDB Compass** connects, browses, runs a query and an aggregation, views
    indexes, and reads server info. Note anything it can't do (its health/stats
    panels may hit unsupported commands).
13. If available: **Studio 3T** / another popular GUI — connect + basic ops.
14. **ORM/ODM:** at least one — Mongoose (Node), Motor/Beanie (Python), or
    spring-data-mongodb (Java): define a model, CRUD, a populate/`$lookup`, and a
    migration/index sync. ORMs exercise unusual command sequences and are good
    breakers.

### F. FerretDB (documented integration)
15. The README/AGENTS note FerretDB uses DocumentDB as a backend engine. If
    feasible, stand up FerretDB pointed at this build and run its smoke — a broken
    integration here is notable given it's an advertised use case. If not feasible,
    mark it a coverage gap.

## How to break it
- Connect with a **very old** driver (low `maxWireVersion`) and a **very new** one
  — does version negotiation via `minWireVersion:0`/`maxWireVersion:21` work at
  both ends?
- Turn on every default a modern driver sets (`retryWrites`, `retryReads`,
  `compressors`, `readPreference`, `w:majority`, `readConcern`) and see which the
  server rejects vs ignores vs honors.
- A driver that auto-calls `hello` repeatedly (monitoring) — confirm the
  `ClientMetadataCannotBeMutated` rule doesn't break normal driver heartbeats.
- Tools that assume a replica set / sharded topology (because of `isdbgrid`/
  `msg`): do they try commands that fail? Does `isMaster` topology confuse them
  into a bad mode?
- Unicode/emoji/large-key documents through each tool's serializer.

## Evidence to capture
A compatibility matrix table: driver/tool + version + {connect, CRUD, aggregate,
index, txn, compression} each PASS/FAIL/PARTIAL, with the failing command + server
code (e.g. 115) for each gap. Save the smoke scripts under `../reports/artifacts/`.

## Out of scope / hand-offs
Server-side correctness of results → 03. Auth internals → 04. Perf under many
drivers → 08. You map the ecosystem edge and classify each gap's severity (a broken
mainstream driver default = S2; a niche tool = S3/S4).

Write your report to `../reports/TRACK-10-compatibility-ecosystem-report.md`.
