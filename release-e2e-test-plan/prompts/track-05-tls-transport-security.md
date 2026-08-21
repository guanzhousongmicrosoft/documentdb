# Track 05 — TLS & Transport Security (agent prompt)

You are a security-QA agent. Verify TLS behavior: default posture, enforcement
modes, certificate handling, versions/ciphers, rotation, and the plaintext/TLS
sniffing on a shared port. Read `../ENVIRONMENT-SETUP.md` and
`../REPORT-TEMPLATE.md` first. Target: container and packaged gateway.

## Contract facts (from the runtime map — assert against these; note the nuance)
- **Library default `EnforceTls = true`.** But the **container** maps
  `--tlsMode`/`TLS_MODE` → `EnforceTls`: `requireTLS → true`, everything else
  (incl. the default `allowTLS` and `disabled`) → **false**. So:
  - **Packaged gateway with default JSON:** TLS enforced (plaintext rejected).
  - **Container default (`allowTLS`):** plaintext AND TLS both accepted on 10260.
  Test **both** postures — they differ, and a user assuming the container enforces
  TLS by default would be wrong.
- **`disabled` does NOT turn TLS off** — it behaves like `allowTLS` and the
  entrypoint prints a warning saying so. There is no plain-only mode.
- **Shared-port sniffing:** when not enforced, the first 3 bytes are sniffed
  (`0x16 0x03 0x01..0x04`) to route TLS vs plaintext on the same port. TLS peek
  timeout is 5s.
- **Default cert = auto-generated self-signed**, `CN=localhost`, **RSA**, 365-day
  validity, via `openssl` shelled out (openssl(1) must be on PATH). Files
  `cert.pem`/`pkey.pem`; the key is chmod **0600**; both are **reused on restart**
  (logs "reusing existing certificate").
- **TLS versions:** min **TLS 1.2**, max **TLS 1.3** (`mozilla_intermediate_v5`).
  No cipher-list config key. Server session cache off; `num_tickets=1`.
- **RSA only:** `is_valid_certificate` requires an RSA key/pubkey match — **an
  ECDSA cert is reported invalid.** (Good break test; also a real limitation to
  document.)
- **Config keys:** JSON `CertificateOptions.{CertType,FilePath,KeyFilePath,CaPath}`;
  env `DOCUMENTDB_TLS_CERT_FILE`, `DOCUMENTDB_TLS_KEY_FILE`,
  `DOCUMENTDB_TLS_AUTO_GENERATE`, `DOCUMENTDB_TLS_STATE_DIR`. Container:
  `--cert-path`+`--key-file` (both required together) switch to `PemFile`.
- **Validation errors (assert each):** cert without key (or key without cert) →
  error; `AUTO_GENERATE=true` together with cert+key → error ("pick one TLS
  source"); `AUTO_GENERATE=false` without cert+key → error.
- **Hot reload:** cert/key re-read every **60s** and swapped atomically.
- **State-dir resolution order:** `DOCUMENTDB_TLS_STATE_DIR` →
  `/var/lib/documentdb-gateway/tls` → `$XDG_STATE_HOME`/`$HOME/.local/state/...`
  → ephemeral `${TMPDIR}/documentdb-gateway-tls-<pid>` (warns). Dirs created 0700.
- **Existing harness:** `documentdb-local/scripts/run_documentdb_local_tls_tests.sh`
  (3 containers: default / enforce / envvar) and gateway `documentdb_tests/tests/ssl_tests.rs`.

## Test cases

### A. Default posture
1. **Container default (allowTLS):** a TLS client (`tls=true&tlsAllowInvalidCertificates=true`)
   connects AND a plaintext client (`tls=false`) connects — both on 10260. Record
   this clearly; a user may expect TLS-only.
2. **Packaged gateway default:** plaintext is **rejected** (EnforceTls=true);
   TLS connects. If plaintext succeeds against a default packaged gateway, that is
   an S1/S2 finding.
3. Self-signed cert presented has `CN=localhost`, is RSA, ~365-day validity; the
   `pkey.pem` on disk is mode 0600; a restart reuses the same cert (fingerprint
   unchanged) and logs the reuse.

### B. Enforcement modes
4. **`requireTLS`:** plaintext connection is **rejected**; TLS succeeds. This is the
   posture a security-conscious user will pick — it must be airtight.
5. **`disabled`:** behaves like allowTLS (both accepted) AND prints the warning
   that it does not disable TLS. Confirm the warning is emitted.
6. Round-trip a real client (mongosh, pymongo) under each mode.

### C. Custom certificates
7. Provide your own RSA cert+key (`--cert-path`/`--key-file` in the container;
   `DOCUMENTDB_TLS_CERT_FILE`/`_KEY_FILE` packaged): the gateway presents YOUR cert;
   a client pinned to your CA validates without `tlsAllowInvalidCertificates`.
8. **Validation negatives** (each must be a clear startup error, not a silent
   fallback): cert without key; key without cert; `AUTO_GENERATE=true` + cert/key
   both set; `AUTO_GENERATE=false` with no cert/key.
9. **ECDSA cert** provided → reported invalid / refused (document as a limitation).
10. **State-dir override** `DOCUMENTDB_TLS_STATE_DIR=/some/dir` — cert lands there,
    dir is 0700. Unset in an env-only install → falls back per the resolution
    order (and the ephemeral `${TMPDIR}` path warns).

### D. Rotation & lifecycle
11. **Hot reload:** replace cert/key files on disk; within ~60s new connections use
    the new cert without a restart. In-flight connections are unaffected.
12. An expired or not-yet-valid cert — behavior (does it serve it / warn / refuse?).

### E. Protocol hardening
13. **Min version:** a TLS 1.0/1.1 client is refused; TLS 1.2 and 1.3 succeed.
14. Confirm the negotiated cipher is from the intermediate profile; no export/NULL/
    anon ciphers offered.
15. Certificate/hostname behavior: with a client that validates (no
    `tlsAllowInvalidCertificates`), a `CN=localhost` self-signed cert fails
    hostname/trust validation as expected — this is why the quickstart uses
    `tlsAllowInvalidCertificates=true` (document that this is expected, and that
    production users must supply a real cert).

## How to break it
- Connect plaintext to a `requireTLS` gateway with a raw socket and a hand-built
  OP_MSG — confirm it is dropped, not partially processed.
- Send a TLS ClientHello then stall (never finish the handshake) — the 5s peek
  timeout must reclaim the connection; open many such half-handshakes to see if
  the listener can be starved (hand connection-exhaustion depth to Track 06).
- Feed a malformed/oversized cert file, a world-readable key (0644), a key that
  doesn't match the cert, a cert chain with a wrong CA — expect clear refusal.
- Downgrade attempt: offer only TLS 1.0 — refused. Offer a NULL cipher — refused.
- Swap the cert files to garbage while running — the 60s reloader must not crash
  the gateway or serve a broken cert to new clients; it should keep the last-good.
- Symlink/permission games on the TLS state dir (0700) — can a non-owner read the
  key? Can a co-tenant on the host read `pkey.pem`?
- Confirm `tlsAllowInvalidCertificates=true` is genuinely required for the
  self-signed default and that turning it off makes validation fail (i.e. the
  gateway isn't accidentally trusted).

## Evidence to capture
`openssl s_client -connect host:10260 -tls1_2` / `-tls1_3` / `-tls1_1` transcripts
(cert subject, validity, negotiated version+cipher); the on-disk cert/key modes;
logs showing generation vs reuse and the 60s reload; the exact validation-error
messages; the plaintext-vs-TLS acceptance results per mode.

## Out of scope / hand-offs
Auth mechanisms → 04. Connection-exhaustion/DoS depth & secret-in-logs → 06.
Network-exposure of the PG port → 02/06.

Write your report to `../reports/TRACK-05-tls-transport-security-report.md`.
