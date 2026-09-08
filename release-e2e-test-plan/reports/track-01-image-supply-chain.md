# Track 01 — Image supply chain & provenance

- **Worker:** Claude Code
- **Date:** 2026-08-21 UTC
- **SUT identity:**
  - Image: `ghcr.io/documentdb/documentdb/documentdb-local@sha256:822903975b2693eb0742e86f269a5aaa132697aadaa08b4aa4cd6d35a37b19ea`
    (tag `pg17-0.116.0`, manifest list), amd64 child `sha256:16d4d8acdbeb…`, PG 17
  - Build run: 32438357061, commit `684ac1626249f0b394cfb5a1391c85a158876d36`
  - Host: Windows 11, Docker 29.6.2, linux/amd64
- **Result:** PASS-WITH-FINDINGS
- **Counts:** S1: 0 · S2: 0 · S3: 1 · S4: 0

## Summary

The published image is authentic and internally consistent. Keyless cosign
verification succeeds against the expected workflow identity, both tamper
negative-tests correctly fail, and the legacy `.sig` tag is present. **The
provenance drift that seed P1 described is gone** — this rebuild's
`org.opencontainers.image.revision` equals both the build commit and the commit the
`v0.116-0` tag now points at, so a user who checks out `revision` gets the tree the
image was built from. The two omissions the plan predicted (C1 no `HEALTHCHECK`,
C2 no `EXPOSE`) are both confirmed and remain the only supply-chain finding. CVE
scanning, SBOM generation, licence/NOTICE checks and the egress test were **not
run** — `trivy`/`grype`/`syft` were unavailable on the host.

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | Tag ↔ manifest inventory | ✅ | All 5 tags present; every `pgNN-0.116.0` is a multi-arch list with amd64 + arm64; `latest` resolves to the **same digests** as `pg17-0.116.0` |
| 2 | Multi-arch integrity | ⚠️ | amd64 verified (`Os=linux Architecture=amd64`); **arm64 not tested** (amd64-only scope) |
| 3 | Labels & provenance (P1/C1/C2) | ✅ | `version=0.116.0`, `revision=684ac162…`, `source=…/documentdb`, `created=2026-08-21T02:04:36Z`; **no HEALTHCHECK, no EXPOSE, no CMD** |
| 4 | `/version.txt` provenance stamp | ✅ | `0.116-0 (commit 684ac162…, built 2026-08-21T02:04:36Z, postgresql 17)` — agrees with labels |
| 5 | Signature verification (cosign) | ✅ | Verified; identity `…/build_gateway.yml@refs/tags/v0.116-0`, issuer `token.actions.githubusercontent.com`, `githubWorkflowSha=684ac162…`; legacy `.sig` tag present |
| 6 | Tamper negative test | ✅ | Wrong identity → exit 12; wrong issuer → exit 12 |
| 7 | Base image & CVE surface | ⛔ | Base confirmed `Debian GNU/Linux 13 (trixie)`; **no scanner available** |
| 8 | SBOM / contents | ⚠️ | `mongosh 2.10.0` present; full SBOM **not generated** |
| 9 | Image size & layers | ✅ | 308.7 MB uncompressed, 25 layers, nothing anomalous |
| 10 | Reproducibility signal | ⛔ | Not assessed |
| 11 | Licence & attribution | ⛔ | Not assessed |
| 12 | No default egress | ⛔ | Not assessed (no `tcpdump`) |
| 13 | In-tree `test_image.py` | ⛔ | Not run |

## Findings

### [S3] Image ships no HEALTHCHECK and no EXPOSE

- **What:** The image config carries neither a `Healthcheck` nor `ExposedPorts` key.
- **Finding-seed:** C1, C2
- **Repro:**
  ```
  docker image inspect ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.116.0
  ```
- **Observed:**
  ```
  Cmd         : <<ABSENT>>
  Healthcheck : <<ABSENT>>
  ExposedPorts: <<ABSENT>>
  Volumes     : {'/data': {}}
  ```
- **Expected:** An orchestrator needs a liveness signal; a user needs port discovery.
  Today both come only from documentation.
- **Impact:** Operators must poll container logs for `=== DocumentDB is ready ===`
  (measured cold start: **8 s**). Compose/Kubernetes users get no readiness gate.
- **Confidence:** high · **Suggested severity:** S3

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| P1 | **NOT-REPRODUCED (fixed)** | `revision=684ac1626249f0b394cfb5a1391c85a158876d36` = build commit = tag commit (`v0.116-0^{}`) |
| C1 | **CONFIRMED** | `Healthcheck` absent (above) |
| C2 | **CONFIRMED** | `ExposedPorts` absent (above) |

## Cross-track notes

- The image ships `documentdb_extended_rum` **installed** (`0.116-0`) with both
  `documentdb_rum` and `documentdb_extended_rum` access methods present. The
  package path does not — see F-01 in the rollup. This contrast is what proves the
  defect is package-specific.
- Two cosign signature entries exist for the same digest (log indices 2541950585 and
  2541951744, 5 s apart) — consistent with `latest` and `pg17-0.116.0` sharing a
  digest and each being signed. Not a defect; noted for completeness.

## Evidence

Commands and full outputs are inline above; the cosign verification payload was
captured in the session transcript.
