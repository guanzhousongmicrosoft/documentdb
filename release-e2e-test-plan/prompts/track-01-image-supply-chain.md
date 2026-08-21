# Track 01 — Image supply chain & provenance

**You are** a release-engineering / supply-chain auditor. Your job is to prove the
published `documentdb-local` image is authentic, correctly built, correctly
labeled, works on both architectures, and carries a verifiable signature — and to
find every place a consumer could be misled about what they are running.

**Read first:** `ENVIRONMENT-SETUP.md` (§1 provenance, §2 image) and
`REPORT-TEMPLATE.md`. **Write** your report to `reports/track-01-image-supply-chain.md`.

## SUT
`ghcr.io/documentdb/documentdb/documentdb-local`, tags `latest`, `pg15-0.116.0`,
`pg16-0.116.0`, `pg17-0.116.0`, `pg18-0.116.0`. Anonymous pull works. You need
`docker` (or `podman`) + `cosign` + `crane`/`skopeo` (optional but helpful).

## What to test (checklist)

1. **Tag ↔ manifest inventory.** List every tag actually present in the registry.
   Confirm each `pgNN-0.116.0` is a multi-arch manifest list with **amd64 + arm64**
   children. Confirm `latest` resolves to the **PG17** digest (per ground truth).
   Record all digests.
2. **Multi-arch integrity.** Pull amd64 and arm64 for pg17 and pg18. Confirm each
   child's config `architecture`/`os` matches its platform entry (a manifest that
   lies about arch is an S2). On an arm64 host (or via emulation) confirm the
   arm64 image actually runs.
3. **Labels & provenance (finding-seeds P1, C1, C2).** Inspect
   `org.opencontainers.image.{version,revision,source,created,title}`.
   - `version` must equal `0.116.0`.
   - **`revision`**: confirm/deny it points to `810cf2cc…` rather than the release
     tag commit `66e9e118…`. Judge the impact: a user who checks out `revision` to
     reproduce the image gets the wrong tree. (P1)
   - Confirm the image has **no `HEALTHCHECK`** (C1) and **no `EXPOSE`** (C2) and
     assess what each omission costs an operator (liveness probes; port discovery).
4. **`/version.txt` provenance stamp.** `docker run --rm --entrypoint /bin/cat
   IMG /version.txt` — confirm it is stamped (not empty/`unknown`) and agrees with
   the labels.
5. **Signature verification (cosign).** Verify the manifest-list signature keyless:
   ```bash
   cosign verify \
     --certificate-identity-regexp 'https://github.com/documentdb/documentdb/.github/workflows/build_gateway.yml@.*' \
     --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
     ghcr.io/documentdb/documentdb/documentdb-local@<manifest-list-digest>
   ```
   Confirm it succeeds and the certificate identity/issuer are as expected. Then
   confirm the **legacy `.sig` tag** exists (cosign v2 compatibility): the tag is
   `<digest-with-':'→'-'>.sig`. A missing `.sig` is a regression (S2).
6. **Tamper negative test.** Verify against a *wrong* identity/issuer and confirm
   cosign **fails** — a verify that passes with wrong parameters is an S1.
7. **Base image & CVE surface.** Identify the base (`debian:trixie-slim`) and run a
   vulnerability scan (`trivy image` / `grype`) on pg17 amd64. Summarize
   critical/high CVEs in shipped OS packages and in the gateway binary. Note
   anything with a fix available.
8. **SBOM / contents.** Generate an SBOM (`syft` or `docker sbom`). Sanity-check
   there is no unexpected content: no build toolchain left in the runtime layer,
   no stray secrets/keys, no `.git`. Confirm `mongosh` is present and its version.
9. **Image size & layers.** Record compressed + uncompressed size per arch and the
   layer count. Flag anything surprising (e.g. a multi-hundred-MB layer, dev
   packages in the runtime stage).
10. **Reproducibility signal.** The build forwards `SOURCE_DATE_EPOCH`. Check
    whether `created` timestamps and file mtimes look pinned (deterministic) vs
    wall-clock. You cannot fully rebuild, but note whether the provenance *claims*
    reproducibility and whether the evidence is consistent.

11. **License & attribution compliance.** The image bundles third-party code with
    distinct licenses (Rust crates, PostgreSQL, PostGIS, pgvector, RUM). Confirm
    the shipped image carries the required license/`NOTICE` material and that the
    SBOM's licence set contains nothing incompatible with how the image is
    distributed. A missing attribution file is S3; a licence conflict is S2 and a
    release-owner decision.
12. **No default egress.** Start the container with default settings on an
    isolated network and watch for outbound connections (`--network` with a
    monitored gateway, or `tcpdump` on the bridge) for a few minutes of idle plus
    a short workload. With `ENABLE_TELEMETRY=false` the image should phone home to
    nothing. Any unexpected egress is **S2** and goes to Track 07 as well.
13. **Reuse the in-tree image test.** `documentdb-local/scripts/documentdb_local_tests/test_image.py`
    already asserts image-level properties. Run it against the **published** image
    and report pass/fail rather than re-deriving what it covers.

## Expected results
Signatures verify; wrong-param verify fails; `.sig` present; labels internally
consistent except the known `revision` drift (P1) to confirm; both arches run;
scanner output is a list you summarize (not necessarily empty). C1/C2 are expected
to be **present omissions** — your job is to confirm and weigh them.

## Report
Fill `REPORT-TEMPLATE.md`. Attach the SBOM and scanner JSON under
`reports/artifacts/track-01-*`. In "Finding-seeds checked", give verdicts for
P1, C1, C2. Pin every digest you tested.
