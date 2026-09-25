#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADMIN="${ROOT}/documentdb-local/scripts/documentdb-gateway-admin.sh"
SETUP="${ROOT}/documentdb-local/scripts/documentdb-setup.sh"
PG_BIN="$(dirname "$(command -v psql)")"
WORK="$(mktemp -d /tmp/documentdb-admin-logging.XXXXXX)"
PG_STARTED=false
CAPTURE_COUNT=0
SERVER_LOGS=("${WORK}/logs/postgresql.log" "${WORK}/logs/postgresql.csv" "${WORK}/logs/postgresql.json")

cleanup() {
    if [[ "${PG_STARTED}" == "true" ]]; then
        "${PG_BIN}/pg_ctl" -D "${WORK}/data" -m immediate -w stop >/dev/null
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(id -u)" != "0" ]] || fail "Run as an unprivileged user in a disposable DocumentDB image."

"${PG_BIN}/initdb" -D "${WORK}/data" --auth-local=trust --auth-host=scram-sha-256 >"${WORK}/init.log" 2>&1
source "${ROOT}/scripts/preload_libraries.sh"
cat >>"${WORK}/data/postgresql.conf" <<CONF
shared_preload_libraries = '$(GetDocumentDBBasePreloadLibraries --rum)'
unix_socket_directories = '${WORK}'
listen_addresses = '127.0.0.1'
port = 57895
cron.database_name = 'postgres'
documentdb.isNativeAuthEnabled = true
log_statement = 'all'
log_min_duration_statement = 0
log_min_error_statement = 'error'
log_error_verbosity = 'verbose'
log_min_messages = 'debug1'
client_min_messages = 'debug1'
logging_collector = on
log_destination = 'stderr,csvlog,jsonlog'
log_directory = '${WORK}/logs'
log_filename = 'postgresql.log'
CONF
"${PG_BIN}/pg_ctl" -D "${WORK}/data" -l "${WORK}/pg.log" -w start >"${WORK}/start.log" 2>&1
PG_STARTED=true
PSQL=("${PG_BIN}/psql" -X -h "${WORK}" -p 57895 -d postgres -v ON_ERROR_STOP=1)
"${PSQL[@]}" -qc 'CREATE EXTENSION documentdb CASCADE; CREATE EXTENSION documentdb_extended_rum; CREATE ROLE postgres LOGIN SUPERUSER;' >"${WORK}/extensions.log" 2>&1

openssl rand -hex 24 >"${WORK}/original-password"
openssl rand -hex 24 >"${WORK}/replacement-password"
ADMIN_ARGS=(--pg-owner "$(id -un)" --socket-dir "${WORK}" --pg-port 57895 --target-db postgres)

run_captured() {
    local expected="$1" rc=0 i attempt flushed marker
    local -a offsets=()
    shift
    CAPTURE_COUNT=$((CAPTURE_COUNT + 1))
    marker="admin-logging-barrier-${CAPTURE_COUNT}"
    for i in "${!SERVER_LOGS[@]}"; do
        offsets+=("$(wc -c <"${SERVER_LOGS[$i]}")")
    done
    "$@" >"${WORK}/stdout" 2>"${WORK}/stderr" || rc=$?
    [[ "${rc}" == "${expected}" ]] || fail "Expected exit ${expected}, got ${rc}."
    "${PSQL[@]}" -qc "DO \$\$ BEGIN RAISE WARNING '${marker}'; END \$\$;" >/dev/null 2>&1
    for ((attempt = 0; attempt < 100; attempt++)); do
        flushed=true
        for i in "${!SERVER_LOGS[@]}"; do
            grep -Fq "${marker}" "${SERVER_LOGS[$i]}" || flushed=false
        done
        [[ "${flushed}" == "true" ]] && break
        sleep 0.05
    done
    [[ "${flushed}" == "true" ]] || fail "PostgreSQL log collector did not flush."
    for i in "${!SERVER_LOGS[@]}"; do
        tail -c "+$((offsets[i] + 1))" "${SERVER_LOGS[$i]}" >"${WORK}/server-${i}"
    done
}

assert_no_secrets() {
    local output
    for output in stdout stderr server-0 server-1 server-2; do
        if grep -Eq 'SCRAM-SHA-256|CREATE ROLE .*PASSWORD|ALTER USER .*PASSWORD' "${WORK}/${output}" \
                || grep -Fq -f "${WORK}/original-password" -f "${WORK}/replacement-password" "${WORK}/${output}"; then
            fail "Credential material in ${output}."
        fi
    done
}

extract_sql() {
    awk -v function_name="$2" '
        $0 == function_name "() {" { in_function = 1 }
        in_function && /^SET log_statement / { in_sql = 1 }
        in_sql && $0 == "SQL" { exit }
        in_sql { print }
    ' "$1"
}

role_snapshot() {
    PGOPTIONS='-c client_min_messages=notice' "${PSQL[@]}" -Atq -v username="$1" <<'SQL'
SELECT md5(row_to_json(r)::text) FROM pg_authid r WHERE rolname = :'username';
SQL
}

authenticate() {
    PGPASSWORD="$(cat "$1")" "${PG_BIN}/psql" -X -h 127.0.0.1 -p 57895 \
        -U dupuser -d postgres -w -Atqc 'SELECT 1' >"${WORK}/auth.stdout" 2>"${WORK}/auth.stderr"
}

run_captured 0 sudo bash "${ADMIN}" create-user "${ADMIN_ARGS[@]}" \
    --username dupuser --password-file "${WORK}/original-password"
assert_no_secrets
authenticate "${WORK}/original-password" || fail "Initial password does not authenticate."

jq -cn --arg user dupuser --rawfile pwd "${WORK}/replacement-password" \
    '{createUser: $user, pwd: ($pwd | rtrimstr("\n")), roles: [{role:"readWriteAnyDatabase",db:"admin"},{role:"clusterAdmin",db:"admin"}], "$db":"admin"}' \
    >"${WORK}/user.json"
export USER_BSON_FILE="${WORK}/user.json"
extract_sql "${ADMIN}" cmd_create_user \
    | sed "/^SET log_min_messages = 'panic';$/d; /^SET client_min_messages = 'notice';$/d; /^\\\\set VERBOSITY terse$/d" >"${WORK}/control.sql"
run_captured 3 "${PSQL[@]}" -f "${WORK}/control.sql"
grep -q 'SCRAM-SHA-256' "${WORK}/stderr" || fail "Control did not expose the verifier in stderr."
for i in "${!SERVER_LOGS[@]}"; do
    grep -q 'SCRAM-SHA-256' "${WORK}/server-${i}" || fail "Control did not expose the verifier in server log ${i}."
done
echo "PASS: control reproduces both disclosure channels"

for username in dupuser postgres; do
    before="$(role_snapshot "${username}")"
    [[ -n "${before}" ]] || fail "Missing role ${username}."
    run_captured 3 sudo bash "${ADMIN}" create-user "${ADMIN_ARGS[@]}" \
        --username "${username}" --password-file "${WORK}/replacement-password"
    grep -q 'already exists' "${WORK}/stderr" || fail "Duplicate-user error was lost."
    ! grep -q 'created with roles' "${WORK}/stdout" || fail "Duplicate creation reported success."
    assert_no_secrets
    [[ "$(role_snapshot "${username}")" == "${before}" ]] || fail "Duplicate creation changed ${username}."
done
authenticate "${WORK}/original-password" || fail "Duplicate creation changed the password."
if authenticate "${WORK}/replacement-password"; then
    fail "Rejected password unexpectedly authenticates."
fi
echo "PASS: duplicate users retain credentials and exit 3 without disclosing secrets"

run_captured 3 sudo bash "${ADMIN}" create-user "${ADMIN_ARGS[@]}" \
    --username rejecteduser --password-file "${WORK}/replacement-password" \
    --roles '[]'
grep -Fq 'No role specified' "${WORK}/stderr" \
    || fail "Invalid-role error was lost."
assert_no_secrets
[[ -z "$(role_snapshot rejecteduser)" ]] || fail "Invalid roles created a user."
echo "PASS: non-duplicate errors remain visible without creating a user"

extract_sql "${SETUP}" create_documentdb_user >"${WORK}/setup-create.sql"
run_captured 3 "${PSQL[@]}" -f "${WORK}/setup-create.sql"
grep -q 'already exists' "${WORK}/stderr" || fail "Setup duplicate-user error was lost."
assert_no_secrets
echo "PASS: setup create-user SQL hides credential context"

jq -cn --arg user missinguser --rawfile pwd "${WORK}/replacement-password" \
    '{updateUser:$user, pwd:($pwd | rtrimstr("\n")), "$db":"admin"}' >"${WORK}/update.json"
export BSON_FILE="${WORK}/update.json"
for entry in "${ADMIN}:cmd_reset_password" "${SETUP}:reset_documentdb_user_password"; do
    extract_sql "${entry%:*}" "${entry##*:}" >"${WORK}/reset.sql"
    run_captured 3 "${PSQL[@]}" -f "${WORK}/reset.sql"
    grep -q 'does not exist' "${WORK}/stderr" || fail "Missing-user reset error was lost."
    assert_no_secrets
done
echo "PASS: both password-reset SQL paths hide credential context"

run_captured 0 sudo bash "${ADMIN}" reset-password "${ADMIN_ARGS[@]}" \
    --username dupuser --password-file "${WORK}/replacement-password"
assert_no_secrets
authenticate "${WORK}/replacement-password" || fail "Reset password does not authenticate."
if authenticate "${WORK}/original-password"; then
    fail "Old password still authenticates after reset."
fi
echo "PASS: successful password reset is unchanged"

run_captured 3 "${PSQL[@]}" <<'SQL'
SELECT 1/0;
SQL
for i in "${!SERVER_LOGS[@]}"; do
    grep -q 'division by zero' "${WORK}/server-${i}" || fail "Logging was disabled outside the credential session."
done
echo "PASS: other sessions still log errors in text, CSV, and JSON"
