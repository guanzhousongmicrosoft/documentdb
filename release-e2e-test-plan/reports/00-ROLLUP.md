# 00 — Release E2E Rollup (v0.116-0, rebuild `684ac162`)

**Coordinator:** Claude Code (single operator, amd64 only) · **Compiled:** 2026-08-21 ·
**Status:** COMPLETE for the tracks listed; several tracks not run (see *Coverage actually achieved*)

---

## Release recommendation

> **GO / NO-GO / GO-WITH-CAVEATS:** **NO-GO** as currently packaged and documented.
>
> The container image is in good shape: it passes the full 10,481-test PR-gate
> allowlist against the published artifact, its signature and provenance verify
> cleanly, and both hardening regressions (#61, #43/#62) hold. The **packages** are
> the problem. Two independent defects each stop a user who follows the documented
> path: the RHEL RPM will not install at all on a clean Rocky 9 with the documented
> repositories, and on **both** DEB and RPM the `documentdb-tune` install path
> produces a database in which **no index of any kind can be created**. Separately,
> a container started without `--password` — which the help text says is REQUIRED —
> comes up with a live, hardcoded admin credential.

**Decision rule:** any open **S1** ⇒ NO-GO. F-01 and F-02 are S1.

---

## SUT under test (pinned)

- **Both runs built from the same commit** `684ac1626249f0b394cfb5a1391c85a158876d36`,
  which the `v0.116-0` tag now points at (annotated tag `b1107382`). This is a
  **rebuild**, newer than the `66e9e118` the plan was written against; the delta is
  **RPM packaging only** (`documentdb.spec`, `packaging-entrypoint-rpm.sh`,
  `e2e-rhel-scenarios.sh`, `test-install-entrypoint-rpm.sh`).
- **Images** — run [32438357061](https://github.com/documentdb/documentdb/actions/runs/32438357061):
  `ghcr.io/documentdb/documentdb/documentdb-local`
  - `pg17-0.116.0` manifest list `sha256:822903975b2693eb0742e86f269a5aaa132697aadaa08b4aa4cd6d35a37b19ea`
    (amd64 child `sha256:16d4d8acdbeb…`); `latest` resolves to the **same** digests.
  - amd64 children: `pg18` `b7b1ab496e68`, `pg16` `3b40aa595c04`, `pg15` `5d15cd596c8a`.
- **Packages** — run [32438343434](https://github.com/documentdb/documentdb/actions/runs/32438343434),
  artifact `documentdb-packages-0.116.0`, **SHA256SUMS 22/22 OK**, `manifest.txt`
  category counts all match expected.
- **Host:** Windows 11 + Docker 29.6.2, linux/amd64, 32 CPU / 67 GB.
- **Provenance seed P1 — NOT REPRODUCED (resolved).** `org.opencontainers.image.revision`
  = `684ac162…` = the build commit = the tag commit. The drift the plan documented is gone.

---

## Consolidated findings

| ID | Sev | Title | Tracks | Seed | Workaround |
|----|-----|-------|--------|------|-----------|
| F-01 | **S1** | Package install leaves a database where **no index can be created** (`extended_rum` AM missing) — DEB **and** RPM | T08, T09, T15 | new | `CREATE EXTENSION documentdb_extended_rum;` (undocumented) |
| F-02 | **S1** | Container started with no `--password` comes up ready with a live hardcoded admin credential `Admin100` | T03, T05 | C3 | always pass `--password` |
| F-03 | **S2** | RPM will not install on clean Rocky 9 with the documented repos — needs **CRB** for `libqhull_r.so.7` | T09 | PK1 (adjacent) | `dnf config-manager --set-enabled crb` |
| F-04 | S3 | Undocumented `PGOPTIONS` env var reaches the backend server argv and reproduces `--allow-external-connections` | T03, T07 | C9 | — |
| F-05 | S3 | `TLS_MODE=disabled` does not disable TLS; still accepts TLS **and** plaintext | T06 | C8 | use `requireTLS` |
| F-06 | S3 | Default `TLS_MODE=allowTLS` accepts plaintext auth — credentials can travel cleartext by default | T06 | new | set `requireTLS` |
| F-07 | S3 | In-container passwordless root: `documentdb` is in group `sudo` with `NOPASSWD: ALL` | T07 | S-esc | — |
| F-08 | S3 | No `HEALTHCHECK` and no `EXPOSE` in the image | T01 | C1, C2 | poll the ready banner |
| F-09 | S3 | The release's **own** local functional-gate runner cannot run: the shipped allowlist contains a `no_parallel` test and the plugin hard-errors | T04 | new | use the CI sharded path |
| F-10 | S4 | RPM ships appliance units (`documentdb-local@.target`, `documentdb-postgresql@.service`) that the DEB does not | T09 | new | — |
| F-11 | S4 | Gateway logs a normal client disconnect at **ERROR** level on connect | T04 | new | — |

### F-01 — no index can be created after a package install (S1)

Reproduced identically on **Ubuntu 24.04 / PG17 / amd64** and **Rocky 9 / PG17 / x86_64**.
After `documentdb-tune` + `CREATE EXTENSION documentdb CASCADE`:

```
documentdb.alternate_index_handler_name = extended_rum
documentdb_extended_rum | 0.116-0 | <installed_version EMPTY>
```
```sql
SELECT documentdb_api.create_indexes_background('testdb',
  '{"createIndexes":"coll","indexes":[{"key":{"n":1},"name":"n_1"}]}');
-- errmsg: Index access method extended_rum is not available,
--         check the alternate_index_handler_name setting
```

`documentdb-tune` writes `documentdb.alternate_index_handler_name = 'extended_rum'`
and `documentdb.rum_library_load_option = 'require_documentdb_extended_rum'`
(`/usr/bin/documentdb-tune:184-185`) but never creates the extension those settings
require. A **plain single-field index** fails, so this is not a vector/geo edge case —
it is every index: unique constraints, TTL, `2dsphere`, `cosmosSearch`, and all query
acceleration. `CREATE EXTENSION documentdb_extended_rum;` fixes it immediately (both
AMs appear and the same index returns `numIndexesAfter: 2`).

**Why this is not simply user error:** the blessed wizard `documentdb-setup` *does*
run `CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE`
(`/usr/bin/documentdb-setup:3240`), so the wizard path is fine. But
`documentdb-gateway-admin` tells the operator, verbatim, *"DocumentDB extension: NOT
loaded (run CREATE EXTENSION documentdb CASCADE;)"* — advice that lands them in
exactly this broken state, and the resulting error names a GUC rather than the
missing extension. **The container image is unaffected** (it ships
`documentdb_extended_rum installed=0.116-0` and both AMs); this is package-path only.

### F-02 — live default credential when `--password` is omitted (S1)

`--help` states `--password … REQUIRED.` Started with `--username docdb_admin`, no
`--password` and no `PASSWORD` env, the container **reaches the ready banner** and:

```
user=docdb_admin pw=Admin100     -> AUTH_OK 1
user=docdb_admin pw=<empty>      -> MongoServerError: Invalid key
```

The gateway binds `0.0.0.0:10260`, so publishing the port exposes an admin account
whose password is a constant in the shipped entrypoint. Either the documented
REQUIRED contract should be enforced (refuse to start), or the default must go.

---

## Severity totals

| | S1 | S2 | S3 | S4 |
|--|:--:|:--:|:--:|:--:|
| Count | 2 | 1 | 6 | 2 |

---

## Finding-seed disposition

| Seed | Owner | Verdict | Evidence |
|------|-------|---------|----------|
| P1 | T01 | **NOT-REPRODUCED (fixed)** | `revision=684ac162` = build commit = tag commit |
| C1 | T01/T02 | **CONFIRMED** | `Healthcheck` absent from image config |
| C2 | T01/T03 | **CONFIRMED** | `ExposedPorts` absent from image config |
| C3 | T03/T05 | **CONFIRMED — S1** | starts ready; `Admin100` authenticates (F-02) |
| C4 | T03/T12 | NOT-TESTED | `--log-level` effect not measured |
| C5 | T03/T12 | NOT-TESTED | no OTLP collector stood up |
| C6 | T04/T13 | NOT-TESTED | driver `compressors=` not exercised |
| C7 | T04 | **NOT-REPRODUCED** | 10,481-test gate incl. discovery passed; no backend-contract error observed |
| C8 | T06/T12 | **CONFIRMED** | `disabled` still accepts TLS **and** plaintext (F-05) |
| S-esc | T07 | **CONFIRMED** | `sudo -n id` → `uid=0(root)`; `/etc/sudoers.d/no-pass-ask` (F-07) |
| PK1 | T09 | **NOT-REPRODUCED** | `postgis36_17` resolves correctly (3.6.3); the RPM blocker is `libqhull_r` — see F-03 |
| PK2 | T10/T12 | NOT-TESTED | needs a systemd host |
| U1 | T12 | **CONFIRMED (static)** | `--help` says "Azure Application Insights"; telemetry is OTLP |
| C9 | T03/T07 | **CONFIRMED** | `PGOPTIONS=-e` ⇒ `listen_addresses=*` + `0.0.0.0/0 scram-sha-256` hba (F-04) |
| C10 | T16 | NOT-TESTED | `--disable-extended-rum` not exercised |
| FG1 | T16 | NOT-TESTED | GUC default inventory not taken |

---

## Fixed-in-0.116 regression checks

| Item | Track | Still fixed? | Evidence |
|------|-------|--------------|----------|
| #43/#62 concurrent-container lock | T02 | **YES** | B exits 1 naming the conflict; A stays `Running=true` and still serves (`docs=2`) |
| #61 bare-positional spin | T03 | **YES** | `exit=1`, **0.00% CPU**, 13 s, stderr `Unexpected argument junk` |
| cosign legacy `.sig` | T01 | **YES** | `sha256-8229…19ea.sig` present |
| #650 backend-contract on getParameter | T04 | **YES (indirect)** | full allowlist gate passed, discovery path included |
| RUM vacuum page-pruning race | T16 | **NOT TESTED** | — |

---

## Known-failure baseline — **the plan was wrong here**

`ENVIRONMENT-SETUP.md §8` described a known-failures xfail model with 15,422
failing / 1,898 flaky / 6 crash entries. **Those files do not exist at the release
commit.** At `684ac162` the config directory holds only `allowlist.yml` and
`image.yml`; the xfail lists are a downstream-fork construct on `main`. §8 has been
corrected in this bundle.

What the release actually ships is an **allowlist gate**:

| Item | Value |
|------|-------|
| Model | `allowlist.yml` schema v2 — every listed test **must pass** |
| Allowlisted tests | **10,481** |
| Suite image (pinned) | `ghcr.io/documentdb/functional-tests@sha256:79ed3d43…` (`source_sha df2623cd`) |
| Engine-crashing files excluded from the allowlist | `setUnion_core`, `setUnion_type_dedup`, `stages_window`, `planCacheStats_type_errors` |
| **Result against the published image** | **10,481 passed / 0 failed / 0 skipped** |

---

## Coverage actually achieved

**amd64 only, by instruction.** No arm64 was tested — every arm64 claim in this
release is **unverified here**, though both arches are present in every manifest list.

| Track | Status |
|-------|--------|
| 01 Image supply chain | **Run** (except CVE scan, SBOM, license/NOTICE, egress — tooling absent) |
| 02 Lifecycle & durability | **Partial** — #43/#62 lock only; no crash/WAL, disk-full, restart-policy |
| 03 Config & entrypoint | **Partial** — #61, C3, C9 only; no port/boolean fuzzing, no C4/C5 |
| 04 Protocol & CRUD | **Run** — smoke + full 10,481 allowlist gate |
| 05 Auth | **Partial** — C3 default-credential path only |
| 06 TLS & transport | **Partial** — the three TLS modes; no cert quality, ciphers, custom cert |
| 07 Adversarial security | **Partial** — S-esc and C9 only |
| 08 DEB packaging | **Run** (amd64, PG17 + PG18) |
| 09 RPM packaging | **Run** (x86_64, PG17 + PG18); SELinux and scriptlet lifecycle not covered |
| 10 Packaged gateway | **Not run** — needs a systemd host |
| 11 Performance & load | **Not run** |
| 12 UX & docs | **Partial (static)** — U1 confirmed from `--help` |
| 13 Compatibility | **Not run** |
| 14 Upgrade & migration | **Not run** |
| 15 Data-plane features | **Partial** — vector/geo attempted on the package path, blocked by F-01 |
| 16 Index/storage/flags | **Not run** |

Environment limits worth recording: the DEB and RPM hosts were plain containers, so
every **systemd**-dependent path (`postgresql-17-setup initdb`, service lifecycle,
`documentdb-setup`, sandbox verification, SELinux/AVC) was untestable. `cosign` ran
containerised; `trivy`/`syft`/`nmap` were unavailable.

---

## Fix verification (Phase D)

| ID | Sev | Fix (PR/commit) | Re-tested on | Verdict |
|----|-----|-----------------|--------------|---------|
| F-01 | S1 | | | NOT-RETESTED |
| F-02 | S1 | | | NOT-RETESTED |
| F-03 | S2 | | | NOT-RETESTED |

---

## Open questions for the release owner

1. **Is `documentdb-setup` the only supported package install path?** If so, F-01 is a
   documentation and error-message defect. If `documentdb-tune` + `CREATE EXTENSION
   documentdb CASCADE` is also supported — and `documentdb-gateway-admin` tells users
   exactly that — it is a functional S1.
2. **Should CRB be a documented RPM prerequisite**, or should the PostGIS dependency be
   relaxed so a clean Rocky 9 + PGDG + EPEL install succeeds?
3. **Should `--password` be enforced**, or the `Admin100` default removed? Shipping both
   a "REQUIRED" help string and a working default is the worst of both.
4. **Is `PGOPTIONS` an intended configuration channel?** If yes it needs documenting and
   validating; if no it should be ignored rather than forwarded to server argv.
5. **Should `TLS_MODE=disabled` be rejected at startup** rather than warn-and-continue,
   given it does the opposite of what its name says?
