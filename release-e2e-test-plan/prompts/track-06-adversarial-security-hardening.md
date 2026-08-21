# Track 06 — Adversarial Security & Hardening (agent prompt)

You are an offensive-security-QA agent. Your job is to **break it**: exposure,
injection, resource exhaustion, secret leakage, container posture, and supply
chain. Read `../ENVIRONMENT-SETUP.md`, `../REPORT-TEMPLATE.md`, and the findings
from Tracks 03/04/05 (they map the surface). Assume authorized testing on
disposable, isolated SUTs only — never a shared host, never external targets.

## Contract facts that shape the attack surface (from the runtime map)
- **Gateway binds `0.0.0.0` AND `[::]` by default** (backlog 4096). Only the
  gateway port should be reachable; the internal PG port must NOT be published.
- **No HTTP/metrics/health endpoint exists** — attack surface is the wire port
  (10260), the internal PG socket, and the container/host.
- **Limits & timeouts:** `maxBsonObjectSize` 16 MiB, `maxMessageSizeBytes` 48 MB,
  `maxWriteBatchSize` 100000; `max_connections` from PG GUC (**fallback 25**);
  pool reserves 2 (system) + 5 (auth); **`SocketConnectionIdleTimeout` = 18000s
  (5 hours)**; `TransactionTimeoutSecs` 30; `PostgresCommandTimeoutSecs` 120; TLS
  peek timeout 5s; conn buffer 262144, idle 300s, lifetime 3600s.
- **OP_COMPRESSED is rejected** (no wire decompression → no zip-bomb via
  compressors, but confirm).
- **Container runs as user `documentdb`, which is in `sudo` with `NOPASSWD:ALL`**
  (`/etc/sudoers.d/no-pass-ask`). Assess blast radius if the gateway or an init
  script is compromised.
- **Password hygiene:** admin creation JSON-encodes the password via `jq
  --rawfile` from a 0600 temp file and pipes SQL on stdin with `ON_ERROR_STOP=1`
  — the password should never appear in argv. Verify this holds.
- **Images are cosign keyless-signed and verified** in CI; `mongosh` 8.0 and a
  full PostgreSQL stack are baked in (CVE surface).

## Test cases (attack, then classify by severity)

### A. Network exposure (S1 if the PG port is reachable)
1. With `docker run -P` (publish all) and defaults, prove the **internal PG port
   is NOT reachable** from the host and PG binds loopback inside (reuse Track 02's
   `/proc/net/tcp` probe). Then port-scan the container's published ports — only
   10260 should answer.
2. `--allow-external-connections true` is the ONLY switch that exposes PG; confirm
   nothing else (a stray flag, INIT_DATA, a mounted config) opens it inadvertently.
3. From a second container on the same docker network, enumerate what the SUT
   exposes; attempt to reach PG 9712 directly.

### B. Injection (NoSQL / BSON / SQL passthrough) — S1/S2
4. Operator/`$where`/`$function`/`mapReduce`-style JS injection in queries — must
   not execute arbitrary code server-side (mapReduce is unsupported → 115; confirm
   no JS engine is reachable).
5. **SQL injection via the translation layer:** field names, collection/db names,
   `$expr`, regex, and values crafted to break out of the generated SQL
   (`'; DROP …`, `\x00`, `${}`, `--`, unicode escapes, nested `$`-operators). The
   gateway delegates to `documentdb_api.*` functions — verify no crafted input
   reaches raw SQL. Namespaces with embedded null are explicitly rejected when
   `enable_null_collection_validation` is on — test both states.
6. Reserved-name / PG-role injection via createUser/createRole (cross-ref Track 04).

### C. Resource exhaustion / DoS — S2/S3
7. **Connection exhaustion:** open connections up to and beyond `max_connections`
   (default fallback 25) — does the gateway degrade gracefully (queue/reject
   cleanly) or wedge? Confirm the 2+5 reserved pool slots keep system/auth working
   under saturation.
8. **Idle-connection hold:** open many connections and hold them idle — the 5-hour
   `SocketConnectionIdleTimeout` means an attacker can pin connections cheaply.
   Measure how many idle connections it takes to deny service; classify.
9. **Slowloris on TLS:** many half-finished TLS handshakes (stall after
   ClientHello) — does the 5s peek timeout protect the listener, or can the accept
   loop be starved?
10. **Memory pressure:** max-size (16 MiB) documents in a 100000-op batch;
    deeply-nested BSON; huge aggregation (`$group` over a large set,
    cartesian `$lookup`). Watch RSS; confirm `PostgresCommandTimeoutSecs`/txn
    timeout bound it and it returns a clean error rather than OOM-killing the
    backend. Run the container with `--memory` caps to force the edge.
11. **Cursor/txn leak:** open many cursors/transactions and abandon them — confirm
    the idle reapers (cursor 60s/600s; txn 30s) actually reclaim them.
12. Malformed/oversized wire frames (bad `messageLength`, 48 MB+1 message,
    truncated OP_MSG) — reject without crashing the backend or leaking fds.

### D. Secret hygiene — S1 if a secret leaks
13. **Password never in argv:** while creating the admin user and while running
    `documentdb-gateway-admin`, scan `/proc/*/cmdline` using the **positive-control
    pattern** (plant a sentinel, prove the probe sees it, then prove it does NOT
    see the password) from `e2e-extra-scenarios.sh`. A probe you didn't validate =
    UNVERIFIED, not PASS.
14. **Password not in logs:** with `--log-level trace`, scan `docker logs`, the
    gateway log files, and PG logs for the plaintext password, SCRAM secrets, or
    the URL-file contents. The `Debug` impl is supposed to redact the password —
    confirm.
15. **Password not in env of other processes / image layers:** `docker inspect`
    env, `/proc/<pid>/environ` of non-owning processes, and image history/layers
    (`docker history`, dive) should not embed a real credential (the Dockerfile
    default is `default_user`, no baked password — confirm no build-time secret).
16. The gateway `pg-url` file is `root:documentdb-gateway 0640` — confirm perms and
    that it carries no password (packaged install rejects passwords in it).

### E. Container / host hardening — S2/S3
17. **`sudo NOPASSWD` posture:** as the `documentdb` user inside the container, you
    can `sudo` freely. Assess: if the gateway process or an init script is
    compromised, it can become root-in-container. Test running the image with
    `--cap-drop=ALL --security-opt=no-new-privileges`, `--read-only`, and a
    non-root `--user` — document what breaks and what a hardened deployment looks
    like. Recommend dropping the NOPASSWD sudo if it isn't needed at runtime.
18. Writable-layer / world-writable file audit inside the image; SUID/SGID binary
    scan; check the gateway binary and scripts aren't group/world-writable.
19. Container escape surface: default `docker run` (no `--privileged`) — confirm no
    host mounts, no docker socket, no host network by default.

### F. Supply chain — S2/S4
20. **Image CVE scan:** run Trivy/Grype on the image; report HIGH/CRITICAL CVEs in
    the base (debian/ubuntu), PostgreSQL stack, `mongosh` 8.0, and any bundled
    libs. Note fixable vs unfixable.
21. **Signature verification:** confirm the release image manifest is cosign-signed
    and verifiable (the identity regexp points at the build workflow). A published
    `latest` that fails verification is a finding.
22. SBOM / bundled-component inventory: list what ships in the image and flag
    anything unexpected (extra tools, debug binaries, secrets in `/root`, shell
    history).

## How to break it (open-ended — this is the point)
Chain the above. E.g.: unauth pre-auth commands (only 4 allowed — try to smuggle a
5th); a crafted namespace that survives validation and reaches SQL; an idle-conn
flood that starves the 25-slot pool while a valid admin is locked out; a trace-log
that leaks a SCRAM secret. If you find a novel break no case named, that's the win
— file it with a clean repro.

## Evidence to capture
Port-scan output; the injection payloads + the exact server responses/logs proving
they were neutralized (or not); resource-exhaustion graphs (connections vs
success, RSS vs load); positive-control secret-scan transcripts; Trivy/Grype JSON;
cosign verify output; `docker inspect`/`history` excerpts.

## Out of scope / hand-offs
Functional correctness of the neutralized inputs → 03. Auth semantics → 04. TLS
protocol details → 05. Durability after a crash → 07. Perf baselines → 08.

Write your report to `../reports/TRACK-06-adversarial-security-hardening-report.md`.
