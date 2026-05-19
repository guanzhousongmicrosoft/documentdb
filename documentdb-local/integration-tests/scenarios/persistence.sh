#!/bin/bash
#
# Scenario: persistence.
#
# Verifies that data written into a documentdb-local container survives a
# container restart when the gateway's data directory (/data) is mounted on
# a host bind volume. The flow is:
#
#   1. Start container A with a fresh /data volume, write a known doc and
#      a custom index into a known collection, stop the container.
#   2. Start container B against the SAME /data volume (different name,
#      same image, same password) and verify the doc and index are still
#      there.
#
# Usage:
#   ./scenarios/persistence.sh <image_ref> [results_dir]

set -euo pipefail

IMAGE_REF="${1:?image reference required as the first argument}"
RESULTS_DIR="${2:-.test-results/integration-persistence}"

mkdir -p "$RESULTS_DIR"

SUFFIX="$$"
CONTAINER_A="docdb-persist-a-${SUFFIX}"
CONTAINER_B="docdb-persist-b-${SUFFIX}"

DOCUMENTDB_USER="docdb_admin"
DOCUMENTDB_PASSWORD="$(python3 -c \
    'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))')"

# A host-owned data directory that both containers will mount as /data.
DATA_DIR="$(mktemp -d -t docdb-persist-data.XXXXXX)"
chmod 777 "$DATA_DIR"

cleanup() {
    for container in "$CONTAINER_A" "$CONTAINER_B"; do
        if docker ps -a --format '{{.Names}}' | grep -Fxq "$container"; then
            docker logs "$container" \
                > "${RESULTS_DIR}/${container}.log" 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
    # Help docker volumes that may have left root-owned files behind.
    chmod -R u+rwX "$DATA_DIR" 2>/dev/null || true
    rm -rf "$DATA_DIR" 2>/dev/null || true
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

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1: $2" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1: write data + index into container A on the shared /data volume
# ---------------------------------------------------------------------------

echo "=== Phase 1: write data into the shared /data volume (container A) ==="

docker run -d \
    --name "$CONTAINER_A" \
    --mount "type=bind,source=${DATA_DIR},target=/data" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --skip-init-data >/dev/null
wait_for_ready "$CONTAINER_A"

mongosh_eval "$CONTAINER_A" '
  const c = db.getSiblingDB("persist_db").widgets;
  c.deleteMany({});
  c.insertMany([
    { _id: 1, color: "red",   qty: 3 },
    { _id: 2, color: "green", qty: 5 },
    { _id: 3, color: "blue",  qty: 7 },
  ]);
  c.createIndex({ color: 1 }, { name: "color_persisted" });
'
pass "wrote persist_db.widgets and color_persisted index in container A"

# Pre-restart sanity check that the data is visible in container A itself.
raw=$(mongosh_eval "$CONTAINER_A" \
    'db.getSiblingDB("persist_db").widgets.countDocuments()')
got=$(printf '%s' "$raw" | tr -d '\r' | tail -n1)
[ "$got" = "3" ] || fail "pre-restart count" "expected 3, got $got"
pass "container A reads 3 widgets back"

# Stop container A but keep the on-disk PG data. `docker stop` gives the
# entrypoint a SIGTERM, which already handles cleanup, then we remove the
# container so its name can be reused (we use a different name to be safe).
docker stop "$CONTAINER_A" >/dev/null
docker rm -f "$CONTAINER_A" >/dev/null

# ---------------------------------------------------------------------------
# Phase 2: restart against the same /data volume with container B
# ---------------------------------------------------------------------------

echo ""
echo "=== Phase 2: restart against the same /data volume (container B) ==="

docker run -d \
    --name "$CONTAINER_B" \
    --mount "type=bind,source=${DATA_DIR},target=/data" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --skip-init-data >/dev/null
wait_for_ready "$CONTAINER_B"

raw=$(mongosh_eval "$CONTAINER_B" \
    'db.getSiblingDB("persist_db").widgets.countDocuments()')
got=$(printf '%s' "$raw" | tr -d '\r' | tail -n1)
[ "$got" = "3" ] || fail "widgets survived restart" \
    "expected 3, got '$got' (raw: $raw)"
pass "widgets survived restart"

# Inspect documents to be sure we are reading the same content back.
raw=$(mongosh_eval "$CONTAINER_B" \
    'JSON.stringify(db.getSiblingDB("persist_db").widgets.find({}, {_id: 1, color: 1}).sort({_id: 1}).toArray())')
last=$(printf '%s' "$raw" | tr -d '\r' | tail -n1)
expected='[{"_id":1,"color":"red"},{"_id":2,"color":"green"},{"_id":3,"color":"blue"}]'
if [ "$last" != "$expected" ]; then
    fail "widget content matches" "expected $expected, got $last"
fi
pass "widget content matches"

# Indexes (other than _id_) are persisted in the catalog and should still
# be present.
raw=$(mongosh_eval "$CONTAINER_B" \
    'JSON.stringify(db.getSiblingDB("persist_db").widgets.getIndexes().map(i => i.name))')
if ! echo "$raw" | grep -Fq "color_persisted"; then
    fail "color_persisted index survived restart" "indexes: $raw"
fi
pass "color_persisted index survived restart"

# A fresh write after restart should also succeed.
mongosh_eval "$CONTAINER_B" \
    'db.getSiblingDB("persist_db").widgets.insertOne({_id: 4, color: "yellow", qty: 1})'
raw=$(mongosh_eval "$CONTAINER_B" \
    'db.getSiblingDB("persist_db").widgets.countDocuments()')
got=$(printf '%s' "$raw" | tr -d '\r' | tail -n1)
[ "$got" = "4" ] || fail "post-restart write" "expected 4, got $got"
pass "post-restart write succeeds"

docker rm -f "$CONTAINER_B" >/dev/null

echo ""
echo "All persistence scenarios passed."
