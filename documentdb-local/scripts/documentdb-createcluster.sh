#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-createcluster — Debian/Ubuntu helper that wraps pg_createcluster
# and documentdb-tune to create a DocumentDB-ready PostgreSQL cluster in one
# step.
#
# Usage:
#  documentdb-createcluster N C [--start]
#
# Example:
#  documentdb-createcluster 17 main --start

set -euo pipefail

readonly PROG="documentdb-createcluster"

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }
# stderr: resolve_extra_extension's stdout is captured by command substitution.
warn() { echo "[${PROG}] WARNING: $*" >&2; }

run_as_user() {
    local target_user="$1"; shift
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "${target_user}" -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "${target_user}" "$@"
    else
        su -s /bin/bash "${target_user}" -c "$(printf '%q ' "$@")"
    fi
}

usage() {
    cat <<'EOF'
Usage: documentdb-createcluster VERSION CLUSTER [OPTIONS]

Create a PostgreSQL cluster tuned for DocumentDB. Debian/Ubuntu only.

Arguments:
  VERSION    PostgreSQL major version (e.g., 15, 16, 17, 18)
  CLUSTER    Cluster name (e.g., "main")

Options:
  --start    Start the cluster after creating and tuning it, then create the
             DocumentDB extensions in the "postgres" database
  -h, --help Show this help message
EOF
}

# ── Help / usage ────────────────────────────────────────────────────
# Handle help and the no-arguments case BEFORE the environment guards below,
# so that `documentdb-createcluster --help` (and a bare invocation) work on
# every platform — including RHEL, where pg_createcluster is intentionally
# absent and the guard would otherwise abort before usage is ever shown.

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    -h|--help) usage; exit 0 ;;
esac

# ── Guard: Debian/Ubuntu only ───────────────────────────────────────

if ! command -v pg_createcluster >/dev/null 2>&1; then
    die "pg_createcluster is not available. This tool is for Debian/Ubuntu only. On RHEL, use 'postgresql-N-setup --initdb' followed by 'documentdb-tune --pg-version N --pgdata /var/lib/pgsql/N/data --yes'."
fi

if ! command -v documentdb-tune >/dev/null 2>&1; then
    die "documentdb-tune is not installed. Install the documentdb-postgresql-tools package first."
fi

# Sourced after the help handling and platform guards above so --help and the
# "Debian/Ubuntu only" diagnostic still work when the library is absent.
_DDB_TOOLS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _ddb_cand in "${_DDB_TOOLS_LIB_DIR}/documentdb-tools-lib.sh" \
                 "/usr/share/documentdb/scripts/documentdb-tools-lib.sh"; do
    if [[ -f "${_ddb_cand}" ]]; then
        # shellcheck source=documentdb-tools-lib.sh
        source "${_ddb_cand}"
        _DDB_TOOLS_LIB_LOADED=1
        break
    fi
done
[[ "${_DDB_TOOLS_LIB_LOADED:-}" == "1" ]] \
    || die "cannot locate documentdb-tools-lib.sh (looked beside ${BASH_SOURCE[0]} and in /usr/share/documentdb/scripts)."

# ── Argument parsing ────────────────────────────────────────────────

PG_VERSION=""
CLUSTER_NAME=""
START=false

[[ $# -ge 2 ]] || die "Both VERSION and CLUSTER arguments are required."

PG_VERSION="$1"
CLUSTER_NAME="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start) START=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "VERSION must be a positive integer."
[[ -n "${CLUSTER_NAME}" ]] || die "CLUSTER name must not be empty."
# Validate before passing to pg_createcluster and documentdb-tune (which
# interpolates it into managed config paths). Restricts to safe characters.
[[ "${CLUSTER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "Invalid CLUSTER name '${CLUSTER_NAME}'. Only alphanumerics, hyphens, and underscores are allowed, and the name must not start with a hyphen."

# ── Main ────────────────────────────────────────────────────────────

log "Creating PostgreSQL ${PG_VERSION} cluster '${CLUSTER_NAME}'."
pg_createcluster "${PG_VERSION}" "${CLUSTER_NAME}" -- \
    --auth-local=peer \
    --auth-host=scram-sha-256 \
    --encoding=UTF8

log "Tuning cluster for DocumentDB."
documentdb-tune --pg-version "${PG_VERSION}" --cluster "${CLUSTER_NAME}" --yes

if [[ "${START}" == "true" ]]; then
    log "Starting cluster."
    pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" start
fi

# documentdb-tune pins documentdb.alternate_index_handler_name='extended_rum'
# whenever the extended-RUM extension is installed, but that access method only
# exists where documentdb_extended_rum has been created, and
# CREATE EXTENSION documentdb CASCADE does not create it. Without this a tuned,
# started cluster cannot create an index of any kind.
#
# Echo the extra extension this host needs, or nothing, using the same probe
# documentdb-tune used so the two cannot disagree.
resolve_extra_extension() {
    local bindir="" sharedir="" candidate=""

    while IFS= read -r candidate; do
        if [[ -x "${candidate}/pg_config" ]]; then
            bindir="${candidate}"
            break
        fi
    done < <(documentdb_pg_bindir_candidates "${PG_VERSION}")

    if [[ -n "${bindir}" ]]; then
        sharedir="$("${bindir}/pg_config" --sharedir 2>/dev/null)" || sharedir=""
    fi

    # Never fail over this, but never fail silently either: an undetected
    # extended-RUM install is how a cluster ends up tuned for an access method
    # that was never created.
    if [[ -z "${sharedir}" ]]; then
        warn "could not read the PostgreSQL ${PG_VERSION} share directory; assuming documentdb_extended_rum is not installed."
        return 0
    fi

    documentdb_detect_extended_rum "${sharedir}"
    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        printf 'documentdb_extended_rum'
    fi
    return 0
}

create_documentdb_extensions() {
    local extra_extension="$1"

    log "Creating DocumentDB extensions in the 'postgres' database."
    # --cluster resolves this cluster's binary, socket, and port, so nothing has
    # to be guessed (pg_createcluster does not always pick 5432).
    if ! documentdb_create_extension_sql "${extra_extension}" \
            | run_as_user postgres psql --cluster "${PG_VERSION}/${CLUSTER_NAME}" \
                -d postgres -X -v ON_ERROR_STOP=1 -f -; then
        die "failed to create the DocumentDB extensions in the 'postgres' database of cluster ${PG_VERSION}/${CLUSTER_NAME}."
    fi
}

EXTRA_EXTENSION="$(resolve_extra_extension)"

if [[ "${START}" == "true" ]]; then
    create_documentdb_extensions "${EXTRA_EXTENSION}"
fi

log "Done. Cluster ${PG_VERSION}/${CLUSTER_NAME} is ready for DocumentDB."
if [[ "${START}" != "true" ]]; then
    echo "Start with: sudo pg_ctlcluster ${PG_VERSION} ${CLUSTER_NAME} start"
    echo "Then create the extensions (required before any index can be created):"
    echo "  $(documentdb_create_extension_command postgres postgres "${EXTRA_EXTENSION}")"
fi
