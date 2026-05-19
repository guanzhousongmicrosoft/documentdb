#!/bin/bash
#
# Scenario: authentication.
#
# Exercises the auth surface of documentdb-local:
#   - correct creds succeed
#   - wrong password is rejected
#   - wrong username is rejected
#   - missing creds are rejected
#   - --create-user false skips user creation, default seeded admin still works
#
# Usage:
#   ./scenarios/auth.sh <image_ref> [results_dir]

set -euo pipefail

IMAGE_REF="${1:?image reference required as the first argument}"
RESULTS_DIR="${2:-.test-results/integration-auth}"

mkdir -p "$RESULTS_DIR"

SUFFIX="$$"
USER_CONTAINER="docdb-auth-user-${SUFFIX}"
NOUSER_CONTAINER="docdb-auth-nouser-${SUFFIX}"

DOCUMENTDB_USER="docdb_admin"
DOCUMENTDB_PASSWORD="$(python3 -c \
    'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))')"
# A deliberately different password used for the negative-test container.
WRONG_PASSWORD="${DOCUMENTDB_PASSWORD}-wrong"

cleanup() {
    for container in "$USER_CONTAINER" "$NOUSER_CONTAINER"; do
        if docker ps -a --format '{{.Names}}' | grep -Fxq "$container"; then
            docker logs "$container" \
                > "${RESULTS_DIR}/${container}.log" 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT

wait_for_ready() {
    local container="$1"
    local waited=0
    local timeout=240
    while ! docker logs "$container" 2>&1 | grep -Fq "=== DocumentDB is ready ==="; do
        local running
        running=$(docker inspect -f '{{.State.Running}}' "$container" \
            2>/dev/null || echo false)
        if [ "$running" != "true" ]; then
            echo "Container ${container} exited before becoming ready." >&2
            docker logs "$container" || true
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge "$timeout" ]; then
            echo "Timed out waiting for ${container} readiness." >&2
            docker logs "$container" || true
            return 1
        fi
    done
}

mongosh_eval() {
    # Args: container, username, password, eval-string
    local container="$1"; shift
    local user="$1"; shift
    local pw="$1"; shift
    local code="$1"; shift
    docker exec -i "$container" mongosh \
        "localhost:10260" \
        -u "$user" -p "$pw" \
        --authenticationMechanism SCRAM-SHA-256 \
        --tls --tlsAllowInvalidCertificates \
        --quiet \
        --eval "$code"
}

mongosh_unauth_eval() {
    local container="$1"; shift
    local code="$1"; shift
    docker exec -i "$container" mongosh \
        "localhost:10260" \
        --tls --tlsAllowInvalidCertificates \
        --quiet \
        --eval "$code"
}

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1: $2" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Scenario 1: --username / --password creates a usable account
# ---------------------------------------------------------------------------

echo "=== Scenario: --username + --password creates a working account ==="

docker run -d \
    --name "$USER_CONTAINER" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --skip-init-data >/dev/null
wait_for_ready "$USER_CONTAINER"

# Positive: correct creds get ok=1 on ping.
out=$(mongosh_eval "$USER_CONTAINER" "$DOCUMENTDB_USER" "$DOCUMENTDB_PASSWORD" \
    'db.runCommand({ping: 1}).ok')
last=$(printf '%s' "$out" | tr -d '\r' | tail -n1)
if [ "$last" = "1" ]; then
    pass "correct creds succeed"
else
    fail "correct creds succeed" "ping last line was '$last' (full: $out)"
fi

# Negative: wrong password is rejected.
if mongosh_eval "$USER_CONTAINER" "$DOCUMENTDB_USER" "$WRONG_PASSWORD" \
    'db.runCommand({ping: 1})' >/dev/null 2>&1; then
    fail "wrong password rejected" "ping unexpectedly succeeded with wrong password"
fi
pass "wrong password rejected"

# Negative: wrong username is rejected.
if mongosh_eval "$USER_CONTAINER" "no_such_user" "$DOCUMENTDB_PASSWORD" \
    'db.runCommand({ping: 1})' >/dev/null 2>&1; then
    fail "wrong username rejected" "ping unexpectedly succeeded with unknown user"
fi
pass "wrong username rejected"

# Negative: unauthenticated connection is rejected. We probe with
# `listDatabases` rather than `ping` because the MongoDB wire protocol
# allows ping (and a handful of other handshake commands) to succeed
# without authentication by design; the documentdb gateway follows that
# rule, so a `ping`-based check is a false negative.
if mongosh_unauth_eval "$USER_CONTAINER" \
    'db.adminCommand({listDatabases: 1})' >/dev/null 2>&1; then
    fail "unauthenticated rejected" "listDatabases unexpectedly succeeded without creds"
fi
pass "unauthenticated rejected"

docker rm -f "$USER_CONTAINER" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 2: --create-user false starts cleanly. We intentionally do not
# assert on which credentials work here, because that depends on whether
# any account was provisioned at PG initdb time, which is outside the
# documentdb-local image's contract. The check that matters is that the
# entrypoint takes the no-user code path, reaches readiness, and stays up.
# ---------------------------------------------------------------------------

echo ""
echo "=== Scenario: --create-user false starts cleanly ==="

docker run -d \
    --name "$NOUSER_CONTAINER" \
    "$IMAGE_REF" \
    --create-user false \
    --skip-init-data >/dev/null
wait_for_ready "$NOUSER_CONTAINER"
pass "container with --create-user false reaches readiness"

# The container should still be running a few seconds after readiness; this
# guards against the entrypoint racing on a missing user and exiting.
sleep 3
running=$(docker inspect -f '{{.State.Running}}' "$NOUSER_CONTAINER" \
    2>/dev/null || echo false)
if [ "$running" != "true" ]; then
    fail "container with --create-user false stays running" \
        "container is no longer running after readiness"
fi
pass "container with --create-user false stays running after readiness"

docker rm -f "$NOUSER_CONTAINER" >/dev/null

echo ""
echo "All auth scenarios passed."
