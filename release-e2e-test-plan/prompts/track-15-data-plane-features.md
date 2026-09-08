# Track 15 — Data-plane feature matrix

**You are** a database feature tester. Track 04 owns the wire protocol and core
CRUD; Track 13 owns drivers. You own the **features layered on top** that the
release ships and that no other track touches: vector search, geospatial, text
search, collation, users/roles (RBAC), sharding, the admin/DBA command surface,
write-side pipeline stages, views/capped collections, and namespace validation.

Two of these are **package-integrity checks in disguise.** Every shipped `.deb`
and `.rpm` hard-depends on pgvector and PostGIS, but Tracks 08/09 only prove
those dependencies *resolve*. A wrong-but-installable PostGIS or pgvector
installs cleanly and then fails at query time. You are the track that catches
that — so run the geo and vector checks on the **package path**, not only the
image.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 bring-up, §6 seeds, §8 known-failure
oracle, §9 feature flags) and `REPORT-TEMPLATE.md`. **Write** to
`reports/track-15-data-plane-features.md`.

## SUT
`documentdb-local:pg17-0.116.0` for the wire-level work, **plus** a
package-installed PG17 (hand-off from Track 08 or 09) for checks 1 and 2. Report
image and package results separately — a divergence between them is itself the
finding.

## Before you file anything
Read `ENVIRONMENT-SETUP §8`. The release carries a curated known-failure baseline
covering 15k+ upstream functional tests. **A feature gap already on that baseline
is not a new finding** — record it as "known, on the baseline" and move on. Only
unlisted behavior is reportable. This rule keeps the rollup from drowning in
re-discovered known gaps.

## What to test (checklist)

1. **Vector search.** Create a vector index and query it, on the image **and** on
   a package-installed instance:
   ```
   createIndexes: { "key": { "v": "cosmosSearch" },
     "cosmosSearchOptions": { "kind": "vector-ivf", "numLists": 2,
                              "similarity": "COS", "dimensions": 3 } }
   pipeline:      [ { "$search": { "cosmosSearch": { "vector": [3.0, 4.9, 1.0],
                                                     "k": 1, "path": "v" } } } ]
   ```
   Cover all three index kinds shipped — `vector-ivf`, `vector-hnsw`,
   `vector-diskann` — plus each `similarity` value, a pre-filter
   (`cosmosSearch.filter`), and dimension-mismatch / wrong-type error handling.
   Confirm `explain()` shows the vector index in use, not a brute-force scan.
   **A vector index that builds but is never chosen, or returns wrong neighbours,
   is S2.** Vector search failing on the package path while working on the image
   points at the pgvector dependency — S1 for the package.
2. **Geospatial.** Create `2dsphere` and `2d` indexes; run `$geoNear`,
   `$geoWithin`, `$geoIntersects` over points, polygons, and GeoJSON. Confirm
   results and distances are correct and the index is used. Run the same on a
   **package** install to prove the PostGIS dependency (`postgis36_N` on RPM,
   `postgresql-N-postgis-3` on DEB — see seed PK1) is not merely resolvable but
   *functionally correct*. Failure on the package path only is S1.
3. **Text search.** Create a `text` index; run `$text` queries with
   `$search`/`$language`/`$caseSensitive`, phrase and negation syntax, and
   `textScore` projection/sort. Include the historical crash shapes: a query of
   only stop words, and an empty search string (a 0.111 crash fix — confirm it
   stays fixed). A backend crash here is **S1**.
4. **Collation.** Collation is gated by
   `documentdb.enableCollationWithNonUniqueOrderedIndexes` /
   `documentdb.enableCollation` (see §9). Exercise collation on `find`, `count`,
   `distinct`, `$group` `$min`/`$max`, and on non-unique ordered indexes with
   `$elemMatch`, `$in`/`$nin`, `$lt`/`$lte`, `$ne`, and `$not` combinations.
   Confirm a collation that is **not** supported for an index type or option is
   **rejected cleanly** rather than silently ignored — a silently-ignored
   collation returns wrong results and is S2.
5. **Users & roles (RBAC).** This is a real surface, not a maybe: exercise
   `createUser`, `updateUser`, `dropUser`, `usersInfo`, `createRole`,
   `grantRolesToUser`, `revokeRolesFromUser`, `rolesInfo`, `dropRole`. Verify a
   built-in role actually constrains: create a `readAnyDatabase` user and confirm
   it can read across DBs and **cannot** write, create users, or drop
   collections. Confirm privilege errors are clean and correctly coded. Any
   granted role that does not constrain is **S1** (authz bypass) — hand it to
   Track 05 as well.
6. **Sharding.** `enableSharding`, `shardCollection` (hashed and ranged keys),
   then CRUD, aggregation, `count`, `distinct`, unique-index behavior, and
   `$sample` **on a sharded collection** (0.114 fixed a `$sample`/TABLESAMPLE bug
   specific to sharded collections — confirm it stays fixed). Check what
   `listShards`/`getShardMap` report. If sharding is not intended to be
   user-facing in this release, confirm the commands fail **cleanly** and say so
   — a half-working `shardCollection` that corrupts routing is S1.
7. **Admin / DBA command surface.** Each of these has a dedicated in-repo test
   module, so each is expected to work: `collStats`, `dbStats`, `dataSize`,
   `validate`, `compact` (both `mode: "full"` and `mode: "standard"` — 0.114
   feature; `full` is gated by `documentdb.enableCompactVacuumFull`), `reIndex`,
   `renameCollection`, `distinct`, `explain`, `listCollections`, `listDatabases`,
   `listIndexes`, `currentOp`, `killOp`, `getLog`, `connectionStatus`, `ping`,
   `endSessions`/`killSessions`. For each: does it return a well-formed
   MongoDB-shaped response, and does it actually do what it claims? Run `compact`
   and `validate` **against a populated collection with indexes** and confirm the
   data and indexes survive — `compact` with `mode: "full"` is a `VACUUM FULL`
   and is the highest-risk item here (data loss ⇒ S1). `currentOp` + `killOp`
   must be able to see and cancel a long-running query.
8. **Write-side pipeline stages.** `$out` and `$merge` — into a new collection,
   over an existing one, into the same collection, with each `whenMatched` /
   `whenNotMatched` mode, and with a failure injected mid-pipeline. These rewrite
   user data; a silent partial write or a clobbered target is **S1**. If they are
   not supported, confirm a clean rejection.
9. **Remaining read-side stages.** `$graphLookup`, `$unionWith`,
   `$setWindowFields`, `$fill` (0.115 fixed a crash with `partitionByFields` when
   a preceding `$sort`/`$limit` migrates the window query into a subquery —
   confirm), `$densify`, `$redact`, `$replaceRoot`/`$replaceWith`, `$let` (0.115
   fixed a use-after-free with a multi-variable `$let` evaluated repeatedly inside
   `$map`/`$filter`/`$reduce` — confirm), and `$setUnion`/`$setIntersection` with
   `CodeWScope` and long `Regex` values (0.115 heap-buffer-overflow fix —
   confirm). Any backend crash is **S1** with the exact document that triggers it.
10. **Views & capped collections.** `create` with `viewOn` + `pipeline`: query the
    view, nest a view on a view, confirm writes to a view are rejected, and
    confirm `collMod` on a view behaves. `convertToCapped` / capped `create`:
    confirm the size bound is enforced and old documents roll off, or that capped
    collections are cleanly unsupported.
11. **Namespace validation.** 0.114's `enableNewNamespaceValidation` blocks
    create/drop/rename/createIndex on reserved collections in `admin` and `local`
    and completes the `config` reserved list (`changelog`, `mongos`,
    `placementHistory`, `tags`, `transactions`, `locks`, `lockpings`,
    `migrations`, `migrationCoordinators`, `rangeDeletions`,
    `reshardingOperations`, `cache.collections`, `cache.databases`). Attempt each
    reserved namespace and confirm it is refused. Also probe namespace edges:
    empty names, names containing `$`, a NUL byte, `.`, unicode, and over-long
    names — the server must reject rather than create something unusable or
    collide with an internal name. A reserved-namespace write that succeeds is S2.

## Expected results
Vector, geo, text, and collation behave identically on the image and the package
path; RBAC roles genuinely constrain; write-side stages are atomic or cleanly
unsupported; the admin surface is well-formed and non-destructive; reserved
namespaces are refused. Anything already on the §8 baseline is *not* a finding.

## Report
`REPORT-TEMPLATE.md`. Deliver a **feature × (image | package) × result** table.
For every unsupported feature, state whether the failure was *clean* or
*silent-wrong*. Cite the §8 baseline for every gap you decided not to file.
