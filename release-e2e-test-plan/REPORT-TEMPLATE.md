# Report Instructions & Template (every track agent must follow this)

Your job is not "run tests" — it is to produce a **verdict a release manager can
act on without re-running anything**. A report that says "all passed" without
evidence is worthless; a report that says "FAIL with this exact repro and log
line" is gold. Optimize for the second.

## Where to write your report
Write a single Markdown file to:
`release-e2e-test-plan/reports/TRACK-<NN>-<slug>-report.md`
(create the `reports/` directory if absent). Attach or inline the evidence
(logs, command transcripts, screenshots) it references. If you produce a helper
script, save it under `release-e2e-test-plan/reports/artifacts/`.

## Hard rules (these are what make the report trustworthy)

1. **Never report PASS for a check you did not actually execute and observe.**
   If a precondition prevented a check from running, its status is **SKIP** with
   the reason — never PASS. (The existing suites treat a silent skip that prints
   PASS as the top failure mode; so do we.)
2. **Every PASS and FAIL cites evidence.** A PASS cites the observed output that
   proves it (the `"ok":1`, the exit code, the absent listener). A FAIL cites the
   exact command, the full error/log excerpt, and the environment.
3. **Every FAIL is reproducible.** Give the minimal command sequence from a clean
   SUT that reproduces it. If you can't reproduce it, mark it **FLAKY** and say
   how many times it occurred out of how many runs.
4. **Distinguish a product defect from a test-harness problem.** If your tooling
   (a driver version, a missing binary) is the cause, say so — don't file it
   against the product.
5. **Credential hygiene (CredScan).** Never write a real credential literal into
   any file you save, including reports. Generate passwords at runtime
   (`$(openssl rand -hex 12)Aa1!`) and refer to them as `<generated>`. When you
   test that a password does NOT leak into argv/logs, follow the positive-control
   pattern used in `e2e-extra-scenarios.sh` (plant a sentinel, prove your probe
   can see the sentinel, THEN prove it cannot see the password) — a probe you did
   not validate reporting "no leak" is an UNVERIFIED result, not a PASS.
6. **Leave the environment clean.** Remove containers/volumes/packages you
   created. If you couldn't, list what you left behind.
7. **State-changing / destructive actions:** you are authorized to create and
   destroy disposable containers, volumes, and package installs *inside
   throwaway Linux containers or a dedicated test VM*. You are NOT authorized to
   mutate a shared/production host, push images, publish packages, or send data
   to any external network service. If a test seems to require that, stop and
   report it as a blocked item.

## Severity rubric (use exactly these labels)

| Severity | Meaning | Examples |
|---|---|---|
| **S1 — Critical / release-blocker** | Data loss, auth bypass, remote unauth access, container won't start on the documented happy path, secret exposed. | PG port reachable externally by default; password in `ps` output; wrong-credentials connection succeeds; WAL corruption after clean restart. |
| **S2 — Major** | A documented feature is broken or a strong security control is weak; no clean workaround. | A documented CRUD/aggregation command errors; `requireTLS` still accepts plaintext; reserved-prefix username accepted; upgrade breaks the extension. |
| **S3 — Moderate** | Works but with a sharp edge, poor failure mode, or missing hardening. | Unclear/actionable-less error message; no HEALTHCHECK; oversized-doc handling returns an internal error instead of a clean one. |
| **S4 — Minor / polish** | Cosmetic, doc drift, UX nit. | Help text names the wrong telemetry backend; typo in a banner; noisy logs. |
| **INFO** | Observation worth recording, not a defect. | "Cold start is ~7s"; "image is 812 MB". |

Also tag each finding with an area: `[functional] [security] [ux] [perf]
[durability] [packaging] [compat] [observability] [docs]`.

## Report structure (fill every section)

```markdown
# Track <NN> — <name> — E2E Report
- **Agent / date:** <who/when>
- **SUT under test:** image tag or package set + resolved version + PG major + arch + host OS
- **Verdict:** GREEN (ship) / YELLOW (ship with caveats) / RED (do not ship) — one line why.

## Summary
2–5 sentences: what you tested, the headline result, the count of findings by severity.

## Findings (most severe first)
For each finding:
### F<n>. <short title>  — <S1..S4/INFO> [area tags]
- **What:** one-sentence statement of the defect/observation.
- **Impact:** who is affected and how badly.
- **Repro:** exact commands from a clean SUT.
- **Observed:** the actual output/log/behavior (quote it).
- **Expected:** what should have happened and why (cite the ground-truth source).
- **Evidence:** path to log/transcript/screenshot.
- **Suggested owner/fix (optional):** if obvious.

## Test coverage table
| ID | Check | Result (PASS/FAIL/SKIP/FLAKY) | Evidence |
|----|-------|-------------------------------|----------|
(one row per check you ran, including the ones that passed)

## What I could NOT test (gaps)
Honest list of anything out of reach (missing arch, driver, time) so the release
manager knows the true coverage. A gap is not a failure — hiding it is.

## Environment cleanup
What you created and whether you removed it.
```

## Roll-up (for the coordinator, not per-track)
After all tracks report, the coordinator produces
`release-e2e-test-plan/reports/00-ROLLUP.md`: the SUT identity, a table of the 12
tracks with their verdict + S1/S2 counts, the consolidated release
GO/NO-GO recommendation, and the top 5 must-fix items. Any single **S1**, or the
container/package failing its documented happy path, is a default **NO-GO** until
resolved or explicitly waived.
