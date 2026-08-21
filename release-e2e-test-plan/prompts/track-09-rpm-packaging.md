# Track 09 — RPM install / upgrade / remove (RHEL / Rocky 9)

**You are** an RPM packaging QA engineer. Same mission as Track 08, on the RHEL
family. The RPM dependency **names differ** from DEB (notably PostGIS), so resolution
is a distinct risk.

**Read first:** `ENVIRONMENT-SETUP.md` (§3 RPM incl. PK1, §5 matrix) and
`REPORT-TEMPLATE.md`. **Write** to `reports/track-09-rpm-packaging.md`.

## SUT
The RHEL9 `.rpm` artifacts from `documentdb-packages-0.116.0` (run 32413347757).
Test on **clean Rocky Linux 9** (or RHEL 9 / AlmaLinux 9), **x86_64 and aarch64**,
for **PG 17 and PG 18**. Packages depend on the **PGDG yum repo** + EPEL — add them
first.

## Setup
```bash
sha256sum -c SHA256SUMS
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm
dnf install -y epel-release
# PGDG modular PostgreSQL: disable the built-in postgresql module so PGDG wins
dnf -qy module disable postgresql || true
dnf makecache
```

## What to test (checklist)

1. **Checksum + arch sanity.** Verify each `.rpm` against `SHA256SUMS`. Confirm the
   extension/gateway RPMs are `el9` and the right arch; meta/common/tools are
   `noarch`.
2. **Dependency resolution (finding-seed PK1).** The extension
   `postgresqlN-documentdb` requires `(postgresqlN or percona-postgresqlN)`,
   `(postgresqlN-server or …)`, `(pgvector_N or percona-pgvector_N)`, `pg_cron_N`,
   **`postgis36_N`**, `rum_N`. Confirm **every** one resolves from PGDG/EPEL on
   EL9 for both arches — especially `postgis36_N` (the name differs from the DEB
   `postgis-3`; a wrong/missing name is **S1**). Install with `dnf install
   ./file.rpm` and confirm deps pull cleanly.
3. **Fresh install → working extension.** Init a PG cluster
   (`/usr/pgsql-N/bin/postgresql-N-setup initdb`), start it, `CREATE EXTENSION
   documentdb CASCADE;`. Confirm `\dx` shows 0.116 and a trivial call works. PG17
   and PG18.
4. **Meta packages.** `documentdb`, `documentdb-17`, `documentdb-18` — confirm the
   one-shot install experience and that they pull the right pieces.
5. **`documentdb-common` co-install regression.** The build has an explicit RPM
   co-install regression job. Confirm `documentdb-common` co-installs across the
   PG17 and PG18 stacks with **no file conflicts** (`rpm`/`dnf` file-conflict
   errors are S1).
6. **`documentdb-postgresql-tools`.** Install; confirm tools on `PATH` and runnable.
7. **File layout & ownership.** `rpm -ql` each package. Extension artifacts under
   the correct `/usr/pgsql-N/...`; binaries in `/usr/bin`; config in `/etc`.
   Nothing misplaced across majors. Verify `rpm -V` reports no unexpected
   verification failures right after install.
8. **Scriptlets.** Watch `%pre`/`%post`/`%preun`/`%postun` output; confirm
   idempotent and clean on a fresh system; confirm no leftover `.rpmnew`/`.rpmsave`
   surprises on reinstall.
9. **Erase & reinstall.** `dnf remove` then reinstall. Confirm a user's data/config
   handling matches docs and nothing is orphaned. `rpm -e` of a single component
   while deps are present must fail sanely, not corrupt the db.
10. **GPG / repo-signing expectation.** These are locally-installed RPMs; note
    whether they are GPG-signed and whether `dnf` warns about unsigned packages
    (the downstream documentdb.io yum repo signs on publish — local artifacts may be
    unsigned; confirm and note it's expected).
11. **SELinux.** On a host with SELinux **enforcing**, confirm the extension +
    gateway run without AVC denials (`ausearch -m AVC`). SELinux denials that break
    the gateway are S2. Note any `semanage`/context steps the docs should mention.
12. **Upgrade from previous release (coordinate with Track 14).** If prior-release
    RPMs exist, `dnf upgrade` to 0.116 and confirm the package-side upgrade is clean;
    hand extension-upgrade semantics to Track 14.

## Expected results
All deps (incl. `postgis36_N`) resolve on EL9/x86_64+aarch64 for PG17+18; extension
loads at 0.116; common co-installs; SELinux-enforcing is clean; erase/reinstall
consistent.

## Report
`REPORT-TEMPLATE.md`. Grid arch × PG-major. Give the PK1 verdict explicitly. Any
unresolved dep, file conflict, or SELinux breakage leads as S1/S2.
