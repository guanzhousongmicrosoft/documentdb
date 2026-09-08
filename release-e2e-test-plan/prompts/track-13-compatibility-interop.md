# Track 13 — Compatibility & interoperability

**You are** an interoperability tester. Real users connect with a zoo of drivers,
tools, ORMs, and connection-string options across four PostgreSQL majors. You find
where DocumentDB's MongoDB-compatibility layer diverges enough to break a real
client.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 image, §5 matrix, §6 C6) and
`REPORT-TEMPLATE.md`. **Write** to `reports/track-13-compatibility-interop.md`.

## SUT
`documentdb-local` images `pg15-0.116.0`, `pg16-0.116.0`, `pg17-0.116.0`,
`pg18-0.116.0`. Connect per `ENVIRONMENT-SETUP §2`.

## What to test (checklist)

1. **Driver matrix.** Exercise a common CRUD + aggregation slice with, at minimum:
   - `mongosh`,
   - **pymongo** (Python),
   - **Node** `mongodb`,
   - one of **Go** `mongo-driver` / **Java** / **C#** if available.
   For each: connect (with TLS + SCRAM), insert, query, aggregate, index, and read
   `hello`/`buildInfo`. Record driver **versions**. A driver that can't connect or
   silently gets wrong results is S2.
2. **Connection-string options.** Systematically vary the URI: `tls=true/false`,
   `tlsAllowInvalidCertificates`, `authMechanism=SCRAM-SHA-256`, `authSource`,
   `retryWrites=true/false`, `w=majority`/`w=1`, `readPreference=…`,
   `directConnection=true`, `appName`, `connectTimeoutMS`, and **`compressors=`**
   (finding-seed C6 — does the gateway negotiate `OP_COMPRESSED` or break/ignore?).
   Note every option the server mishandles.
3. **`retryWrites` / `w` / read concern.** Drivers default `retryWrites=true` and
   `w=majority`. Confirm the server accepts (or cleanly rejects) these so default
   driver configs work out of the box. A default-config driver that fails is S2.
4. **Server discovery / topology.** Confirm the server presents a coherent topology
   to drivers (standalone vs replica-set expectations). If drivers expect a
   `setName` or replica-set fields for certain features (transactions, change
   streams), confirm the server's advertised topology doesn't mislead them into a
   broken code path.
5. **GUI / tool clients.** Connect with **MongoDB Compass** and/or **mongodump/
   mongorestore/mongoexport/mongoimport** from the MongoDB Database Tools. Confirm:
   Compass can browse/query; `mongodump` + `mongorestore` round-trips a database
   with fidelity; `mongoexport`/`mongoimport` handle JSON/CSV. Tooling breakage is a
   very visible S2/S3.
6. **PG-version parity (15/16/17/18).** Run the same core slice against all four
   image majors. Flag any behavior that differs by PG major (a feature that works on
   17 but not 18, different error text, different plan). Divergence across majors we
   ship is S2/S3. Note that packages ship only 17/18 — 15/16 are image-only.
7. **BSON/type edge interop.** Cross-driver: write a decimal128/UUID-binary/date
   from one driver, read it from another; confirm identical values. Type drift
   between drivers is S2.
8. **Feature-gap honesty.** For MongoDB features DocumentDB doesn't implement
   (change streams, GridFS, certain aggregation stages, server-side JS, map-reduce,
   multi-doc transactions if unsupported), confirm the server returns a **clean
   "not supported"** to the driver rather than a confusing error or wrong result.
   Build the "supported vs not" table a user would want.
9. **Wire-version / min-driver.** Determine the minimum driver/wire version that
   works, and whether very new or very old drivers are rejected cleanly. Document
   the supported driver-version floor.

10. **Build the feature table from the baseline, not from guesswork.** The
    supported-vs-not table in your report must be reconciled against the
    known-failure baseline (`ENVIRONMENT-SETUP §8`): 15,422 upstream functional
    tests are already listed as expected-failures for this gateway, and that list
    is the authoritative statement of what MongoDB compatibility does not extend
    to. Anything you observe as "not supported" that is **already listed** is
    known — cite it. Anything **not** listed is a real finding. Deep feature
    coverage (vector, geo, text, collation, RBAC, sharding, admin commands) is
    Track 15's; stay on driver and tooling behavior here.

## Expected results
Common drivers with default configs connect and work; tooling round-trips; behavior
is consistent across PG majors and across drivers; unsupported features fail
cleanly. C6 compression behavior characterized from the driver matrix side.

## Report
`REPORT-TEMPLATE.md`. Deliver two tables: (a) driver/tool × result, (b)
supported-vs-not MongoDB features. Record every driver/tool **version**. Corroborate
C6. Note PG-major divergences explicitly.
