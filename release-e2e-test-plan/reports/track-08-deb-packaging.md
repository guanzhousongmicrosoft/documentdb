# Track 08 — DEB install / upgrade / remove (Ubuntu 24.04)

- **Worker:** Claude Code
- **Date:** 2026-08-21 UTC
- **SUT identity:** `documentdb-packages-0.116.0` from run 32438343434, commit `684ac162`.
  `ubuntu24.04-postgresql-17-documentdb_0.116-0_amd64.deb` and the full 11-file DEB set.
  Host: `ubuntu:24.04` container, **amd64**, PGDG apt repo added. **SHA256SUMS 22/22 OK.**
- **Result:** PASS-WITH-FINDINGS
- **Counts:** S1: 1 · S2: 0 · S3: 0 · S4: 0

## Summary

Packaging mechanics are sound: every declared dependency resolves from PGDG, the
extension installs cleanly, PG17 and PG18 co-install without file conflicts, all
eight local packages install in a single apt transaction including the meta
packages, and `documentdb-tune` writes a correct managed config block. The
extension loads at **0.116-0** and a real `insert_one` round-trip works through the
packaged extension.

**But the resulting install cannot create a single index.** `documentdb-tune` sets
`documentdb.alternate_index_handler_name = 'extended_rum'` while
`CREATE EXTENSION documentdb CASCADE` does not create `documentdb_extended_rum`, so
every `createIndexes` — including a plain single-field index — fails. That is S1 and
it is the finding that matters from this track.

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | Checksum + arch sanity | ✅ | 22/22 SHA256SUMS OK; extension/gateway `amd64`/`arm64`, meta/common/tools `all` |
| 2 | Dependency resolution | ✅ | `postgresql-17`, `-cron`, `-pgvector`, `-postgis-3`, `-rum` all resolved from PGDG; `INSTALL_EXIT=0` |
| 3 | Fresh install → working extension | ⚠️ | Extension loads at `0.116-0` **only after** the preload config; see finding |
| 4 | Meta packages | ✅ | `documentdb`, `documentdb-17`, `documentdb-18` install when the whole set is offered in one transaction (`ALL_EXIT=0`) |
| 5 | `documentdb-common` co-install PG17+PG18 | ✅ | Both `postgresql-17-documentdb` and `postgresql-18-documentdb` installed, no dpkg file conflicts |
| 6 | `documentdb-postgresql-tools` | ✅ | 7 binaries on PATH; declared `Suggests`, not a hard dep |
| 7 | File layout & ownership | ✅ | 316 files, all under `/usr/lib/postgresql/17/…` and `/usr/share/postgresql/17/extension/`; nothing stray |
| 8 | Maintainer scripts | ✅ | postinst prints useful next-step guidance; no half-configured state; `dpkg --audit` clean |
| 9 | Remove vs purge | ✅ | `apt-get remove` and `purge` both exit 0; no orphaned files observed |
| 10 | Reinstall & repair | ✅ | `--reinstall` exit 0 |
| 11 | Upgrade from previous release | ⛔ | Not tested (Track 14 not run) |
| 12 | Proxy/offline | ⛔ | Not tested |
| — | **Index creation after install** | ❌ | **S1 — see finding** |

## Findings

### [S1] After a package install, no index of any kind can be created

- **What:** `documentdb.alternate_index_handler_name` is set to `extended_rum`, but the
  `documentdb_extended_rum` extension is never created, so the access method does not
  exist and every `createIndexes` fails.
- **Finding-seed:** new
- **Repro:**
  ```bash
  # clean ubuntu:24.04 + PGDG
  apt-get install -y ./ubuntu24.04-postgresql-17-documentdb_0.116-0_amd64.deb \
                     ./ubuntu24.04-documentdb-gateway_0.116.0_amd64.deb \
                     ./ubuntu24.04-documentdb-common_0.116.0_all.deb \
                     ./ubuntu24.04-documentdb-postgresql-tools_0.116.0_all.deb
  documentdb-tune --pg-version 17 --cluster main --yes
  pg_ctlcluster 17 main restart
  psql -c "CREATE EXTENSION documentdb CASCADE;"
  psql -c "SELECT documentdb_api.create_indexes_background('testdb',
             '{\"createIndexes\":\"coll\",\"indexes\":[{\"key\":{\"n\":1},\"name\":\"n_1\"}]}');"
  ```
- **Observed:**
  ```
   documentdb.alternate_index_handler_name | extended_rum
   documentdb_extended_rum | 0.116-0 |          <- installed_version EMPTY

  errmsg: Index access method extended_rum is not available,
          check the alternate_index_handler_name setting
  ```
  `pg_am` contains `documentdb_rum` but **not** `documentdb_extended_rum`.
- **Expected:** After the documented install the database should create indexes.
- **Impact:** No unique constraints, no TTL, no `2dsphere`, no `cosmosSearch` vector
  index, no query acceleration. The packaged product is unusable for anything past a
  collection scan. The error names a GUC rather than the missing extension, so the
  fix is not discoverable. **The container image is unaffected.**
- **Workaround:** `CREATE EXTENSION documentdb_extended_rum;` — after which the same
  index succeeds (`numIndexesAfter: 2`) and `2dsphere` also succeeds. Undocumented.
- **Mitigating context:** the wizard `documentdb-setup` does run
  `CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE`
  (`/usr/bin/documentdb-setup:3240`). If that wizard is the only supported path this
  drops to a docs/error-message defect — but `documentdb-gateway-admin` explicitly
  advises *"run CREATE EXTENSION documentdb CASCADE;"*, which produces the broken state.
- **Confidence:** high · **Suggested severity:** S1

## Evidence of the good path

```
=== D. restart + verify preload ===
pg_cron, pg_documentdb_core, pg_documentdb, pg_documentdb_extended_rum

=== E. CREATE EXTENSION documentdb CASCADE ===
NOTICE:  installing required extension "documentdb_core"
NOTICE:  installing required extension "pg_cron"
NOTICE:  installing required extension "tsm_system_rows"
NOTICE:  installing required extension "vector"
NOTICE:  installing required extension "postgis"
CREATE EXTENSION
documentdb=0.116-0   documentdb_core=0.116-0   pg_cron=1.6
postgis=3.6.4        tsm_system_rows=1.0       vector=0.8.6

=== F. real round-trip ===
insert_one -> {n: 1, ok: 1.0}   (x2)
```

## Cross-track notes

- `documentdb-common` **depends on** `documentdb-gateway (>= 0.116.0)`; installing it
  from a local file without the gateway `.deb` in the same apt invocation fails with
  "held broken packages". Expected for local-file installs, not a defect — but worth a
  line in the docs.
- The DEB installs only two systemd units (`documentdb-gateway.service`,
  `documentdb-gateway-local@.service`) where the RPM installs four. See Track 09.
- Vector and geospatial verification on the package path (Track 15 checks 1–2) is
  **blocked** by the finding above.

## Evidence

`art/track08.log`, `art/track08b.log`, `art/track08c.log` in the session scratchpad.
