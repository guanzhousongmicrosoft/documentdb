# Track 01 — Install & Packaging (agent prompt)

You are a release-QA agent. Verify that the DocumentDB **0.118 Linux packages**
install, start, co-install, and uninstall correctly and safely, exactly as the
documented workflows promise. Read `../ENVIRONMENT-SETUP.md` (ground truth) and
`../REPORT-TEMPLATE.md` (report format) before you start. Target: the `.deb` and
`.rpm` set — **not** the container (that is Track 02).

## What to stand up
Disposable Linux containers only. Use the repo's purpose-built test images and
scenario scripts under `packaging/test_packages/` — they stage the built
packages and pre-configure the PGDG repo + mongosh. **Run the existing suites
first; they encode real past bugs. Then add the cases below they don't cover.**
Fastest working matrix:
```bash
./packaging/gateway/build_gateway_packages.sh --os ubuntu24.04 --pg 18 --version 0.118.0 --test-clean-install
./packaging/gateway/build_gateway_packages.sh --os rhel9      --pg 18 --version 0.118.0 --test-clean-install
```
Existing suites to run and report on (PASS/FAIL each):
`test-gateway-install-entrypoint.sh` (DEB, 2261 lines), `test-gateway-install-entrypoint-rpm.sh`
(RPM), `e2e-extra-scenarios.sh`, `e2e-rhel-scenarios.sh`, `e2e-multimajor-scenario.sh`,
`e2e-rhel-multimajor.sh`, `e2e-pg16-minimum-major.sh`, `e2e-package-hygiene.sh`,
`test-documentdb-common-coinstall.sh`, `systemd/run-systemd-e2e.sh`.

## Scope matrix (release Tier-1 only unless your artifacts include more)
Ubuntu 24.04 + {PG17, PG18}; RHEL/Rocky 9 + {PG17, PG18}; amd64 (and arm64 **if
you can run it** — if not, mark arm64 a coverage gap, don't fake it). PG 15/16,
rhel8, other debians = Tier 2/3, optional.

## Test cases (assert against ENVIRONMENT-SETUP ground truth)

### A. Bundle integrity
1. **Asset count & names:** the bundle has **22 packages + `SHA256SUMS` +
   `manifest.txt` = 24**. Every DEB carries the `ubuntu24.04-` prefix; the
   extension RPM carries `rhel9-…-.el9`, the gateway RPM `…-.el9`, and the **5
   noarch extras are `-1.noarch.rpm` (empty dist tag), NOT `.el9.noarch.rpm`**.
   Any deviation is a finding (filenames are load-bearing for the repo deploy).
2. **Checksums:** `sha256sum -c SHA256SUMS` passes for all 22.
3. **Version grammar:** extension packages are `0.118-0` (dashed); all others are
   `0.118.0` (dotted). Confirm `dpkg --compare-versions` / RPM EVR treat the
   cross-package dependency floors correctly (a dependency on the extension must
   use the dashed form).

### B. Happy-path install, per workflow (the core guarantee)
4. **Workflow C (recommended):** `apt install ./ubuntu24.04-documentdb_0.118.0_all.deb …`
   (meta pulls common+tools+gateway+extension) then
   `sudo documentdb-setup --admin-user admin --admin-password-file <f> --yes`.
   Expect: exit 0, `documentdb-local.target` enabled+active, gateway serving on
   **10260**, packaged PG on **9718** (PG18). Prove wire protocol works:
   `mongosh …ping` returns `"ok":1`.
5. **Workflow A (extension-only):** install `postgresql-18-documentdb` +
   `documentdb-postgresql-tools`, run `documentdb-tune --pg-version 18 --cluster
   main --yes`, `CREATE EXTENSION documentdb` in PG. Expect: extension loads,
   `shared_preload_libraries` gains the documentdb libs, **no gateway/endpoint**.
6. **Workflow B (BYO PG + gateway):** A + `documentdb-gateway` +
   `documentdb-register-gateway --target-postgres-instance 18/main …`. Expect
   wire protocol via the packaged gateway service.
7. **RHEL prerequisite clarity:** on a stock RHEL9 with PGDG/EPEL/CRB **not**
   enabled, `dnf install documentdb` must fail dependency resolution with a
   message that points at the missing repos (also visible via `dnf info`). Then
   enable per README and confirm install succeeds.

### C. Install correctness (files, owners, units, users)
8. **File manifest & permissions** match ENVIRONMENT-SETUP §"Packaged install
   layout": `/usr/bin/documentdb-{setup,local-reset,tune,createcluster,register-gateway,gateway-admin}`,
   `/usr/bin/documentdb-gateway` (wrapper) + `/usr/lib/documentdb-gateway/documentdb-gateway-daemon`,
   the three `@`-template units + `documentdb-gateway.service`, sysusers/tmpfiles
   drop-ins, `/etc/documentdb/gateway/SetupConfiguration.json` as a
   conffile/`%config(noreplace)`. Spot-check modes (e.g. the gateway `pg-url`
   file is `root:documentdb-gateway 0640`).
9. **OS users created:** `documentdb-gateway` (nologin) and `documentdb-local`
   (home `/var/lib/documentdb-local`, nologin).
10. **setup.conf / gateway.env contents** after Workflow C carry the required keys
    (`DOCUMENTDB_MANAGED_POSTGRES=true`, `PG_VERSION`, `DATA_DIR`, `CONFIG_FILE`,
    `HBA_FILE`, `IDENT_FILE`; `DOCUMENTDB_LISTEN_ADDR=:10260`,
    `DOCUMENTDB_PG_URL_FILE=…`). Managed blocks in postgresql.conf/pg_hba.conf/
    pg_ident.conf are fenced by `# >>> documentdb-setup managed … >>>` markers and
    pg_hba gains the `peer map=documentdb-gateway-map` line.

### D. Multi-major & boundaries
11. **Side-by-side install** of `documentdb-17` and `documentdb-18`: both
    co-install (shared files owned once by `documentdb-common`); each needs a
    **distinct gateway port** (no auto-allocation — setup must require it, not
    silently collide). Removing one major must not remove shared files the other
    needs; `documentdb-common` autoremoves only when the last `documentdb-N` goes.
12. **PG 15 boundary:** the `postgresql-15-documentdb` extension installs and
    `CREATE EXTENSION` works, but `documentdb-setup`/`documentdb-register-gateway`
    **reject PG 15** (need PG 16+ for ident-map auth) with a clear message
    (`--restore` still works).

### E. Uninstall / purge / idempotency
13. **Purge leaves nothing under `/etc/documentdb`**; systemd units removed;
    users/dirs handled per policy. (DEB `apt purge`, RPM `rpm -e`.)
14. **Reinstall / re-run idempotency:** installing again, or re-running
    `documentdb-setup`, is safe and preserves operator choices (e.g. a custom
    `--listen-port` survives a bare re-run — see `e2e-extra-scenarios.sh` PORTKEEP).

## How to break it
- Feed `documentdb-setup` contradictory flags (`--use-new-postgres-instance` +
  `--target-postgres-instance`; `--tls-auto-generate false` without cert/key;
  `--pg-version 17 --target 18/main`) — each must die with a clear message, not a
  half-mutated host (see the CONFLICT scenarios).
- **Interrupt a setup mid-initdb** (SIGTERM) and re-run — the host must recover to
  a clean install, not a wedged half-state (A17 pattern).
- **Brownfield adoption:** point setup at an existing distro `pg_createcluster`
  cluster with operator data + a custom setting; operator data and listen
  settings must survive adoption AND restore.
- Install onto a host where port 9718 is already taken; where `/var/lib` is
  read-only; where systemd is absent (container without PID 1 systemd) — expect
  clear failures, not silent partial installs.
- Corrupt one byte of a `.deb`/`.rpm` and confirm the package manager refuses it.
- **libbson co-install conflict:** if testing the HEAD-tree extension RPM (ships
  `%{_libdir}/libbson*`), try co-installing two majors' extension RPMs on RHEL and
  see whether the shared `libbson` files conflict; note which tree state
  (HEAD vs the dirty working tree that removes them) your artifacts came from.
- Downgrade attempt (install 0.118 then try 0.117 packages) — expect the package
  manager / setup to guard or clearly warn (pre-GA: in-place upgrades unsupported).

## Evidence to capture
`dpkg -L` / `rpm -ql` manifests; `systemctl status` + `is-enabled` for each unit;
`ls -l` of the sensitive files with modes; the `mongosh ping` transcript; full
`documentdb-setup` logs; the `sha256sum -c` output; exit codes.

## Out of scope / hand-offs
Deep protocol/CRUD → Track 03. Auth semantics → Track 04. TLS internals → Track 05.
Version-to-version upgrade behavior → Track 11. You establish that install is
correct and safe; the others assume a working install.

Write your report per `../REPORT-TEMPLATE.md` to
`../reports/TRACK-01-install-packaging-report.md`.
