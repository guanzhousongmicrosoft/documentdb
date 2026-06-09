#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-local-reset — destructive per-major cluster wipe.
#
# Scope: greenfield (stand-alone-package-owned) installs ONLY. In
# brownfield mode the adopted PostgreSQL instance is the operator's
# property and its managed-block mutations live in the system PG's
# pg_hba.conf / pg_ident.conf / postgresql.conf. This tool refuses to
# touch those — `documentdb-setup --restore` is the correct entry point
# for brownfield because it knows how to strip managed blocks safely.
#
# Usage:
#   documentdb-local-reset --pg-version N --confirm-destroy

set -euo pipefail

readonly PROG="documentdb-local-reset"

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }

usage() {
    cat <<'EOF'
Usage: documentdb-local-reset --pg-version N --confirm-destroy

Destructive wipe of the GREENFIELD DocumentDB Local appliance for a specific
PostgreSQL major version. This stops services, removes the per-major data
directory, gateway state, backups, logs, config, and runtime dirs.
THE DATA IS PERMANENTLY LOST.

Brownfield (adopted PostgreSQL) installs are NOT supported by this tool —
they keep the operator's existing PG service and config files, which this
destructive path is not safe to touch. Use `documentdb-setup --restore`
for brownfield instead; it strips only the package-managed blocks and
leaves the adopted PostgreSQL data, roles, and contents intact.

Options:
  --pg-version N       PostgreSQL major version to reset (required)
  --confirm-destroy    Required safety flag (no default)
  -h, --help           Show this help message
EOF
}

PG_VERSION=""
CONFIRMED=false

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pg-version)
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                PG_VERSION="$2"; shift 2 ;;
            --confirm-destroy)
                CONFIRMED=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    [[ -n "${PG_VERSION}" ]] || die "--pg-version is required."
    [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg-version must be a positive integer."
    [[ "${CONFIRMED}" == "true" ]] || die "--confirm-destroy is required. This operation is destructive and irreversible."
}

main() {
    parse_arguments "$@"

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Must be run as root."
    fi

    local data_dir="/var/lib/documentdb-local/${PG_VERSION}/data"
    local gw_dir="/var/lib/documentdb-local/${PG_VERSION}/gateway"
    local backup_dir="/var/lib/documentdb-local/${PG_VERSION}/backups"
    local log_dir="/var/log/documentdb-local/${PG_VERSION}"
    local config_dir="/etc/documentdb/local/${PG_VERSION}"
    local run_dir="/run/documentdb-local/${PG_VERSION}"
    local brownfield_marker="/etc/documentdb/local/${PG_VERSION}/brownfield.conf"

    # Reviewer-flagged (multi-model blocker C): refuse to proceed on a
    # brownfield install. The destructive cleanup below only knows about
    # the greenfield layout (per-major /var/lib/documentdb-local/N/...
    # and the package-owned systemd target). On brownfield the gateway
    # is layered on top of an operator-owned PostgreSQL service whose
    # data dir is at /var/lib/postgresql/N/main (Debian/Ubuntu) or
    # /var/lib/pgsql/N/data (RHEL) and whose pg_hba.conf / pg_ident.conf
    # carry the documentdb-setup managed blocks. This tool can neither
    # safely delete that operator-owned data nor strip those managed
    # blocks, so it must hand the operator to `documentdb-setup --restore`
    # which knows how to do the non-destructive restore correctly.
    if [[ -f "${brownfield_marker}" ]]; then
        die "Brownfield install detected at ${brownfield_marker}. This tool only handles greenfield (stand-alone-package-owned) installs. Run 'documentdb-setup --restore' to non-destructively detach the gateway from the adopted PostgreSQL instance, or remove the brownfield marker manually after handling its lifecycle if you truly want to wipe per-major state."
    fi

    # Stop services
    if command -v systemctl >/dev/null 2>&1; then
        log "Stopping documentdb-local@${PG_VERSION}.target..."
        systemctl stop "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
        systemctl disable "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
    fi

    # Remove data
    if [[ -d "${data_dir}" ]]; then
        log "Removing data directory: ${data_dir}"
        rm -rf "${data_dir}"
    fi

    # Remove gateway state
    if [[ -d "${gw_dir}" ]]; then
        log "Removing gateway directory: ${gw_dir}"
        rm -rf "${gw_dir}"
    fi

    # Remove backups
    if [[ -d "${backup_dir}" ]]; then
        log "Removing backups: ${backup_dir}"
        rm -rf "${backup_dir}"
    fi

    # Remove logs
    if [[ -d "${log_dir}" ]]; then
        log "Removing logs: ${log_dir}"
        rm -rf "${log_dir}"
    fi

    # Remove config
    if [[ -d "${config_dir}" ]]; then
        log "Removing config: ${config_dir}"
        rm -rf "${config_dir}"
    fi

    # Remove runtime dir
    if [[ -d "${run_dir}" ]]; then
        rm -rf "${run_dir}"
    fi

    # Clean up empty parent dirs
    rmdir --ignore-fail-on-non-empty /var/lib/documentdb-local/"${PG_VERSION}" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    log "Greenfield DocumentDB Local for PostgreSQL ${PG_VERSION} has been completely reset."
}

main "$@"
