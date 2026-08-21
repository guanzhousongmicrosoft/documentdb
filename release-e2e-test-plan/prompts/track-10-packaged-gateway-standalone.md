# Track 10 — Packaged gateway & standalone setup

**You are** an operator standing up DocumentDB from packages (not the container) on
a real host: the systemd gateway service, the `documentdb-setup` wizard, the
helper scripts, and the appliance multi-instance model. You verify the intended
operator journey works and probe its edges.

**Read first:** `ENVIRONMENT-SETUP.md` (§4 packaged gateway + standalone, §6 PK2)
and `REPORT-TEMPLATE.md`. **Write** to `reports/track-10-packaged-gateway-standalone.md`.

## SUT
`documentdb-gateway` package + the standalone tooling on **Ubuntu 24.04** and
**Rocky 9** (at least one of each), PG 17 (repeat key paths on PG 18). This builds
on Tracks 08/09 having the extension installable.

## What to test (checklist)

1. **Gateway service install.** Install `documentdb-gateway`. Confirm it creates the
   `documentdb-gateway` system user/group, installs
   `/usr/bin/documentdb-gateway`, the unit `documentdb-gateway.service`,
   `/etc/documentdb/gateway/gateway.env`, and the TLS state dir under
   `/var/lib/documentdb-gateway`. Confirm the service is **not** silently started/
   enabled without configuration (it needs a PG URL first).
2. **`documentdb-setup` greenfield.** Run the wizard to initdb a **private**
   PostgreSQL instance and wire up the gateway end-to-end. Confirm:
   - it delegates to `documentdb-tune` (a managed block appears in
     `postgresql.conf`) and `documentdb-register-gateway` (hba/ident/role + the
     connection-URL file),
   - the backend PG comes up on the per-major port **9700+major** (9717 for PG17),
   - the gateway starts, and `mongosh localhost:10260` (TLS, allow-invalid) can
     auth and round-trip a document. This is the headline standalone journey — a
     break here is S1/S2.
3. **`documentdb-setup` brownfield.** Point `--target-postgres-instance` at an
   **existing** local PG cluster. Confirm the backup-and-rollback safety: it backs
   up `postgresql.conf`/`pg_hba.conf` before editing, applies a clearly-delimited
   managed block, and can be rolled back. Deliberately fail mid-run (e.g. revoke a
   permission) and confirm rollback restores the originals. Silent, unbacked
   mutation of a user's PG config is S2.
4. **Local-PG-only limitation (finding-seed PK2).** `gateway.env` states this
   release supports **local PostgreSQL over a Unix socket with peer/trust auth
   only** — cloud/remote PG over TCP with password auth is **not** supported. Verify
   this boundary: attempt to point the gateway at a remote/TCP PG with a password
   and confirm it is refused or clearly documented-as-unsupported (not a silent
   half-working state). Confirm the limitation is **discoverable** by an operator
   (in `gateway.env`, `--help`, or docs) before they hit it. An undocumented hard
   limit is a UX finding (feed to Track 12).
5. **systemd sandbox effectiveness.** The unit ships hardened
   (`ProtectSystem=strict`, `NoNewPrivileges`, `MemoryDenyWriteExecute`,
   `SystemCallFilter=@system-service`, `RestrictAddressFamilies`, `UMask=0077`).
   Confirm the service actually **runs** under these (not failing and getting them
   removed) and spot-check the sandbox holds: e.g. the service can't write outside
   `ReadWritePaths`, can't gain new privileges. `systemd-analyze security
   documentdb-gateway.service` — record the exposure score. A sandbox that had to
   be disabled to make things work is S2.
6. **gateway.env configuration.** Exercise the documented knobs:
   `DOCUMENTDB_LISTEN_ADDR`, `DOCUMENTDB_TLS_CERT_FILE`/`_KEY_FILE` vs
   `DOCUMENTDB_TLS_AUTO_GENERATE`, `DOCUMENTDB_TLS_STATE_DIR`,
   `DOCUMENTDB_LOG_LEVEL`, `DOCUMENTDB_PG_URL_FILE`. Confirm each takes effect after
   `systemctl restart`. Note any that are documented but ignored (parallels
   container C4/C5).
7. **Service lifecycle.** `start`/`stop`/`restart`/`reload`; `Restart=on-failure`
   (kill the process, confirm respawn); reboot persistence (`enable` + reboot →
   comes back). Confirm clean shutdown doesn't corrupt the backend.
8. **TLS auto-gen (package path).** With no cert configured, confirm the gateway
   writes and **reuses** a self-signed cert under the TLS state dir across restarts
   (container regenerates; package is meant to persist — verify). Key file perms
   must not be world-readable.
9. **Helper scripts.** `documentdb-createcluster`, `documentdb-gateway-admin`,
   `documentdb-local-reset`, `documentdb-tune`, `documentdb-register-gateway`: run
   `--help`, exercise the primary path of each, and confirm they fail safely on bad
   input. `documentdb-local-reset` is destructive — confirm it warns/confirms
   before wiping.
10. **Appliance multi-instance.** The `@`-templated units
    (`documentdb-postgresql@.service`, `documentdb-gateway-local@.service`,
    `documentdb-local@.target`) support multiple instances. Bring up **two**
    instances on different ports; confirm isolation (separate data dirs, no port
    clash, independent lifecycle) and that the `.target` groups them.
11. **Uninstall cleanliness.** Remove/purge the gateway package; confirm the
    service is stopped/disabled, the system user handling matches docs, and no
    user data is deleted without warning.

## Expected results
Greenfield and brownfield setup both reach a working `mongosh` round-trip; rollback
works; the sandbox holds; remote-PG limit is enforced + discoverable; multi-instance
isolates; uninstall is clean.

## Report
`REPORT-TEMPLATE.md`. Give the PK2 verdict and the `systemd-analyze security`
score. Capture `documentdb-setup` transcripts under `reports/artifacts/track-10-*`.
Distinguish OS (Ubuntu vs Rocky) for anything that differs.
