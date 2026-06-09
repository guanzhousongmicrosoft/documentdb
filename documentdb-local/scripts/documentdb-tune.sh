#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-tune — apply or remove the recommended DocumentDB postgresql.conf
# settings for one PostgreSQL cluster.
#
# On Debian/Ubuntu this writes a per-cluster config file at
# /etc/postgresql-common/documentdb/<version>/<cluster>/postgresql.conf
# which is picked up via the createcluster.d include_if_exists hook.
#
# On RHEL (or when --pgdata is given) it edits the cluster's
# postgresql.conf directly using managed blocks.

set -euo pipefail
umask 077

readonly PROG="documentdb-tune"
# Managed block markers — intentionally match documentdb-setup.sh for backward
# compatibility with existing postrm cleanup scripts.
readonly MANAGED_BLOCK_START="# >>> documentdb-setup managed configuration >>>"
readonly MANAGED_BLOCK_END="# <<< documentdb-setup managed configuration <<<"

# ── Defaults ────────────────────────────────────────────────────────
PG_VERSION=""
CLUSTER_NAME=""
PGDATA=""
ACTION="apply"      # apply | restore | print
DRY_RUN=false
YES=false
VERBOSE=false

# Resolved at runtime
CONFIG_TARGET=""
IS_DEBIAN=false
HAS_EXTENDED_RUM=false
PG_SHAREDIR=""
DEBIAN_LIVE_PG_CONF=""

# ── Helpers ─────────────────────────────────────────────────────────

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }
log_verbose() { [[ "${VERBOSE}" == "true" ]] && echo "[${PROG}] $*"; return 0; }

# Real-user E2E flagged (Gap #14): tools that printed
# "sudo systemctl restart postgresql@N-main" gave no fallback on hosts
# without systemd (containers, minimal installs). Detect a working
# systemd PID-1 and print the platform-correct command; fall back to
# pg_ctlcluster (Debian) or pg_ctl (RHEL) when systemd is unavailable.
has_working_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

usage() {
    cat <<'EOF'
Usage: documentdb-tune [OPTIONS]

Apply or remove the recommended DocumentDB postgresql.conf settings for a
PostgreSQL cluster.

Options:
  --pg-version N    PostgreSQL major version (required unless --pgdata is given)
  --cluster C       Cluster name (Debian/Ubuntu, default: "main")
  --pgdata DIR      PostgreSQL data directory (overrides --pg-version/--cluster)
  --yes             Apply changes without prompting
  --dry-run         Show what would change without writing
  --restore         Remove the managed config block
  --print           Print the recommended config snippet to stdout and exit
  --verbose         Show detailed output
  -h, --help        Show this help message
EOF
}

trim_whitespace() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "${v}"
}

strip_wrapping_quotes() {
    local v="$1"
    if [[ "${v}" == \'*\' ]]; then
        v="${v:1:${#v}-2}"
    elif [[ "${v}" == \"*\" ]]; then
        v="${v:1:${#v}-2}"
    fi
    printf '%s' "${v}"
}

array_contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

# ── Managed-block helpers ───────────────────────────────────────────

strip_managed_block() {
    local target_file="$1" start="$2" end="$3"
    [[ -f "${target_file}" ]] || return 0
    # Safety: refuse to strip if start marker exists without end marker
    # (file appears truncated/corrupt). Match the postrm safety behavior.
    if grep -Fqx "${start}" "${target_file}" 2>/dev/null; then
        if ! grep -Fqx "${end}" "${target_file}" 2>/dev/null; then
            echo "${PROG}: refusing to strip managed block in ${target_file}: end marker missing." >&2
            cat "${target_file}"
            return 0
        fi
    fi
    awk -v s="${start}" -v e="${end}" \
        '$0==s{skip=1;next} $0==e{skip=0;next} !skip{print}' \
        "${target_file}"
}

extract_managed_block_content() {
    local target_file="$1" start="$2" end="$3"
    [[ -f "${target_file}" ]] || return 0
    awk -v s="${start}" -v e="${end}" \
        '$0==s{b=1;next} $0==e{b=0;next} b{print}' \
        "${target_file}"
}

rewrite_with_managed_block() {
    local target_file="$1" start="$2" end="$3" content="$4"
    local _rwmb_stripped _rwmb_tmp
    local _rwmb_dir
    _rwmb_dir="$(dirname "${target_file}")"

    # Reviewer-flagged (multi-model should-fix H — sibling parity with
    # documentdb-register-gateway.sh): create temp files in the target
    # file's directory so the eventual mv is an atomic same-filesystem
    # rename, and so an interrupted run does not leak postgresql.conf
    # contents into /tmp. mktemp's default template lands in /tmp which
    # is typically a separate filesystem from /etc/postgresql/.
    _rwmb_stripped="$(mktemp "${_rwmb_dir}/.documentdb-tune.XXXXXX")" \
        || die "Failed to create temp file in ${_rwmb_dir}."
    _rwmb_tmp="$(mktemp "${_rwmb_dir}/.documentdb-tune.XXXXXX")" \
        || { rm -f "${_rwmb_stripped}"; die "Failed to create temp file in ${_rwmb_dir}."; }
    # shellcheck disable=SC2064
    trap "rm -f '${_rwmb_stripped}' '${_rwmb_tmp}'" RETURN

    strip_managed_block "${target_file}" "${start}" "${end}" > "${_rwmb_stripped}"

    {
        cat "${_rwmb_stripped}"
        if [[ -n "${content}" ]]; then
            [[ -s "${_rwmb_stripped}" ]] && printf '\n'
            printf '%s\n' "${start}"
            printf '%s\n' "${content}"
            printf '%s\n' "${end}"
        fi
    } > "${_rwmb_tmp}"

    if [[ -e "${target_file}" ]]; then
        chown --reference="${target_file}" "${_rwmb_tmp}" 2>/dev/null || true
        chmod --reference="${target_file}" "${_rwmb_tmp}" 2>/dev/null || true
    fi
    mv "${_rwmb_tmp}" "${target_file}"
    rm -f "${_rwmb_stripped}"
}

# ── Config generation ───────────────────────────────────────────────

detect_extended_rum() {
    HAS_EXTENDED_RUM=false
    if [[ -n "${PG_SHAREDIR}" && -f "${PG_SHAREDIR}/extension/documentdb_extended_rum.control" ]]; then
        HAS_EXTENDED_RUM=true
    fi
}

read_shared_preload_libraries_from_file() {
    local config_path="$1"
    local current_value=""
    [[ -f "${config_path}" ]] || return 0

    current_value="$(
        awk -F= '
            /^[[:space:]]*#/ { next }
            $0 ~ /^[[:space:]]*shared_preload_libraries[[:space:]]*=/ {
                v=$0; sub(/^[^=]*=/, "", v)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                print v
            }
        ' "${config_path}" | tail -n 1
    )"
    current_value="$(strip_wrapping_quotes "${current_value}")"
    printf '%s' "${current_value}"
}

merge_shared_preload_libraries() {
    local current_value="$1"
    local item joined=""
    local -a merged=() current_items=()
    local -a required=(
        "pg_cron"
        "pg_documentdb_core"
        "pg_documentdb"
    )
    [[ "${HAS_EXTENDED_RUM}" == "true" ]] && required+=("pg_documentdb_extended_rum")

    local cleaned
    cleaned="$(strip_wrapping_quotes "${current_value}")"
    if [[ -n "${cleaned}" ]]; then
        IFS=',' read -r -a current_items <<< "${cleaned}"
        for item in "${current_items[@]}"; do
            item="$(trim_whitespace "${item}")"
            [[ -z "${item}" ]] && continue
            array_contains "${item}" "${merged[@]+"${merged[@]}"}" || merged+=("${item}")
        done
    fi

    for item in "${required[@]}"; do
        array_contains "${item}" "${merged[@]+"${merged[@]}"}" || merged+=("${item}")
    done

    for item in "${merged[@]}"; do
        joined+="${joined:+, }${item}"
    done
    printf '%s' "${joined}"
}

build_config_block() {
    local merged_preload="$1"
    local block=""

    block="shared_preload_libraries = '${merged_preload}'"
    block+=$'\n'"cron.database_name = 'postgres'"
    block+=$'\n'"documentdb.enableBackgroundWorker = true"
    block+=$'\n'"documentdb.enableBackgroundWorkerJobs = true"
    block+=$'\n'"documentdb.indexBuildsScheduledOnBgWorker = false"

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        block+=$'\n'"documentdb.rum_library_load_option = 'require_documentdb_extended_rum'"
        block+=$'\n'"documentdb.alternate_index_handler_name = 'extended_rum'"
    fi

    printf '%s' "${block}"
}

# ── Safety helpers ──────────────────────────────────────────────────

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local timestamp
    timestamp="$(date +%Y%m%d%H%M%S)"
    local backup
    backup="$(mktemp "$(dirname "${file}")/$(basename "${file}").documentdb-backup.${timestamp}.XXXXXX")" \
        || die "Cannot create backup file for ${file}."
    cp -a "${file}" "${backup}"
    log_verbose "Backed up ${file} -> ${backup}"
}

check_foreign_markers() {
    local file="$1" our_start="$2"
    [[ -f "${file}" ]] || return 0
    local foreign_count our_count
    # Total managed-block start markers (any tool).
    local total_count
    total_count="$(grep -cE '^\s*#\s*>>>\s+\S+\s+managed\s+' "${file}" 2>/dev/null || true)"
    # Markers owned by sibling tools in the documentdb-* family
    # (documentdb-setup, documentdb-tune, documentdb-register-gateway):
    # we treat these as friendly because all three are shipped by the
    # same package set and never collide on the same logical block.
    # Without this, documentdb-tune --restore leaves the
    # documentdb-setup-managed block intact, then the next
    # documentdb-tune --yes wrongly flags it as "another tool".
    local family_count
    family_count="$(grep -cE '^\s*#\s*>>>\s+documentdb-(setup|tune|register-gateway)\s+managed\s+' "${file}" 2>/dev/null || true)"
    foreign_count=$(( total_count - family_count ))
    our_count="$(grep -cFx "${our_start}" "${file}" 2>/dev/null || true)"
    if (( foreign_count > our_count )); then
        die "${file} contains managed-block markers from another tool. Refusing to modify."
    fi
}

# ── Distro / path resolution ───────────────────────────────────────

detect_distro() {
    IS_DEBIAN=false
    if [[ -f /etc/debian_version ]] || command -v dpkg >/dev/null 2>&1; then
        IS_DEBIAN=true
    fi
}

resolve_pg_sharedir() {
    PG_SHAREDIR=""
    local candidate_paths=(
        "/usr/lib/postgresql/${PG_VERSION}/bin/pg_config"
        "/usr/pgsql-${PG_VERSION}/bin/pg_config"
    )
    for pg_config in "${candidate_paths[@]}"; do
        if [[ -x "${pg_config}" ]]; then
            PG_SHAREDIR="$("${pg_config}" --sharedir 2>/dev/null || true)"
            return 0
        fi
    done
}

resolve_config_target() {
    if [[ -n "${PGDATA}" ]]; then
        CONFIG_TARGET="${PGDATA}/postgresql.conf"
        return 0
    fi

    if [[ "${IS_DEBIAN}" == "true" ]]; then
        # Debian/Ubuntu: write a separate per-instance file that the
        # createcluster.d hook's include_if_exists picks up. The hook
        # references documentdb.conf (PostgreSQL only loads .conf files
        # via include_dir; the .sample example in
        # /usr/share/doc/documentdb-postgresql-tools/examples/ follows the
        # PostgreSQL .sample convention). Per packaging-design.md §4.2.
        local cluster_dir="/etc/postgresql-common/documentdb/${PG_VERSION}/${CLUSTER_NAME}"
        CONFIG_TARGET="${cluster_dir}/documentdb.conf"
        # Track the live instance's postgresql.conf so that, on existing
        # clusters that pre-date the hook, we can add the include line
        # ourselves; otherwise the fragment would be silently unused.
        DEBIAN_LIVE_PG_CONF="/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}/postgresql.conf"
        return 0
    fi

    # RHEL: edit the cluster's postgresql.conf directly.
    local rhel_data="/var/lib/pgsql/${PG_VERSION}/data"
    if [[ -d "${rhel_data}" ]]; then
        CONFIG_TARGET="${rhel_data}/postgresql.conf"
        return 0
    fi

    die "Cannot resolve config file. Use --pgdata to specify the data directory."
}

# Debian-only: on existing clusters created before documentdb-postgresql-tools
# was installed, the createcluster.d hook never ran, so the live cluster's
# postgresql.conf has no include_if_exists line pointing at our fragment.
# documentdb-tune --apply must add that line so the fragment is actually
# loaded; otherwise the operator silently writes /etc/postgresql-common/...
# but PG never reads it. The line is wrapped in our managed-block markers
# so --restore strips it cleanly.
ensure_debian_include_line() {
    [[ "${IS_DEBIAN}" == "true" ]] || return 0
    [[ -n "${DEBIAN_LIVE_PG_CONF}" && -f "${DEBIAN_LIVE_PG_CONF}" ]] || return 0

    local include_marker_start="# >>> documentdb-tune managed include >>>"
    local include_marker_end="# <<< documentdb-tune managed include <<<"
    local include_line="include_if_exists = '/etc/postgresql-common/documentdb/${PG_VERSION}/${CLUSTER_NAME}/documentdb.conf'"

    # Skip if the hook (or a prior tune run) already added the include.
    if grep -Fq "${include_line}" "${DEBIAN_LIVE_PG_CONF}" 2>/dev/null; then
        log_verbose "Include line already present in ${DEBIAN_LIVE_PG_CONF}; nothing to do."
        return 0
    fi

    # Reviewer-flagged (Opus 4.8 should-fix G): match the §7 contract that
    # every config-edit path refuses to mutate files containing markers from
    # a tool we don't recognize. The fragment-write path at line ~405 already
    # calls check_foreign_markers; the live-conf append path was missing it.
    check_foreign_markers "${DEBIAN_LIVE_PG_CONF}" "${include_marker_start}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] would append managed include block to ${DEBIAN_LIVE_PG_CONF}:"
        printf '  %s\n  %s\n  %s\n' "${include_marker_start}" "${include_line}" "${include_marker_end}"
        return 0
    fi

    log "Appending managed include block to ${DEBIAN_LIVE_PG_CONF}."
    backup_file "${DEBIAN_LIVE_PG_CONF}"
    {
        printf '\n%s\n%s\n%s\n' \
            "${include_marker_start}" \
            "${include_line}" \
            "${include_marker_end}"
    } >> "${DEBIAN_LIVE_PG_CONF}"
}

# ── Actions ─────────────────────────────────────────────────────────

do_print() {
    local current_preload="" merged_preload="" block=""

    if [[ -n "${CONFIG_TARGET}" && -f "${CONFIG_TARGET}" ]]; then
        current_preload="$(read_shared_preload_libraries_from_file "${CONFIG_TARGET}")"
    fi

    merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
    block="$(build_config_block "${merged_preload}")"

    printf '%s\n' "${MANAGED_BLOCK_START}"
    printf '%s\n' "${block}"
    printf '%s\n' "${MANAGED_BLOCK_END}"
}

do_apply() {
    local current_preload="" merged_preload="" block=""
    local existing_block=""

    if [[ -f "${CONFIG_TARGET}" ]]; then
        current_preload="$(read_shared_preload_libraries_from_file "${CONFIG_TARGET}")"
    fi

    merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
    block="$(build_config_block "${merged_preload}")"

    if [[ -f "${CONFIG_TARGET}" ]]; then
        existing_block="$(extract_managed_block_content "${CONFIG_TARGET}" "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}")"
        if [[ "${existing_block}" == "${block}" ]]; then
            log "Config is already up to date: ${CONFIG_TARGET}"
            return 0
        fi
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Would write managed block to ${CONFIG_TARGET}:"
        printf '%s\n' "${MANAGED_BLOCK_START}"
        printf '%s\n' "${block}"
        printf '%s\n' "${MANAGED_BLOCK_END}"
        return 0
    fi

    if [[ "${YES}" != "true" ]]; then
        echo "${PROG}: about to write DocumentDB config to ${CONFIG_TARGET}"
        printf '%s\n' "${MANAGED_BLOCK_START}"
        printf '%s\n' "${block}"
        printf '%s\n' "${MANAGED_BLOCK_END}"
        read -r -p "Proceed? [y/N] " answer
        case "${answer}" in
            y|Y|yes|YES) ;;
            *) log "Aborted."; exit 0 ;;
        esac
    fi

    # Ensure parent directory exists (Debian per-cluster path)
    local parent_dir
    parent_dir="$(dirname "${CONFIG_TARGET}")"
    if [[ ! -d "${parent_dir}" ]]; then
        install -d -m 0755 "${parent_dir}"
    fi

    # Safety: check for foreign markers and back up before writing
    check_foreign_markers "${CONFIG_TARGET}" "${MANAGED_BLOCK_START}"
    backup_file "${CONFIG_TARGET}"

    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        # Debian: write the entire per-instance file (not a managed block
        # inside an existing postgresql.conf); the createcluster.d hook
        # brings it in via include_if_exists. For instances that pre-date
        # the hook, we also add the include line to the live cluster's
        # postgresql.conf so the fragment is actually picked up rather
        # than silently ignored.
        printf '%s\n' "${block}" > "${CONFIG_TARGET}"
        chmod 0644 "${CONFIG_TARGET}"
        ensure_debian_include_line
    else
        # RHEL or --pgdata: managed block inside the existing config file.
        if [[ ! -f "${CONFIG_TARGET}" ]]; then
            touch "${CONFIG_TARGET}"
        fi
        rewrite_with_managed_block "${CONFIG_TARGET}" \
            "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}" "${block}"
    fi

    log "Config written to ${CONFIG_TARGET}"

    if [[ -n "${PG_VERSION}" ]]; then
        if has_working_systemd; then
            if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
                log "Restart the cluster to apply: sudo systemctl restart postgresql@${PG_VERSION}-${CLUSTER_NAME}"
            else
                log "Restart PostgreSQL to apply the new settings (e.g. sudo systemctl restart postgresql-${PG_VERSION})."
            fi
        else
            # No systemd → fall back to pg_ctlcluster / pg_ctl
            if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
                log "Restart the cluster to apply (no systemd detected): sudo pg_ctlcluster ${PG_VERSION} ${CLUSTER_NAME} restart"
            elif [[ -n "${PGDATA}" ]]; then
                # PG bin layout differs between Debian (/usr/lib/postgresql/N/bin)
                # and RHEL family (/usr/pgsql-N/bin). Probe in that order and
                # fall back to a generic hint if neither is on disk.
                local pg_ctl_path=""
                for candidate in \
                    "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl" \
                    "/usr/pgsql-${PG_VERSION}/bin/pg_ctl"; do
                    if [[ -x "${candidate}" ]]; then
                        pg_ctl_path="${candidate}"
                        break
                    fi
                done
                if [[ -n "${pg_ctl_path}" ]]; then
                    log "Restart PostgreSQL to apply (no systemd detected): sudo -u postgres ${pg_ctl_path} -D ${PGDATA} restart"
                else
                    log "Restart PostgreSQL to apply (no systemd detected): sudo -u postgres <pg_ctl> -D ${PGDATA} restart"
                fi
            else
                log "Restart PostgreSQL to apply the new settings (your distro's preferred command)."
            fi
        fi
    fi
}

do_restore() {
    # Strip the managed include line from the live Debian postgresql.conf
    # first (no-op if absent / not on Debian / not on an existing cluster).
    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" && -n "${DEBIAN_LIVE_PG_CONF}" && -f "${DEBIAN_LIVE_PG_CONF}" ]]; then
        local include_marker_start="# >>> documentdb-tune managed include >>>"
        local include_marker_end="# <<< documentdb-tune managed include <<<"
        if grep -Fqx "${include_marker_start}" "${DEBIAN_LIVE_PG_CONF}" 2>/dev/null; then
            if [[ "${DRY_RUN}" == "true" ]]; then
                log "[dry-run] would strip managed include block from ${DEBIAN_LIVE_PG_CONF}."
            else
                rewrite_with_managed_block "${DEBIAN_LIVE_PG_CONF}" \
                    "${include_marker_start}" "${include_marker_end}" ""
                log "Managed include block stripped from ${DEBIAN_LIVE_PG_CONF}"
            fi
        fi
    fi

    if [[ ! -f "${CONFIG_TARGET}" ]]; then
        log "Nothing to restore (${CONFIG_TARGET} does not exist)."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Would remove managed block from ${CONFIG_TARGET}."
        return 0
    fi

    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        # Debian per-instance file: remove the file entirely.
        rm -f "${CONFIG_TARGET}"
        local parent_dir
        parent_dir="$(dirname "${CONFIG_TARGET}")"
        rmdir --ignore-fail-on-non-empty "${parent_dir}" 2>/dev/null || true
        log "Removed ${CONFIG_TARGET}"
    else
        rewrite_with_managed_block "${CONFIG_TARGET}" \
            "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}" ""
        log "Managed block removed from ${CONFIG_TARGET}"
    fi
}

# ── Argument parsing ────────────────────────────────────────────────

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pg-version)
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                PG_VERSION="$2"; shift 2 ;;
            --cluster)
                [[ $# -ge 2 ]] || die "--cluster requires a value."
                CLUSTER_NAME="$2"; shift 2 ;;
            --pgdata)
                [[ $# -ge 2 ]] || die "--pgdata requires a value."
                PGDATA="$2"; shift 2 ;;
            --yes) YES=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --restore) ACTION="restore"; shift ;;
            --print) ACTION="print"; shift ;;
            --verbose) VERBOSE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    # Validate
    if [[ -z "${PGDATA}" ]]; then
        if [[ -z "${PG_VERSION}" ]]; then
            if [[ "${ACTION}" == "print" || "${ACTION}" == "apply" || "${ACTION}" == "restore" ]]; then
                die "--pg-version is required (or use --pgdata). Run 'documentdb-tune --help' for usage."
            fi
        fi
        [[ -n "${PG_VERSION}" ]] || { usage; exit 1; }
        [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg-version must be a positive integer."
        [[ -z "${CLUSTER_NAME}" ]] && CLUSTER_NAME="main"
    fi

    # Warn if --cluster is given on RHEL where it has no effect
    if [[ -n "${CLUSTER_NAME}" && "${CLUSTER_NAME}" != "main" ]]; then
        detect_distro
        if [[ "${IS_DEBIAN}" != "true" ]]; then
            log "WARNING: --cluster '${CLUSTER_NAME}' is ignored on RHEL/Fedora (only Debian/Ubuntu uses named clusters). Using default PGDATA path."
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────

main() {
    parse_arguments "$@"
    detect_distro

    if [[ -n "${PG_VERSION}" ]]; then
        resolve_pg_sharedir
        detect_extended_rum
    fi

    resolve_config_target

    case "${ACTION}" in
        print)   do_print ;;
        apply)
            # Require root when writing to system paths, but allow non-root
            # for --pgdata (operator-controlled paths, dev/test).
            if [[ "$(id -u)" -ne 0 && -z "${PGDATA}" ]]; then
                die "Must be run as root (use sudo) to apply changes to system clusters."
            fi
            do_apply ;;
        restore)
            if [[ "$(id -u)" -ne 0 && -z "${PGDATA}" ]]; then
                die "Must be run as root (use sudo) to restore changes to system clusters."
            fi
            do_restore ;;
    esac
}

main "$@"
