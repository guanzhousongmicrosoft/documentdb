# Track 09 — UX, Docs & First-Run Fidelity (agent prompt)

You are a developer-experience-QA agent. Verify that a new user following the
**published instructions verbatim** succeeds, that errors are clear and
actionable, and that docs match reality. Read `../ENVIRONMENT-SETUP.md` and
`../REPORT-TEMPLATE.md` first. You test the *experience*, so favor "do exactly
what the README says, byte for byte" over clever shortcuts.

## Known doc/behavior drifts to confirm (finding-seeds from the source)
- **`--log-level` / `LOG_LEVEL` and `--enable-telemetry` / `ENABLE_TELEMETRY` are
  validated by the container entrypoint but NEVER exported to the gateway.** So in
  the container, `--log-level debug` and `ENABLE_TELEMETRY=true` are **currently
  no-ops** (the daemon reads `DOCUMENTDB_LOG_LEVEL`/`RUST_LOG` and telemetry from
  JSON). Confirm live — this is likely an **S2/S3** UX+functional finding.
- **`--enable-telemetry` help text says "Azure Application Insights"**, but the
  shipped config is **provider-neutral OTLP** (`http://localhost:4317`). Doc drift
  (S4) — confirm and report.
- **No `HEALTHCHECK`** in the image — orchestration UX gap (S3). Recommend a probe.
- **Two version grammars** (`0.118-0` for the extension vs `0.118.0` for
  everything else) — confirm this is documented and not confusing in `dpkg`/`dnf`
  output for a packager.
- **`--tlsMode disabled` does not disable TLS** (prints a warning) — verify the
  warning is clear enough that a user isn't misled.

## Test cases

### A. README quickstart, verbatim (the front door)
1. Follow the README Get-Started **exactly**: `docker pull` the image, `docker tag`
   it `documentdb`, `docker run -p 10260:10260 … --username … --password …`, then
   the pymongo snippet (create db/collection, insert, find, aggregate). Every step
   must work as written. Any deviation needed to succeed is a doc bug — record the
   exact fix required.
2. The `mongodb://…?tls=true&tlsAllowInvalidCertificates=true` connection string in
   the README connects. Confirm the README explains *why* `tlsAllowInvalidCertificates`
   is needed (self-signed default) and what a production user should do instead.
3. The port note (10260 default, "you may use 27017") is accurate — try remapping
   to 27017 and confirm the instructions for updating both the run command and the
   connection string are complete.

### B. Packaged install docs (packaging/README.md workflows)
4. Follow Workflow C, A, and B **as documented** on the paved-road target
   (Ubuntu 24.04 + PG 18). Each documented command exists, the flags are real, and
   the described outcome happens (cross-ref Track 01 for correctness; here you
   judge whether the *docs* are followable by a newcomer).
5. The RHEL PGDG/EPEL/CRB prerequisite block works copy-paste; the guidance is also
   visible in `dnf info` before install (as claimed).
6. `--load-sample-data` requires mongosh — the docs say so and the failure when
   mongosh is absent is clear.

### C. CLI help & discoverability
7. `documentdb-setup --help`, `documentdb-gateway-admin --help` (+ each
   subcommand), `documentdb-tune --help`, `documentdb-register-gateway --help`,
   and the container `--help` (`usage()`): each lists its real flags, defaults, and
   at least one example. Flags shown in help actually exist and work; flags that
   exist are shown in help (no hidden required flags).
8. `documentdb-gateway --version` / `-V` and `documentdb-gateway check` behave and
   are documented. `--config` missing file exits **78** with a clear message;
   unknown flag / duplicate `--config` exits **2**.
9. `documentdb-setup --status` / `--print-config` / `--dry-run` give useful,
   honest output on a clean host (they must not silently mutate — cross-ref
   Track 01 DRYRUN/READONLY).

### D. Error-message quality (the thing users actually hit)
10. Trigger the common mistakes and judge whether the message tells the user *what
    to do*:
    - Start the container with no password → the refusal explains how to set one.
    - Blocked/reserved username → the message names the allowed alternatives.
    - Wrong port / not published → connection failure is diagnosable.
    - `documentdb-setup` on PG 15 → the "needs PG 16+" message is clear.
    - Contradictory setup flags → the "mutually exclusive" message names both.
    - Missing RHEL repos → the dependency error points at the fix.
11. The container "ready" banner prints a usable connection URI and the persistence
    (`-v`) guidance; the default-credentials warning is prominent and tells the
    user to migrate.

### E. First-run friction & polish
12. Cold-start time to the ready banner (record; a long, silent wait with no
    progress output is a UX finding — is there interim progress?).
13. Log readability at default `info`: can a user tell it's healthy? Are the
    `[POSTGRES]`/`[GATEWAY]`/`[ENTRYPOINT]` prefixes helpful, or is it noisy?
14. Version/identity discoverability: `/version.txt`, image labels, `buildInfo`
    version all agree and are easy to find.
15. Docs cross-check: README, `packaging/README.md`, `AGENTS.md`, and the
    `gateway.env`/`SetupConfiguration.json` comments don't contradict each other on
    ports, defaults, or supported versions.

## How to break the experience
- Do exactly what a rushed developer does: copy-paste the quickstart into a fresh
  machine with nothing installed; skip the optional steps; use a weak password;
  forget `-v`; use `27017`. Note every place they'd get stuck without reading
  further.
- Follow a doc that references a flag/path and verify it actually exists (catch
  stale docs). Grep the docs for any command and run it.
- Try the "obvious wrong thing" for each flag and see if the error teaches or
  confuses.

## Evidence to capture
The verbatim command transcripts (showing it worked or exactly where it broke);
side-by-side of doc text vs actual behavior for each drift; the help outputs; the
error messages quoted in full; cold-start timing.

## Out of scope / hand-offs
Deep functional correctness → 03. Security of the defaults → 06. Telemetry/logging
internals → 12. You judge *followability and clarity*, and file doc-vs-reality
drift as findings.

Write your report to `../reports/TRACK-09-ux-docs-fidelity-report.md`.
