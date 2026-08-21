# Track 14 — Upgrade & migration

**You are** an existing user upgrading to 0.116-0. Your data already exists and must
survive. You test in-place upgrades of both the container image and the packaged
extension, across PG majors where relevant, and confirm no data loss, no broken
extension state, and a clear path.

**Read first:** `ENVIRONMENT-SETUP.md` (§1 version, §2 image, §3 packages) and
`REPORT-TEMPLATE.md`. **Write** to `reports/track-14-upgrade-migration.md`.

## SUT
- **Container:** an older `documentdb-local` (e.g. a v0.114 tag) → `pg17-0.116.0`,
  same data volume.
- **Packages:** a prior-release extension (e.g. 0.114) installed, then upgraded to
  0.116 via `apt`/`dnf`, then `ALTER EXTENSION documentdb UPDATE`.
Coordinate with Tracks 08/09 for the package-manager mechanics; this track owns the
**data and extension-state** correctness.

## Step 0 — confirm you have a baseline (do this first, report immediately)

Every scenario below needs a prior release to upgrade **from**, and that is the
single most likely reason this track fails to run. Before anything else,
establish and record:

- Which older `documentdb-local` tags actually exist in the registry under this
  repository path (`0.113`/`0.114`, per PG major), with digests.
- Whether the prior-release `.deb`/`.rpm` artifacts are still downloadable —
  GitHub Actions artifacts expire (~90 days), so an older release's build run may
  no longer serve them. Fallbacks: the downstream `documentdb.io` apt/yum repos,
  or building the baseline from the older tag.

If a baseline cannot be obtained, the affected scenarios are **⛔ BLOCKED, not
PASSED** — tell the coordinator immediately rather than at report time, because a
release with an untested upgrade path is a release-owner decision.

## What to test (checklist)

1. **Container image upgrade, same volume.** Start an older image on a named volume,
   create representative data (multiple DBs/collections, indexes incl. unique/TTL,
   a `$jsonSchema` validator, large + typed documents). Stop, `docker rm`, start
   `pg17-0.116.0` on the **same** volume. Confirm:
   - the container starts (does it run any needed extension upgrade / PG catalog
     migration automatically?),
   - **all data is present and correct**,
   - indexes still exist and still enforce (unique still rejects dupes; TTL still
     expires),
   - the validator still validates,
   - the server reports 0.116. Any data/index/validator loss on upgrade is **S1**.
2. **Same-major PG, extension upgrade.** With the packaged extension: install 0.114
   on PG17, populate, `apt/dnf upgrade` to 0.116, then `ALTER EXTENSION documentdb
   UPDATE`. Confirm `\dx` moves to 0.116 and data/queries are intact. A failed or
   partial `ALTER EXTENSION UPDATE` (leaving a mixed-version catalog) is S1.
3. **Skip-version upgrade.** If artifacts allow, upgrade from an **older** baseline
   (e.g. 0.113) directly to 0.116 (skipping intermediates, and noting 0.115 was
   skipped in the release line). Confirm the update path handles the gap or fails
   with a clear "upgrade to X first" message rather than corrupting state.
4. **PG major upgrade interaction.** The scenario where a user also moves PG majors
   (e.g. PG17→PG18) using `pg_upgrade` with the DocumentDB extension present.
   Confirm the extension is compatible post-`pg_upgrade` (or that the docs state the
   supported procedure). This is a classic breakage point — test it or clearly mark
   it untested with the reason.
5. **Downgrade behavior.** Attempt to start an **older** image on a volume already
   upgraded to 0.116 (and the extension-downgrade case). Confirm it fails **safely
   and clearly** (refuses, names the version mismatch) rather than silently
   corrupting the newer data. A silent downgrade that damages data is S1.
6. **Rollback story.** Determine and document what a user can actually do if a
   0.116 upgrade goes wrong: is there a supported rollback? A backup step the docs
   should mandate before upgrade? If the only safe answer is "restore from backup,"
   the docs must say so (feed to Track 12).
7. **Config/format migrations.** Check for any on-disk format, gateway config, or
   catalog-schema change between the baseline and 0.116 that needs migration.
   Confirm it happens automatically or is documented. The 0.116 changelog's index/
   metadata changes (per-path multikey, composite-index parallel-array rules) are
   candidates — confirm existing indexes built on the old version still behave.
8. **Interrupted upgrade.** Kill the container / interrupt the package upgrade
   mid-way. Restart. Confirm the system recovers to a consistent state (either fully
   old or fully new, never a corrupt in-between). Coordinate crash mechanics with
   Track 02.

9. **TOAST-compression rollback hazard (specific, and already flagged in the
   code).** The image applies TOAST compression through an include fragment
   written under `GATEWAY_HOME`, which is image-ephemeral. The entrypoint itself
   warns that after an image rollback the include line dangles and "rolling this
   volume back to an older image may fail to start." Reproduce it: run 0.116 with
   `--toast-compression lz4` on a volume, then start an **older** image on that
   same volume. Confirm the failure is clean and self-explanatory rather than a
   cryptic PG start error, and that the documented recovery works. This is the
   concrete instance of check 5. Coordinate with Track 16 §10.
10. **Legacy index metadata.** 0.116 changes per-path multikey marking and
    rejects parallel arrays on metadata-backed composite indexes. An index
    **built on the old version** carries the old metadata. After upgrading,
    confirm such an index still returns correct results — compare index-path and
    sequential-scan answers for the same predicates — or that a rebuild is
    required *and documented*. A silently-wrong legacy index is **S1**;
    Track 16 §9 has the integrity oracle.

## Expected results
In-place image and extension upgrades preserve all data, indexes, and validators;
version reports 0.116; skip-version and downgrade fail clearly rather than
corrupting; PG-major upgrade path is confirmed or documented; interrupted upgrade
recovers consistently.

## Report
`REPORT-TEMPLATE.md`. State the exact baseline version(s) you upgraded **from**.
Any data/index/validator loss, or any mixed-version catalog, is S1 at the top with
full repro. Note which upgrade paths you could not test and why.
