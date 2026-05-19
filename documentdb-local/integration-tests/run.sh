#!/bin/bash
#
# Local runner for the documentdb-local integration tests.
#
# Builds nothing - takes an image reference, starts a fresh container with
# --skip-init-data, mounts the tests/ directory read-only, then executes
# every tests/*.js file with `docker exec mongosh --file`. Prints PASS/FAIL
# per file and a summary at the end. Exits non-zero if any test file fails.
#
# Usage:
#   ./integration-tests/run.sh --image documentdb-local:dev
#   ./integration-tests/run.sh --image documentdb-local:dev --only 03-indexes.js
#   ./integration-tests/run.sh --image documentdb-local:dev --results-dir /tmp/results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

IMAGE_REF=""
CONTAINER_NAME="documentdb-local-integration-$$"
DOCUMENTDB_USER="docdb_admin"
DOCUMENTDB_PASSWORD=""
DOCUMENTDB_PORT="10260"
ONLY=""
RESULTS_DIR=""
READY_TIMEOUT="240"
KEEP_CONTAINER="false"

usage() {
    cat <<EOF
Run the documentdb-local integration tests against a built image.

Options:
  --image <ref>            Docker image reference (required).
  --container <name>       Container name (default: documentdb-local-integration-<pid>).
  --user <name>            DocumentDB username (default: docdb_admin).
  --password <pw>          DocumentDB password (default: a random 32-char string).
  --port <port>            Container port for the gateway (default: 10260).
  --only <file>            Run a single tests/<file> only (basename, e.g. 03-indexes.js).
  --results-dir <path>     Write container logs to this directory on failure.
  --ready-timeout <secs>   Time to wait for the readiness log line (default: 240).
  --keep-container         Leave the container running after the run.
  -h, --help               Show this help.

Examples:
  $0 --image documentdb-local:dev
  $0 --image documentdb-local:dev --only 03-indexes.js
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)           IMAGE_REF="$2"; shift 2 ;;
        --container)       CONTAINER_NAME="$2"; shift 2 ;;
        --user)            DOCUMENTDB_USER="$2"; shift 2 ;;
        --password)        DOCUMENTDB_PASSWORD="$2"; shift 2 ;;
        --port)            DOCUMENTDB_PORT="$2"; shift 2 ;;
        --only)            ONLY="$2"; shift 2 ;;
        --results-dir)     RESULTS_DIR="$2"; shift 2 ;;
        --ready-timeout)   READY_TIMEOUT="$2"; shift 2 ;;
        --keep-container)  KEEP_CONTAINER="true"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$IMAGE_REF" ]; then
    echo "Error: --image is required." >&2
    usage >&2
    exit 1
fi

if [ ! -d "$TESTS_DIR" ]; then
    echo "Error: tests directory not found: $TESTS_DIR" >&2
    exit 1
fi

if [ -z "$DOCUMENTDB_PASSWORD" ]; then
    DOCUMENTDB_PASSWORD=$(python3 -c \
      'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))')
fi

# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    local code=$?
    if [ "$KEEP_CONTAINER" = "true" ]; then
        echo "Leaving container running: $CONTAINER_NAME"
    else
        if [ -n "$RESULTS_DIR" ] && [ "$code" -ne 0 ]; then
            mkdir -p "$RESULTS_DIR"
            docker logs "$CONTAINER_NAME" \
                > "$RESULTS_DIR/$(basename "$CONTAINER_NAME").log" 2>&1 || true
        fi
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    exit "$code"
}
trap cleanup EXIT

wait_for_log() {
    local pattern="$1"
    local timeout_seconds="$2"
    local waited=0
    while ! docker logs "$CONTAINER_NAME" 2>&1 | grep -Fq "$pattern"; do
        local running
        running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" \
            2>/dev/null || echo false)
        if [ "$running" != "true" ]; then
            echo "Container exited before log pattern appeared: $pattern" >&2
            docker logs "$CONTAINER_NAME" || true
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge "$timeout_seconds" ]; then
            echo "Timed out waiting for log pattern: $pattern" >&2
            docker logs "$CONTAINER_NAME" || true
            return 1
        fi
    done
}

echo "Starting container ${CONTAINER_NAME} from image ${IMAGE_REF}..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --mount "type=bind,source=${TESTS_DIR},target=/integration-tests,readonly" \
    "$IMAGE_REF" \
    --username "$DOCUMENTDB_USER" \
    --password "$DOCUMENTDB_PASSWORD" \
    --skip-init-data >/dev/null

wait_for_log "=== DocumentDB is ready ===" "$READY_TIMEOUT"
echo "Container is ready."

# Build the test-file list. Prefer find . -maxdepth 1 over ls | grep so the
# order is alphabetical and non-script files do not sneak in.
mapfile -t test_files < <(
    cd "$TESTS_DIR" && \
        find . -maxdepth 1 -type f -name '*.js' -printf '%f\n' | sort
)

if [ -n "$ONLY" ]; then
    test_files=("$ONLY")
    if [ ! -f "${TESTS_DIR}/${ONLY}" ]; then
        echo "Error: --only file does not exist: ${TESTS_DIR}/${ONLY}" >&2
        exit 1
    fi
fi

if [ "${#test_files[@]}" -eq 0 ]; then
    echo "Error: no test files found in ${TESTS_DIR}" >&2
    exit 1
fi

passed_files=()
failed_files=()

for tf in "${test_files[@]}"; do
    echo ""
    echo "------------------------------------------------------------"
    echo "Running ${tf}"
    echo "------------------------------------------------------------"

    if docker exec -i "$CONTAINER_NAME" mongosh \
        "localhost:${DOCUMENTDB_PORT}" \
        -u "$DOCUMENTDB_USER" -p "$DOCUMENTDB_PASSWORD" \
        --authenticationMechanism SCRAM-SHA-256 \
        --tls --tlsAllowInvalidCertificates \
        --quiet \
        --file "/integration-tests/${tf}"; then
        passed_files+=("$tf")
    else
        failed_files+=("$tf")
    fi
done

echo ""
echo "============================================================"
echo "Integration test summary"
echo "============================================================"
echo "Passed (${#passed_files[@]}):"
for f in "${passed_files[@]}"; do echo "  PASS  $f"; done
echo "Failed (${#failed_files[@]}):"
for f in "${failed_files[@]}"; do echo "  FAIL  $f"; done

if [ "${#failed_files[@]}" -gt 0 ]; then
    exit 1
fi
exit 0
