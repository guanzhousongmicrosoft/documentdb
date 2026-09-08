# Track 08 — DEB install / upgrade / remove (Ubuntu 24.04)

**You are** a Debian packaging QA engineer. You install the shipped `.deb` set on a
clean Ubuntu 24.04, on both architectures and both PG majors, and try to find a
missing dependency, a broken maintainer script, a file in the wrong place, or a
lifecycle (upgrade/remove/purge/reinstall) that leaves the system inconsistent.

**Read first:** `ENVIRONMENT-SETUP.md` (§3 DEB, §5 platform matrix) and
`REPORT-TEMPLATE.md`. **Write** to `reports/track-08-deb-packaging.md`.

## SUT
The Ubuntu 24.04 `.deb` artifacts from `documentdb-packages-0.116.0` (run
32413347757). Test on **clean** Ubuntu 24.04 (container or VM), **amd64 and
arm64**, for **PG 17 and PG 18**. Packages depend on the **PGDG apt repo** — add it
first.

## Setup
```bash
# Verify checksums first
sha256sum -c SHA256SUMS        # from the aggregate bundle; expect all OK
# Add PGDG (the extension deps live here)
apt-get install -y curl ca-certificates gnupg lsb-release
install -d /usr/share/postgresql-common/pgdg
curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt-get update
```

## What to test (checklist)

1. **Checksum + arch sanity.** Verify each `.deb` against `SHA256SUMS`. Confirm the
   arch-specific extension packages are actually built for their arch
   (`dpkg-deb -I` → `Architecture:`) and the `_all.deb` meta/common/tools packages
   are `all`.
2. **Dependency resolution.** For each extension package
   `postgresql-{17,18}-documentdb_0.116-0_<arch>.deb`, confirm its declared deps
   (`postgresql-N`, `postgresql-N-cron`, `postgresql-N-pgvector`,
   `postgresql-N-postgis-3`, `postgresql-N-rum`) all **resolve from PGDG** on 24.04
   for that arch. A dep that doesn't exist for 24.04/arch is **S1** (package can't
   install). Install via `apt-get install ./file.deb` (pulls deps) and confirm a
   clean exit.
3. **Fresh install → working extension.** After install, start PG, `CREATE
   EXTENSION documentdb CASCADE;` (or the documented incantation). Confirm the
   extension loads, `\dx` shows it at 0.116, and a trivial DocumentDB SQL call
   works. Repeat for PG17 and PG18.
4. **Meta packages.** Install the top `documentdb` meta and the per-major
   `documentdb-17`/`documentdb-18`. Confirm they pull the right components and the
   documented "one command to get everything" experience works.
5. **`documentdb-common` co-install.** The build includes a "documentdb-common DEB
   co-install regression" job — confirm `documentdb-common` can be co-installed
   across the PG17 and PG18 stacks **simultaneously** without file conflicts
   (`dpkg` errors on overlapping paths). File conflicts here are S1.
6. **`documentdb-postgresql-tools`.** Install it; confirm the tools it ships are on
   `PATH` and run (`--version`/`--help`). Confirm it's `Suggests`, not a hard dep.
7. **File layout & ownership.** `dpkg -L` each package. Confirm files land under
   sane paths (extension `.so`/`.control`/`.sql` under the PG lib/share dirs for
   the right major; binaries in `/usr/bin`; config under `/etc`). Nothing in `/`,
   `/root`, or another major's directory. Check ownership/mode on anything
   security-relevant.
8. **Maintainer scripts.** Watch `postinst`/`prerm`/`postrm` output. They must be
   idempotent and must not fail on a clean system. Trigger `preinst`/`postinst`
   error paths if you can (e.g. install with PG not yet present) and confirm clean
   messaging, not a half-configured `dpkg` state.
9. **Remove vs purge.** `apt-get remove` (keep config) then `purge` (drop config).
   Confirm remove leaves data/config as documented and purge cleans up
   **without** deleting a user's database unexpectedly (deleting user data on purge
   without warning is S2). Confirm no orphaned users/services/files after purge.
10. **Reinstall & repair.** Reinstall over an existing install; `apt-get install
    -f` after a deliberately interrupted install. Confirm the system self-heals.
11. **Upgrade from previous release (coordinate with Track 14).** If a v0.114/0.113
    `.deb` is available, install it, create data, then upgrade to 0.116 and confirm
    the extension upgrade path (`ALTER EXTENSION documentdb UPDATE`) and data
    survival. Deep upgrade logic is Track 14; here just confirm the **package**
    upgrade (`dpkg`/`apt` side) is clean.
12. **Idempotent, offline, and proxy cases.** Confirm install works behind a
    typical apt proxy and that repeated `apt-get update && install` is stable.

## Expected results
All deps resolve from PGDG on 24.04/amd64 and arm64 for PG17+18; extension loads at
0.116; common co-installs; layout is sane; remove/purge/reinstall are clean.

## Report
`REPORT-TEMPLATE.md`. Record arch × PG-major as a grid (4 cells min). Any unresolved
dep or file conflict is S1 at the top. Note PGDG package names you had to add.
