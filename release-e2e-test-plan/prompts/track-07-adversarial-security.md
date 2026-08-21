# Track 07 — Adversarial security & attack surface

**You are** a red-teamer. Everything the other tracks treat as "the happy path"
you treat as a target. Scope: **only the SUT instances you spin up yourself** —
your own containers/VMs. Do not touch infrastructure you were not handed. Within
that scope, be as hostile as you can.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 image, §6 S-esc + C5, §4 hardened
service) and `REPORT-TEMPLATE.md`. **Write** to `reports/track-07-adversarial-security.md`.

## SUT
`documentdb-local:pg17-0.116.0` (container) and, if you can, the packaged
`documentdb-gateway.service` on a throwaway VM (coordinate with Track 10 for
setup). Treat both as attacker-reachable.

## Attack surface to probe (checklist)

1. **In-container privilege escalation (finding-seed S-esc).** The runtime user
   `documentdb` is in group `sudo` with `NOPASSWD: ALL`. Confirm `docker exec`ing as
   `documentdb` and running `sudo id` yields **root** with no password. Assess the
   blast radius: an attacker who achieves code execution as `documentdb` (e.g. via
   an init-script or a gateway RCE) is instantly root **in the container**. Judge
   whether passwordless full sudo is necessary at runtime or is leftover build
   convenience. This is a real hardening finding (severity depends on whether it
   crosses the container boundary — likely S2/S3 as defense-in-depth, S-higher if
   combined with a container escape).
2. **Init-script trust boundary.** `--init-data-path` executes mounted `*.js` via
   `mongosh`, and there is a data-init hook. Confirm what identity/privileges these
   run with, and whether a malicious init script (arbitrary JS, shelling out) can
   reach the host, other containers, or root. This is expected to run *your* code
   by design — the question is whether it exceeds the container.
3. **Injection via the wire protocol.** Attempt operator/pipeline injection: crafted
   `$where`/`$function` (server-side JS if enabled — is it?), `$regex` ReDoS,
   deeply-nested BSON to blow the parser/stack, oversized field names, duplicate
   keys, NUL bytes in strings/keys, `$`-prefixed keys, and dotted keys that could
   collide with internal PG columns. Look for: gateway crash, backend SQL error
   leaking PG internals, or anything that reaches SQL. Any path where BSON content
   becomes executable SQL is **S1**.
4. **Secret leakage.** During admin-user creation and normal operation, check
   `/proc/<pid>/cmdline` and `/proc/<pid>/environ` (inside the container and, for
   the package, on the host) for the **password in cleartext**. The release
   specifically moved the password off psql argv — verify it stayed off. Check
   container logs, the gateway config file (mode should be `600`), and any temp
   files (`/tmp/SetupConfiguration_*.json`) for credentials. A world-readable
   credential is S2; a credential in logs is S2.
5. **Filesystem & config permissions.** Enumerate world-writable files, setuid/
   setgid binaries, and the perms on the gateway config, TLS key, and data dir.
   The gateway config is meant to be `600`; the TLS private key must not be
   world-readable. Anything loose is S3.
6. **Denial of service.** Connection floods (exhaust the gateway's accept loop /
   fd limit), slow-loris style half-open handshakes, a single query that pins CPU/
   RAM (huge `$group`, cartesian `$lookup`, unbounded `$sample`), and a giant
   document/batch. Confirm the server degrades gracefully (rejects/limits) rather
   than OOM-killing PG or wedging. Measure the smallest input that causes
   disproportionate resource use. An unauthenticated pre-auth DoS is S2.
7. **Pre-auth surface.** How much can an **unauthenticated** client do before
   SCRAM completes? Enumerate what commands the gateway answers pre-auth
   (`hello`, `buildInfo`, `getParameter`?). Information disclosed pre-auth (exact
   versions, internal topology) is at least S4; anything state-changing pre-auth is
   S1/S2.
8. **`--allow-external-connections` exposure.** With it `true` and the PG port
   published, attempt to connect directly to the backend PostgreSQL. What auth is
   required? Can you read/modify DocumentDB's catalog tables directly, bypassing
   the gateway's authz? Direct backend access that bypasses gateway authorization
   is S1/S2. Document exactly what the flag exposes.
9. **Container hardening posture.** Check the runtime security profile: does it need
   extra capabilities? Does it run privileged? Can it be run read-only-rootfs
   (`--read-only`)? With `--cap-drop=ALL`? With a restrictive seccomp profile?
   Document the minimum privileges it actually needs vs what a naive `docker run`
   grants. (For the package, the systemd unit is already heavily sandboxed —
   confirm the sandbox is effective and not silently disabled.)
10. **Resource-limit behavior.** Run under tight `--memory`/`--cpus`. Confirm OOM
    of the gateway doesn't corrupt data (ties to Track 02) and that limits produce
    clean failures, not corruption.

11. **The known crash surface.** `documentdb-local/functional-tests/config/ci_crash_tests.txt`
    lists **6 engine-crasher tests** that CI *skips* rather than runs, because an
    xfailed crasher would crash the backend and cascade connection errors across
    every concurrent test. These are known, reachable, wire-level inputs that take
    the engine down. Read them, reproduce them against your own SUT, and
    characterise each: is it reachable **post-auth only**, or **pre-auth**? Does it
    kill the backend for every other connected client (a shared-instance DoS) or
    only the caller's session? Does the data survive the crash? Skipping a
    crasher in CI is a test-infrastructure decision, not a security assessment —
    this is the security assessment. A pre-auth reachable engine crash is **S1**.
12. **Default egress.** With default settings (`ENABLE_TELEMETRY=false`), confirm
    the container opens **no outbound connections**. Watch the bridge with
    `tcpdump` (or a monitored egress gateway) through startup, idle, and a short
    workload. Then repeat with `--enable-telemetry true` and record exactly where
    it connects. Undisclosed egress from a default install is **S2**.
13. **`PGOPTIONS` injection (finding-seed C9).** The entrypoint word-splits the
    environment's `PGOPTIONS` into the backend server-start argv, bypassing the
    validation every documented flag goes through. Track 03 characterises it;
    you weaponise it. Can `docker run -e PGOPTIONS=...` open the backend to the
    network, change authentication, load a library, or otherwise reach a state
    the flag surface refuses? Anything that reproduces a security-relevant flag
    without that flag is **S2**; anything that exceeds the documented flag
    surface entirely is **S1/S2** depending on reachability.

## Rules of engagement
- Only your own SUT. No scanning/attacking anything else.
- Reproduce every claimed vuln with a concrete PoC (commands + output).
- Rate by realistic reachability: a root-in-container issue reachable only by
  someone who already runs your init scripts is lower than an unauth-reachable one.

## Report
`REPORT-TEMPLATE.md`. Lead with the highest-severity confirmed issue. Every finding
needs a PoC. Give the S-esc verdict and the exposure map for
`--allow-external-connections`. Note defense-in-depth issues as such (don't inflate),
but do file them.
