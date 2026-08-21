# Track 09 — RPM install / upgrade / remove (RHEL / Rocky 9)

- **Worker:** Claude Code
- **Date:** 2026-08-21 UTC
- **SUT identity:** `documentdb-packages-0.116.0` from run 32438343434, commit `684ac162`.
  `rhel9-postgresql17-documentdb-0.116.0-1.el9.x86_64.rpm` and the full 11-file RPM set.
  Host: `rockylinux/rockylinux:9` container, **x86_64**. **SHA256SUMS 22/22 OK.**
- **Result:** FAIL (documented path) → PASS-WITH-FINDINGS (with CRB enabled)
- **Counts:** S1: 1 · S2: 1 · S3: 0 · S4: 1

## Summary

**This is the highest-delta area of the release** — the only source difference between
the `66e9e118` the plan was written against and the `684ac162` actually built is RPM
packaging (`documentdb.spec`, `packaging-entrypoint-rpm.sh`, and two RHEL test scripts).

Following the documented setup (PGDG + EPEL, `module disable postgresql`), the PG17
extension RPM **fails to install** on a clean Rocky 9: PostGIS pulls GDAL, and no
enabled repository provides `libqhull_r.so.7`. Enabling Rocky's **CRB** repository —
which is off by default and not mentioned anywhere in the setup — resolves it, after
which everything installs cleanly and seed **PK1 is disproved**: `postgis36_17` is the
correct name and resolves fine (3.6.3). Once installed, the RPM path hits the **same
S1 index defect as the DEB path** (F-01).

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | Checksum + arch sanity | ✅ | Extension/gateway `x86_64`/`aarch64` `el9`; meta/common/tools `noarch` |
| 2 | Dependency resolution (PK1) | ❌→✅ | **Fails** with documented repos; **passes** with CRB. `postgis36_17` itself resolves correctly |
| 3 | Fresh install → working extension | ⚠️ | Extension loads at `0.116-0`; index creation broken (F-01) |
| 4 | Meta packages | ✅ | `documentdb`, `documentdb-17`, `documentdb-18` all install (`ALL_RPM_EXIT=0`) |
| 5 | `documentdb-common` co-install PG17+PG18 | ✅ | Both installed; only shared path is `/usr/lib/.build-id` (a directory — harmless) |
| 6 | `documentdb-postgresql-tools` | ✅ | 7 binaries on PATH |
| 7 | File layout & ownership | ✅ | Under `/usr/pgsql-17/…`; `rpm -V` clean after install |
| 8 | Scriptlets | ✅ | No errors; gateway user `uid=998(documentdb-gateway)` created |
| 9 | Erase & reinstall | ✅ | `dnf remove` exit 0 |
| 10 | GPG / repo-signing | ⚠️ | All RPMs **unsigned** (`SIGPGP` = `(none)`) — expected for build artifacts, signed on downstream publish; confirm before shipping |
| 11 | SELinux | ⛔ | **Not tested** — no SELinux-enforcing host available |
| 12 | Upgrade from previous release | ⛔ | Not tested |

## Findings

### [S2] RPM will not install on a clean Rocky 9 with the documented repositories

- **What:** The dependency chain `postgresql17-documentdb → postgis36_17 → gdal*-libs`
  requires `libqhull_r.so.7()(64bit)`, which no repository in the documented setup
  provides.
- **Finding-seed:** adjacent to PK1 (PK1 itself is disproved)
- **Repro:**
  ```bash
  # clean rockylinux:9
  dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  dnf install -y epel-release
  dnf -qy module disable postgresql
  dnf install -y ./rhel9-postgresql17-documentdb-0.116.0-1.el9.x86_64.rpm
  ```
- **Observed:**
  ```
  - nothing provides libqhull_r.so.7()(64bit) needed by gdal311-libs-3.11.0-1PGDG.rhel9.x86_64
  … (19 more gdal candidates, all the same)
  (try to add '--skip-broken' … or '--nobest' …)
  INSTALL_EXIT=1
  ```
- **Root cause / fix:** `libqhull_r-1:7.2.1-11.el9` lives in Rocky's **CRB** repo,
  disabled by default:
  ```bash
  dnf config-manager --set-enabled crb
  dnf install -y ./rhel9-postgresql17-documentdb-…x86_64.rpm   # INSTALL_WITH_CRB_EXIT=0
  ```
  After which all deps resolve: `postgis36_17-3.6.3`, `pgvector_17-0.8.6`,
  `pg_cron_17-1.6.7`, `rum_17-1.3.14`.
- **Expected:** Either the documented prerequisites list CRB, or the PostGIS
  dependency is loosened so PGDG+EPEL suffices.
- **Impact:** A user following the instructions cannot install on the Tier-1 RHEL
  platform, and the failure is 20 lines of GDAL noise that never mentions qhull's
  repo. High support cost, trivial fix.
- **Confidence:** high · **Suggested severity:** S2 (a release owner could reasonably
  call this S1 — a shipped package that will not install as documented)

### [S1] Same `extended_rum` index defect as the DEB path

- **What:** identical to F-01; see `track-08-deb-packaging.md` for the full write-up.
- **Repro (RPM path):** manual `initdb` → `documentdb-tune --pg-version 17 --pgdata
  /var/lib/pgsql/17/data --yes` → `CREATE EXTENSION documentdb CASCADE` →
  `create_indexes_background`.
- **Observed:**
  ```
   documentdb.alternate_index_handler_name | extended_rum
   documentdb_extended_rum | 0.116-0 |            <- installed_version EMPTY

  .....raw......defaultShard......ok......errmsg.b...Index access method extended_rum
  is not available, check the alternate_index_handler_name setting..code.(......ok......
  ```
- **Confidence:** high · **Suggested severity:** S1

### [S4] RPM ships two systemd units the DEB does not

- **Observed:** RPM installs `documentdb-gateway.service`,
  `documentdb-gateway-local@.service`, `documentdb-local@.target`,
  `documentdb-postgresql@.service`. The DEB installs only the first two.
- **Impact:** The appliance multi-instance model (Track 10 §10) appears available on
  RHEL but not on Ubuntu. Intended, or a packaging gap?
- **Confidence:** high · **Suggested severity:** S4 / Question

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| PK1 | **NOT-REPRODUCED** | `postgis36_17` is the correct name and resolves (3.6.3); the real blocker is `libqhull_r.so.7` from CRB |

## Evidence of the good path

```
=== full set install ===
ALL_RPM_EXIT=0
documentdb / documentdb-17 / documentdb-18 / documentdb-common /
documentdb-gateway / documentdb-postgresql-tools /
postgresql17-documentdb / postgresql18-documentdb   (all 0.116.0)

=== tune + extension ===
[documentdb-tune] Config written to /var/lib/pgsql/17/data/postgresql.conf
TUNE_EXIT=0
shared_preload_libraries = pg_cron, pg_documentdb_core, pg_documentdb, pg_documentdb_extended_rum
CREATE EXTENSION
documentdb documentdb_core pg_cron plpgsql postgis tsm_system_rows vector
```

`documentdb-tune` gave a genuinely good error when pointed at an uninitialised data
directory — *"does not look like a PostgreSQL data directory (no PG_VERSION or
postgresql.conf found there). Check the path for typos; refusing to fabricate a new
postgresql.conf."* Worth keeping.

## Cross-track notes

- `postgresql-17-setup initdb` requires systemd and fails in a plain container
  (`Failed to connect to bus`); I used `initdb` directly. Every systemd-dependent
  path — service lifecycle, `documentdb-setup`, sandbox verification, SELinux — is
  **untested** and needs a real VM.

## Evidence

`art/track09.log` in the session scratchpad.
