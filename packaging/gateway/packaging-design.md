# DocumentDB Packaging Design (Track 1)

> **Status:** Design draft for final review.
>
> Track 1 is the package strategy for the current release: split packages, systemd-native conventions, a hosted apt repository for the paved road, and a documented install path that matches what the gateway architecturally supports today (local PostgreSQL with peer authentication and a narrow `pg_ident.conf` map).
>
> Track 2 (gateway refactor for cloud-managed PostgreSQL over TCP/password) is **deferred** to a follow-on effort and is **out of scope** for this design. See [§11 Deferred work](#11-deferred-work).

---

## Contents

1. [Scope and goals](#1-scope-and-goals)
2. [Design constraints](#2-design-constraints)
3. [The promise (one line per package)](#3-the-promise-one-line-per-package)
4. [The four packages](#4-the-four-packages)
5. [User workflows](#5-user-workflows)
6. [Behavior matrix](#6-behavior-matrix)
7. [Security posture](#7-security-posture)
8. [Tool inventory](#8-tool-inventory)
9. [Packaging ownership boundary](#9-packaging-ownership-boundary)
10. [Known limitations (by design)](#10-known-limitations-by-design)
11. [Deferred work](#11-deferred-work)

---

## 1. Scope and goals

### In scope

- Define a four-package shape for both `.deb` and `.rpm` outputs — `postgresql-N-documentdb` (extension), `documentdb-postgresql-tools` (PostgreSQL administrator helpers), `documentdb-gateway` (wire-protocol translation layer), and `documentdb-N` + `documentdb` meta (stand-alone package) — while limiting first-party build/host/test commitments to the apt paved road.
- Adopt systemd-native conventions for service users, runtime directories, hardened sandboxing, and a single public systemd target (`documentdb-local.target`) so the stand-alone package's day-2 lifecycle — start, stop, restart, enable-on-boot — goes through one `systemctl` name.
- **Paved road:** build, host, and test one opinionated combination — **Ubuntu 24.04 LTS + PostgreSQL 18** — via a self-hosted apt repository. The package shape remains version-parametric so community channels can publish additional PostgreSQL majors where it is worth the friction, but this design does **not** commit the core project to every major/version permutation. Additional majors and their retirement are intentionally outside this packaging spec and would require a separate support-policy decision that is not yet defined in this repo. Other distros (Debian 12, Ubuntu 22.04, RHEL 9 / Fedora) are likewise community channels: **Fedora COPR** for the RPM family and **PGDG-style** conventions for additional deb packaging. See Non-goals below.
- Document and ship the workflow the gateway architecture genuinely supports today.

### Out of scope (deferred)

- **Docker images.** The existing `ghcr.io/documentdb/documentdb/documentdb-local:latest` image keeps being built by existing CI; this design does not modify it. Refactored, layered images (lean gateway image, separate `postgres-documentdb` image) are deferred.
- **Backend PostgreSQL topologies beyond the local paved road.** This design documents the same-host peer-auth path; an administrator who has already configured `trust` locally for the gateway OS user is also covered as a Workflow B precondition, but Track 1's package-managed registration writes peer + ident-map only. Cloud / remote PostgreSQL over TCP/password remains Track 2 capability work; see §2 and §11.1. The package shape does not need to change when that lands.
- **Production two-container compose.** Same blocker as above.

### Non-goals

The following are deliberately *not* commitments of this design. Keeping the paved road narrow lets us ship and support it well; the four-package split is shaped so each non-goal item is achievable by community packagers without core changes.

- **A maintained build matrix across every distro × every PG major.** We build and test the paved-road combination (Ubuntu 24.04 LTS + PG 18). RHEL/Fedora builds are produced via Fedora COPR; builds for additional PG majors or other distros rely on PGDG conventions and community packagers. We do not commit to producing or testing every cell, and we do not promise indefinite packaging for older PostgreSQL majors.
- **Side-by-side stand-alone installs for multiple PG majors as a first-class product story.** The package shape supports it (per-major naming, per-major paths/ports), but the paved-road flow is one PG major per host. Multi-major remains documented as an advanced capability (see §4.4); paved-road testing is single-major only.
- **A first-party documented/tested backend topology beyond the local paved road.** Cloud / remote PostgreSQL over TCP/password remains out of scope for Track 1; see "Out of scope (deferred)" and §11.1.

### What "done" looks like

- On the paved-road target (**Ubuntu 24.04 LTS + PostgreSQL 18**), `apt install documentdb` from our hosted apt repository pulls the stand-alone package and its dependencies.
- For community RPM channels, enabling the corresponding **Fedora COPR repo** makes `dnf install documentdb` follow the same high-level four-package contract, while distro-specific config mechanics differ.
- `sudo documentdb-setup` creates a DocumentDB instance backed by either a new or existing PostgreSQL instance, backing up configuration before making changes and supporting rollback.
- `sudo systemctl enable --now documentdb-local.target` brings up a working DocumentDB endpoint on port 10260.
- Purging the stand-alone package(s) removes package-managed services/configuration and restores managed config blocks, but preserves PostgreSQL data directories and database contents. Destructive data removal for stand-alone-package-owned private PostgreSQL state is only through `documentdb-local-reset --pg-version N --confirm-destroy`.
- The existing `documentdb-local` Docker image keeps building from existing CI without changes.

---

## 2. Design constraints

These are the user-facing realities the design must respect.

| Constraint | Why it matters for the design |
|---|---|
| Supported install path uses local passwordless PostgreSQL connections | The paved-road deployment puts the gateway and PostgreSQL on the same host with peer auth via Unix socket. Other backend topologies are configuration choices outside this design's scope; remote/TCP/password support still depends on Track 2 gateway work. |
| Advanced multi-major PostgreSQL coexistence on the same host | The package shape preserves per-major package names (`postgresql-N-documentdb`, `documentdb-N`), per-major file paths, and per-major systemd template instances for upgrade/migration scenarios. Each stand-alone PostgreSQL instance has at most one managed gateway, and Track 1 does not define a package-managed "many gateways against one PostgreSQL instance" topology. The paved road remains one major per host. |

---

## 3. The promise (one line per package)

| Package | Promise |
|---|---|
| `postgresql-N-documentdb` | "I extend your PostgreSQL major N. I install extension files only and do not configure PostgreSQL instances." |
| `documentdb-postgresql-tools` | "PostgreSQL administrator helpers (`documentdb-tune`, `documentdb-createcluster`, `documentdb-register-gateway`, future doctor commands). Optional for extension-only use. Required by the stand-alone package." |
| `documentdb-gateway` | "Wire-protocol translation layer. I am the runtime package only: systemd unit, binary, env sample, and connectivity check." |
| `documentdb-N` | "I make a DocumentDB instance work on this machine. Greenfield (I `initdb` my own private underlying PostgreSQL instance) or brownfield (I adopt an existing underlying PostgreSQL instance, with consent prompts before each invasive change). Co-installable with other PG majors." |

`documentdb-postgresql-tools` is a deliberate split from `postgresql-N-documentdb`: the pure extension package contains only the extension files, matching what Citus, pgvector, pg_cron, and TimescaleDB ship. Administrators who need PostgreSQL-side setup (`documentdb-tune`, `documentdb-createcluster`, or `documentdb-register-gateway`) install `documentdb-postgresql-tools` explicitly. The stand-alone package pulls it in automatically.

---

## 4. The four packages

### 4.1 `postgresql-N-documentdb` (extension only)

**Purpose:** ship the `documentdb` PostgreSQL extension for major version N. Per-major naming follows PGDG convention (matches `postgresql-N-cron`, `postgresql-N-pgvector`, etc.).

**What it installs (high level):**
- Extension shared libraries and SQL definitions under `/usr/lib/postgresql/N/lib/` and `/usr/share/postgresql/N/extension/`.
- Documentation that points administrators to `documentdb-postgresql-tools` for the inert config sample and tuning helper.

**Dependencies (summary):** `postgresql-N`, `postgresql-N-cron`, `postgresql-N-pgvector`, `postgresql-N-postgis-3`, `postgresql-N-rum` (PG ≤17) or built-in (PG 18+). Suggests `documentdb-postgresql-tools`.

**Mutates on install:** nothing.

**Does not:** edit `postgresql.conf` of running PostgreSQL instances, restart PostgreSQL, or run `CREATE EXTENSION`.

---

### 4.2 `documentdb-postgresql-tools` (PostgreSQL administrator helpers)

**Purpose:** ship administrator helpers that make a PostgreSQL instance DocumentDB-ready, with or without one managed local gateway attached.

**What it installs:** `/usr/bin/documentdb-tune`, `/usr/bin/documentdb-createcluster`, `/usr/bin/documentdb-register-gateway`, `/usr/share/doc/documentdb-postgresql-tools/examples/documentdb.conf.sample`, and documentation. The sample is intentionally inert: PostgreSQL's native include support (`include`, `include_if_exists`, `include_dir`) exists across the supported majors, and `include_dir` only loads files ending in `.conf`, so the managed fragment is named `documentdb.conf` while the example follows PostgreSQL's own `.sample` convention. This is a packaging/layout convention, not a new PostgreSQL-version boundary: the supported majors all support include files, while whether a PostgreSQL instance already exposes a `conf.d`-style directory depends on distro packaging. On Debian/Ubuntu it also installs a harmless global `createcluster.d` hook:

```conf
add_include_if_exists = '/etc/postgresql-common/documentdb/%v/%c/documentdb.conf'
```

Administrators can activate the extension settings in one of two ways:
1. **Recommended:** run `documentdb-tune`, which writes the active per-instance `documentdb.conf` file, records the managed changes for `--restore`, and tells the administrator whether reload or restart is required.
2. **Manual:** copy the inert sample to an active `.conf` file in the target PostgreSQL instance's existing include directory, for example `conf.d/99-documentdb.conf` or `postgresql.conf.d/99-documentdb.conf`, then reload or restart PostgreSQL as required by the changed settings.

The Debian/Ubuntu tuning flow is intentionally explicit:
1. `pg_createcluster` owns `/etc/postgresql/N/C/postgresql.conf`.
2. The hook adds one `include_if_exists` line for newly-created PostgreSQL instances.
3. `documentdb-tune --pg-version N --cluster C --yes` creates or removes the matching per-instance fragment, for example `/etc/postgresql-common/documentdb/N/main/documentdb.conf`.
4. The administrator reloads or restarts PostgreSQL.

The RHEL/Fedora RPM flow is different because there is no `postgresql-common` or `createcluster.d` hook model there. The RPM path is: `documentdb-tune` targets the selected PostgreSQL instance only when the administrator invokes it, writes `documentdb.conf` into that instance's existing config drop-in directory when present, and otherwise falls back to a clearly marked managed block in that instance's `postgresql.conf`.

For Debian/Ubuntu PostgreSQL instances that predate the tools package, the first `documentdb-tune --yes` adds that single managed `include_if_exists` line if it is missing, then writes the fragment. On distros that already enable a config drop-in directory (for example `conf.d` or `postgresql.conf.d`), `documentdb-tune` writes the active file there. Where no drop-in directory exists, it adds or uses a managed `include_if_exists` entry rather than expecting package install to mutate `postgresql.conf`; only if that pattern is unavailable does it fall back to a clearly marked managed block in the target `postgresql.conf`.

Gateway registration is also explicit and lives here for the same reason: it mutates the PostgreSQL instance, not the gateway runtime package. `documentdb-register-gateway` writes the managed `pg_hba.conf` / `pg_ident.conf` blocks for one PostgreSQL instance, creates or reuses the gateway PG role, and writes the gateway connection file for the paired local gateway service. It requires the `documentdb-gateway` package to already be installed so the `documentdb-gateway` OS user, service unit, and config directories exist; if that runtime package is missing, the tool exits with a clear prerequisite error rather than partially editing PostgreSQL.

**Track 1 boundary:** this package owns **all PostgreSQL-side mutations** — `postgresql.conf`, `pg_hba.conf`, `pg_ident.conf`, and the gateway PG role. The `documentdb-gateway` package is intentionally runtime-only. Track 1 models **one managed local gateway per PostgreSQL instance**; a future many-gateways-to-one-PostgreSQL topology would need a more explicit gateway-instance model and is out of scope here.

**Dependencies (summary):** `postgresql-common` on Debian; `jq` is also pulled in because `documentdb-gateway-admin` parses JSON output from `psql -A -t` extension probes. `Suggests:` (not `Depends:` or `Recommends:`) on the per-major `postgresql-N-documentdb` packages and on `documentdb-gateway` — `documentdb-postgresql-tools` is PostgreSQL administrator scaffolding that is useful even before the extension package or gateway runtime package is installed (e.g., previewing the managed fragment via `--dry-run`).

**Mutates on install:** no existing PostgreSQL instances. The package only installs files; it has no maintainer-script side effects.

**Why a separate package:** putting config-mutating CLIs in the pure extension package weakens its PGDG-clean shape, and putting them in the gateway runtime package blurs the runtime/config boundary. None of Citus, pgvector, pg_cron, or TimescaleDB ship config-editing tooling in their extension packages. The bar for upstream-Debian acceptance is "the extension package contains only the extension." This design applies the same principle to the gateway: the gateway package stays runtime-only, while `documentdb-postgresql-tools` owns the explicit, administrator-invoked PostgreSQL-side setup steps for both extension enablement (`documentdb-tune`) and local gateway attachment (`documentdb-register-gateway`). That keeps headless installs clean, keeps the runtime package lean, and makes the boundary easy to explain.

The stand-alone package `documentdb-N` **`Depends:`** on `documentdb-postgresql-tools` (not `Suggests:`) — its setup wizard invokes `documentdb-tune` and `documentdb-register-gateway`, so it cannot function without them.

---

### 4.3 `documentdb-gateway` (wire-protocol translation layer)

**Purpose:** ship the wire-protocol translation layer, packaged as a systemd-managed service, suitable for use with the stand-alone package or in an independent deployment against a local PostgreSQL instance on the same host.

**What it installs (high level):**
- `/usr/bin/documentdb-gateway` — single binary used by the systemd unit and by utility flags such as `--check` and `--version`.
- A hardened systemd service unit and matching `sysusers.d` / `tmpfiles.d` files for the OS user and runtime directories.
- A sample environment file at `/usr/share/doc/documentdb-gateway/examples/gateway.env.sample`; the live file remains `/etc/documentdb/gateway/gateway.env` when the administrator chooses to create it.
- Documentation and connection-string examples.

**Dependencies (summary):** no product-specific runtime dependency beyond the OS/runtime libraries that the binary links to and any direct gateway runtime requirements. **`Suggests:` (not `Recommends:`)** the per-major `postgresql-N-documentdb` packages — apt installs `Recommends:` by default, which would silently pull the local `documentdb` PostgreSQL extension package for users who only want the gateway package.

**Invocation surface (explicit `run` subcommand plus utility flags):**

| Invocation | Purpose |
|---|---|
| `documentdb-gateway run` | Explicit service-mode entry point. |
| `documentdb-gateway --check` | Utility flag for connectivity probe; smoke test once `documentdb-register-gateway` (or `documentdb-setup`) has finished writing the gateway's connection file and PostgreSQL-side wiring. |
| `documentdb-gateway --version` | Utility flag for version info. |

**Why there is no `setup` subcommand here:** PostgreSQL-side gateway integration mutates the PostgreSQL instance, so this design keeps that logic in `documentdb-postgresql-tools` (`documentdb-register-gateway`) instead of the runtime package. That makes the package boundary crisp: `documentdb-gateway` is the runtime artifact; `documentdb-postgresql-tools` owns local PostgreSQL configuration; `documentdb-setup` is the higher-level stand-alone wrapper.

**Configuration:** systemd reads `EnvironmentFile=-/etc/documentdb/gateway/gateway.env`; the leading `-` means the live file is optional. The package ships `/usr/share/doc/documentdb-gateway/examples/gateway.env.sample` rather than a pre-created live file, matching PostgreSQL's own `.sample` naming (`postgresql.conf.sample`, `pg_hba.conf.sample`, `pg_ident.conf.sample`). Administrators who need non-default listen/TLS/state settings copy the sample into place, edit it, and restart the service.

**Transitional back-compat:** for pre-Phase-3 deployments that were configured with `/etc/documentdb/gateway/SetupConfiguration.json`, the package still ships that file (marked as a dpkg `conffile` so administrator edits survive upgrades) and the binary still loads it before falling back to env-only. The wizard (`documentdb-setup`) also still rewrites `PostgresPort`, `GatewayListenPort`, `PostgresHostName`, `PostgresSystemUser`, and `PostgresDataUser` in that JSON during apply — this is required for the no-systemd fallback path inside the existing `ghcr.io/documentdb/documentdb/documentdb-local:latest` Docker image, where the gateway is launched as `documentdb-gateway <SetupConfiguration.json>` rather than via the systemd unit. In every other supported path (the systemd-managed `documentdb-gateway-local@N.service` and `documentdb-gateway.service` units), the per-major `gateway.env` file is the authoritative source of truth: `DOCUMENTDB_PG_URL_FILE` and `DOCUMENTDB_LISTEN_ADDR` from the env file override any conflicting JSON field, and Track 1's role / connection-file decisions are recorded only in the env file. The JSON file is therefore best understood as a compat shim for the Docker/no-systemd path; it will be retired in a future revision once that path is refactored. **TODO(track-2):** delete the JSON shim and update the Docker image to source `gateway.env`.

Two different credential concepts appear in this design and they are easy to confuse:

1. **Gateway-to-PostgreSQL identity (runtime).** In the documented Track 1 flows, the gateway runs as the OS user `documentdb-gateway` and connects to a **local** PostgreSQL instance over a Unix socket. `pg_hba.conf` + `pg_ident.conf` map that OS user to the PostgreSQL role(s) the gateway is allowed to assume. So the gateway's connection file (`DOCUMENTDB_PG_URL_FILE`) identifies **where** PostgreSQL is and **which local role mapping to use**, but for Track 1 it does **not** contain a PostgreSQL password. This is why the doc keeps saying "local peer auth" and why `documentdb-register-gateway` owns the `pg_hba.conf` / `pg_ident.conf` edits plus the gateway role creation. The default connection-file path for per-major stand-alone installs is `/var/lib/documentdb-local/N/gateway/pg-url` (mode `0640`, owner `root:documentdb-gateway`), written by `documentdb-register-gateway` / `documentdb-setup`; it lives in the persistent per-major working directory so it survives reboot (a `/run`-based path would be cleared by tmpfs and the gateway env file's `DOCUMENTDB_PG_URL_FILE` pointer would dangle on next boot). For Workflow B without the stand-alone wrapper, the same file path is the documented convention but the administrator supplies the exact value through `gateway.env`.
2. **DocumentDB admin user credential (bootstrap/day-2).** Separately, the first product-facing admin user may need a password so that `mongosh` and applications can authenticate through the wire protocol. That password belongs to the client-facing DocumentDB login, not to the gateway. In interactive setup the CLI may simply prompt for it on the terminal; `--admin-password-file` is the non-interactive / scripted form. It is **not** the password the gateway uses to reach PostgreSQL.

Other backend topologies are left to administrator configuration, but the current gateway still lacks remote/TCP/password support. In Track 1, the connection file remains passwordless and points at a local Unix-socket PostgreSQL endpoint; password-bearing connection-file variants are deferred to Track 2. **Passwords inside `DOCUMENTDB_PG_URL` are rejected** — the gateway exits with an error to prevent leakage via `/proc/<pid>/environ`.

Optional configuration includes:
- listen address (default `:10260`)
- TLS cert/key files; if neither is set, `DOCUMENTDB_TLS_AUTO_GENERATE=true` is the documented default in stand-alone setup and is what the Workflow C and Workflow B examples assume (auto-generated self-signed certificate). Administrators who supply their own cert/key set this to `false`.
- state directory
- log level (`DOCUMENTDB_LOG_LEVEL`)

Note: an extension/gateway version compatibility check is **deferred** for Track 1 — the runtime does not currently enforce one, and the corresponding env var is intentionally not exposed. It will be reintroduced together with the actual compat-check implementation as part of a future packaging-design revision.

**Service:** runs as the unprivileged `documentdb-gateway` OS user under a hardened systemd unit (no privilege escalation, private tmp/devices, read-only filesystem except its state and runtime directories, restricted syscalls and address families, write-execute memory denied).

**Mutates on install:** creates the `documentdb-gateway` OS user and runtime directories via `sysusers.d`/`tmpfiles.d`. **Does not start the service. Does not touch PostgreSQL.**

**Mutates on administrator invocation:** none in Track 1. PostgreSQL-side gateway registration lives in `documentdb-postgresql-tools` (`documentdb-register-gateway`). The runtime package itself only provides the service, binary, env sample, and connectivity probe.

---

### 4.4 `documentdb-N` (stand-alone package, per PG major) + `documentdb` (meta)

**Purpose:** make DocumentDB just work on this machine. Pulls in the `postgresql-N-documentdb` extension package, the gateway package, and the administrator tooling, owns the DocumentDB instance lifecycle, exposes a single systemd target for day-2 lifecycle.

**Naming:**
- `documentdb-N` — per-major stand-alone package naming pattern. Paved-road builds and tests **`documentdb-18`**. Additional `documentdb-N` packages may exist via community packaging for PostgreSQL majors that community channels choose to keep active; this spec does not promise that every historical major gets a package forever.
- `documentdb` — small meta/alias package depending on the paved-road default major (**`documentdb-18`**) and owning the public systemd alias.

**Co-installable across majors (advanced capability).** The stand-alone package follows PGDG's pattern: `documentdb-18` and `documentdb-19` can be installed side-by-side, just like `postgresql-18` and `postgresql-19`. **No `Conflicts:`** between major-N variants. This is preserved for staging and migration workflows, but it is not the paved-road story. Each stand-alone DocumentDB instance owns exactly one underlying PostgreSQL instance and one gateway, so side-by-side installs require the administrator to assign distinct public gateway ports for the non-default instances; this is manual configuration, not automatic allocation.

The meta package `documentdb` is intentionally opinionated: in first-party packages it is a fixed pointer to `documentdb-18`, and `documentdb-local.target` is a fixed alias to `documentdb-local@18.target`. Administrators running another major act on that major's per-instance target directly (`documentdb-local@N.target`). Community packagers may choose a different fixed alias target, but the design does not define a routine in-place "switch the default major" workflow for existing installations.

**Dependencies (summary):** `postgresql-N`, `postgresql-N-documentdb (>= ${binary:Version})`, `documentdb-gateway (= ${binary:Version})`, **`documentdb-postgresql-tools (>= ${binary:Version})`** (hard, not Suggests). The hard `Depends:` on `documentdb-postgresql-tools` reflects that `documentdb-setup` invokes `documentdb-tune` and `documentdb-register-gateway`, so it cannot function without it. The exact-match constraint on `documentdb-gateway` is intentional: the stand-alone setup wizard, its bundled `gateway-local@N.service` template, and the gateway runtime are validated together against one version, so they release in lockstep. The extension and tools packages keep a `>=` floor because they can move ahead under independent point releases without breaking the stand-alone wrapper.

**Owned paths (per-major):**

| Path | Purpose |
|---|---|
| `/var/lib/documentdb-local/N/data` | PG data directory for major N (initdb here). |
| `/var/lib/documentdb-local/N/gateway` | Gateway working dir (TLS state) for major N. Also persistent location of the connection-URL file `pg-url` (`root:documentdb-gateway` `0640`) — see §4.3. |
| `/var/lib/documentdb-local/N/backups` | Stand-alone-package rollback records for the private per-major flow. |
| `/run/documentdb-local/N/postgresql` | Unix socket directory for major N. |
| `/var/log/documentdb-local/N` | Logs for major N. |
| `/etc/documentdb/local/N/setup.conf` | Per-major remembered greenfield setup config. Drives the per-major env file (`/etc/documentdb/local/N/gateway.env`) loaded by `documentdb-gateway-local@N.service`; the global `/etc/documentdb/gateway/gateway.env` is the Workflow B single-instance path. `documentdb-postgresql@N.service` activates only when this file exists (via `ConditionPathExists`). |
| `/etc/documentdb/local/N/brownfield.conf` | Per-major remembered brownfield setup state, written under a different filename from `setup.conf` so the templated greenfield PG service does not activate against an adopted system PostgreSQL instance. Drives the `--restore` path and the brownfield gateway drop-in (see below). |
| `/etc/systemd/system/documentdb-gateway-local@N.service.d/brownfield.conf` | Wizard-managed systemd drop-in written only in brownfield mode. Resets the unit's greenfield `Requires=`/`After=` and re-points them at the adopted PostgreSQL service unit (`postgresql@N-C.service` on Debian/Ubuntu or `postgresql-N.service` on RHEL) so boot ordering for `documentdb-local@N.target` is correct without the greenfield template needing to activate. Removed by `documentdb-setup --restore` and by the `documentdb-N` postrm / %postun. |

**Two OS users** (shared across majors):
- `documentdb-local` is both the OS user that owns the stand-alone PostgreSQL data directory and the PostgreSQL superuser created by `initdb --username=documentdb-local`; the names intentionally match so peer auth on the private socket maps the OS user 1:1 to the DB superuser.
- `documentdb-gateway` runs the gateway (created by the gateway package).

Per-major isolation lives in data/state/socket paths and systemd template instances, not in OS users.

Log rotation for `/var/log/documentdb-local/N` is a packaging detail that should be handled with distro-appropriate defaults when the stand-alone package is implemented; this Track 1 design does not define a bespoke rotation policy.

Private stand-alone PostgreSQL instances are intentionally outside `postgresql-common`'s cluster discovery model. `pg_lsclusters`, `pg_upgradecluster`, `pg_renamecluster`, and `sudo -u postgres psql` do not manage or connect to `/var/lib/documentdb-local/N/data`; administrators use `systemctl status documentdb-local.target` (or `documentdb-local@N.target`) and the DocumentDB tooling instead. Brownfield PostgreSQL instances adopted from the system PostgreSQL packages keep their existing discovery and ownership model.

#### Security model: peer auth + ident map

The gateway connects to PostgreSQL via Unix socket. Peer auth identifies it by its OS user name; a narrow `pg_ident.conf` map controls which DB roles that OS user is allowed to assume:

| Map name | OS user (from peer auth) | Allowed DB role |
|---|---|---|
| `documentdb-gateway-map` | `documentdb-gateway` | `documentdb-gateway` (the role created by `documentdb-register-gateway`, matching the OS user name) |
| `documentdb-gateway-map` | `documentdb-gateway` | `+documentdb_admin_role` (any role member of the admin group, created by `CREATE EXTENSION`) |
| `documentdb-gateway-map` | `documentdb-gateway` | `+documentdb_readwrite_role` |
| `documentdb-gateway-map` | `documentdb-gateway` | `+documentdb_readonly_role` |
| `documentdb-gateway-map` | `documentdb-local` | `+documentdb_admin_role` (wizard bootstrap path — see below) |
| `documentdb-gateway-map` | `documentdb-local` | `+documentdb_readwrite_role` |
| `documentdb-gateway-map` | `documentdb-local` | `+documentdb_readonly_role` |

The first four entries cover the gateway runtime path (the `documentdb-gateway` OS user assumes a documentdb role group when serving wire-protocol clients). The next three cover the **wizard bootstrap path**: `documentdb-setup` runs as root and downgrades to the `documentdb-local` OS user via `runuser` to invoke `psql` for steps like `CREATE EXTENSION` and the first-admin-user bootstrap. Those steps need to assume `+documentdb_admin_role` over peer auth on the same Unix socket, so the wizard's OS identity gets the same ident-map entries (without `documentdb-gateway`'s direct-role grant — only the group memberships, because `documentdb-local` is already the PG superuser and never needs to assume the gateway runtime role).

This means the gateway's runtime PostgreSQL access is managed by **OS identity + local PostgreSQL auth rules**, not by storing a PostgreSQL password for the gateway in the package-managed config. The separate admin password file used by `documentdb-setup` is only for bootstrapping the first DocumentDB login for clients such as `mongosh`.

The leading `+` means "any role that is a member of this group" ([Postgres docs](https://www.postgresql.org/docs/current/auth-username-maps.html)). This is the trust boundary: the gateway can assume any role in the documentdb role groups, but cannot become `postgres`, the PostgreSQL instance owner, or any application role. **`SUPERUSER` is never granted to DocumentDB users.**

#### Default ports

- **PostgreSQL:** assigned per major (15 → 9715, 16 → 9716, 17 → 9717, 18 → 9718, 19 → 9719) so the assignment is predictable and stable regardless of install order. Private stand-alone PostgreSQL instances never bind to port 5432, even when no system PostgreSQL is running; this guarantees no collision with unrelated PostgreSQL services on the host. Override via `documentdb-setup --pg-port` to another non-5432 port.
- **Gateway:** the paved-road gateway (`documentdb-18`) listens on 10260 (the public port). This is the only automatically configured public gateway port. In advanced multi-major setups, each additional stand-alone install has one gateway tied to its PostgreSQL instance, and the administrator must choose a unique public listen port (for example 10261, 10262, …) with `documentdb-setup --listen-port`; packages do not dynamically allocate or switch ports.

Port 10260 is the default everywhere to avoid colliding with an existing service on the standard wire-protocol port. Administrators who want that standard port can set `--listen-port 27017` (or `DOCUMENTDB_LISTEN_ADDR=:27017`) explicitly.

**Conflict handling is explicit, not automatic.** If the requested public gateway port is already in use — by another DocumentDB gateway, an existing service on 10260, or a service already bound to 27017 or any other chosen port — the setup/start step fails with a clear "address already in use" style error and tells the administrator to choose another port. The packages do **not** auto-increment, auto-steal, or silently rewrite an existing gateway to a new port, because that would make client connection strings unstable.

So the resolution path is:

1. **Paved-road / stand-alone flow:** keep 10260 for the primary instance. For any additional stand-alone instance, rerun setup with an explicit override such as `documentdb-setup --listen-port 10261`.
2. **BYO gateway flow (Workflow B):** set a unique listen address in `/etc/documentdb/gateway/gateway.env` (for example `DOCUMENTDB_LISTEN_ADDR=:10261`) before starting the service.
3. **If the administrator wants 27017:** that remains an explicit opt-in, and the same conflict rule applies — if 27017 is already occupied, setup/service start fails and the administrator must pick another port.

#### Systemd: per-major template + public alias

For the stand-alone package, each major has its own templated unit instance shipped by `documentdb-N`:

- `documentdb-local@N.target` — composite target for major N.
- `documentdb-postgresql@N.service` — private PG instance for major N in greenfield mode.
- `documentdb-gateway-local@N.service` — stand-alone gateway instance for major N.

In greenfield/private-PG mode, the PG service and gateway service are `PartOf=` the per-major target — they stop and restart together when the administrator acts on the target. In brownfield/adopted-PG mode, the adopted PostgreSQL service remains outside the stand-alone target and keeps its existing administrator-owned lifecycle; the stand-alone target only owns the local gateway side and orders it after the adopted PostgreSQL service. Stopping `documentdb-local@N.target` in brownfield mode must therefore not stop the system PostgreSQL service. The plain `documentdb-gateway.service` from the `documentdb-gateway` runtime package remains the Workflow B surface; `documentdb-gateway-local@N.service` is the stand-alone-only template.

**Brownfield drop-in mechanism (normative).** Because `Requires=`/`After=` in the shipped `documentdb-gateway-local@N.service` template are wired to the greenfield `documentdb-postgresql@%i.service` (which is gated by `ConditionPathExists=/etc/documentdb/local/%i/setup.conf` and therefore inactive in brownfield mode), brownfield needs a runtime override so the gateway is correctly ordered after the **adopted** PostgreSQL service. `documentdb-setup` writes a per-instance systemd drop-in at `/etc/systemd/system/documentdb-gateway-local@N.service.d/brownfield.conf` that:

1. **Resets** the templated `Requires=`/`After=` (with `Requires=` followed by the empty value to drop the previous list, then a new line pointing at the adopted unit).
2. **Re-points** boot ordering at the adopted PostgreSQL service unit — `postgresql@N-C.service` on Debian/Ubuntu, or `postgresql-N.service` on RHEL/Fedora.

The drop-in is owned by the wizard: written by `documentdb-setup` apply, removed by `documentdb-setup --restore`, and removed by the `documentdb-N` postrm / `%postun`. This keeps the shipped template file purely greenfield (no brownfield knowledge baked into the package-owned unit file) while still giving brownfield correct boot-time ordering. The same per-instance drop-in approach is reused if `documentdb-gateway-local@N.service` later needs other instance-specific overrides (TLS state dir, alternate working directory, etc.) without forking the template.

**Aliasing the public target.** Because systemd's native `Alias=` does not support template instances, the paved-road `documentdb-local.target` is implemented as a thin wrapper unit shipped by the `documentdb` meta package: the wrapper has `Requires=documentdb-local@18.target` + `After=…`, and a reverse `PartOf=` drop-in on `documentdb-local@18.target` propagates `stop`/`restart` from the wrapper to the per-major target. Day-2 commands (`enable`, `start`, `stop`, `restart`, `status`) on `documentdb-local.target` therefore behave identically to acting on `documentdb-local@18.target` directly.

The administrator controls a specific greenfield stand-alone stack with one verb:

```bash
sudo systemctl enable --now documentdb-local@N.target     # start the stand-alone stack for major N
sudo systemctl status documentdb-local@N.target           # see both services for major N
sudo systemctl restart documentdb-local@N.target          # ordered restart
sudo systemctl stop documentdb-local@N.target             # stop both
```

For the paved-road major, a top-level `documentdb-local.target` symlink (systemd alias) points at `documentdb-local@18.target` in first-party packages — so `systemctl enable --now documentdb-local.target` Just Works for the common single-major greenfield case. Advanced multi-major administrators act on `documentdb-local@N.target` directly. **`documentdb-local.target` is the public day-2 surface for the stand-alone package.**

#### `documentdb-setup` (the stand-alone package's setup wizard)

`documentdb-setup` is the single orchestration command administrators use after `apt install documentdb`. It handles greenfield (create a fresh private DocumentDB instance with its own underlying PostgreSQL instance) and brownfield (create a DocumentDB instance by adopting an existing PostgreSQL instance, with consent prompts) in the same flow.

Key flags (matches `documentdb-setup --help`):
- Targeting: `--use-new-postgres-instance` (force greenfield by creating a new backing PostgreSQL instance; deprecated alias `--use-private-cluster`), `--target-postgres-instance V/C` (build the DocumentDB instance on top of a specific Debian/RHEL PostgreSQL instance, named by the distro's existing identifier such as `18/main`; deprecated alias `--target-cluster`), `--data-dir DIR` (per-major default `/var/lib/documentdb-local/N/data`), `--pg-port N`, `--pg-version N`.
- Bootstrap: `--listen-port N` (alias `--gateway-port`), `--admin-user NAME` (alias `--username`). The first admin password can be supplied via `--admin-password-file FILE` (alias `--password-file`) for scripted installs, piped on stdin via `--admin-password-stdin`, or — in the typical interactive case — entered at a terminal prompt. The legacy `DOCUMENTDB_PASSWORD` env-var form is still accepted for compatibility but is **deprecated** (it leaks via `/proc/<pid>/environ`); use one of the three forms above instead. TLS for the gateway is configured via `--tls-cert FILE` / `--tls-key FILE` / `--tls-auto-generate {true|false}` on the wizard, which threads them through to the per-major `gateway.env` so the runtime gateway picks them up via `DOCUMENTDB_TLS_CERT_FILE` / `DOCUMENTDB_TLS_KEY_FILE` / `DOCUMENTDB_TLS_AUTO_GENERATE` (single source of truth whether the gateway was set up by `documentdb-setup` or `documentdb-register-gateway`).
- Behavior: `--yes` (non-interactive for CI), `--dry-run` (preview every invasive step the wizard would take, no side effects), `--verbose`.
- Lifecycle (read-only operational queries): `--print-config` (report the resolved per-major paths, ports, and templated systemd units the wizard would use; no side effects), `--status` (report the current per-major installation state — PG service / gateway service / listening port / state-file presence; exit 0 if a healthy install is found).
- Lifecycle (mutating): `--restore` (remove package-managed integration only; does not delete PostgreSQL data; `apt purge documentdb-N` triggers the same restore flow non-interactively), `--load-sample-data` / `--skip-init-data` (control built-in sample-data ingest after first install, requires `mongosh`), `--no-enable` (apply config but do not start the gateway service or enable `documentdb-local.target` at boot).

By default the wizard ends with `systemctl enable --now documentdb-local.target` (or `documentdb-local@N.target` for non-paved-road majors) as part of its own apply path, so the operator does not need to run a separate enable command. Pass `--no-enable` to defer this — the wizard then writes all config and stops just before the enable step, printing the exact command to run when ready.

The bootstrap flags are a stand-alone-package convenience: when requested, `documentdb-setup` bootstraps the first admin user through the extension-side user-management API after the extension and gateway integration are in place. In the normal interactive path, `documentdb-setup` can prompt for that first user password directly on the terminal. `--admin-password-file` is the automation / CI form, not a requirement for ordinary installs. That bootstrap is intentionally above the `documentdb-gateway` package boundary.

Terminology in this design is intentional: a **DocumentDB instance** is the product-facing unit — one gateway paired with one underlying PostgreSQL instance. When the doc says **PostgreSQL instance**, it specifically means that underlying server/config surface. The setup flags therefore use PostgreSQL-oriented naming when the administrator is selecting that backing server directly: `--use-new-postgres-instance` provisions a new backing PostgreSQL instance, and `--target-postgres-instance` points at an existing one using the distro's existing identifier (for example `18/main` on Debian/Ubuntu). Lower-level PostgreSQL-side helpers keep the same convention: `documentdb-tune` keeps `--cluster` because it intentionally follows the established Debian/Ubuntu `pg_createcluster` / `pg_lsclusters` naming, while `documentdb-register-gateway` uses `--target-postgres-instance`.

For each invasive step (write `postgresql.conf` managed block, write `pg_hba.conf`, write `pg_ident.conf`, restart or reload PG, run `CREATE EXTENSION`, optionally bootstrap the first admin user through the extension-side user API), `documentdb-setup` itself prompts the administrator with a description and offers `[y/N/dry-run]`, then invokes the appropriate sub-tool (`documentdb-tune` or `documentdb-register-gateway`) or extension-side bootstrap step non-interactively to do the actual work. For system PostgreSQL instances, the tools print the required `systemctl restart` or `systemctl reload` command and the administrator runs it. For private stand-alone PostgreSQL instances, `documentdb-setup --yes` may restart or reload `documentdb-postgresql@N.service` directly because that service is owned by the stand-alone package. In the private stand-alone flow, package-managed rollback records live under `/var/lib/documentdb-local/N/backups/<timestamp>/`; lower-level PostgreSQL tools that edit an existing instance directly may also create adjacent `*.documentdb-backup.<timestamp>` files beside the config they touched. In both cases, `--restore` and package purge remove package-managed integration while leaving PostgreSQL data directories, extension state, users, and application data intact.

So `documentdb-setup` owns the administrator UX — the consent prompts, the dry-run preview, the rollback plan — while the sub-tools do the file edits. Administrators do not need to know or run the sub-tools directly.

**Safety properties:**
- Always write a timestamped backup before any file change.
- Refuse to mutate any config file containing **foreign** managed-block markers (markers from another tool we don't recognize). Print conflict, exit non-zero.
- Warn loudly when adopting a `postgres`-owned PostgreSQL instance (vs. an empty one we'd init ourselves), explain implications, require confirmation. Don't refuse — the user installed `documentdb`; that's the consent.
- `--restore` strips every managed block ever written across all PostgreSQL instances touched and removes package-managed service wiring/connection files, but does **not** delete PostgreSQL data directories, extension state, roles, users, or application data.
- `apt purge documentdb-N` invokes the same non-destructive restore via inline shell in `postrm`.

---

## 5. User workflows

Three install paths. **Workflow C (the stand-alone package) is the recommended default** for new users — a few commands, no packaging decisions to make. Workflows A and B are advanced paths for users with specific needs.

```mermaid
graph LR
    Q[I want DocumentDB]
    Q -->|just make it work| C[Workflow C: stand-alone]
    Q -->|extension only into my own PG| A[Workflow A: extension only]
    Q -->|wire-protocol gateway on my existing local PG| B[Workflow B: gateway + BYO PG]

    style C fill:#dfd,stroke:#363
```

If you're not sure which to pick, pick **C**. The stand-alone package handles everything; you can move to A or B later if your needs change.

`documentdb-postgresql-tools` is the explicit way to make an administrator-managed PostgreSQL instance DocumentDB-ready. Use `documentdb-tune` for an existing PostgreSQL instance, or `documentdb-createcluster` when creating a fresh Debian/Ubuntu PostgreSQL instance.

The concrete command examples below are Debian/Ubuntu-shaped where that makes the instance identifiers explicit (`--cluster main`, `18/main`). For RPM-family community packaging, treat those identifiers as high-level equivalents rather than a normative CLI syntax in this Track 1 doc.

`--restore` scope differs by tool:
- `documentdb-tune --restore` removes only the managed PostgreSQL tuning/config fragments.
- `documentdb-register-gateway --restore` removes only the managed gateway registration wiring for a PostgreSQL instance.
- `documentdb-setup --restore` removes the stand-alone wrapper's package-managed integration across the surfaces it orchestrated.

### Conventions used in the examples

**Default port: 10260.** All three workflows use port `10260` in the single-instance examples for the DocumentDB endpoint to avoid colliding with another service already using the standard wire-protocol port on the same host. Override with `DOCUMENTDB_LISTEN_ADDR=:27017` for that standard port. If that chosen port is already occupied, setup/start fails and the administrator must choose another explicit port; the tooling never auto-reassigns ports behind the user's back.

**Interactive prompt vs. password file.** The first admin password is for the **DocumentDB login being created for clients**, not for the gateway's own PostgreSQL connection. In an ordinary interactive install, `documentdb-setup` can just prompt for that password on the terminal. `--admin-password-file` is the non-interactive / automation form and is mainly useful for CI, scripted installs, or repeated local testing. Most examples below use the interactive path. Only use a password file for non-interactive examples such as CI or scripted installs:

```bash
# One-time: prepare the admin password file (interactive entry, no shell-history leak)
read -s -p "DocumentDB admin password: " PWFILE_CONTENT
PWFILE=$(mktemp) && chmod 600 "$PWFILE" && printf '%s' "$PWFILE_CONTENT" > "$PWFILE"
unset PWFILE_CONTENT
# After install: rm -f "$PWFILE"
```

If you choose to use `$PWFILE` in automation, it should contain the admin password and be mode `0600`.

**TLS in the connection string.** `tlsAllowInvalidCertificates=true` is correct for the gateway's auto-generated self-signed cert. For production, supply your own cert via `DOCUMENTDB_TLS_CERT_FILE`/`DOCUMENTDB_TLS_KEY_FILE` and drop the flag.

---

### Workflow C — Full stand-alone install (`apt install documentdb`) **[recommended default]**

**When to use:** the default path. Anyone who wants `apt install` → working DocumentDB in a few commands. In greenfield mode, the stand-alone package creates and owns a private underlying PostgreSQL instance. In brownfield mode, it layers a DocumentDB instance on top of an existing PostgreSQL instance, with consent prompts before each invasive change. Most users should pick this.

> ⚠ **PostgreSQL repository prerequisite (Debian/Ubuntu).** `documentdb` depends on `postgresql-18` (and matching `postgresql-18-cron` / `-pgvector` / `-postgis-3`) which is **not** in Ubuntu 24.04's default apt sources. Enable the PGDG repo first:
> ```bash
> sudo apt-get install -y curl ca-certificates gnupg lsb-release
> sudo install -d /usr/share/postgresql-common/pgdg
> curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
>   | sudo gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
> echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
>   | sudo tee /etc/apt/sources.list.d/pgdg.list
> sudo apt-get update
> ```
> On RHEL/Fedora the equivalent PGDG repo enablement is documented at <https://www.postgresql.org/download/linux/redhat/>. Minimal Rocky/Alma 9 hosts also need the **CRB** (CodeReady Builder) and **EPEL** repositories enabled because `postgis36_18` (a PGDG dep of the extension RPM) pulls in `hdf5` and `xerces-c` from there:
> ```bash
> sudo dnf install -y dnf-plugins-core
> sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
> sudo dnf -qy module disable postgresql
> sudo dnf config-manager --set-enabled crb
> sudo dnf install -y epel-release
> ```

```bash
# (1) Install the meta package (pulls in the stand-alone package + gateway + tools)
sudo apt install documentdb

# (2) Run the setup wizard — single command. The wizard prompts interactively
# for the first admin password, runs initdb / CREATE EXTENSION / first-user
# bootstrap, AND enables documentdb-local.target so the stack survives reboot.
# After this returns successfully the gateway is already running and the
# target is already enabled at boot — there is no separate "now enable the
# target" step.
sudo documentdb-setup --admin-user admin

# (3) Connect — the --eval round-trips a ping to prove it works
mongosh 'mongodb://admin@127.0.0.1:10260/mydb?tls=true&tlsAllowInvalidCertificates=true' \
        --eval 'db.runCommand({ping: 1})'

# Day-2:
#   sudo systemctl status  documentdb-local.target    # current state
#   sudo systemctl restart documentdb-local.target    # ordered restart of gateway + private PG
#   sudo systemctl stop    documentdb-local.target    # graceful stop of both
#   sudo documentdb-setup --restore                   # detach package-managed integration
```

`documentdb-setup` walks the administrator through either selecting an existing PostgreSQL instance or creating a fresh private one, then turns that into a managed DocumentDB instance with backup-and-rollback safety around each config-file modification. The command sequence above shows the default greenfield/private-PostgreSQL path; brownfield is selected by passing `--target-postgres-instance N/cluster` (Debian-style `pg_lsclusters` identifier) so the wizard adopts an existing PostgreSQL service instead of creating a private one. Future revisions of the wizard may add an interactive prompt that detects an existing PostgreSQL service and offers the brownfield path without the explicit flag; for Track 1 the flag-driven selection is the documented contract.

Pass `--no-enable` if you want to defer the `systemctl enable --now documentdb-local.target` step (for example to inspect state before bringing the stack up). Without `--no-enable`, the wizard owns the full apply-then-enable path so the operator never has to remember a second command.

**What you get:** a full DocumentDB instance with the integration and gateway wiring managed by the stand-alone package. In greenfield mode, day-2 lifecycle is `systemctl <verb> documentdb-local.target` (or `documentdb-local@N.target` for a specific major when multiple are installed) because the package also owns the private PostgreSQL service. In brownfield mode, the stand-alone package still manages the DocumentDB integration and local gateway wiring, while the adopted PostgreSQL service remains under the administrator's existing lifecycle.

**What you don't get:** in greenfield mode, independent control over the private underlying PostgreSQL instance. In brownfield mode, you keep control of the adopted PostgreSQL service, but the stand-alone wrapper still owns the DocumentDB integration it layered on top. Use Workflow A or B if you want to manage those pieces separately end-to-end.

---

### Workflow A — Install the extension into a managed PostgreSQL instance *(advanced)*

**Primary intent:** install the `documentdb` extension into a PostgreSQL instance the administrator manages. This is for users whose primary interest is the extension itself — for example, ops/migration tooling, or as preparation for layering the gateway on top in Workflow B. The same install steps happen inside Workflow C; the stand-alone package just bundles them.

**Precondition:** PostgreSQL major N is already installed via the PGDG apt repo or your distro's package set. The examples below use **PostgreSQL 18** because that is the paved-road major; replace `18` with your target PG major when using community-built packages for another major.

**The next steps the administrator runs:**

```bash
# (1) Install the package
sudo apt install postgresql-18-documentdb

# (2) Materialize the managed DocumentDB config fragment
sudo apt install documentdb-postgresql-tools                        # ships documentdb-tune
sudo documentdb-tune --pg-version 18 --cluster main --dry-run       # preview
sudo documentdb-tune --pg-version 18 --cluster main --yes
sudo systemctl restart postgresql@18-main

# (3) Create the extension in the `postgres` database (the tune fragment
# pins cron.database_name='postgres', so pg_cron — pulled in via CASCADE —
# only allows extension creation there). If you need a custom DB name,
# either override cron.database_name in the per-instance documentdb.conf
# fragment before restart, OR keep the DocumentDB metadata in `postgres`
# and create your application data DBs separately.
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 \
        -c 'CREATE EXTENSION documentdb CASCADE;'

# (4) Verify
sudo -u postgres psql -d postgres -c '\dx documentdb*'
# Should list: documentdb, documentdb_core, plus dependencies (pg_cron, pgvector, postgis, ...)
```

**Even simpler on Debian/Ubuntu when starting from scratch:**

```bash
sudo apt install postgresql-18-documentdb
sudo apt install documentdb-postgresql-tools
sudo documentdb-createcluster 18 main --start
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 \
        -c 'CREATE EXTENSION documentdb CASCADE;'
```

`documentdb-createcluster` wraps `pg_createcluster` and `documentdb-tune`, so the PostgreSQL instance is created and the per-instance `documentdb.conf` fragment is written in one step. On Debian/Ubuntu the instance config stays under `/etc/postgresql/18/main/`, while the managed fragment lives at `/etc/postgresql-common/documentdb/18/main/documentdb.conf`. When `--start` is requested, the wrapper tunes the instance before starting it.

After verification the administrator has three options:

- **Stop here** — extension is available for ops/migration scripts via SQL.
- **Add the wire-protocol gateway** — continue with Workflow B.
- **Switch to the stand-alone package** — `apt install documentdb && sudo documentdb-setup` will detect the existing PostgreSQL instance (with the extension already loaded) and offer to use it; the wizard is brownfield-aware.

---

### Workflow B — Extension + gateway (BYO local PG with passwordless local auth) *(advanced)*

> ⚠ **The documented Workflow B path uses PostgreSQL on the same host with passwordless local authentication for the gateway OS user. `documentdb-register-gateway` writes a peer + ident-map block in `pg_hba.conf`; if the administrator's pre-existing config already grants trust for the same Unix socket, that satisfies the precondition as well. Cloud-managed or other remote TCP/password PostgreSQL backends are a Track 2 topic, not a supported/documented Track 1 flow.** See §2 and [§11.1](#111-track-2--gateway-byo-refactor-for-cloud--remote-postgresql). If you don't have local PG with passwordless auth available, use Workflow C instead.

**When to use:** a power user with a local PostgreSQL instance who wants a DocumentDB instance on top of it, without the stand-alone package taking ownership of the underlying PostgreSQL instance lifecycle.

**Precondition:** PostgreSQL major N is already installed via the PGDG apt repo or your distro's package set, configured to allow passwordless local connections (peer or trust auth in `pg_hba.conf`) for the gateway's OS user. The examples below use **PostgreSQL 18** because that is the paved-road major; replace `18` with your target PG major when using community-built packages for another major.

**Track 1 assumption:** one managed local gateway per target PostgreSQL instance. If you want multiple gateways against the same PostgreSQL instance, this design does not define package-managed role / `pg_hba.conf` / connection-file ownership for that topology; treat it as manual / deferred work.

```bash
# (1) Install both packages
sudo apt install postgresql-18-documentdb documentdb-gateway

# Optional: if you need a non-default public port, TLS paths, or state directory,
# copy the sample once and edit /etc/documentdb/gateway/gateway.env before start.
# sudo install -D -m 0640 /usr/share/doc/documentdb-gateway/examples/gateway.env.sample /etc/documentdb/gateway/gateway.env
# sudoedit /etc/documentdb/gateway/gateway.env

# (2) Apply PostgreSQL settings
sudo apt install documentdb-postgresql-tools
sudo documentdb-tune --pg-version 18 --cluster main --yes
sudo systemctl restart postgresql@18-main
sudo -u postgres psql -d postgres -c 'CREATE EXTENSION documentdb CASCADE;'

# (3) One-shot PostgreSQL-side gateway registration against the local PostgreSQL instance.
# Auto-detects when there is exactly one PostgreSQL instance on the host (typical case).
sudo documentdb-register-gateway --yes
sudo systemctl reload postgresql@18-main

# When you have multiple PostgreSQL instances, name the backing PostgreSQL instance explicitly:
#   sudo documentdb-register-gateway --target-postgres-instance 18/main --yes

# (4) Validate the configured connection before starting the service
sudo -u documentdb-gateway documentdb-gateway --check

# (5) Start
sudo systemctl enable --now documentdb-gateway

# (6) Bootstrap the first admin user through the extension-side user-management API.
# This non-interactive example reuses $PWFILE from the conventions section above.
# $PWFILE is mode 0600 owned by the invoking user, so the password is read in
# the invoking shell with $(cat ...) and handed to psql via -v; this avoids
# making PWFILE itself readable by the postgres user. The password appears
# briefly in psql's argv (visible to root and the postgres user via ps for the
# lifetime of the process), which is acceptable for this scripted bootstrap.
# Run this against the same database where CREATE EXTENSION was executed (postgres here).
sudo -u postgres psql -d postgres -X -v ON_ERROR_STOP=1 \
    -v admin_password="$(sudo cat "$PWFILE")" <<'SQL'
SELECT documentdb_api.create_user(
  jsonb_build_object(
    'createUser', 'admin',
    'pwd', :'admin_password',
    'roles', jsonb_build_array(
      jsonb_build_object('role', 'readWriteAnyDatabase', 'db', 'admin'),
      jsonb_build_object('role', 'clusterAdmin', 'db', 'admin')
    ),
    '$db', 'admin'
  )::text::documentdb_core.bson
);
SQL

# (7) Connect
mongosh 'mongodb://admin@127.0.0.1:10260/?tls=true&tlsAllowInvalidCertificates=true' \
        --eval 'db.runCommand({ping: 1})'
```

`documentdb-register-gateway` is a one-shot command that, against the targeted existing PostgreSQL instance:
- Creates a PG role matching the gateway's OS user (or reuses if present).
- Writes a managed block to `pg_hba.conf` (peer auth with named ident map).
- Writes a managed block to `pg_ident.conf` mapping the gateway OS user to the documentdb role groups.
- Prints the required PostgreSQL reload command for system PostgreSQL instances; PostgreSQL instances owned by the stand-alone package may be reloaded by `documentdb-setup --yes`.
- Writes the gateway's connection URL file (mode `0640`, owner `root:documentdb-gateway`).
- Requires the `documentdb-gateway` runtime package to already be installed; otherwise it exits with a clear prerequisite error.
- Records package-managed integration so `documentdb-register-gateway --restore` (and `documentdb-setup --restore` when using the stand-alone wrapper) can detach the local gateway wiring cleanly without deleting PostgreSQL data directories or in-database contents.

Without `--yes`, the command is interactive: it shows what it will change and prompts before each invasive step. `--dry-run` previews all changes without writing.

The PostgreSQL instance's `postgresql.conf` is **not** modified by `documentdb-register-gateway` — that's `documentdb-tune`'s job. The two tools compose: `documentdb-tune` handles `postgresql.conf`; `documentdb-register-gateway` handles `pg_hba.conf`/`pg_ident.conf` plus the role and connection file. First-user bootstrap intentionally stays outside the gateway package so headless and gateway-backed deployments can use the same extension-side user-management model.

**What you get:** a DocumentDB instance backed by your chosen PostgreSQL instance, with the wire protocol, full SCRAM authentication, and the same gateway capabilities the stand-alone package provides.

**What you don't get:** a first-party documented/tested path for a remote or password-authenticated PostgreSQL backend; that capability is deferred to Track 2. You also do not get stand-alone-package-managed DocumentDB instance lifecycle (use Workflow C if you want that).

---

### After any workflow

The `mongosh` examples above omit `--password`, so `mongosh` prompts on stdin instead of exposing the password in shell history or the process list. For one-off trusted-host smoke tests, administrators may construct a short-lived URI from `$PWFILE`, but any password placed on a command line is visible through tools such as `ps` for the lifetime of the process and is not a production monitoring pattern.

If you used a password file for a non-interactive example, don't forget to remove it:

```bash
rm -f "$PWFILE"
```

### Workflows NOT in this release

- **Docker evaluation** — the existing `ghcr.io/documentdb/documentdb/documentdb-local:latest` image keeps building from existing CI; this design does not modify it. Refactored, layered Docker images are deferred.
- **Cloud / remote PG over TCP/password as a supported/documented workflow** — Track 2.
- **Production two-container compose** — same blocker as above. Track 2 + Docker work.

---

## 6. Behavior matrix

The bolded cells are the only places `postgresql.conf`, `pg_hba.conf`, or `pg_ident.conf` are modified on the forward path. All happen only on explicit administrator invocation, never on package install. The reverse path (`apt purge documentdb-N` / `dnf erase`) runs the same `--restore` logic from the package's `postrm` / `%postun`, removing managed blocks and managed fragments without deleting PostgreSQL data; this is the only non-CLI-driven config rollback in the design.

| Action | `postgresql-N-documentdb` install | `documentdb-gateway` install | `documentdb-N` install | `documentdb-tune` | `documentdb-register-gateway` | `documentdb-setup` |
|---|---|---|---|---|---|---|
| Install extension files | Yes | No | Via dep | No | No | No |
| Install gateway binary | No | Yes | Via dep | No | No | No |
| Create OS service user | No | Yes (sysusers.d, eager) | Yes (sysusers.d, eager) | No | No | Ensure/reuse |
| Create gateway PG role | No | No | No | No | Yes | Delegates to `register-gateway` |
| `initdb` | No | No | No | No | No | Yes (greenfield mode) |
| Edit `postgresql.conf` | No | No | No | **Yes (managed fragment preferred; managed block as fallback)** | No | Delegates to `tune` |
| Edit `pg_hba.conf` | No | No | No | No | **Yes (managed block)** | Delegates to `register-gateway` |
| Edit `pg_ident.conf` | No | No | No | No | **Yes (managed block)** | Delegates to `register-gateway` |
| Run `CREATE EXTENSION` | No | No | No | No | No | Yes |
| Bootstrap first admin user | No | No | No | No | No | Optional convenience via extension-side user API |
| Auto-start service on install | No | No | No | No | No | No (administrator runs `systemctl enable --now documentdb-local.target` after setup completes) |
| Restart active gateway service on upgrade | N/A | Yes | Yes (gateway side only) | N/A | N/A | N/A |
| Preserve PG data on remove/purge | Yes | Yes | Yes | N/A | N/A | N/A |
| Reversible | N/A | N/A | N/A | Yes (managed config only) | Yes (managed gateway integration only; DB contents preserved) | Yes (package-managed integration only; DB contents preserved) |

---

## 7. Security posture

| Concern | Decision |
|---|---|
| Postinst modifies PostgreSQL instance config | **Never.** Only `documentdb-tune`, `documentdb-register-gateway`, and `documentdb-setup` do, only when explicitly invoked. |
| Postinst auto-runs setup wizards | **Never.** Debian and RPM both. |
| Maintainer scripts restart PostgreSQL | **Never.** A maintainer script restarting PG would be a surprising side effect under unattended upgrades or scripted CI. |
| CLI tools restart/reload PostgreSQL | For system PostgreSQL instances (`postgresql@N-main.service` on Debian/Ubuntu, `postgresql-N.service` on RHEL), `documentdb-tune --yes` and `documentdb-register-gateway --yes` apply file changes and print the required `systemctl restart` or `systemctl reload` command; they never invoke it. For private stand-alone PostgreSQL instances (`documentdb-postgresql@N.service`), `documentdb-setup --yes` and the `documentdb-local@N.target` day-2 lifecycle may restart or reload the service because the stand-alone package owns it. Interactive defaults remain **no**. |
| Interactive prompts in maintainer scripts (`debconf` etc.) | **Never used.** Maintainer scripts are non-interactive on both Debian and RPM by policy. All consent for invasive operations lives in administrator-invoked CLIs. Rationale: preserves one packaging contract across first-party and community builds, and matches what major PostgreSQL extensions do (Citus, TimescaleDB, pg_cron, pgvector). See §9. |
| OS users created at install | Yes, via `sysusers.d`, narrow scope, no shell, no home, created at package-install time (not lazily on first service start). |
| Gateway runs as root | **Never.** `User=documentdb-gateway`, sandboxed. |
| Connection-file ownership | **`root:documentdb-gateway` mode `0640`** — gateway reads, can't overwrite. |
| Passwords in env vars | **Rejected in Track 1.** The local PostgreSQL connection file is passwordless; password-bearing `*_FILE` connection settings are deferred to Track 2. |
| TLS cert auto-gen path | Configurable; gateway never writes certs to its current working directory. |
| `SUPERUSER` granted to DocumentDB users | **Never.** We use `documentdb_admin_role`. |
| Reversibility | `--restore` and `apt purge` remove package-managed integration and managed-block edits only; PostgreSQL data directories and in-database contents are preserved. |
| PostgreSQL instance modification safety | Always backed up before write; refuses to overwrite foreign managed-block markers; warns when adopting another OS user's PostgreSQL instance; `--dry-run` always available. |
| Compatibility check | Deferred for Track 1. The runtime does not currently enforce extension/gateway version compatibility; the previously-documented `DOCUMENTDB_STRICT_VERSION_CHECK` env var is intentionally not exposed. Will be reintroduced together with the actual compat-check implementation in a future revision. |
| Supply chain | GPG-signed apt repo for first-party packages; Fedora COPR for RPM-family community builds. |
| `Suggests:` not `Recommends:` from gateway to extension | Yes. |

---

## 8. Tool inventory

| Tool / unit | Lives in | Job |
|---|---|---|
| `documentdb-gateway` (systemd unit) | `documentdb-gateway` | The wire-protocol translation layer, packaged as a systemd unit and binary. |
| `documentdb-gateway --check` | `documentdb-gateway` | Connectivity probe; runs after `documentdb-register-gateway` (or `documentdb-setup`) has written the gateway's connection file and PostgreSQL-side wiring. |
| `documentdb-postgresql@N.service` | `documentdb-N` | Stand-alone private PostgreSQL service template for greenfield/per-major flows. |
| `documentdb-gateway-local@N.service` | `documentdb-N` | Stand-alone gateway service template paired with `documentdb-local@N.target`; brownfield keeps the adopted PostgreSQL service outside this unit's ownership boundary. |
| `documentdb-tune` | `documentdb-postgresql-tools` | Apply or remove the recommended DocumentDB config for one local PostgreSQL instance. On Debian/Ubuntu this writes `/etc/postgresql-common/documentdb/%v/%c/documentdb.conf` and ensures the instance `postgresql.conf` includes it. On distros with a config drop-in directory it writes `documentdb.conf` there; otherwise it falls back to a managed block in the target `postgresql.conf`. |
| `documentdb-createcluster N C` | `documentdb-postgresql-tools` | Debian/Ubuntu helper that wraps `pg_createcluster N C`, runs `documentdb-tune` for that specific PostgreSQL instance, then starts the instance if requested. |
| `documentdb-register-gateway` | `documentdb-postgresql-tools` | One-shot local gateway registration against an existing PostgreSQL instance (Workflow B). |
| `documentdb-gateway-admin` | `documentdb-postgresql-tools` | Administrator helper for ongoing user/role management against a DocumentDB-enabled PostgreSQL instance (`create-user`, `drop-user`, `list-users`, `reset-password`, `check`). Used by `documentdb-setup` and `documentdb-register-gateway` for the optional first-admin bootstrap; day-2 user management is normally done via the wire protocol but this CLI remains available for scripted scenarios where no admin connection is yet established. |
| `documentdb-setup` | `documentdb-N` | Stand-alone package setup wizard (delegates to `documentdb-tune` and `documentdb-register-gateway`). |
| `documentdb-local-reset` | `documentdb-N` | Destructive wipe of stand-alone-package-owned private PostgreSQL state (per-major); not for adopted brownfield PostgreSQL instances. |
| `documentdb-local.target` (systemd alias) | `documentdb` (meta/alias package) | Public day-2 lifecycle for the stand-alone package — first-party packages pin it to `documentdb-local@18.target`. **This is the public surface; use plain `systemctl`.** |
| `documentdb-local@N.target` (systemd template instance) | `documentdb-N` | Per-major day-2 lifecycle for advanced multi-major setups. |
| `/etc/postgresql-common/createcluster.d/99-documentdb.conf` | `documentdb-postgresql-tools` | Debian/Ubuntu hook that adds `include_if_exists = '/etc/postgresql-common/documentdb/%v/%c/documentdb.conf'` to newly-created PostgreSQL instances. Harmless until `documentdb-tune` creates the per-instance fragment. No equivalent on RHEL. |

We do **not** ship `documentdb-local-status`/`-start`/`-stop` — those are just `systemctl` aliases. The platform's primitives are the user interface.

---

## 9. Packaging ownership boundary

This section makes the scope boundary explicit: what the core project builds, hosts, tests, and documents itself versus what is intentionally left to community packagers.

### 9.1 First-party paved road

The core project owns one opinionated combination end to end:

- **Distro / repo:** Ubuntu 24.04 LTS via the project's hosted apt repository.
- **PostgreSQL major:** 18.
- **Meta package behavior:** `documentdb` is a fixed alias to `documentdb-18`.
- **Public lifecycle surface:** `documentdb-local.target` is a fixed alias to `documentdb-local@18.target`.
- **Install docs and validation:** our website, release validation, and smoke tests describe and verify this path first.

That is the contract we commit to keep simple and polished.

### 9.2 Community packaging boundary

Other permutations are intentionally outside the first-party support envelope, even though the package shape is designed to make them achievable:

- **RPM family (RHEL 9 / Fedora):** community-built and distributed through **Fedora COPR**.
- **Additional PostgreSQL majors beyond the paved-road default:** community packaging following **PGDG-style** per-major naming and layout conventions, but only for majors that the project still chooses to treat as active packaging targets outside this spec.
- **Advanced multi-major stand-alone installs:** supported by the package shape and documented as an advanced capability, but not the paved-road story and not the default website flow.

This design intentionally does **not** define the support lifetime for individual PostgreSQL majors. That policy is separate from packaging and is not yet defined in this repo. When a major ages out under that future policy, we stop treating it as an active packaging target here rather than carrying it indefinitely just because the package naming pattern makes it possible.

The project still constrains community packages to preserve the same behavioral contract:

1. Package install is non-interactive and file-only.
2. Administrator-invoked CLIs perform the invasive work.
3. The public day-2 systemd surface remains `documentdb-local.target` for the paved-road alias and `documentdb-local@N.target` for explicit per-major control.
4. Per-major package naming and paths stay aligned with PGDG conventions.

### 9.3 Distro-specific implications

Within that boundary, distro-specific differences are implementation details rather than product commitments:

- **Debian/Ubuntu:** `documentdb-postgresql-tools` may install the harmless `createcluster.d` include hook because `postgresql-common` provides one.
- **RHEL/Fedora:** there is no equivalent hook directory, so community RPM packagers rely on the PostgreSQL instance's existing config drop-in directory when present, and otherwise edit the selected PostgreSQL instance config only when the administrator invokes the relevant CLI.
- **All distros:** maintainer scripts remain non-interactive; they do not run setup wizards, prompt administrators, or restart PostgreSQL automatically.

The result is intentionally asymmetrical in ownership: one first-party paved road, with the rest of the matrix delegated to community packaging channels rather than treated as equal-scope release commitments.

---

## 10. Known limitations (by design)

The following behaviors are intentional design choices for Track 1, documented here so administrators know what to expect and reviewers can confirm the reasoning.

### 10.1 `documentdb` meta package pins PostgreSQL 18 on the paved road

The `documentdb` meta package depends on `documentdb-18`. On a host where only another PostgreSQL major is installed, `apt install documentdb` will pull in PostgreSQL 18 as a transitive dependency. This is intentional: the meta package is a convenience pointer to the paved-road default major, not a dynamic selector.

**Update semantics are intentionally conservative:**

1. `apt update` only refreshes package metadata; it does not install a new PostgreSQL major or change the active DocumentDB instance.
2. Routine package updates (`apt upgrade`, unattended-upgrades, etc.) are expected to stay within the already-installed per-major package set (`documentdb-18`, `postgresql-18-documentdb`, and matching dependencies). This design does **not** use a routine update of the `documentdb` meta package to silently switch an existing installation from PostgreSQL 18 to PostgreSQL 19.
3. If the project later decides that PostgreSQL 19 becomes the new paved-road default for **new installs**, that default change is a fresh-install / new-default decision, not an automatic in-place major upgrade story for existing `documentdb` users.
4. Existing installations that want to stay on their current major can keep updating the installed per-major packages normally. Existing installations that want to move to the next PostgreSQL major must do so explicitly by installing the new per-major package (`documentdb-19`) and following the migration workflow; there is no implicit major hop hidden behind `apt upgrade documentdb`.

This split is deliberate because the design also explicitly does **not** provide an automatic `pg_upgrade`/major-migration helper in Track 1.

**Workaround:** install the specific per-major package directly: `apt install documentdb-N`. The meta package is optional; per-major packages are the first-class install target for non-paved-road combinations.

### 10.2 No `pg_upgrade` migration helper

There is no `documentdb-local-migrate N M` command for major-version upgrades. Private stand-alone PostgreSQL instances are intentionally outside `postgresql-common`'s cluster discovery model, so `pg_upgradecluster` does not apply.

**Workaround:** install both majors side-by-side (`documentdb-N` and `documentdb-M`), run `documentdb-setup` for each, migrate application data through the wire protocol or `pg_dump`/`pg_restore`, then decommission the old stand-alone-package-owned private major with `documentdb-local-reset --pg-version N --confirm-destroy`.

### 10.3 No dedicated first-user bootstrap helper for Workflow A/B

The design does not introduce a gateway-owned user-management CLI for extension-only or BYO-gateway installs. That is intentional: user lifecycle is a property of the extension/API surface, not of the gateway package.

**Workaround:** bootstrap the first admin user through the extension-side user-management API (for example `SELECT documentdb_api.create_user(:'user_bson'::documentdb_core.bson);`) and then use standard wire-protocol commands for day-2 user management once an admin exists. If you want the package to script that first-user bootstrap for you, use Workflow C (`documentdb-setup`).

### 10.4 No automatic rollback on `documentdb-tune` failure

If PostgreSQL fails to restart after `documentdb-tune --yes` (e.g., config typo, port collision), there is no `--rollback-last` command. When the tool edits `postgresql.conf` directly, the backup file (`*.documentdb-backup.<timestamp>`) is written before every modification but must be restored manually. This is separate from the stand-alone package's rollback records under `/var/lib/documentdb-local/N/backups/<timestamp>/`. When the tool is using a managed `documentdb.conf` fragment, the administrator must remove or fix that fragment manually.

**Workaround:** if the PostgreSQL instance is using a managed fragment, remove or fix `documentdb.conf` and restart PostgreSQL. On Debian/Ubuntu this is typically `/etc/postgresql-common/documentdb/N/main/documentdb.conf`. If the tool edited `postgresql.conf` directly, restore the backup file and restart PostgreSQL: `mv /path/to/postgresql.conf.documentdb-backup.<ts> /path/to/postgresql.conf && systemctl restart postgresql@N-main`. Alternatively, `documentdb-tune --restore` removes the managed configuration entirely (equivalent to undoing the tune).

### 10.5 Partial `initdb` not auto-cleaned on failure

If `documentdb-setup` fails mid-way through `initdb` (e.g., disk full), the partially initialized data directory is left on disk. Re-running setup will fail with "Data directory exists but is not a valid PostgreSQL instance."

**Workaround:** remove the partial directory and retry: `sudo rm -rf /var/lib/documentdb-local/N/data && sudo documentdb-setup --admin-user admin`. Or use `documentdb-local-reset --pg-version N --confirm-destroy` to clean up the stand-alone package's per-major private state.

---

## 11. Deferred work

The following items are deliberately **out of scope** for Track 1. They are listed here so reviewers can confirm what is and isn't being shipped, and so future planning has a clear handoff point.

### 11.1 Track 2 — gateway BYO refactor for cloud / remote PostgreSQL

**Capability:** point the gateway at a cloud-managed PostgreSQL (AWS RDS, Azure Database for PostgreSQL, Aiven, etc.) over TCP with password authentication.

**Why deferred:** the gateway's connection pools currently open without a password after SCRAM. Making them pass a real password through the layered SCRAM/proxy/data-pool plumbing is a non-trivial refactor that warrants its own design, review, and test cycle.

**Impact on packaging:** none. The four-package shape, all maintainer scripts, and the systemd surface stay the same when Track 2 lands. The gateway just gains capability — Workflow B's compatibility warning goes away, and a new "cloud-PG" workflow becomes documentable.

### 11.2 Docker image refactor

**Capability:** layered Docker images (lean gateway image, separate `postgres-documentdb` image, refactored `documentdb-local`) instead of the single stand-alone image we ship today.

**Why deferred:** the existing `ghcr.io/documentdb/documentdb/documentdb-local:latest` image keeps being built by existing CI and serves the evaluation use case adequately. A refactor is desirable but not blocking.

**Impact on packaging:** the lean gateway package shipped in this design is the right starting point for a future lean gateway image. No package rework needed when this lands.

### 11.3 PGRX `bgworker` gateway variant

**Capability:** ship the gateway as a PostgreSQL background worker (in-process with the PG server) for environments that want a single-process deployment.

**Why deferred:** the stand-alone systemd-unit variant is the dominant use case (and the only one the OSS gateway supports today). The bgworker variant is an additional shape, not a replacement.

**Impact on packaging:** would add a new package `postgresql-N-documentdb-gateway-bgworker` in the `postgresql-N-*` namespace, parallel to `postgresql-N-documentdb`. The four-package shape in this design is unaffected.
