# Track 04 — Authentication, Authorization & User Management (agent prompt)

You are a security-QA agent. Verify that authentication is enforced correctly, the
supported mechanisms behave, user/role management works, and reserved-name and
privilege boundaries hold. Read `../ENVIRONMENT-SETUP.md` and
`../REPORT-TEMPLATE.md` first. Target: container and packaged gateway.

## Contract facts (from the runtime map — assert against these)
- **Mechanisms: SCRAM-SHA-256 and MONGODB-OIDC only. PLAIN is NOT supported.**
  A `saslStart` with any other mechanism → **code 18 `AuthenticationFailed`**,
  "Only SCRAM-SHA-256 and MONGODB-OIDC are supported, got: …". Drivers are told
  `saslSupportedMechs: ["SCRAM-SHA-256"]`.
- **Pre-auth allowlist:** only `isMaster`, `hello`, `ping`, `buildInfo` run before
  authentication. **Any other command pre-auth → code 13 `Unauthorized`**,
  "Command X is not allowed as the connection is not authenticated yet."
- **`logout` resets auth state.**
- **User/role commands implemented** (delegate to the extension): `createUser`,
  `dropUser`, `updateUser`, `usersInfo`, `connectionStatus`, `createRole`,
  `updateRole`, `dropRole`, `rolesInfo`.
- **Auth-management commands NOT supported** (assert they error, code 115):
  `grantRolesToUser`, `revokeRolesFromUser`, `grantPrivilegesToRole`,
  `grantRolesToRole`, `revokeRolesFromRole`, `revokePrivilegesFromRole`,
  `dropAllUsersFromDatabase`, `dropAllRolesFromDatabase`, `invalidateUserCache`.
  (This is a real capability gap — a user who can be created cannot then be
  granted extra roles via the wire. Judge the UX/security impact.)
- **Reserved / blocked names:**
  - Blocked prefixes (case-insensitive): `documentdb`, `citus`, `pg`,
    `internal_role`.
  - 11 exact reserved role names (see ENVIRONMENT-SETUP).
  - 24 Mongo built-in role names cannot be re-created as custom roles (`root`,
    `readWrite`, `readAnyDatabase`, `clusterAdmin`, `userAdminAnyDatabase`, …).
- **Default container admin user** gets `readWriteAnyDatabase@admin` +
  `clusterAdmin@admin`.
- **Packaged (non-container) PG auth = passwordless local peer only.** Setting a
  password anywhere is a hard startup error: `PGPASSWORD` non-empty →
  error; `PostgresDataUserPassword` in JSON → error; a password in the
  `DOCUMENTDB_PG_URL_FILE` or inline URL → the gateway/wrapper refuses to start.
- **Container backend PG** only appends `host all all 0.0.0.0/0 scram-sha-256`
  when `ALLOW_EXTERNAL_CONNECTIONS=true`.

## Test cases

### A. AuthN enforcement (S1 territory)
1. **Wrong password / unknown user** → connection fails with `AuthenticationFailed`
   (18) / `UserNotFound` (11). No command executes.
2. **No credentials at all** → any real command (e.g. `find`) is refused with
   `Unauthorized` (13); only `hello`/`ping`/`buildInfo`/`isMaster` answer.
3. **PLAIN mechanism** explicitly requested → rejected (18), not silently downgraded
   or accepted.
4. **SCRAM happy path** with the admin user succeeds; `authMechanism` negotiation
   picks SCRAM-SHA-256; `connectionStatus` reflects the authenticated user.
5. **`logout` then a command** → back to Unauthorized until re-auth.
6. Password with special/unicode/very-long characters authenticates (round-trips
   through SCRAM correctly).

### B. User & role management
7. `createUser` a normal user with a role (e.g. `readWrite@testdb`); it can do
   exactly what the role allows and **nothing more** (see C).
8. `usersInfo`, `updateUser` (change password / roles), `dropUser` behave; a
   dropped user can no longer authenticate.
9. `createRole` a custom role, `rolesInfo`, `updateRole`, `dropRole`.
10. **Reserved/blocked rejections:** `createUser`/`createRole` with a blocked
    prefix (`documentdb…`, `pg…`, `citus…`, `internal_role…`), an exact reserved
    role name, or a Mongo built-in role name → rejected with a clear error. The
    container pre-flight (`documentdb_validate_username.sh`) must also reject a
    blocked `USERNAME` before the container reports ready (cross-check Track 02).
11. **Unsupported auth-mgmt commands** (list above) → code 115, consistently.
12. Packaged-install admin flow: `documentdb-gateway-admin create-user /
    list-users / reset-password / drop-user / check` work; `--password-stdin` /
    `--password-file` keep the secret off argv (positive-control probe — see
    REPORT-TEMPLATE rule 5).

### C. AuthZ boundaries (privilege separation — S1/S2)
13. A `readAnyDatabase`/`readWrite`-scoped user **cannot** perform admin actions
    (createUser, drop another db, cluster ops). Verify the denial, not just that
    the happy path works.
14. A read-only user (`[{"role":"readAnyDatabase","db":"admin"}]`) cannot write.
15. Cross-database isolation: a user scoped to db A cannot read/write db B.
16. The default container admin's `clusterAdmin` scope is intentional — document
    what it can do, and confirm a *non-admin* created user does not inherit it.

### D. OIDC (if you can stand up an issuer)
17. If feasible, exercise `MONGODB-OIDC`: a valid JWT (with `oid`+`aud`) authenticates;
    an expired token → after expiry, commands get **code 391
    `ReauthenticationRequired`**; a malformed token (not 3 parts) → auth failure.
    If you cannot stand up an issuer, mark OIDC a coverage gap (do not fake it).

### E. Packaged passwordless posture (S1 if broken)
18. On a packaged install, confirm the gateway **refuses to start** if a password
    is injected via `PGPASSWORD`, `PostgresDataUserPassword`, or a
    password-bearing `DOCUMENTDB_PG_URL_FILE`/inline URL. This is a deliberate
    hardening; a start that succeeds anyway is a finding.
19. Confirm the PG-side `pg_hba`/`pg_ident` uses peer + the
    `documentdb-gateway-map` ident map, and the gateway connects as the client's
    role over the local socket with an empty password (PG 16+ feature).

## How to break it
- Reconnect-and-replay a captured SCRAM exchange (nonce reuse) — must fail.
- Attempt privilege escalation: as a low-priv user, call every unsupported
  auth-mgmt command and every admin command; confirm none partially succeed.
- Username/role **injection**: names containing `;`, `--`, `'`, `"`, backticks,
  `\x00`, `$()`, newlines, and PG role-y strings (`; DROP ROLE`, `postgres`) — must
  be rejected or safely escaped, never executed as SQL/PG role manipulation.
- Case/Unicode-normalization bypass of blocked prefixes (`Documentdb`, `PG_`,
  full-width chars, homoglyphs) — the check is case-insensitive; probe for gaps.
- Race two `createUser` for the same name; a `dropUser` concurrent with that
  user's active session (does the session keep working after drop?).
- Brute-force many bad passwords quickly — is there any lockout/backoff, or does
  it happily accept unlimited attempts? (Document; likely INFO/S3 but note it.)
- With `ALLOW_EXTERNAL_CONNECTIONS=true`, confirm the added `0.0.0.0/0
  scram-sha-256` HBA still requires valid PG credentials and doesn't open a
  trust/peer hole to the outside.

## Evidence to capture
Raw auth exchange results (codes + codeNames); the exact rejection messages for
reserved names and injection attempts; `usersInfo`/`rolesInfo` output;
positive-control transcripts for the argv/secret-hygiene checks; the packaged
`pg_hba.conf`/`pg_ident.conf` managed blocks.

## Out of scope / hand-offs
TLS/transport → 05. Broader injection/DoS/secret-in-logs → 06. Wire-protocol CRUD
depth → 03.

Write your report to `../reports/TRACK-04-auth-authz-users-report.md`.
