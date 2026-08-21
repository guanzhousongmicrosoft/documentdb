# ENVIRONMENT-SETUP.md — ground truth for v0.116-0 E2E testing

Single source of truth for the SUT. Every track cites this file. Values here were
read from the actual release artifacts and the source at the release tag on
2026-08-20. **If reality disagrees with this doc, reality wins — and that
disagreement is itself a finding.**

---

## 1. Release identity & build provenance

| Fact | Value |
|------|-------|
| Version (dotted / dashed) | `0.116.0` / `0.116-0` |
| Git tag | `v0.116-0` → commit `66e9e1188d4eda5cf46a74aea7c82fe502d81022` |
| CHANGELOG date | August 20, 2026 |
| Skipped version | v0.115-0 (its changes are folded into 0.116-0) |
| **Packages** build run | Actions run **32413347757** — "Build all packages", ref `v0.116-0`, head `66e9e118…`, success |
| **Images** build run | Actions run **32408805324** — "Build and push gateway images", ref `v0.116-0`, head `810cf2ccf00fc5d089cb9d462ce61c556abbc394`, success |

> ⚠️ **Provenance note to verify (finding-seed P1).** The two runs were built from
> **different commits**. Packages came from the tag commit `66e9e118`; images
> came from its parent-ish commit `810cf2cc` (they differ only in
> `build_packages.sh` / `build_gateway_packages.sh`). The image's
> `org.opencontainers.image.revision` label therefore reads `810cf2cc…`, **not**
> the release-tag commit. Confirm this on the pulled image and judge whether a
> release should ship an image whose revision label is not the tagged commit.

The tag commit `66e9e118` is **not** an ancestor of `main` (main advanced on a
different line). Treat the tag — not `main` — as the source of truth for what
shipped. To read shipped source:
```bash
git fetch <upstream> v0.116-0
git show v0.116-0:documentdb-local/scripts/emulator_entrypoint.sh   # etc.
```

---

## 2. Container image

**Repository:** `ghcr.io/documentdb/documentdb/documentdb-local` (public; anonymous pull works)

**Tags published for this release:**

| Tag | Meaning |
|-----|---------|
| `latest` | Floating; currently **PG 17** |
| `pg17-0.116.0` | PG 17 (multi-arch) |
| `pg18-0.116.0` | PG 18 (multi-arch) |
| `pg16-0.116.0` | PG 16 (multi-arch) |
| `pg15-0.116.0` | PG 15 (multi-arch) |
| `32408805324-2026-08-20-pgNN-{amd64,arm64}` | Per-arch build tags (internal; prefer the `pgNN-0.116.0` manifest tags) |

**Pinned digests (pg17):**
- manifest-list `pg17-0.116.0` → `sha256:4396b86015b723781c33d56e8b7046c8b27d90f5de6161ad808db7449bc11b5f`
- amd64 image → `sha256:374f2057f2198936b0c1a50b17089ef79e9b92bf10a88dfc5cce663403230573`
- amd64 config blob → `sha256:c00d2b94dd1ac9a24de72e6e8b93531e64f1840762003b5269c12fbabbcec84d`

**Image config (verified, amd64/pg17):**
- **User:** `documentdb` (non-root). **WorkingDir:** `/home/documentdb/gateway/scripts`.
- **Entrypoint:** `/bin/bash -c '/home/documentdb/gateway/scripts/emulator_entrypoint.sh "$@"' --`
- **No `HEALTHCHECK`. No `EXPOSE`/ExposedPorts. No `CMD`.** (finding-seeds C1/C2)
- **Base:** `debian:trixie-slim`. The `documentdb` user is in group `sudo` with
  `%sudo ALL=(ALL:ALL) NOPASSWD: ALL` (finding-seed S-esc — in-container passwordless root).
- **VOLUME** `/data`.
- Labels: `org.opencontainers.image.title=DocumentDB Local`,
  `.version=0.116.0`, `.revision=810cf2cc…`, `.source=…/documentdb`,
  `.created=2026-08-20T…Z`, `com.documentdb.documentdb.local=true`.

**Default environment baked into the image:**

| Env | Default | Notes |
|-----|---------|-------|
| `DOCUMENTDB_PORT` | `10260` | Gateway (MongoDB wire) port. **Not** EXPOSEd — publish with `-p`. |
| `POSTGRESQL_PORT` | `9712` | **Internal** backend PG port (container-only). |
| `TLS_MODE` | `allowTLS` | Accepts plain **and** TLS on the gateway port. |
| `ENABLE_TELEMETRY` | `false` | OTLP, opt-in. |
| `LOG_LEVEL` | `info` | quiet/error/warn/info/debug/trace. |
| `USERNAME` | `default_user` | |
| `PASSWORD` | *(unset)* | Usage says **REQUIRED**; verify empirically (finding-seed C3). |
| `CREATE_USER` | `true` | |
| `START_POSTGRESQL` | `true` | `--start-pg`. |
| `OWNER` | `documentdb` | |
| `PG_VERSION_USED` | `17` | Per-tag. |
| `ALLOW_EXTERNAL_CONNECTIONS` | `false` | Exposes the internal PG port directly when `true`. |
| `INIT_DATA` / `INIT_DATA_PATH` | *(unset)* / `/init_doc_db.d` | Sample-data / custom-init hooks. |

**Entrypoint flags** (each overrides the matching env var): `--cert-path`,
`--key-file`, `--data-path`, `--documentdb-port`, `--enable-telemetry`,
`--log-level`, `--username`, `--password`, `--create-user`, `--start-pg`,
`--pg-port`, `--owner`, `--allow-external-connections`, `--init-data`,
`--init-data-path`, `--skip-init-data`, `--disable-extended-rum`,
`--toast-compression`. `-h`/`--help` prints usage.

### Minimal container bring-up

```bash
IMG=ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.116.0
PW="$(openssl rand -hex 12)Aa1!"          # meets any complexity rule
docker run -d --name ddb -p 10260:10260 "$IMG" --username docdb_admin --password "$PW"
# Wait for readiness:
docker logs -f ddb 2>&1 | grep -m1 "=== DocumentDB is ready ==="
# Connect (self-signed cert ⇒ allow invalid certs):
docker exec ddb mongosh "localhost:10260" -u docdb_admin -p "$PW" \
  --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --quiet \
  --eval 'db.getSiblingDB("t").c.insertOne({ok:1}); print(db.getSiblingDB("t").c.countDocuments({}))'
```
From the host (rather than `docker exec`), point `mongosh` at `localhost:10260`
with the same flags. The gateway **auto-generates a self-signed certificate**
(`CertType: PemAutoGenerated`), so clients must accept an invalid/unknown CA
(`--tlsAllowInvalidCertificates`, or the driver equivalent) unless you mount your
own cert with `--cert-path`/`--key-file`.

---

## 3. Packages (22 total)

Aggregate artifact **`documentdb-packages-0.116.0`** on run 32413347757 bundles
every package plus `SHA256SUMS` and `manifest.txt`. **`SHA256SUMS` verifies
clean** (checked). Download with:
```bash
gh run download 32413347757 -R documentdb/documentdb -n documentdb-packages-0.116.0 -D pkgs
cd pkgs && sha256sum -c SHA256SUMS       # expect all OK
```

### Ubuntu 24.04 (`.deb`)
| Package | File | Arch |
|---------|------|------|
| Extension (PG17) | `ubuntu24.04-postgresql-17-documentdb_0.116-0_{amd64,arm64}.deb` | amd64/arm64 |
| Extension (PG18) | `ubuntu24.04-postgresql-18-documentdb_0.116-0_{amd64,arm64}.deb` | amd64/arm64 |
| Gateway | `ubuntu24.04-documentdb-gateway_0.116.0_{amd64,arm64}.deb` | amd64/arm64 |
| Meta (top) | `ubuntu24.04-documentdb_0.116.0_all.deb` | all |
| Meta (PG17/18) | `ubuntu24.04-documentdb-17_0.116.0_all.deb`, `…-18_…` | all |
| Common | `ubuntu24.04-documentdb-common_0.116.0_all.deb` | all |
| Tools | `ubuntu24.04-documentdb-postgresql-tools_0.116.0_all.deb` | all |

**DEB extension deps** (`postgresql-N-documentdb`): `postgresql-N`,
`postgresql-N-cron`, `postgresql-N-pgvector`, `postgresql-N-postgis-3`,
`postgresql-N-rum`. `Suggests: documentdb-postgresql-tools`. These come from the
**PGDG apt repo** — the install track must add PGDG first.

### RHEL / Rocky 9 (`.rpm`)
| Package | File | Arch |
|---------|------|------|
| Extension (PG17) | `rhel9-postgresql17-documentdb-0.116.0-1.el9.{x86_64,aarch64}.rpm` | x86_64/aarch64 |
| Extension (PG18) | `rhel9-postgresql18-documentdb-0.116.0-1.el9.{x86_64,aarch64}.rpm` | x86_64/aarch64 |
| Gateway | `documentdb-gateway-0.116.0-1.el9.{x86_64,aarch64}.rpm` | x86_64/aarch64 |
| Meta (top) | `documentdb-0.116.0-1.noarch.rpm` | noarch |
| Meta (PG17/18) | `documentdb-17-0.116.0-1.noarch.rpm`, `…-18-…` | noarch |
| Common | `documentdb-common-0.116.0-1.noarch.rpm` | noarch |
| Tools | `documentdb-postgresql-tools-0.116.0-1.noarch.rpm` | noarch |

**RPM extension deps** (`postgresqlN-documentdb`): `(postgresqlN or
percona-postgresqlN)`, `(postgresqlN-server or percona-…-server)`,
`(pgvector_N or percona-pgvector_N)`, `pg_cron_N`, **`postgis36_N`**, `rum_N`.
These come from the **PGDG yum repo**. Note the PostGIS package name differs from
DEB (`postgis36_N` vs `postgis-3`) — verify both resolve (finding-seed PK1).

> There is **no `documentdb-local` package** — the local emulator ships only as
> the container image. The `.deb`/`.rpm` set is the extension + gateway + the
> standalone tooling.

---

## 4. Packaged gateway & standalone tooling (for Track 10)

- **systemd unit** `documentdb-gateway.service`: `User/Group=documentdb-gateway`,
  `WorkingDirectory=/var/lib/documentdb-gateway`, `EnvironmentFile=-/etc/documentdb/gateway/gateway.env`,
  `ExecStart=/usr/bin/documentdb-gateway run`, `Restart=on-failure`. Listens on
  `:10260` by default. **Heavily sandboxed** (`ProtectSystem=strict`,
  `NoNewPrivileges`, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`,
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `UMask=0077`). TLS
  auto-generates a self-signed cert under `/var/lib/documentdb-gateway/tls`
  unless `DOCUMENTDB_TLS_CERT_FILE`/`_KEY_FILE` are set.
- **Stated limitation (verify + judge, finding-seed PK2):** `gateway.env` says —
  *"This release only supports LOCAL PostgreSQL with peer/trust authentication
  over a Unix socket. Cloud-managed PostgreSQL (RDS, Azure, Aiven) over TCP with
  password authentication is NOT supported."* Confirm the gateway indeed cannot
  target a remote/TCP-password PG, and that this limit is discoverable by a user.
- **Standalone setup** = `documentdb-setup` (greenfield: initdb a private PG;
  brownfield: adopt an existing instance via `--target-postgres-instance`), which
  delegates to `documentdb-tune` (postgresql.conf) and `documentdb-register-gateway`
  (hba/ident/role + connection-URL file). Other helpers: `documentdb-createcluster`,
  `documentdb-gateway-admin`, `documentdb-local-reset`. Per-major backend PG port
  for standalone = **9700 + PG major** (9717 for PG17, 9718 for PG18).
- **Appliance systemd templates** (multi-instance): `documentdb-gateway-local@.service`,
  `documentdb-postgresql@.service`, `documentdb-local@.target`.

---

## 5. Platform support matrix (what shipped = Tier 1)

| | Ubuntu 24.04 | RHEL/Rocky 9 | Container image |
|--|:--:|:--:|:--:|
| PG 15 | — | — | ✅ (image only) |
| PG 16 | — | — | ✅ (image only) |
| PG 17 | ✅ | ✅ | ✅ |
| PG 18 | ✅ | ✅ | ✅ |
| Arch | amd64 + arm64 | amd64 + arm64 | amd64 + arm64 |

RHEL 8, Debian, other distros are **not** in this release's Tier-1 set — testing
them is out of scope unless a track says otherwise.

---

## 6. Finding-seeds registry (hypotheses to verify — DO NOT assert blindly)

Each has an owning track. Reproduce live before reporting; a disproved seed is a
reportable result too.

| ID | Owner | Hypothesis |
|----|-------|-----------|
| P1 | T01 | Image `revision` label = `810cf2cc`, not the tag commit `66e9e118`. |
| C1 | T01/T02 | Image has **no HEALTHCHECK** — orchestrators can't tell healthy from hung. |
| C2 | T01/T03 | Image has **no EXPOSE** — port discovery relies on docs only. |
| C3 | T03/T05 | Password: usage says REQUIRED, but the entrypoint also carries an `Admin100` default. What actually happens with no `--password`? |
| C4 | T03/T12 | `--log-level` is validated + exported but may not change gateway verbosity (not written to gateway config / CLI). Does it actually take effect? |
| C5 | T03/T12 | `--enable-telemetry true` is validated + exported, but the gateway config hardcodes `Enabled:false`. Does telemetry actually turn on (OTLP to `:4317`)? |
| C6 | T04/T13 | **Wire compression** (`OP_COMPRESSED`): no zstd/snappy/zlib compressor symbols in the gateway. Do drivers with `compressors=` fail, or silently fall back? |
| C7 | T04 | `getParameter` backend-contract (issue #650): the discovery probe `mongosh` runs on connect. Behavior differs under `--start-pg=false`. |
| C8 | T06/T12 | `TLS_MODE=disabled` does **not** disable TLS (gateway has no plain-only mode); it warns and behaves like `allowTLS`. |
| S-esc | T07 | `documentdb` user has passwordless `sudo` (NOPASSWD:ALL) inside the container. |
| PK1 | T09 | RPM PostGIS dep is `postgis36_N` (vs DEB `postgis-3`) — both must resolve from PGDG. |
| PK2 | T10/T12 | Packaged gateway supports **local peer/trust PG only**; remote/TCP-password PG unsupported this release. |
| U1 | T12 | `--enable-telemetry` help says "Azure Application Insights", but telemetry is provider-neutral **OTLP/OpenTelemetry**. |

---

## 7. Fixed-in-0.116 behaviors worth a regression check

The release-prep commit (`66e9e118`) hardens the container. Confirm these
**stay** fixed (owning track in parens):

- **#43 / #62 — concurrent-container data-dir lock (T02).** Ownership of `/data`
  is taken with an `flock(2)` on the data-dir inode (crosses PID namespaces), not
  from `postmaster.pid`. A second container on a volume already in use must
  **refuse to start and name the conflict**, not delete the live lock.
- **#61 — emulator bare-positional spin (T03).** A non-`-` positional argument
  used to spin PID 1 at 100% CPU forever. It must now print the offending token
  on stderr and exit 1.
- **cosign legacy signature (T01).** Signing pairs `--new-bundle-format=false
  --use-signing-config=false` so a cosign v2 client can verify; the legacy `.sig`
  tag must be present.
- **Backend-contract gate #650 (T04).** The gateway must not emit disallowed
  backend-contract SQLSTATEs on the `getParameter` discovery path.
