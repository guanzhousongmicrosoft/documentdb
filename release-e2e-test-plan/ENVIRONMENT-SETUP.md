# Environment Setup & Ground Truth (read this first)

This file is the **shared reference** every track agent depends on. It describes
the System Under Test (SUT), how to bring it up, and the hard facts (ports,
credentials, defaults, config keys) that your assertions must be written
against. **Do not guess any of these values — they are copied from the release
source and are authoritative.** If reality disagrees with a value here, that
disagreement is itself a finding: record it, do not silently "fix" your test to
match.

> Platform note: the release artifacts are **Linux** (Docker image + `.deb` /
> `.rpm`). The plan author's workstation is Windows, but **all testing must run
> on a Linux host or Linux containers** (a Linux VM, WSL2, or a CI Linux
> runner with Docker). Docker Desktop on Windows/macOS works for the container
> tracks; the package-install tracks need real Linux (containers are fine).

---

## 1. What the "release" consists of

Two independently-shippable deliverables. A track targets one or both.

### 1a. The `documentdb-local` container image (the emulator)
- **Image (canonical):** `ghcr.io/documentdb/documentdb/documentdb-local:<tag>`
  - The README quickstart pulls `:latest` and re-tags it `documentdb`.
  - **`latest` is pinned to the PG 17 image.** Release manifest-list tags are
    `pg<N>-<V>` for N ∈ {15,16,17,18} (the **image** matrix is wider than the
    package matrix — images build for PG 15/16/17/18 × amd64/arm64).
  - For a **release candidate you built locally**, use whatever local tag you
    built it under. Confirm with `docker images | grep documentdb`.
  - Built by the **only** product Dockerfile: `packaging/gateway/docker/Dockerfile_documentdb_local`
    (the `documentdb-local/` dir has no Dockerfile). CI base is `debian:trixie-slim`
    (the Dockerfile's own default is `ubuntu:22.04`).
  - The gateway is **compiled from source inside the image** (`--profile=release-with-symbols`),
    not installed from the gateway `.deb`. The extension is installed from the
    `deb13-postgresql-N-documentdb` `.deb`.
- **Bundled PostgreSQL major:** build arg `POSTGRES_VERSION` — confirm the actual
  major with `docker exec <c> cat /version.txt`.
- **Bundled client:** `mongosh` 8.0 is baked into the image at `/usr/bin/mongosh`.
- **Manifests are cosign keyless-signed and verified** in CI — supply-chain check
  material for Track 6.
- **Identity:** image label `com.documentdb.documentdb.local="true"`, and
  `org.opencontainers.image.version` carries the DocumentDB version. `/version.txt`
  prints `<version> (commit <sha>, built <date>, postgresql <major>)` and is
  cross-checked against the installed extension version at build time.
- **No `EXPOSE` and no `HEALTHCHECK`** anywhere in the image (confirmed) — ports
  must be published explicitly; orchestrators get no native health signal.
- **Readiness banners** (grep these): `=== DocumentDB is ready ===` and, when
  seeding, `Custom data initialization completed.`

### 1b. The Linux packages (`.deb` / `.rpm`)
Five package roles (see `packaging/README.md` for the authoritative contract):

| Package | Role |
|---|---|
| `postgresql-N-documentdb` | The PostgreSQL extension for major N (file-only). |
| `documentdb-postgresql-tools` | Admin helpers: `documentdb-tune`, `documentdb-createcluster`, `documentdb-register-gateway`, `documentdb-gateway-admin`. |
| `documentdb-gateway` | Wire-protocol runtime (binary + `documentdb-gateway.service`). |
| `documentdb-common` | PG-agnostic shared payload: `documentdb-setup`, `documentdb-local-reset`, systemd template units, sysusers/tmpfiles drop-ins, helper scripts, sample data. |
| `documentdb-N` (+ `documentdb` meta) | Per-major stand-alone package; pins PostgreSQL major N + its extension; owns the per-major systemd lifecycle. |

- **Paved-road default:** Ubuntu 24.04 LTS + PostgreSQL 18. The `documentdb`
  meta pins PG 18.
- **Version grammars (deliberately two):** extension packages use **`X.Y-Z`**
  (e.g. `0.117-0`); all other packages use flat **`X.Y.Z`** (e.g. `0.117.0`).
  `dpkg --compare-versions 0.117-0 ge 0.117.0` is **FALSE** — the two grammars
  sort differently; never assume they are equal.
- **Supported PG majors:** 15, 16, 17, 18. **PG 15 is extension-only** —
  `documentdb-setup`/`documentdb-register-gateway` reject PG 15 (the gateway's
  ident-map auth needs PG 16+). Architectures: **amd64 + arm64**.
- **Three install workflows:**
  - **C (recommended):** `apt install documentdb && sudo documentdb-setup --admin-user admin`
  - **A (extension-only):** `apt install postgresql-18-documentdb documentdb-postgresql-tools` then `sudo documentdb-tune ...`
  - **B (BYO PG + gateway):** Workflow A + `apt install documentdb-gateway` + `sudo documentdb-register-gateway ...`
- **RHEL prerequisite:** PGDG + EPEL + CRB repos must be enabled before
  `dnf install documentdb` (see `packaging/README.md` for the exact commands).

> **Version at HEAD is `0.118-0` (dashed) / `0.118.0` (dotted).** All three
> `.control` files set `default_version = '0.118-0'` and `CHANGELOG.md:1` is
> `### documentdb v0.118-0 (Unreleased)`. Confirm the built artifacts carry
> `0.118` — run `ls -la packaging/packages/ packaging/*.deb packaging/*.rpm
> 2>/dev/null` and `docker images` on the build host and paste the concrete
> filenames + resolved version into `README.md → Artifact Inventory`.
>
> **Working-tree caveat:** the repo tree is dirty — `packaging/rpm/spec/documentdb.spec`
> has an uncommitted change removing the bundled `libbson*` payload from the
> extension RPM's `%files`. The extension RPM's payload therefore differs between
> HEAD and the working tree (a co-install-conflict concern). **Record which tree
> state the artifacts under test were built from** and note it in every RPM
> finding.

### Exact Tier-1 release set (22 package files; V=`0.118.0`, VD=`0.118-0`)
CI/release builds **only** Tier 1: **Ubuntu 24.04** (DEB) + **RHEL/Rocky 9** (RPM),
**PG 17 and 18**, **amd64 + arm64**. rhel8 / deb11-13 / ubuntu22.04 / ubuntu26.04 /
PG 15-16 are **build-on-demand (Tier 2/3) and do NOT ship in a release** — test
them only if your artifacts include them.

- DEB (all names carry the `ubuntu24.04-` OS prefix):
  `ubuntu24.04-postgresql-{17,18}-documentdb_<VD>_{amd64,arm64}.deb` (4),
  `ubuntu24.04-documentdb-gateway_<V>_{amd64,arm64}.deb` (2),
  `ubuntu24.04-documentdb-postgresql-tools_<V>_all.deb` (1),
  `ubuntu24.04-documentdb-common_<V>_all.deb` (1),
  `ubuntu24.04-documentdb-{17,18}_<V>_all.deb` (2),
  `ubuntu24.04-documentdb_<V>_all.deb` (meta, pins PG 18) (1).
- RPM: only the **extension** RPM gets an OS prefix and `.el9`;
  `rhel9-postgresql{17,18}-documentdb-<V>-1.el9.{x86_64,aarch64}.rpm` (4),
  `documentdb-gateway-<V>-1.el9.{x86_64,aarch64}.rpm` (2),
  and the **noarch extras built on the Ubuntu runner have an empty dist tag →
  `-1.noarch.rpm`, NOT `-1.el9.noarch.rpm`**: `documentdb-postgresql-tools`,
  `documentdb-common`, `documentdb-{17,18}`, `documentdb` (meta) (5).
- **GitHub release bundle = 22 package files + `SHA256SUMS` + `manifest.txt` =
  24 assets** (draft + prerelease; a `documentdb-debug-symbols-*.zip` is wired in
  but not produced today). Asset filenames are load-bearing — the
  documentdb.github.io deploy selects packages by filename pattern, so a rename is
  a release-breaking finding.
- **There is no `documentdb-local` package and no `documentdb-tools` package.**
  "documentdb-local" is only the container image name, an OS user, and the
  `/var/lib/documentdb-local` path prefix. The per-major package is `documentdb-N`;
  the meta is `documentdb`; the tools package is `documentdb-postgresql-tools`.

---

## 2. Bring up the container SUT (tracks 2,3,4,5,6,7,8,9,10,12)

```bash
# Pick the image under test (local RC tag OR the ghcr image).
export IMG=documentdb-local:rc        # <-- set to your built tag
export GW_PORT=10260                   # gateway (MongoDB wire) port
export ADMIN_USER=admin
export ADMIN_PW="$(openssl rand -hex 12)Aa1!"   # strong, generated — never hardcode

# Minimal run (gateway only; internal PostgreSQL is NOT published — by design):
docker run -d --name ddb -p ${GW_PORT}:10260 \
  -e USERNAME=${ADMIN_USER} -e PASSWORD="${ADMIN_PW}" \
  "${IMG}"

# Wait for readiness (the entrypoint prints this exact banner):
until docker logs ddb 2>&1 | grep -qF "=== DocumentDB is ready ==="; do
  sleep 2; docker ps -q -f name=ddb | grep -q . || { docker logs --tail 40 ddb; break; }
done
```

**Connect (from the host, using the baked-in mongosh inside the container, or a host mongosh):**
```bash
# TLS is on by default with an auto-generated self-signed cert, so clients must
# allow an invalid cert (this is expected for the emulator, NOT a finding):
docker exec ddb mongosh \
  "mongodb://${ADMIN_USER}:${ADMIN_PW}@127.0.0.1:10260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256" \
  --quiet --eval 'db.runCommand({ping:1})'
```
```python
# pymongo from the host:
import pymongo
c = pymongo.MongoClient(f"mongodb://{USER}:{PW}@localhost:10260/"
                        "?tls=true&tlsAllowInvalidCertificates=true")
```

**Persistence:** mount a named volume at `/data` (`-v ddbdata:/data`) — without an
explicit mount each `docker run` gets a fresh anonymous volume.

---

## 3. Bring up the package SUT (tracks 1,4,5,7,11,12)

The package tracks run **inside disposable Linux containers** so a botched
install never touches a real host. The repo already ships purpose-built test
images and harness scripts under `packaging/test_packages/` — **use them; do not
reinvent install harnesses.**

- DEB gateway test image: `packaging/gateway/test/Dockerfile_deb_gateway_test`
  (stages all built `.deb`s at `/tmp/install_setup`, pre-configures PGDG + mongosh).
- RHEL gateway test image: `packaging/test_packages/Dockerfile-rhel-gateway-test`.
- Fastest path to a working install matrix: build with the built-in test flag:
  ```bash
  ./packaging/gateway/build_gateway_packages.sh --os ubuntu24.04 --pg 18 --version <V> --test-clean-install
  ./packaging/gateway/build_gateway_packages.sh --os rhel9      --pg 18 --version <V> --test-clean-install
  ```
- Existing E2E scenario scripts you will **run and extend** (do not duplicate):
  - `packaging/test_packages/e2e-container-scenarios.sh` — container C1/C3/C4.
  - `packaging/test_packages/e2e-extra-scenarios.sh` — setup wizard A/B scenarios (dry-run, conflicts, env hygiene, special-char pw, port keep, interrupt recovery, brownfield adoption).
  - `packaging/test_packages/e2e-rhel-scenarios.sh`, `e2e-multimajor-scenario.sh`, `e2e-rhel-multimajor.sh`, `e2e-pg16-minimum-major.sh`, `e2e-package-hygiene.sh`.
  - `packaging/test_packages/systemd/run-systemd-e2e.sh` — systemd lifecycle.

---

## 4. Ground-truth facts (assert against these)

### Ports
| Port | Role | Exposed by default? |
|---|---|---|
| **10260** | Gateway / MongoDB wire protocol (container AND packaged install) | **Yes** (you publish it with `-p`). Gateway binds all interfaces. |
| **9712** | Internal PostgreSQL **inside the container only** (legacy dev port) | **No** — must NOT be published unless `--allow-external-connections true`. Bound to localhost otherwise. |
| **9717 / 9718** | Package-managed PostgreSQL = **9700 + major** (PG17→9717, PG18→9718) | Local Unix socket; `--pg-port 5432` is explicitly rejected for a new private instance. |
| 27017 | Not used by default | The README notes you *may* remap the gateway to 27017 if you prefer. |
| 4317 | OTLP telemetry endpoint (opt-in, default OFF) | No. |

Dev container forwards **9712** (PG) and **10260** (gateway). Note the two PG
port schemes: the **container** uses 9712; a **packaged** stand-alone install uses
9700+major (9718 for the paved-road PG 18). Side-by-side majors need distinct
gateway ports (no auto-allocation).

### Container env vars / CLI flags (each flag overrides the env var)
| Env var | Flag | Default | Notes |
|---|---|---|---|
| `USERNAME` | `--username` | `default_user` | Admin user to create. |
| `PASSWORD` | `--password` | *(required)* | No default; container refuses to start without it unless the default-password escape hatch is set. |
| `CREATE_USER` | `--create-user` | `true` | |
| `DOCUMENTDB_PORT` | `--documentdb-port` | `10260` | Gateway port. |
| `POSTGRESQL_PORT` | `--pg-port` | `9712` | Internal PG. |
| `DATA_PATH` | `--data-path` | `/data` | Declared `VOLUME`. |
| `ALLOW_EXTERNAL_CONNECTIONS` | `--allow-external-connections` | `false` | Opens internal PG to all interfaces. Security-sensitive. |
| `TLS_MODE` | `--tlsMode` | `allowTLS` | `disabled` behaves same as `allowTLS` (no plain-only mode); `requireTLS` rejects plaintext. |
| `CERT_PATH` / `KEY_FILE` | `--cert-path` / `--key-file` | *(empty → auto-gen self-signed)* | Provide both to use your own PEM. |
| `LOG_LEVEL` | `--log-level` | `info` | `quiet\|error\|warn\|info\|debug\|trace`. |
| `ENABLE_TELEMETRY` | `--enable-telemetry` | `false` | Help text says "Azure Application Insights" but the gateway config is provider-neutral OTLP — **flag this doc drift** (Track 9/12). |
| `INIT_DATA` | `--init-data` | `false` | Seed built-in sample data (once per fresh volume). |
| `INIT_DATA_PATH` | `--init-data-path` | `/init_doc_db.d` | Run `*.js` via mongosh, alphabetical, once per fresh volume, not retried on failure. |
| `SKIP_INIT_DATA` | `--skip-init-data` | — | Legacy alias for `--init-data false`. |
| `DISABLE_EXTENDED_RUM` | `--disable-extended-rum` | *(rum enabled)* | |
| `DOCUMENTDB_TOAST_COMPRESSION` | `--toast-compression` | `lz4` | `lz4\|pglz\|default`. lz4 values readable only by lz4-capable PG. |
| `START_POSTGRESQL` | `--start-pg` | `true` | `false` = advanced/BYO external PG. |
| `OWNER` | `--owner` | `documentdb` | |
| `DOCUMENTDB_ALLOW_DEFAULT_PASSWORD` | — | `false` | Escape hatch: allows the `default_user`/`Admin100` fallback. **Should stay off**; a release that starts with defaults silently is a finding. |

### Auth / roles
- **Client auth mechanism:** SCRAM-SHA-256 over the wire.
- **Reserved role names** (exact match rejected as a username): `documentdb_admin_role`,
  `documentdb_api_find_role`, `documentdb_api_insert_role`, `documentdb_api_remove_role`,
  `documentdb_api_update_role`, `documentdb_bg_worker_role`, `documentdb_cluster_admin_role`,
  `documentdb_readonly_role`, `documentdb_readwrite_role`, `documentdb_root_role`,
  `documentdb_user_admin_role`.
- **Blocked role prefixes** (case-insensitive, from `SetupConfiguration.json`):
  `documentdb`, `citus`, `pg`, `internal_role`. A username starting with any of these
  must be rejected before the container reports ready.
- **Gateway admin CLI (packaged installs):** `documentdb-gateway-admin`
  `create-user | drop-user | list-users | reset-password | check`
  (`--username`, `--password-stdin` / `--password-file`).

### TLS
- Default: auto-generated self-signed PEM (`CertType: PemAutoGenerated`). Clients
  must use `tlsAllowInvalidCertificates=true` (expected).
- Packaged gateway TLS keys: `DOCUMENTDB_TLS_CERT_FILE`, `DOCUMENTDB_TLS_KEY_FILE`,
  `DOCUMENTDB_TLS_AUTO_GENERATE` (default true), `DOCUMENTDB_TLS_STATE_DIR`
  (default `/var/lib/documentdb-gateway/tls`).

### Gateway config (`pg_documentdb_gw/SetupConfiguration.json`, baked into the image)
`NodeHostName=localhost`, `PostgresPort=9712`, `GatewayListenPort=10260`,
`HostConfigurationWatchIntervalMs=1000`, `CertificateOptions.CertType=PemAutoGenerated`,
`UseLocalHost=false`. Telemetry (`TelemetryOptions`): **opt-in, both Metrics and
Tracing `Enabled:false`**, OTLP endpoint `http://localhost:4317`, overridable via
`OTEL_*` env vars.

### Packaged install layout (Workflow C, stand-alone)
- Config: `/etc/documentdb/local/N/gateway.env`, `/etc/documentdb/local/N/setup.conf`.
- PG-side include: `/etc/postgresql-common/documentdb/%v/%c/documentdb.conf`.
- Private sockets: `/run/documentdb-local/N/postgresql`, gateway URL file under
  `/var/lib/documentdb-local/N/gateway/pg-url` (mode 0640).
- Systemd units: `documentdb-local@.target`, `documentdb-postgresql@.service`,
  `documentdb-gateway-local@.service`, plus `documentdb-gateway.service`.
- OS users: `documentdb-local`, `documentdb-gateway` (via sysusers.d).

### Known doc/behavior notes to verify (not yet findings — confirm live)
1. **Container runs as user `documentdb`, which is in the `sudo` group with
   `NOPASSWD: ALL`** (`/etc/sudoers.d/no-pass-ask`). Assess the security impact
   (Track 6).
2. **No `HEALTHCHECK` instruction** in the local Dockerfile — orchestrators get no
   native health signal (Track 2/9).
3. **`ENABLE_TELEMETRY` help text names Azure App Insights**, but the shipped
   config is provider-neutral OTLP (Track 9/12 doc-drift check).
4. **`default_user` / `Admin100`** fallback exists but is gated behind
   `DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true` (Track 4/6 — verify the gate holds).
