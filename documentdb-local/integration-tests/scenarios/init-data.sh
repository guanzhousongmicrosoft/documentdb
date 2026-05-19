#!/bin/bash
#
# Scenario: init-data.
#
# Exercises the four init-data code paths in scripts/init_documentdb_data.sh:
#   1. --init-data true loads the built-in sample-data into 'sampledb'
#   2. --init-data-path /path with user-mounted *.js loads custom data
#   3. --skip-init-data leaves the server bare (no sampledb)
#   4. Invalid JS in the init-data directory causes the container to exit
#      with non-zero, instead of silently coming up with partial state.
#
# Usage:
#   ./scenarios/init-data.sh <image_ref> [results_dir]

set -euo pipefail

IMAGE_REF="${1:?image reference required as the first argument}"
RESULTS_DIR="${2:-.test-results/integration-init-data}"

mkdir -p "$RESULTS_DIR"

SUFFIX="$$"
BUILTIN_CONTAINER="docdb-init-builtin-${SUFFIX}"
CUSTOM_CONTAINER="docdb-init-custom-${SUFFIX}"
SKIP_CONTAINER="docdb-init-skip-${SUFFIX}"
INVALID_CONTAINER="docdb-init-invalid-${SUFFIX}"

DOCUMENTDB_USER="docdb_admin"
DOCUMENTDB_PASSWORD="$(python3 -c \
    'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))')"

CUSTOM_DIR="$(mktemp -d -t docdb-init-custom.XXXXXX)"
INVALID_DIR="$(mktemp -d -t docdb-init-invalid.XXXXXX)"

cleanup() {
    for container in "$BUILTIN_CONTAINER" "$CUSTOM_CONTAINER" \
                     "$SKIP_CONTAINER" "$INVALID_CONTAINER"; do
        if docker ps -a --format '{{.Names}}' | grep -Fxq "$container"; then
            docker logs "$container" \
                > "${RESULTS_DIR}/${container}.log" 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "$CUSTOM_DIR" "$INVALID_DIR"
}
trap cleanup EXIT

wait_for_ready() {
    local container="$1"
    local waited=0
    local timeout="${2:-240}"
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

wait_for_log() {
    local container="$1"
    local pattern="$2"
    local timeout="${3:-240}"
    local waited=0
    while ! docker logs "$container" 2>&1 | grep -Fq "$pattern"; do
        local running
        running=$(docker inspect -f '{{.State.Running}}' "$container" \
            2>/dev/null || echo true)
        if [ "$running" != "true" ]; then
            echo "Container ${container} exited before pattern '${pattern}'." >&2
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge "$timeout" ]; then
            echo "Timed out waiting for '${pattern}' in ${container}." >&2
            return 1
        fi
    done
}

mongosh_eval() {
    local container="$1"; shift
    local code="$1"; shift
    docker exec -i "$container" mongosh \
        "localhost:10260" \
        -u "$DOCUMENTDB_USER" -p "$DOCUMENTDB_PASSWORD" \
        --authenticationMechanism SCRAM-SHA-256 \
        --tls --tlsAllowInvalidCertificates \
        --quiet \
        --eval "$code"
}

assert_count_eq() {
    local container="$1"
    local db_name="$2"
    local coll_name="$3"
    local expected="$4"
    local label="$5"

    local raw
    raw=$(mongosh_eval "$container" \
        "db.getSiblingDB('${db_name}').getCollection('${coll_name}').countDocuments()")
    local got
    got=$(printf '%s' "$raw" | tr -d '\r' | tail -n1)
    if [ "$got" = "$expected" ]; then
        echo "  PASS  ${label} (expected ${expected}, got ${got})"
    else
        echo "  FAIL  ${label}: expected ${expected}, got '${got}' (raw: ${raw})" >&2
        exit 1
    fi
}

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1: $2" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Scenario 1: --init-data true populates the built-in sampledb
# ---------------------------------------------------------------------------

echo "=== Scenario: --init-data true loads built-in sample data ==="

docker run -d \
    --name "$BUILTIN_CONTAINER" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --init-data true >/dev/null
wait_for_ready "$BUILTIN_CONTAINER"
wait_for_log "$BUILTIN_CONTAINER" "Sample data initialization completed!" 240

assert_count_eq "$BUILTIN_CONTAINER" sampledb users    5 "sampledb.users == 5"
assert_count_eq "$BUILTIN_CONTAINER" sampledb products 5 "sampledb.products == 5"
assert_count_eq "$BUILTIN_CONTAINER" sampledb orders   4 "sampledb.orders == 4"

docker rm -f "$BUILTIN_CONTAINER" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 2: custom --init-data-path via volume mount
# ---------------------------------------------------------------------------

echo ""
echo "=== Scenario: custom init-data via volume mount ==="

cat > "$CUSTOM_DIR/01-seed.js" <<'JS'
use('customdb');
db.widgets.insertMany([
  { _id: 1, color: 'red',   qty: 3 },
  { _id: 2, color: 'green', qty: 5 },
  { _id: 3, color: 'blue',  qty: 7 },
]);
db.widgets.createIndex({ color: 1 }, { name: 'color_1' });
JS

cat > "$CUSTOM_DIR/02-more.js" <<'JS'
use('customdb');
db.tags.insertOne({ _id: 1, name: 'alpha' });
JS

docker run -d \
    --name "$CUSTOM_CONTAINER" \
    --mount "type=bind,source=${CUSTOM_DIR},target=/init_doc_db.d,readonly" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --init-data-path /init_doc_db.d >/dev/null
wait_for_ready "$CUSTOM_CONTAINER"
wait_for_log "$CUSTOM_CONTAINER" "Sample data initialization completed!" 240

assert_count_eq "$CUSTOM_CONTAINER" customdb widgets 3 "customdb.widgets == 3"
assert_count_eq "$CUSTOM_CONTAINER" customdb tags    1 "customdb.tags == 1"

# Verify the index from the init script materialized.
raw=$(mongosh_eval "$CUSTOM_CONTAINER" \
    "JSON.stringify(db.getSiblingDB('customdb').widgets.getIndexes().map(i => i.name))")
if echo "$raw" | grep -Fq "color_1"; then
    pass "color_1 index created by init script"
else
    fail "color_1 index created by init script" "indexes: $raw"
fi

docker rm -f "$CUSTOM_CONTAINER" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 3: --skip-init-data leaves the server bare
# ---------------------------------------------------------------------------

echo ""
echo "=== Scenario: --skip-init-data leaves the server bare ==="

docker run -d \
    --name "$SKIP_CONTAINER" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --skip-init-data >/dev/null
wait_for_ready "$SKIP_CONTAINER"

# sampledb should not exist.
raw=$(mongosh_eval "$SKIP_CONTAINER" \
    "JSON.stringify(db.adminCommand({listDatabases: 1, nameOnly: true}).databases.map(x => x.name))")
if echo "$raw" | grep -Fq "sampledb"; then
    fail "no sampledb after --skip-init-data" "databases: $raw"
fi
pass "no sampledb after --skip-init-data"

# Make sure the database is healthy enough to write/read after skip.
out=$(mongosh_eval "$SKIP_CONTAINER" 'db.runCommand({ping: 1}).ok')
last=$(printf '%s' "$out" | tr -d '\r' | tail -n1)
[ "$last" = "1" ] || fail "ping after --skip-init-data" "ping last line: $last"
pass "ping after --skip-init-data"

docker rm -f "$SKIP_CONTAINER" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 4: invalid JS init-data causes the container to exit non-zero
# ---------------------------------------------------------------------------

echo ""
echo "=== Scenario: invalid init JS makes the container exit non-zero ==="

cat > "$INVALID_DIR/01-bad.js" <<'JS'
// Deliberately broken: missing closing quote and bracket.
use('bad');
db.broken.insertOne({ k: "unterminated string
JS

# Run the container in the foreground so we can directly observe its exit
# code. --init-data-path with broken JS should make init_documentdb_data.sh
# return non-zero, the entrypoint propagates the failure, and `docker run`
# itself exits non-zero.
set +e
docker run \
    --name "$INVALID_CONTAINER" \
    --mount "type=bind,source=${INVALID_DIR},target=/init_doc_db.d,readonly" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --init-data-path /init_doc_db.d \
    > "${RESULTS_DIR}/${INVALID_CONTAINER}.foreground.log" 2>&1
exit_code=$?
set -e

if [ "$exit_code" -eq 0 ]; then
    fail "invalid init JS rejected" \
        "container unexpectedly exited 0 with broken init script (log: ${RESULTS_DIR}/${INVALID_CONTAINER}.foreground.log)"
fi
if ! grep -Fq "Failed to execute" "${RESULTS_DIR}/${INVALID_CONTAINER}.foreground.log"; then
    fail "invalid init JS rejected" \
        "expected 'Failed to execute' in container log: ${RESULTS_DIR}/${INVALID_CONTAINER}.foreground.log"
fi
pass "invalid init JS rejected (exit ${exit_code})"

docker rm -f "$INVALID_CONTAINER" >/dev/null 2>&1 || true

echo ""
echo "All init-data scenarios passed."
