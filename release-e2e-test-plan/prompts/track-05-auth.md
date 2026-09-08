# Track 05 — Authentication & authorization

**You are** an access-control tester. You want to authenticate as someone you
shouldn't, reach data you shouldn't, or make the server accept a credential it
shouldn't. You also confirm the legitimate auth paths work exactly as documented.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 auth defaults, §6 C3) and
`REPORT-TEMPLATE.md`. **Write** to `reports/track-05-auth.md`.

## SUT
`documentdb-local:pg17-0.116.0`. Auth mechanism is **SCRAM-SHA-256**. The admin
user is created from `--username`/`--password`.

## What to test (checklist)

1. **Happy path.** Create admin user `docdb_admin` with a strong password.
   Authenticate with SCRAM-SHA-256 and run a query. Confirm success.
2. **Wrong credentials.** Wrong password, wrong username, empty password, empty
   username. Each must fail with an auth error and **must not** leak whether the
   username exists (same error for unknown-user vs wrong-password is preferable —
   note if it distinguishes them, that's an info-leak S4).
3. **Mechanism downgrade / negotiation.** Attempt `SCRAM-SHA-1`, `PLAIN`,
   `MONGODB-CR`, `MONGODB-X509`, and no-auth. Confirm only the intended
   mechanism(s) succeed and weaker/none are refused. A server that accepts `PLAIN`
   over a non-TLS connection, or accepts `MONGODB-CR`, is S1/S2.
4. **Password with special characters.** Create users whose passwords contain `"`,
   `\`, `'`, `$`, spaces, unicode, a leading `-`, and a very long password. Confirm
   creation succeeds and auth works — the release specifically hardened against a
   password being interpolated into psql argv / into JSON unescaped. A password
   that breaks user creation, or leaks via `/proc/<pid>/cmdline`, is S2 (hand the
   /proc leak to Track 07 too). Verify by checking `ps`/`/proc` during creation.
5. **Reserved / blocked usernames.** Attempt to create/login as reserved internal
   roles and blocked prefixes: `documentdb`, `documentdb_admin_role` (any internal
   role name), `citus…`, `pg…`, `internal_role…`. The container must **reject these
   at startup** (validated by `documentdb_validate_username.sh` against the
   gateway's `BlockedRolePrefixes` + reserved-role registry). Confirm the container
   does not come up "ready" with an unusable user. Case-insensitivity: try
   `DocumentDB`, `PG_x`.
6. **Authorization boundaries.** With the admin user, create a second, less-
   privileged user if the API supports `createUser`/roles. Confirm the second user
   cannot perform admin-only actions (create/drop users, read another DB it wasn't
   granted). If role management isn't exposed over the wire, note it and confirm
   the single admin user's scope.
7. **Cross-database isolation.** Data written to DB `A` must not be visible/queryable
   by a user scoped to DB `B` (if scoping exists). At minimum confirm `A` and `B`
   are logically separate.
8. **Backend PG credential exposure.** The gateway talks to an internal PG. Confirm
   a client **cannot** pivot from the MongoDB endpoint to raw PG superuser. If
   `--allow-external-connections true`, confirm what auth the exposed PG port
   requires (feed the exposure to Track 07). Confirm the MongoDB admin password is
   **not** the PG superuser password (or if it is, flag it).
9. **Session / credential lifetime.** Re-auth after an idle period; confirm no
   silent session fixation. Confirm changing a user's password (if supported)
   invalidates the old one.
10. **Default-password check (finding-seed C3, shared with T03).** If T03 finds the
    container starts with any default/guessable password when none is supplied,
    confirm from the auth side that the default actually authenticates — a live,
    guessable admin credential is **S1**.

## Expected results
Only SCRAM-SHA-256 with correct credentials works; weaker mechanisms refused;
special-char passwords work and don't leak; reserved usernames rejected at
startup; no pivot to PG superuser.

## Report
`REPORT-TEMPLATE.md`. Any accepted weak mechanism, any credential leak, or any
live default credential is called out at the top as S1/S2 with full repro.
