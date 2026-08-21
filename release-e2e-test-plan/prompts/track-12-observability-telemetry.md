# Track 12 — Observability & Telemetry (agent prompt)

You are an observability-QA agent. Verify logging, health-probing, and telemetry:
that telemetry is genuinely opt-in and off by default, that enabling it works and
points where configured, and that operators can actually tell whether the system
is healthy. Read `../ENVIRONMENT-SETUP.md` and `../REPORT-TEMPLATE.md` first.

## Contract facts (from the runtime map)
- **Telemetry is provider-neutral OTLP, opt-in, OFF by default:**
  `TelemetryOptions.Metrics.Enabled=false`, `Tracing.Enabled=false`, OTLP endpoint
  `http://localhost:4317`, `ExportIntervalMs 15000`, `SamplerRatio 1.0`. Overridable
  via `OTEL_*` env vars. (This is the v0.117 "provider-neutral" refactor.)
- **No HTTP metrics/health endpoint exists.** Health is out-of-band:
  `documentdb-gateway check` (a connectivity/extension probe) and the container's
  `nc -z localhost 10260` readiness loop.
- **`serverStatus` is unsupported (code 115)** — monitoring tools that poll it will
  break (cross-ref Track 10). `currentOp`/`killOp` are supported.
- **Container `ENABLE_TELEMETRY` and `LOG_LEVEL` are validated but NEVER exported
  to the gateway** → enabling telemetry or raising log level *via the container
  flags* is currently a **no-op**. The daemon reads `DOCUMENTDB_LOG_LEVEL`/`RUST_LOG`
  and telemetry from the JSON config. **Assert this and file it (S2/S3).**
- **`--enable-telemetry` help text names "Azure Application Insights"** — stale;
  it's OTLP now. Doc drift (S4).
- Log files: `/var/log/documentdb/{gateway_entrypoint,gateway,oss_server}.log`,
  `/var/log/documentdb/postgres/pglog.log`; docker-log prefixes `[POSTGRES]`,
  `[POSTGRES-SYSTEM]`, `[OSS-SERVER]`, `[ENTRYPOINT]`, `[GATEWAY]`, `[GATEWAY-FILE]`.
- The gateway `Debug` impl **redacts the password**.

## Test cases

### A. Telemetry default-off (privacy/trust — S1 if it phones home)
1. **Nothing is emitted by default.** Run the container/gateway with defaults and a
   packet capture (or an OTLP sink you control at `:4317`, plus egress monitoring):
   confirm **zero** metrics/traces leave the process, and no connection is attempted
   to any external endpoint. A default build that sends telemetry anywhere is an
   **S1** trust violation.
2. Confirm the shipped `SetupConfiguration.json` really has both `Enabled:false`
   and that the packaged/stripped config doesn't accidentally flip them.

### B. Telemetry opt-in actually works
3. Enable metrics+tracing in the JSON config (or via `OTEL_*` env), point
   `OtlpEndpoint` at a collector you run (e.g. an OTEL Collector or a netcat sink),
   generate load, and confirm metrics/traces arrive at the configured endpoint with
   the `ServiceName` `documentdb_gateway`. `OTEL_EXPORTER_OTLP_ENDPOINT` /
   `OTEL_TRACES_SAMPLER_ARG` overrides take effect.
4. **Container flag no-op:** set `ENABLE_TELEMETRY=true` on the container with
   default JSON and confirm — per the contract — that it does **NOT** turn
   telemetry on (because the flag isn't wired to the gateway). File the finding;
   also confirm the *supported* way (editing the JSON / OTEL env) does work.

### C. Logging
5. Default `info` logs are useful: startup, readiness, connection, and error events
   are visible with sensible detail; the `[COMPONENT]` prefixes route correctly.
6. **Log-level control:** raising verbosity via the **supported** mechanism
   (`DOCUMENTDB_LOG_LEVEL=debug`/`trace` or `RUST_LOG`) actually increases gateway
   verbosity; confirm the **container `--log-level` flag does NOT** (the no-op
   finding). An invalid level warns and falls back to `info`.
7. **Secret redaction:** at `trace`, no plaintext password, SCRAM secret, or
   URL-file credential appears in any log (cross-ref Track 06's positive-control
   scan). The redacting `Debug` impl holds.
8. Log volume/noise at `info` is reasonable (not a flood); errors carry the
   `code`/`codeName` so they're greppable.

### D. Health & monitoring
9. **`documentdb-gateway check`** reports connectivity + extension status
   correctly: green when healthy, non-zero + a clear reason when PG is down / the
   extension is missing / the port is wrong.
10. Readiness signal: the `=== DocumentDB is ready ===` banner and the `nc -z`
    loop are the only built-in readiness signals — assess whether that's enough for
    Kubernetes/compose. Recommend a concrete liveness/readiness probe (e.g. a
    `mongosh --eval 'db.runCommand({ping:1})'` exec probe or a TCP check on 10260),
    since there's **no HEALTHCHECK** and **no HTTP health endpoint**.
11. **`serverStatus` unsupported:** confirm the 115 response and enumerate which
    common monitoring paths (mongostat, Compass server stats, APM MongoDB
    integrations) break as a result. `currentOp` works — verify it returns running
    ops and `killOp` can stop one.
12. PostgreSQL-side observability still available (the `pglog.log`, PG stats
    views) for operators who go under the hood — confirm it's reachable and useful.

## How to break it
- Point `OtlpEndpoint` at a dead/black-hole address under load — does a failing
  exporter block or crash the gateway, or degrade quietly? (An exporter that
  back-pressures the request path is a real availability risk.)
- Enable tracing with `SamplerRatio 1.0` under heavy load and measure the overhead
  (hand the number to Track 08).
- Fill/rotate the log volume — does logging handle a full disk without wedging the
  gateway?
- Feed `OTEL_*` env vars with garbage — clear rejection/fallback, not a crash.
- Confirm there's truly no unauthenticated info-leak surface (since there's no HTTP
  endpoint, verify nothing like a debug port or pprof is exposed).

## Evidence to capture
The packet-capture / collector state proving default-off; the collector showing
data on opt-in; log excerpts at each level (with the no-op flag demonstrated
side-by-side with the working mechanism); `documentdb-gateway check` output in
healthy and broken states; the `serverStatus` 115 response; the recommended probe
config.

## Out of scope / hand-offs
Secret-hygiene depth & CVE → 06. Perf overhead numbers → 08. Doc wording fixes →
09 (but file the telemetry-backend-name drift here too). You own: is it off when it
should be, on when asked, and can an operator see health?

Write your report to `../reports/TRACK-12-observability-telemetry-report.md`.
