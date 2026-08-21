# Track 02 — Container Lifecycle & Emulator (agent prompt)

You are a release-QA agent. Verify the `documentdb-local` **container image**
starts, configures, persists, and shuts down correctly and safely across its
whole flag/env surface. Read `../ENVIRONMENT-SETUP.md` and `../REPORT-TEMPLATE.md`
first. Target: the image only (packaged install = Track 01).

## What to stand up
Docker on a Linux host (Docker Desktop on Win/Mac is acceptable for this track).
Set `IMG` to the image under test. **Run the existing container suite first**,
then add the cases below:
```bash
DOCUMENTDB_LOCAL_IMAGE="$IMG" ./packaging/test_packages/e2e-container-scenarios.sh   # C1/C3/C4
```
Always start containers with a **runtime-generated** strong password
(`PW="$(openssl rand -hex 12)Aa1!"`), never a literal.

## Reference facts (from ground truth)
Entrypoint takes flags as `docker run $IMG --username X --password Y …`. Gateway
port 10260; internal PG 9712 (must stay localhost). Readiness banner:
`=== DocumentDB is ready ===`. `VOLUME ["/data"]`. No HEALTHCHECK, no EXPOSE.
Runs as user `documentdb`. `/version.txt` identifies the build.

## Test cases

### A. Startup & identity
1. **Happy path:** `docker run -d -p 10260:10260 -e USERNAME=admin -e PASSWORD=$PW $IMG`
   reaches the ready banner within a sane time (record cold-start seconds as INFO);
   `mongosh ping` returns `"ok":1`.
2. **Identity:** `/version.txt` prints `<0.118.x> (commit …, built …, postgresql
   <N>)`; image label `com.documentdb.documentdb.local=true` and
   `org.opencontainers.image.version` present. `docker exec $c cat /version.txt`
   agrees with the installed extension version.
3. **Flags vs env override:** setting both `-e DOCUMENTDB_PORT=10261` and
   `--documentdb-port 10262` → the flag wins (10262). Spot-check a few
   env/flag pairs from the ground-truth table behave as "flag overrides env".

### B. Credential & default-password policy (safety-critical)
4. **No password → refuse to start.** With neither `PASSWORD` nor `--password`,
   the container must NOT silently start on `default_user`/`Admin100`. It should
   error and exit (unless `DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true`).
5. **Escape hatch works but is loud:** with `DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true`
   and no creds, it starts on the defaults **with a visible warning** telling the
   user to migrate. Confirm the warning text exists.
6. **Special-character password** (`pa"ss'w0rd\!x`) round-trips: container becomes
   ready and that password authenticates via mongosh (C4 covers this — extend
   with more nasty inputs: unicode, spaces, very long).
7. **Reserved/blocked username** (`USERNAME=documentdb_x`, or exact
   `documentdb_admin_role`) must **fail the container** (exit non-zero), never
   report ready with an unusable user (C4b pattern; blocked prefixes:
   `documentdb`, `citus`, `pg`, `internal_role`).

### C. Network exposure (safety-critical — this is the CHANGELOG breaking fix)
8. **Internal PG not published by default:** with `-P` (publish all), the internal
   PG port (9712) must NOT be reachable from the host, and inside the container PG
   must be bound to loopback, not `0.0.0.0` (C1 pattern — reuse its `/proc/net/tcp`
   probe).
9. **`--allow-external-connections true`** deliberately opens PG to all interfaces
   — confirm it does what it says AND that this is the ONLY way it happens.
   Document the risk for Track 06.

### D. Persistence, restart, shutdown (durability handshake — deeper in Track 07)
10. **Named volume persistence:** write data, `docker restart`, data survives.
    `docker rm` + new container on the same volume → data + the admin user survive
    and authenticate.
11. **Clean shutdown = no WAL recovery:** stop the container gracefully; next boot
    on the same volume shows no "database system was not properly shut down /
    automatic recovery in progress" (C3 pattern).
12. **Gateway self-exit → clean PG stop + non-zero exit:** kill the gateway inside
    the container; the entrypoint must run `pg_ctl stop -m fast` ("Stopping
    PostgreSQL (fast)") and the container must exit non-zero (C3).
13. **SIGTERM handling:** `docker stop` completes within the grace period without
    a SIGKILL; PG stops cleanly.

### E. Config surface behaviors
14. **`--init-data true`** seeds sample data once per fresh volume and prints
    `Custom data initialization completed.`; re-run on the same volume does NOT
    re-seed; a fresh volume seeds again.
15. **`--init-data-path`** runs mounted `*.js` alphabetically once per fresh
    volume; a failing script is not retried on restart (document the behavior).
16. **`--tlsMode requireTLS`** rejects plaintext; `allowTLS`/`disabled` accept both
    (hand the deep TLS matrix to Track 05, but sanity-check here).
17. **`--log-level`** changes verbosity (quiet…trace); `--toast-compression
    lz4|pglz|default` is accepted and applied (lz4 default). `--start-pg false`
    behaves as documented (BYO external PG; getParameter returns a raw PG error).
18. **Custom `--documentdb-port` / `--pg-port`** work end-to-end.

## How to break it
- Start with `DATA_PATH` pointing at a read-only mount, or a non-empty non-PG
  directory, or a directory owned by the wrong uid — expect a clear failure, not
  corruption or a hang.
- OOM: run with `--memory=256m` and hammer it — does it fail cleanly or get
  OOM-killed leaving a dirty volume (feeds Track 07)?
- Yank the volume mid-write (`docker kill -s SIGKILL` during a bulk insert) then
  reboot — assess recovery (hand detail to Track 07).
- Pass garbage to every flag (`--documentdb-port abc`, `--log-level yell`,
  `--tlsMode maybe`, `--allow-external-connections perhaps`,
  `--toast-compression zstd`) — expect validation + a sane default or a clean
  refusal (the entrypoint has `sanitize_uint`; verify it actually guards).
- Two containers publishing the same host port — expect the second to fail
  clearly.
- Run the image with `--read-only` rootfs; run as a non-root `--user`; drop all
  caps (`--cap-drop=ALL`) — document what still works (orchestration-hardening UX).
- **No HEALTHCHECK:** confirm the image really ships none, and note the
  orchestration-UX cost (Kubernetes/compose users must write their own probe).
  Suggest what a good probe would be (e.g. `mongosh ping` or a gateway TCP check).

## Evidence to capture
`docker logs` around the ready banner and around shutdown; `docker inspect`
(State, ExitCode, Config.Labels, Healthcheck=null); the `/proc/net/tcp` listener
readout for C1; `docker port` output; cold-start timing; the mongosh transcripts.

## Out of scope / hand-offs
Protocol/CRUD depth → 03. Auth semantics depth → 04. TLS matrix → 05. Adversarial
resource/secret attacks → 06. Durability deep-dive → 07. Telemetry → 12.

Write your report to `../reports/TRACK-02-container-lifecycle-report.md`.
