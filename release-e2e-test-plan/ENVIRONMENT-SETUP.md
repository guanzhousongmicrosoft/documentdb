# ENVIRONMENT-SETUP.md — ground truth for v0.116-0 E2E testing

Single source of truth for the SUT. Every track cites this file. Values here were
read from the actual release artifacts and the source at the release tag on
2026-08-20. **If reality disagrees with this doc, reality wins — and that
disagreement is itself a finding.**

---

## 0. Before you start (read this first)

You were handed three files: **this one** (ground truth), one
`prompts/track-NN-*.md` (your assignment), and `REPORT-TEMPLATE.md` (your output
format). That is everything you need to know *what* to do. This section is how you
get into a position to actually do it. Work through it before touching your track.

### 0.1 Get the source at the release tag

Several tracks read files out of the DocumentDB repository itself — the
functional-test runner and its baselines, the in-tree contract tests, the regress
suites, the shipped docs. Clone it and check out **the tag**, not `main`:

```bash
git clone https://github.com/documentdb/documentdb.git
cd documentdb
git checkout v0.116-0     # tag commit 66e9e118...; NOT an ancestor of main
```

Tracks that need the source: 01 (`test_image.py`), 03 (entrypoint tests), 04
(functional suite + contract tests), 06 (TLS test script), 07 (crash list), 08/09
(regress suites), 10 (setup tests), 12 (shipped docs), 15, 16. If you skip this,
those checks are not merely harder — they are impossible, and you will report a
gap that is really a missing checkout.

### 0.2 Tooling

**Every track:** `docker` (or `podman`), `mongosh`, `openssl`, `git`, `python3`,
`jq`, and an authenticated `gh` for artifact download.

| Track | Also needs |
|-------|-----------|
| 01 | `cosign`; `trivy` or `grype`; `syft`; optionally `crane`/`skopeo` |
| 06 | `nmap` (with `ssl-enum-ciphers`) or `testssl.sh` |
| 07 | `tcpdump`; a runtime you can constrain (`--memory`/`--cpus`/`--cap-drop`) |
| 08 | clean **Ubuntu 24.04** (VM or container), amd64 **and** arm64 |
| 09 | clean **Rocky/RHEL/Alma 9**, x86_64 **and** aarch64, one with SELinux **enforcing** |
| 10 | a real **systemd** host — a plain docker container will not do |
| 11 | a driver-based load harness and a fixed, recorded host |
| 13 | `pymongo`, Node `mongodb`, optionally Go/Java/C# drivers; MongoDB Database Tools; Compass |
| 14 | prior-release artifacts — run that track's Step 0 first (see also §10) |
| 15 | a package-installed host from Track 08 or 09, in addition to the image |
| 16 | `psql` (available via `docker exec`), optionally `amcheck` |

**If a tool or a host is unavailable, do not silently skip the check.** Mark it
⛔ blocked in your checklist with the reason. An unrun check that reads as a pass
is worse than a gap you declared.

### 0.3 Getting the artifacts

**Image** — anonymous `docker pull` works; no credentials needed:
```bash
docker pull ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.116.0
```

**Packages** — `gh run download` (see §3) needs an authenticated `gh` with read
access to that repository's Actions artifacts. If you do not have it, or the
artifacts have aged out, fall back to (a) the downstream `documentdb.io` apt/yum
repositories, or (b) building from the tag. **Record which source you used**: a
locally built package is not the package that shipped, and for a release gate that
difference is the whole point.

### 0.4 Where your report goes

Write `reports/track-NN-<slug>.md` **inside this bundle directory** — the same
directory this file came from — and put captured evidence under
`reports/artifacts/track-NN-*`. Use exactly the filename your track prompt states;
the rollup matches on those names. If you have no write access to the bundle,
return the report as your final output and say where the artifacts live.

Alongside the file, send the coordinator one status line:

```
TRACK NN — PASS | PASS-WITH-FINDINGS | FAIL | BLOCKED — S1:_ S2:_ S3:_ S4:_
```

### 0.5 If your track cannot run at all

Report **BLOCKED** with exactly what was missing, and tell the coordinator
**early** rather than at report time. Do not substitute a different, easier test
and report it as the track.

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

> **Provenance seed P1 — RESOLVED in the rebuild (verified 2026-08-21).** The plan was
> written against build runs whose packages (`66e9e118`) and images (`810cf2cc`) came
> from *different* commits. The release was subsequently **rebuilt**: runs
> **32438343434** (packages) and **32438357061** (images) are both from
> `684ac1626249f0b394cfb5a1391c85a158876d36`, and the `v0.116-0` tag now points there
> (annotated tag `b1107382`). The image's `org.opencontainers.image.revision` reads
> `684ac162…` — equal to the build commit *and* the tag. The drift is gone. If you are
> testing an older build, the original seed still applies.
>
> The only source delta from `66e9e118` to `684ac162` is **RPM packaging**:
> `packaging/rpm/spec/documentdb.spec`, `packaging/rpm/packaging-entrypoint-rpm.sh`,
> `packaging/test_packages/e2e-rhel-scenarios.sh`,
> `packaging/test_packages/test-install-entrypoint-rpm.sh`. Weight Track 09 accordingly.

The tag commit `66e9e118` is **not** an ancestor of `main` (main advanced on a
different line). Treat the tag — not `main` — as the source of truth for what
shipped. To read shipped source:
```bash
git fetch https://github.com/documentdb/documentdb.git v0.116-0
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

Only **pg17** is pinned here. If your track touches pg15/pg16/pg18 or arm64,
resolve those digests yourself (`docker buildx imagetools inspect`, `crane
digest`, or `docker inspect`) and record them — worker rule 3 applies to whatever
you actually tested, not to what this file happens to list.

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
| `PGOPTIONS` | *(unset)* | **Not in `--help`.** Read from the environment and word-split into the backend server-start argv; the entrypoint sets `-e` here itself for `--allow-external-connections`. See finding-seed C9. |

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
| P1 | T01 | Image `revision` label = `810cf2cc`, not the tag commit `66e9e118`. **RESOLVED in the `684ac162` rebuild — see §1.** |
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
| C9 | T03/T07 | `PGOPTIONS` is read from the environment and word-split into the server-start argv (that is how `--allow-external-connections` passes `-e`). Can a user set it on `docker run` to inject backend server arguments **behind** the validated flag surface? |
| C10 | T16 | `--disable-extended-rum` drops `-r` from the server start, so extended RUM is on by default. Does the flag observably change the installed AM, and is toggling it on an existing volume safe in both directions? |
| FG1 | T16 | Do the real GUC defaults match what the CHANGELOG claims for the 0.116 (on) and 0.115 (off) feature flags? |

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
- **RUM vacuum page-pruning race (T16).** `documentdb_rum.prune_rum_empty_pages`
  now revalidates that the left/right siblings still bracket the target after
  re-locking (a concurrent left-sibling split could otherwise drop pages from the
  leaf chain), zeroes the retained high-key tuple's posting-tree pointer, and
  takes posting-tree root cleanup locks conditionally up front. This is the
  riskiest change in the release: verify it under concurrent vacuum + churn.

---

## 8. The functional gate — the oracle every track must consult

**Read this before filing anything.** The repository carries an authoritative
statement of what is expected to pass, and the plan is far weaker without it.

> **Correction (verified 2026-08-21 against the shipped release).** Earlier revisions
> of this section described a *known-failures xfail* model with 15,422 failing /
> 1,898 flaky / 6 engine-crasher entries. **Those files do not exist at the release
> commit.** At `684ac162` the config directory contains only `allowlist.yml` and
> `image.yml`; the xfail lists are a downstream-fork construct on that fork's `main`.
> What the release actually ships is the **allowlist** model below. Reality won.

`documentdb-local/functional-tests/` runs the pinned upstream
`documentdb/functional-tests` wire-protocol suite under an **allowlist** model:

| Fact | Value |
|------|-------|
| Model | `allowlist.yml`, `schema_version: 2` — every listed test **must pass** |
| Allowlisted tests | **10,481** |
| Suite image (pinned by digest) | `ghcr.io/documentdb/functional-tests@sha256:79ed3d43…` (`source_sha df2623cd`) |
| Excluded engine-crashers | `setUnion_core`, `setUnion_type_dedup`, `stages_window`, `planCacheStats_type_errors` |
| Provenance of the list | intersection of passing tests across repeated scheduled full-suite runs (non-flaky passers only) |

The allowlist is a **must-pass** contract, not a known-failure list: any failure is a
regression, and the gate also fails if a listed test disappears.

### How to run it against the published image

CI (`.github/workflows/functional_tests.yml`, job 3) does **not** use the runner's
`allowlist` mode. It shards the allowlist into explicit pytest node IDs and passes
them positionally — reproduce that:

```bash
python3 documentdb-local/functional-tests/tools/functional_gate.py \
  --image  documentdb-local/functional-tests/config/image.yml \
  --allowlist documentdb-local/functional-tests/config/allowlist.yml \
  --engine-name documentdb shard-allowlist \
  --num-shards 8 --shard-id "$i" --prefix documentdb_tests/ --output ids_$i.txt

docker run --rm --network host -v "$PWD:/results" --entrypoint sh \
  ghcr.io/documentdb/functional-tests@sha256:79ed3d43… -c \
  "cd /app && exec pytest --rootdir documentdb_tests \$(cat /results/ids_$i.txt) \
     --engine-name documentdb --connection-string '<uri>' -n 12 \
     --json-report --json-report-file=/results/report_$i.json -q"
```

Three traps, all of which cost real time on the first run:

- **`--engine-name` must be `documentdb`.** Any other value silently deselects every
  test (`12518 deselected / 0 selected`) rather than erroring.
- **`functional_gate.py` writes CRLF on Windows.** pytest folds the trailing `\r` into
  the node ID and collects nothing. Normalise the ID files to LF.
- **The runner's own `allowlist` mode is broken at this commit** — the shipped
  allowlist contains a `no_parallel`-marked test and `tools/conftest_allowlist.py`
  raises an unconditional `UsageError` before any test runs. Use the sharded path.

`functional_tests.yml` also documents a **known RUM dynamic-cursor race that segfaults
the engine under parallel workers**, and re-runs each shard's failures sequentially to
absorb it. Treat an engine crash under `-n` as known-but-unfixed, and hand it to
Track 16.

### Other automated gates already in the tree

These exist and are cheap; cite them rather than re-deriving their results:

| Asset | Covers | Track |
|-------|--------|-------|
| `documentdb-local/scripts/documentdb_local_tests/test_image.py` | image-level assertions | T01 |
| `.../backend_contract.py` + `test_backend_contract.py` | the #650 SQLSTATE deny-list | T04 |
| `.../catalog_contract.py` + `test_catalog_contract.py` | catalog contract | T04/T16 |
| `.../test_emulator_entrypoint.py` | entrypoint flag/env handling | T03 |
| `.../test_documentdb_setup.py` | `documentdb-setup` standalone wizard | T10 |
| `.../test_gateway_wrapper.py` | gateway wrapper | T10 |
| `documentdb-local/scripts/run_documentdb_local_tls_tests.sh` | container TLS paths | T06 |
| `documentdb-local/test-init-data/` | init-data hooks, incl. invalid data | T02 |
| `pg_documentdb_gw/documentdb_tests/` | per-command gateway integration tests | T04/T15 |
| `pg_documentdb/src/test/regress/` | extension SQL behavior | T08/T09/T15 |

The regress suites are the highest-value **packaging** check available: run them
against a **package-installed** extension, not the build tree.

---

## 9. Feature flags / GUCs — how to read and set them

The 0.116 change set is overwhelmingly **feature-flagged**, and several flags
ship *enabled by default while pending stabilization*. Nothing in this plan is
meaningful without knowing which state you tested. There is **no entrypoint flag
for GUCs** — go to the backend PostgreSQL:

```bash
# read
docker exec ddb psql -p 9712 -U documentdb -d postgres -X -tA \
  -c "SELECT name, setting, boot_val FROM pg_settings WHERE name LIKE 'documentdb%' ORDER BY 1;"
# set + reload
docker exec ddb psql -p 9712 -U documentdb -d postgres -X \
  -c "ALTER SYSTEM SET documentdb.enable_group_by_dynamic_streaming = off;" \
  -c "SELECT pg_reload_conf();"
```
(`9712` is `POSTGRESQL_PORT`; `documentdb` is `OWNER`. With
`--allow-external-connections true` and `-p 9712:9712` you can do this from the
host instead. Confirm which database holds the DocumentDB catalog before
assuming `postgres`.)

Flags this release turns **on** by default (verify — seed FG1):
`documentdb.enable_group_by_dynamic_streaming`,
`enableSortPushToAccumulatorWithPrefix`,
`documentdb.enable_composite_reduced_correlated_bounds_planning`,
`documentdb.enable_failure_on_parallel_index_arrays_for_metadata_tracking`,
`enable_min_max_skip_null_values`,
`documentdb.enableNonBlockingUniqueIndexBuild`, schema validation.

Flags shipped **off** (opt-in; a failure behind one is not a default-config
blocker, but say so): `enableProjectPushUpBeforeUnwindWithGroup`,
`enable_single_pass_posting_tree_vacuum`, `enable_targeted_posting_tree_pruning`,
`documentdb_rum.enable_emit_reuse_page_on_recycle`.

Track 16 owns the full inventory and the flag-off correctness matrix.

---

## 10. Known plan risks and accepted gaps

State these in the rollup rather than discovering them mid-run:

- **arm64 execution.** Tracks 01/08/09/15 claim both architectures. Decide up
  front whether arm64 runs on **native hardware** or under **QEMU emulation** and
  record which — emulated arm64 packaging and performance results degrade
  silently and are not evidence. If no arm64 host is available, mark arm64
  **untested** rather than implying coverage.
- **Runtime depth on PG 15/16.** The image ships pg15–pg18 but only Track 13 §6
  and a Track 04 slice touch 15/16. Durability, auth, and TLS are validated on
  PG17 (+PG18) only. That is a deliberate risk-based cut — record it as an
  accepted gap, not as coverage.
- **Track 14 baseline availability.** Every upgrade scenario needs a prior
  release to upgrade *from*. GitHub Actions artifacts expire (~90 days) and older
  `documentdb-local` tags may not exist under this repository path. **Confirm the
  0.113/0.114 image tags and package artifacts are actually obtainable before
  dispatching Track 14**; if they are not, the track is BLOCKED, not FAILED, and
  the coordinator needs to know on day one.
- **Tracks 08/09/10 need real hosts.** Ubuntu 24.04 and Rocky 9, both
  architectures, plus one SELinux-enforcing host. Confirm they exist before fan-out.
