# Track 12 — UX & documentation fidelity

**You are** a first-time user and a documentation auditor at once. You follow the
official quickstart/docs exactly as written, note every place reality diverges from
what you were told, and judge whether error messages, help text, and defaults set a
new user up to succeed or to get stuck.

**Read first:** `ENVIRONMENT-SETUP.md` (whole file; esp. §6 C4/C5/C8/U1, §4 PK2)
and `REPORT-TEMPLATE.md`. **Write** to `reports/track-12-ux-docs.md`.

## SUT
Both the container image and the packages, but judged through the **documentation**:
the repo `README`, the container/quickstart docs, `--help` output, `gateway.env`
comments, and the `documentdb.io` site if reachable. Prefer the docs that ship with
the release tag.

## What to test (checklist)

1. **Quickstart, literally.** Follow the documented "run the container" quickstart
   verbatim, copy-pasting commands. Every command must work as written. A
   copy-paste that fails (missing `-p`, missing TLS flags, a wrong image tag, a
   required `--password` the quickstart omits) is an S2/S3 depending on how stuck it
   leaves a new user. Record each divergence.
2. **`--help` accuracy.** Compare `--help` (container entrypoint) against actual
   behavior for every flag. Known mismatches to confirm:
   - **U1:** `--enable-telemetry` help says **"Azure Application Insights"**, but
     telemetry is provider-neutral **OTLP/OpenTelemetry** (the config comments say
     OTLP/OTEL). The help text names the wrong system → S3/S4 doc bug.
   - **C4:** if Track 03 confirms `--log-level` doesn't actually change verbosity,
     the help documenting it as effective is a doc bug too.
   - **C5:** if `--enable-telemetry true` is a no-op, the help promising telemetry
     is misleading.
   - Any flag whose documented default disagrees with the baked-in env default in
     `ENVIRONMENT-SETUP §2`.
3. **TLS mode wording (C8).** The `disabled` TLS mode does **not** disable TLS.
   Confirm the docs/warning make this clear **before** a user relies on it. Silent
   or buried is S3.
4. **Password requirement clarity (C3).** Is it obvious to a new user that
   `--password` is required (or what the default is)? The first-run failure mode for
   a forgotten password should be a clear message, not a cryptic exit.
5. **Connection instructions.** Do the docs give a **working** `mongosh`/driver
   connection string including the TLS + auth flags the self-signed default
   requires? A quickstart that shows `mongosh localhost:10260` with no TLS flags
   (which fails against the default) is S2 — it's the first thing every user does.
6. **Readiness guidance (C1).** With no HEALTHCHECK, do the docs tell operators how
   to wait for readiness (the `=== DocumentDB is ready ===` banner) and how to
   health-check in an orchestrator? Missing guidance is S3.
7. **Package docs.** Do the DEB/RPM install docs list the **PGDG repo** prerequisite
   and the exact package names? Do they cover `documentdb-setup` greenfield vs
   brownfield, and the **local-PG-only** limitation (PK2)? A user who follows the
   docs must reach a working gateway. Missing PGDG step is S2 (install just fails).
8. **Error-message quality.** Trigger the common first-timer errors (no password,
   bad port, reserved username, wrong TLS flags, disk full, PG not ready) and judge
   each message: does it say what's wrong and what to do? Collect the bad ones.
9. **Sample data / examples.** If `--init-data`/sample-data and the `sample-data/`
   scripts are advertised, run them as documented and confirm they load and the
   examples in the docs return what the docs claim.
10. **Version/label discoverability.** Can a user easily confirm which version
    they're running (image label, `/version.txt`, a server command)? Confirm the
    documented method works and reports `0.116.0`.
11. **Changelog/release-notes fidelity.** Spot-check that headline 0.116 changelog
    claims (e.g. `$jsonSchema enum`/`oneOf`, `$sample` rename, streaming `$group`)
    are actually true against the running server — a release note that describes a
    feature that isn't there is S3.
12. **Consistency of naming.** "DocumentDB Local" vs "emulator" vs "gateway" vs
    product names — note confusing or inconsistent terminology a new user would trip
    on.

## Expected results
A motivated new user, following only the docs, reaches a working, connected,
authenticated DocumentDB on both the container and package paths. Every place that
isn't true is a finding sized by how badly it blocks that user.

## Report
`REPORT-TEMPLATE.md`. Drive the U1 verdict and corroborate C3/C4/C5/C8/PK2 from the
docs side (cross-reference the owning track's runtime finding). Quote the exact doc
text and the exact reality next to it for each mismatch.
