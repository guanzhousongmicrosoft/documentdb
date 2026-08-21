# Track 11 — Upgrade / Migration / Uninstall (agent prompt)

You are a lifecycle-QA agent. Verify version-to-version upgrade, extension update,
multi-major coexistence, downgrade guards, and clean uninstall — with data
surviving where it must. Read `../ENVIRONMENT-SETUP.md` and `../REPORT-TEMPLATE.md`
first. Target: packages (primary) and the container image (for the volume-reuse
cases).

## Contract facts
- **Pre-GA: the release notes footer states in-place upgrades are NOT supported.**
  So the primary job here is to verify (a) the **supported** path works and (b)
  **unsupported** paths fail **clearly and safely**, never with silent data loss.
  Confirm the exact current upgrade policy from the release notes / docs and test
  against *that*, not an assumption.
- Extension version at HEAD is **0.118-0**; a prior shipped line is **0.117-0**.
- **Two version grammars:** extension `X.Y-Z`, others `X.Y.Z`; cross-package
  dependency floors on the extension must use the dashed form. `dpkg
  --compare-versions 0.117-0 ge 0.117.0` is FALSE.
- Multi-major: shared files owned once by `documentdb-common`; per-major
  `documentdb-N`; `documentdb-common` autoremoves only when the last `documentdb-N`
  is gone. Side-by-side majors need distinct gateway ports.
- Container PG major is fixed per image; moving a volume to a different PG major is
  a PG-level migration (dump/restore), not an in-place upgrade.

## Test cases

### A. Extension update (SQL side)
1. If both versions are available: install extension 0.117, `CREATE EXTENSION
   documentdb`, load data, then install the 0.118 package and
   `ALTER EXTENSION documentdb UPDATE` — does it succeed, and is data intact and
   queryable? If update is unsupported, the ALTER must fail clearly (not corrupt).
2. `\dx documentdb` shows the expected version before/after; the update scripts
   present in the package match the version jump.
3. A fresh 0.118 install: `CREATE EXTENSION documentdb` reports `default_version =
   0.118-0`.

### B. Package upgrade (apt/dnf)
4. `apt install`/`dnf install` an older package set, then upgrade to 0.118:
   observe whether the package manager allows it, what it does to the running
   service, and whether data survives. Compare against the documented policy.
5. Config-file handling on upgrade: `/etc/documentdb/gateway/SetupConfiguration.json`
   is a conffile/`%config(noreplace)` — an operator's edits must be **preserved**
   (or the standard 3-way prompt shown), never silently overwritten.
6. systemd units on upgrade: the service restarts cleanly (or stays down per
   policy) and comes back healthy; no orphaned units.

### C. Multi-major coexistence & removal
7. Install `documentdb-17` and `documentdb-18` side by side with distinct gateway
   ports; both serve. (Reuse `e2e-multimajor-scenario.sh` /
   `e2e-rhel-multimajor.sh`.)
8. Remove one major: shared `documentdb-common` files survive for the other; the
   surviving major keeps serving; its data is untouched.
9. Remove the last major: `documentdb-common` autoremoves; nothing is left under
   `/etc/documentdb` after purge.
10. `documentdb-setup --restore --pg-version N` (scoped) detaches one major without
    touching another's live gateway/records; an unscoped `--restore` stops all and
    removes every per-port record (contract from `e2e-extra-scenarios.sh`).

### D. Container / volume migration
11. New image (same PG major, newer DocumentDB version) started on an **old
    volume**: data + admin user survive, `/version.txt` updates. If the extension
    needs an update step, confirm the container performs it or fails clearly.
12. Volume from an **older PG major** started on a newer-PG-major image: expect a
    refusal or a documented dump/restore path — NOT silent corruption. Confirm the
    lz4-TOAST caveat is handled (target must be lz4-capable).
13. `documentdb-local-reset` fully resets a data volume to fresh state.

### E. Downgrade & safety guards
14. Install 0.118, then attempt to install/downgrade to 0.117 packages — the
    package manager and/or setup must guard or clearly warn; data must not be
    silently broken. A `documentdb.spec`-tree note: verify which extension-RPM tree
    state (libbson bundled vs stripped) your artifacts use, as it affects co-install
    conflicts across versions.
15. Attempt an unsupported in-place upgrade deliberately and confirm the failure is
    loud, safe, and reversible (restore the prior state).

## How to break it
- Upgrade while under active write load — does the restart drop acked writes or
  corrupt anything (cross-ref Track 07)?
- Interrupt an upgrade midway (SIGTERM during the package postinst / extension
  update) and re-run — the host must recover to a consistent installed state.
- Mixed-version dependency floor: install a gateway/tools version that expects a
  newer extension than is present — the dashed-vs-dotted dependency check must
  catch it, not silently mismatch.
- Downgrade the extension under data written by the newer version (new BSON
  features/indexes) — reads must fail safely, not return wrong results.
- Remove `documentdb-common` while a `documentdb-N` still depends on it — the
  package manager must refuse.
- Leave a stale gateway pid/record from an interrupted restore and start again —
  no signal is sent to a recycled pid.

## Evidence to capture
`\dx` / `dpkg -l` / `rpm -q` version transitions; the exact package-manager
messages on upgrade/downgrade; conffile prompt/preservation evidence;
before/after data counts proving intactness; `systemctl status` across the
transition; the restore-record cleanup state.

## Out of scope / hand-offs
Fresh-install correctness → 01. Durability of the write path itself → 07. You own
the *change-over-time* dimension: upgrades, downgrades, coexistence, and removal,
with data-survival as the bar.

Write your report to `../reports/TRACK-11-upgrade-migration-report.md`.
