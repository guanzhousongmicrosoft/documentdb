# Track 03 — Container config & entrypoint hardening

**You are** a fuzzer of the container's configuration surface. Every flag, every
env var, every bad value. You want to find an input that makes the container lie
about its state (reports ready but isn't), silently ignore a setting, spin, or
start in a surprising configuration.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 flags/env/defaults, §6 seeds, §7 #61)
and `REPORT-TEMPLATE.md`. **Write** to `reports/track-03-container-config-entrypoint.md`.

## SUT
`documentdb-local:pg17-0.116.0`. The flag/env inventory and defaults are in
`ENVIRONMENT-SETUP.md §2`. Flags override env vars.

## What to test (checklist)

1. **`--help` / `-h` fidelity.** Dump usage. Cross-check every documented flag
   against actual behavior (Track 12 owns deep doc-fidelity; here just flag that
   help text and behavior disagree). Confirm help lists: cert-path, key-file,
   data-path, documentdb-port, enable-telemetry, log-level, username, password,
   create-user, start-pg, pg-port, owner, allow-external-connections, init-data,
   init-data-path, skip-init-data, disable-extended-rum, toast-compression.
2. **Password contract (finding-seed C3).** Start with **no** `--password` and no
   `PASSWORD`. What happens? Usage says REQUIRED; the entrypoint also carries an
   `Admin100` default. Determine empirically: does it refuse to start, or does it
   start with a **default/guessable password**? A container that silently starts
   with a known default password is **S1/S2** (auth). Document the exact outcome.
3. **Port parsing.** `--documentdb-port` with: a normal value; a zero-padded value
   (`010260` — must be parsed base-10, not octal); non-numeric (`abc`); empty;
   `0`; `70000` (out of range); a value already in use. Confirm valid values bind
   and invalid ones are rejected **before** the "ready" banner. Same battery for
   `--pg-port`. A bad port that leaves the gateway silently on the default (not the
   requested one) is S2.
4. **Boolean validation.** For each strict boolean (`--enable-telemetry`,
   `--allow-external-connections`, `--init-data`, `--skip-init-data`,
   `--create-user`, `--start-pg`): pass `true`, `false`, and junk (`1`, `yes`,
   `TRUE`, ``). Confirm junk is rejected with a clear message and the container
   does **not** start half-configured.
5. **`--log-level` effect (finding-seed C4).** Set `--log-level debug` and
   `--log-level quiet`. Compare gateway log volume/verbosity against the default.
   Determine whether the setting **actually changes gateway output** or is a
   validated no-op (it is exported to the env but may not be written to gateway
   config / passed as a flag). If quiet still logs at info, or debug adds nothing,
   that's an S3 UX/observability defect. Invalid level must be rejected.
6. **`--enable-telemetry` effect (finding-seed C5).** Stand up a throwaway OTLP
   collector reachable at the gateway's `OtlpEndpoint` (default
   `http://localhost:4317` — you may need `OTEL_EXPORTER_OTLP_ENDPOINT` or
   `--network host`). Start with `--enable-telemetry true`. Determine whether any
   spans/metrics actually arrive. If the flag validates + exports but the gateway
   config still hardcodes `Enabled:false` and nothing is emitted, the flag is a
   **no-op** → S2/S3 (a security-relevant setting that does nothing). Also confirm
   default (`false`) emits **nothing**.
7. **Bare-positional spin — #61 (finding-seed, §7).** Pass a **bare positional**
   argument that does not start with `-` (e.g. `docker run IMG foo` or
   `... --username u --password P junk`). It must **print the offending token on
   stderr and exit 1 within seconds** — NOT spin PID 1 at 100% CPU forever. Measure
   CPU for ~15s to be sure. A spin/hang here is **S1** (regression of #61).
8. **`--start-pg false` mode.** Documented advanced mode: expects an external PG on
   `localhost:--pg-port`. Start it with no external PG and confirm it fails clearly
   (doesn't hang forever or report ready). If you can provide an external PG,
   confirm gateway-only setup works and note the documented caveat that
   `getParameter` returns a raw PG undefined-function error in this mode (C7 lives
   in T04).
9. **`--allow-external-connections true`.** Confirm it opens the **internal PG
   port** (`listen_addresses='*'` + permissive hba) and that `false` keeps it
   closed. Publish the PG port (`-p 9712:9712`) and verify reachability matches the
   flag. This is a security-relevant exposure — record exactly what becomes
   reachable and with what auth (feed anything alarming to Track 07).
10. **`--data-path`, `--owner`, `--username` validation.** Reserved/blocked
    usernames (e.g. `documentdb`, `pg…`, `citus`, `internal_role`) must be
    **rejected before start** (the container must not report ready with a user that
    can never authenticate). Non-existent/again unwritable `--data-path` must fail
    clearly. `--toast-compression` with lz4/pglz/an invalid value.
11. **Combined-flag sanity.** A realistic "everything at once" invocation
    (custom port + username + init-data-path + allow-external + toast-compression)
    must either start correctly or fail with one clear message — never partially.

12. **`--disable-extended-rum`.** Inventoried in `ENVIRONMENT-SETUP §2` and easy
    to forget. Confirm it is accepted, that the container starts, and that the
    setting is observable at runtime (it drops `-r` from the backend server
    start, so extended RUM is **on** by default). Depth — AM selection, result
    equivalence, volume toggling both ways — belongs to Track 16 (seed C10); here
    just prove the flag is wired and does not half-start the container.
13. **`PGOPTIONS` back-door (finding-seed C9).** The entrypoint reads `PGOPTIONS`
    **from the environment** and word-splits it into the backend server-start
    argv — it is the channel the entrypoint itself uses to pass `-e` for
    `--allow-external-connections`. It is not documented in `--help` and appears
    in no validation path. Determine empirically what
    `docker run -e PGOPTIONS="..." IMG ...` can do: can a user reach backend
    server arguments the flag surface deliberately gates (external connections
    among them), bypassing the validation every other setting goes through? An
    unvalidated env channel that reaches server argv is at least S3, and **S2 if
    it reproduces the effect of a security-relevant flag** without that flag.
    Hand whatever you find to Track 07.

## Expected results
Invalid inputs are rejected **before** "ready"; #61 positional exits fast; reserved
usernames rejected; the C3/C4/C5 seeds get definitive empirical verdicts.

## Report
`REPORT-TEMPLATE.md`. This track drives verdicts for C3, C4, C5 and the #61
regression check. For each rejected-input case, show the exit code and the stderr
line. Note CPU measurement for the #61 case.
