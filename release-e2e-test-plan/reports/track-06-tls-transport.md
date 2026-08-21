# Track 06 — TLS & transport security

- **Worker:** Claude Code · **Date:** 2026-08-21 UTC
- **SUT identity:** `documentdb-local@sha256:822903975b26…19ea` (`pg17-0.116.0`), amd64, PG 17
  · Host: Windows 11, Docker 29.6.2
- **Result:** PARTIAL — PASS-WITH-FINDINGS
- **Counts:** S1: 0 · S2: 0 · S3: 2 · S4: 0

## Summary

The three TLS modes were exercised end to end with both a TLS and a plaintext client.
**`requireTLS` genuinely enforces** — the plaintext client is refused — which is the
result that matters most and it is correct. **Seed C8 is confirmed:** `TLS_MODE=disabled`
does not disable TLS; the gateway still accepts TLS *and* plaintext, i.e. it behaves
exactly like `allowTLS` despite its name. Separately, the shipped default (`allowTLS`)
accepts full plaintext authentication, so out of the box credentials and data can
travel in clear. Certificate quality, cipher/protocol floor, custom-cert mounting and
cert persistence were **not tested** (no `nmap`/`testssl` available).

## Checklist results

| # | Check | Result | Note |
|---|-------|--------|------|
| 1 | Default `allowTLS` accepts both | ✅ (finding) | TLS **and** plaintext both authenticate and query |
| 2 | `requireTLS` rejects plaintext | ✅ | Plaintext client → `MongoServerSelectionError`; TLS client connects |
| 3 | `disabled` is not "off" (C8) | ✅ (confirmed) | Still accepts TLS **and** plaintext; extra warning line emitted |
| 4 | Auto-generated certificate quality | ⛔ | Not tested |
| 5 | Mounted custom cert | ⛔ | Not tested |
| 6 | Downgrade / protocol floor | ⛔ | Not tested — no `nmap`/`testssl.sh` |
| 7 | Strict client rejects self-signed | ⛔ | Not tested |
| 8 | Backend PG transport | ⚠️ | Covered indirectly by Track 03 C9: exposed PG requires `scram-sha-256` |
| 9 | Certificate persistence | ⛔ | Not tested |

## Evidence — the TLS mode matrix

```
--- TLS_MODE=allowTLS ---     ready:1   TLS client: CONNECTED   PLAINTEXT client: CONNECTED
--- TLS_MODE=requireTLS ---   ready:1   TLS client: CONNECTED   PLAINTEXT client: MongoServerSelectionError
--- TLS_MODE=disabled ---     ready:1   TLS client: CONNECTED   PLAINTEXT client: CONNECTED
```

All three modes reach the ready banner; only `requireTLS` changes client behaviour.

## Findings

### [S3] `TLS_MODE=disabled` does not disable TLS

- **What:** Setting the mode named `disabled` leaves TLS fully available and continues
  to accept plaintext — the same behaviour as `allowTLS`.
- **Finding-seed:** C8 — **CONFIRMED**
- **Repro:** `docker run -d -e TLS_MODE=disabled <img> --username u1 --password <pw>`,
  then connect once with `--tls --tlsAllowInvalidCertificates` and once without `--tls`.
- **Observed:** both connect (matrix above). The container emits an additional
  warning line relative to the other modes but still starts and reports ready.
- **Expected:** either genuinely serve plaintext only, or **refuse to start** and tell
  the user the mode is unsupported.
- **Impact:** An operator who sets `disabled` to force plaintext-only (for a sidecar
  proxy, or to satisfy a policy that forbids in-cluster TLS termination) silently does
  not get it. The setting's name states the opposite of its behaviour.
- **Confidence:** high · **Suggested severity:** S3

### [S3] The default TLS mode accepts plaintext authentication

- **What:** `TLS_MODE=allowTLS` is the baked-in default, and a plaintext client
  authenticates and queries successfully against it.
- **Finding-seed:** new
- **Observed:** in `allowTLS`, the plaintext `mongosh` client (no `--tls`) returned
  `CONNECTED` after SCRAM authentication.
- **Expected:** debatable — `allowTLS` is doing what it says. The finding is about the
  **default**: a user who never thinks about TLS gets a server that will happily accept
  cleartext credentials from any client that omits `--tls`.
- **Impact:** Combined with the S1 default-credential finding (C3, Track 03), a
  default-ish container published to a network accepts a known admin credential over an
  unencrypted connection.
- **Confidence:** high · **Suggested severity:** S3 (a product decision — flagged for
  the release owner rather than asserted as a defect)

## Finding-seeds checked

| Seed | Verdict | Evidence |
|------|---------|----------|
| C8 | **CONFIRMED** | `disabled` accepts both TLS and plaintext (matrix above) |

## Cross-track notes

`requireTLS` working correctly is the mitigation for both findings above; the docs
should lead with it. Feed the `disabled` wording to Track 12.
