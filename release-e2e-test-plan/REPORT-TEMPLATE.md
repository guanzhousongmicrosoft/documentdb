# REPORT-TEMPLATE.md — how to write a track report

Copy this into `reports/track-NN-<slug>.md` and fill it in. One report per track.
The rollup agent parses these, so **keep the headings and the severity labels
exactly as written here.**

---

## Severity rubric (S1–S4) — use these, do not invent others

| Severity | Meaning | Release impact |
|----------|---------|----------------|
| **S1 — Blocker** | Data loss/corruption; auth bypass; container/service won't start on a supported platform; RCE; signature can't be verified; a shipped package won't install with its stated deps. | **NO-GO.** Must fix before release. |
| **S2 — Critical** | Major feature broken or a documented capability doesn't work; security weakness needing a workaround; a default that is unsafe or surprising; crash under normal use. | Fix or ship a loud, documented caveat. |
| **S3 — Major** | Feature works but with a real defect, poor error, or wrong behavior in an edge case; performance regression; a fixed-in-0.116 regression that partially returns. | Should fix; acceptable with a known-issue note. |
| **S4 — Minor / Question** | Cosmetic, doc/UX nit, or "is this intended?" where behavior may be by design. | Backlog; note in release notes if user-visible. |

When unsure whether something is a bug or intended design, file **S4 / Question**
and describe both the observed and the expected behavior. Do not inflate severity
to get attention, and do not bury an S1 as an S3 because you're not 100% sure —
mark confidence explicitly.

---

## Report file

```markdown
# Track NN — <title>

- **Worker:** <agent/who>
- **Date:** <UTC>
- **SUT identity:**
  - Image: `<repo>@sha256:<digest>` (tag `<tag>`), arch `<amd64|arm64>`, PG `<NN>`
    — and/or —
  - Package(s): `<filename>` SHA256 `<hash>`, arch `<...>`
  - Host: `<OS + version>`, runtime `<docker/podman + version>`
- **Result:** PASS / PASS-WITH-FINDINGS / FAIL / BLOCKED
- **Counts:** S1: _ · S2: _ · S3: _ · S4: _

## Summary
<3–6 sentences: what you tested, the headline outcome, and the single most
important thing the release owner must know.>

## Checklist results
<The track prompt lists required checks. Reproduce that list here, each marked
✅ pass / ❌ fail / ⚠️ partial / ⛔ blocked, one line of result each.>

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | … | ✅ | … |

## Findings
<One block per finding. Omit the section if none. Order by severity.>

### [S_] <short title>
- **What:** <the defect in one sentence>
- **Finding-seed:** <ID from ENVIRONMENT-SETUP §6, or "new">
- **Repro:**
  ```
  <exact commands>
  ```
- **Observed:**
  ```
  <exact output, trimmed to the relevant lines>
  ```
- **Expected:** <what should happen and why — cite the doc/help/spec if any>
- **Impact:** <who is affected, how bad, is there a workaround>
- **Confidence:** high / medium / low
- **Suggested severity:** S_

## Finding-seeds checked
<For each seed this track owns: seed ID → CONFIRMED / NOT-REPRODUCED / N-A, one
line of evidence. This tells the rollup which hypotheses were actually tested.>

## Cross-track notes
<Anything you noticed outside this track's scope. Do not chase it — just flag it
with enough detail for the right track to pick up.>

## Evidence
<Paths under reports/artifacts/ for logs, pcaps, SBOMs, GIFs, screenshots you
captured. Name them track-NN-<what>.>
```

---

## Evidence hygiene

- Pin the **digest**, not just the tag — tags are mutable.
- Paste **real** output. If you must trim, keep the lines that prove the point and
  mark trims with `…`.
- Note the **architecture** and **host OS** for anything that could be
  platform-specific (it usually can).
- Redact only genuine secrets (real cert private keys). Generated test passwords
  are fine to show and help reproduction.
- Prefer a machine-checkable assertion (exit code, count, digest) over a prose
  claim.
