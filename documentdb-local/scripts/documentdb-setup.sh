#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-setup — the stand-alone package's setup wizard. Single
# orchestration command after `apt install documentdb`. Handles
# greenfield (initdb a private PostgreSQL instance) and brownfield
# (adopt an existing PostgreSQL instance via --target-postgres-instance)
# with backup-and-rollback safety around every invasive change.
# Delegates postgresql.conf to documentdb-tune and hba/ident/role/
# connection-URL-file to documentdb-register-gateway per
# packaging-design.md §4.4.

set -euo pipefail

# Restrict default permissions so temp files are never world-readable.
umask 077

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
    SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${SCRIPT_DIR}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly POSTGRES_CONF_BLOCK_START="# >>> documentdb-setup managed configuration >>>"
readonly POSTGRES_CONF_BLOCK_END="# <<< documentdb-setup managed configuration <<<"
readonly POSTGRES_LISTEN_BLOCK_START="# >>> documentdb-setup managed listen >>>"
readonly POSTGRES_LISTEN_BLOCK_END="# <<< documentdb-setup managed listen <<<"
readonly PG_HBA_BLOCK_START="# >>> documentdb-setup managed hba >>>"
readonly PG_HBA_BLOCK_END="# <<< documentdb-setup managed hba <<<"
readonly PG_IDENT_BLOCK_START="# >>> documentdb-setup managed pg_ident >>>"
readonly PG_IDENT_BLOCK_END="# <<< documentdb-setup managed pg_ident <<<"
readonly POSTGRES_SERVICE_ENV_FILE="/etc/documentdb/documentdb-postgresql.env"
# Multi-reviewer flagged (should-fix F): the prior sentinel was 9712 (the
# legacy dev port from copilot-instructions.md). That was confusing and
# brittle because contributors mistook it for an intentional default. Use 0
# (an invalid TCP port — IANA reserved) so the value is obviously a sentinel
# that MUST be replaced by the per-major default (9700 + PG_VERSION) once
# PostgreSQL detection completes. The range validation later in
# parse_arguments catches any case where this leaks through. Equality checks
# `[[ PG_PORT == DEFAULT_PG_PORT ]]` continue to work as the "still at
# sentinel default" discriminator without further refactoring.
readonly DEFAULT_PG_PORT="0"
readonly DEFAULT_GATEWAY_PORT="10260"
readonly DEFAULT_DATA_DIR="/var/lib/documentdb-local/data"
readonly DEFAULT_PG_SOCKET_DIR="/run/documentdb-local/postgresql"
readonly PUBLIC_ALIAS_PG_MAJOR="18"
PG_SOCKET_DIR="${DEFAULT_PG_SOCKET_DIR}"

VERBOSE=false
USERNAME=""
PASSWORD=""
PASSWORD_FILE=""
PASSWORD_FROM_STDIN=false
TLS_CERT_FILE=""
TLS_KEY_FILE=""
TLS_AUTO_GENERATE=""
TEMP_FILES=()
PG_VERSION="${PG_VERSION:-}"
PG_VERSION_EXPLICIT=false
PG_PORT=""
PG_PORT_EXPLICIT=false
GATEWAY_PORT="${DEFAULT_GATEWAY_PORT}"
DATA_DIR=""
DATA_DIR_EXPLICIT=false
NO_ENABLE=false
LOAD_SAMPLE_DATA=false
YES=false
DRY_RUN=false
RESTORE=false
PRINT_CONFIG=false
STATUS_ONLY=false
USE_PRIVATE_CLUSTER=false
TARGET_CLUSTER=""
PG_OWNER=""

GATEWAY_BINARY=""
CONFIG_FILE=""
SAMPLE_DATA_DIR=""
INIT_DATA_SCRIPT=""
HAS_WORKING_SYSTEMD=false
CAN_LOAD_SAMPLE_DATA=false
HAS_EXTENDED_RUM=false
EXTENSION_CONTROL_FILE=""
EXTENDED_RUM_CONTROL_FILE=""
PG_BIN_DIR=""
PG_CONFIG=""
INITDB=""
PG_CTL=""
PSQL=""
PG_ISREADY=""
LIVE_DATA_DIR=""
LIVE_CONFIG_FILE=""
LIVE_HBA_FILE=""
LIVE_IDENT_FILE=""
LIVE_PRELOAD_LIBRARIES=""
PG_CONFIG_CHANGED=false
PG_RELOAD_CHANGED=false
GATEWAY_WAS_ACTIVE=false

error() {
    local line_number="$1"
    local exit_code="${2:-1}"
    cleanup_temp_files
    echo "Error on or near line ${line_number}; exiting with status ${exit_code}" >&2
    exit "${exit_code}"
}
trap 'error ${LINENO} $?' ERR
trap cleanup_temp_files EXIT

usage() {
    cat <<'EOF'
Usage: documentdb-setup [OPTIONS]

Appliance setup wizard for DocumentDB Local.

Required:
  --admin-user <USER>    Admin username to create (also: --username).
                         When omitted on an interactive terminal the
                         wizard prompts (default: "admin").

Authentication (one of the following; interactive prompt is the default):
  --admin-password-file <FILE>  Read the admin password from a file
                         (also: --password-file; for non-interactive/CI use).
                         File should be mode 0600.
  --admin-password-stdin Read the admin password from stdin (single line).
                         Best practice for piping a secret without
                         touching disk:
                           printf '%s' "$PW" | sudo documentdb-setup ... \
                             --admin-password-stdin
  DOCUMENTDB_PASSWORD    Environment variable alternative (DEPRECATED —
                         leaks via /proc/<pid>/environ; prefer
                         --admin-password-file or --admin-password-stdin).
  (interactive prompt)   Default when running on a TTY without the above.

TLS for the gateway listener (all three are pass-through to the per-major
gateway env file; design §4.3 is the source of truth on precedence):
  --tls-cert <FILE>      PEM certificate file; must be paired with --tls-key.
  --tls-key  <FILE>      PEM private key file; must be paired with --tls-cert.
  --tls-auto-generate <true|false>
                         Force or disable auto-generated self-signed
                         certificate. Defaults to true when neither
                         --tls-cert nor --tls-key is set (the design's
                         standalone default).

Options:
  --pg-version <VER>      PostgreSQL version (auto-detected if not specified)
  --pg-port <PORT>        PostgreSQL port (default: 9700 + PG_VERSION)
  --listen-port <PORT>    Gateway listen port (default: 10260; also: --gateway-port)
  --data-dir <DIR>        PostgreSQL data directory
                          (default: /var/lib/documentdb-local/<VER>/data)
  --use-new-postgres-instance
                          Force greenfield: initdb a new private instance
                          (also: --use-private-cluster, deprecated)
  --target-postgres-instance <V/C>
                          Brownfield: adopt an existing PostgreSQL instance
                          named by its distro identifier (e.g., 18/main)
                          (also: --target-cluster, deprecated)
  --yes                   Non-interactive (no confirmation prompts)
  --dry-run               Preview changes without writing
  --restore               Remove all managed configuration blocks and revert
  --print-config          Print the resolved per-major config (paths, ports,
                          systemd units) the wizard would use, and exit. No
                          side effects.
  --status                Report the current per-major installation state
                          (PG service active, gateway service active, ports
                          listening, admin user exists), and exit.
  --no-enable             Do not start the gateway after setup
  --load-sample-data      Load built-in sample data after setup (requires mongosh)
  --skip-init-data        Skip the post-setup sample-data ingest step (the default
                          when neither --load-sample-data nor --skip-init-data
                          is passed)
  --verbose               Show detailed output
  -h, --help              Show this help message
EOF
}

log_info() {
    echo "[documentdb-setup] $*"
}

log_warn() {
    echo "[documentdb-setup] WARNING: $*" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "[documentdb-setup] $*"
    fi
}

log_success() {
    echo "[documentdb-setup] SUCCESS: $*"
}

die() {
    echo "[documentdb-setup] ERROR: $*" >&2
    exit 1
}

cleanup_temp_files() {
    if (( ${#TEMP_FILES[@]} == 0 )); then
        return 0
    fi

    rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
    TEMP_FILES=()
}

register_temp_file() {
    TEMP_FILES+=("$1")
}

create_temp_file() {
    local target_var="$1"
    local template="${2:-}"
    local created_file=""
    local -n target_ref="${target_var}"

    if [[ -n "${template}" ]]; then
        created_file="$(mktemp "${template}")"
    else
        created_file="$(mktemp)"
    fi

    register_temp_file "${created_file}"
    target_ref="${created_file}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

normalize_whitespace() {
    local value="$1"
    value="$(printf '%s' "${value}" | tr '\t' ' ')"
    value="$(printf '%s' "${value}" | sed -E 's/[[:space:]]+/ /g')"
    value="$(trim_whitespace "${value}")"
    printf '%s' "${value}"
}

strip_wrapping_quotes() {
    local value="$1"
    if [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "${value}"
}

array_contains() {
    local needle="$1"
    shift || true
    local item=""
    # Use ${@+"$@"} instead of "$@" so an empty argument list does not
    # trigger an "unbound variable" error under set -u on bash 4.x.
    for item in ${@+"$@"}; do
        if [[ "${item}" == "${needle}" ]]; then
            return 0
        fi
    done
    return 1
}

preserve_file_metadata() {
    local source_file="$1"
    local target_file="$2"
    # Note: --reference is GNU coreutils-specific (Linux).  This is acceptable
    # because the script targets DEB/RPM Linux packaging only.
    if [[ -e "${source_file}" ]]; then
        chown --reference="${source_file}" "${target_file}"
        chmod --reference="${source_file}" "${target_file}"
    fi
}

strip_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"

    if [[ ! -f "${target_file}" ]]; then
        return 0
    fi

    awk -v start="${block_start}" -v end="${block_end}" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "${target_file}"
}

extract_managed_block_content() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"

    if [[ ! -f "${target_file}" ]]; then
        return 0
    fi

    awk -v start="${block_start}" -v end="${block_end}" '
        $0 == start { in_block = 1; next }
        $0 == end { in_block = 0; next }
        in_block { print }
    ' "${target_file}"
}

rewrite_with_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local block_content="$4"
    local stripped_file=""
    local temp_file=""

    create_temp_file stripped_file
    create_temp_file temp_file
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"

    {
        cat "${stripped_file}"
        if [[ -n "${block_content}" ]]; then
            if [[ -s "${stripped_file}" ]]; then
                printf '\n'
            fi
            printf '%s\n' "${block_start}"
            printf '%s\n' "${block_content}"
            printf '%s\n' "${block_end}"
        fi
    } > "${temp_file}"

    preserve_file_metadata "${target_file}" "${temp_file}"
    mv "${temp_file}" "${target_file}"
    rm -f "${stripped_file}"
}

# Like rewrite_with_managed_block, but inserts the managed block before the
# first non-comment, non-blank line.  This is important for pg_hba.conf where
# rules are evaluated top-to-bottom and the first match wins.
prepend_with_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local block_content="$4"
    local stripped_file=""
    local temp_file=""
    local block_file=""

    create_temp_file stripped_file
    create_temp_file temp_file
    create_temp_file block_file
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"

    if [[ -z "${block_content}" ]]; then
        cat "${stripped_file}" > "${temp_file}"
    else
        {
            printf '%s\n' "${block_start}"
            printf '%s\n' "${block_content}"
            printf '%s\n' "${block_end}"
        } > "${block_file}"

        awk -v blockfile="${block_file}" '
            BEGIN { inserted = 0 }
            !inserted && /^[^#]/ && !/^[[:space:]]*$/ {
                while ((getline line < blockfile) > 0) print line
                close(blockfile)
                print ""
                inserted = 1
            }
            { print }
            END {
                if (!inserted) {
                    while ((getline line < blockfile) > 0) print line
                    close(blockfile)
                }
            }
        ' "${stripped_file}" > "${temp_file}"
    fi

    preserve_file_metadata "${target_file}" "${temp_file}"
    mv "${temp_file}" "${target_file}"
    rm -f "${stripped_file}" "${block_file}"
}

has_line_outside_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local line_to_find="$4"
    local stripped_file=""

    create_temp_file stripped_file
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"
    if grep -Fqx "${line_to_find}" "${stripped_file}"; then
        rm -f "${stripped_file}"
        return 0
    fi
    rm -f "${stripped_file}"
    return 1
}

has_normalized_line_outside_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local line_to_find="$4"
    local stripped_file=""
    local normalized_target=""
    local matched=false

    create_temp_file stripped_file
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"
    normalized_target="$(normalize_whitespace "${line_to_find}")"

    while IFS= read -r candidate_line; do
        if [[ "$(normalize_whitespace "${candidate_line}")" == "${normalized_target}" ]]; then
            matched=true
            break
        fi
    done < "${stripped_file}"

    rm -f "${stripped_file}"
    if [[ "${matched}" == "true" ]]; then
        return 0
    fi
    return 1
}

update_json_file() {
    local json_file="$1"
    local temp_file=""
    create_temp_file temp_file

    jq \
        --argjson pgport "${PG_PORT}" \
        --argjson gwport "${GATEWAY_PORT}" \
        --arg pguser "documentdb-local" \
        --arg pghost "${PG_SOCKET_DIR}" \
        '.PostgresPort = $pgport
         | .GatewayListenPort = $gwport
         | .PostgresSystemUser = $pguser
         | .PostgresDataUser = $pguser
         | .PostgresHostName = $pghost' \
        "${json_file}" > "${temp_file}"

    preserve_file_metadata "${json_file}" "${temp_file}"
    mv "${temp_file}" "${json_file}"
}

resolve_password() {
    if [[ -n "${PASSWORD_FILE}" ]]; then
        if [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
            die "--admin-password-file and --admin-password-stdin are mutually exclusive."
        fi
        [[ -r "${PASSWORD_FILE}" ]] || die "--admin-password-file ${PASSWORD_FILE} is not readable."
        # Warn if password file is world-readable
        local file_perms
        file_perms="$(stat -c '%a' "${PASSWORD_FILE}" 2>/dev/null || true)"
        if [[ -n "${file_perms}" && "${file_perms}" != "600" && "${file_perms}" != "400" ]]; then
            log_warn "Password file ${PASSWORD_FILE} has permissions ${file_perms} (recommended: 0600). Other users on this system may be able to read it."
        fi
        PASSWORD="$(< "${PASSWORD_FILE}")"
    elif [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
        # Read a single line (strip trailing newline) from stdin. Best
        # practice for "pipe a secret without touching disk" — see
        # `docker login --password-stdin`, `gh auth login --with-token`.
        # If stdin is a TTY we refuse rather than block waiting on the
        # operator to type the password without an echo prompt: that
        # would be confusing UX. Operator should use the interactive
        # prompt path (default when no auth flag is supplied) instead.
        if [[ -t 0 ]]; then
            die "--admin-password-stdin requires the password on stdin (e.g. 'printf %s \"\$PW\" | sudo documentdb-setup ... --admin-password-stdin'). Stdin is a TTY; omit the flag to use the interactive prompt."
        fi
        # `IFS= read -r` reads one line preserving leading/trailing
        # whitespace except the trailing newline. Allow non-zero exit
        # from `read` when there's no trailing newline on the pipe.
        IFS= read -r PASSWORD || true
    elif [[ -n "${DOCUMENTDB_PASSWORD:-}" ]]; then
        # Deprecation warning for the env-var path is printed earlier
        # in main() so it surfaces even in --dry-run / --print-config /
        # --status. Here we just consume the value.
        PASSWORD="${DOCUMENTDB_PASSWORD}"
    elif [[ -t 0 ]]; then
        # Interactive TTY: prompt for password
        local pw_confirm=""
        read -r -s -p "[documentdb-setup] Enter admin password: " PASSWORD
        echo ""
        read -r -s -p "[documentdb-setup] Confirm admin password: " pw_confirm
        echo ""
        if [[ "${PASSWORD}" != "${pw_confirm}" ]]; then
            die "Passwords do not match."
        fi
    fi

    [[ -n "${PASSWORD}" ]] || die "A password is required. Use --admin-password-file, --admin-password-stdin, set DOCUMENTDB_PASSWORD (deprecated), or run interactively to be prompted."
}

create_documentdb_user() {
    local owner="$1"
    local port="$2"
    local username="$3"
    local password="$4"
    local user_bson=""
    local user_bson_file=""

    local password_file=""

    create_temp_file password_file
    printf '%s' "${password}" > "${password_file}"
    chmod 600 "${password_file}"

    user_bson="$(
        jq -cn \
            --arg user "${username}" \
            --rawfile pwd "${password_file}" \
            '{createUser: $user, pwd: $pwd, roles: [{role: "readWriteAnyDatabase", db: "admin"}, {role: "clusterAdmin", db: "admin"}]}'
    )"
    rm -f "${password_file}"

    create_temp_file user_bson_file
    printf '%s' "${user_bson}" > "${user_bson_file}"
    chmod 600 "${user_bson_file}"
    chown "${owner}" "${user_bson_file}"

    # Idempotency guard (S38 fix): a previous successful run of this
    # wizard already created the admin user; the SQL would otherwise
    # fail on the duplicate. Capture stderr, treat "already exists"
    # as success (with a clear log line telling the operator how to
    # rotate the password instead), re-raise any other error.
    #
    # This matters for:
    #   - operators re-running `documentdb-setup` after a transient
    #     failure in a later step (idempotent re-try)
    #   - configuration-management tools (Ansible/Puppet/Chef) that
    #     converge the wizard on every run
    #   - the recovery path where setup partially succeeded and the
    #     operator wants to re-run to finish
    local create_output=""
    local create_rc=0
    create_output="$(run_as_user "${owner}" env "USER_BSON_FILE=${user_bson_file}" \
            "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL' 2>&1
\set user_bson `cat "$USER_BSON_FILE"`
SELECT documentdb_api.create_user(:'user_bson'::documentdb_core.bson);
SQL
    )" || create_rc=$?

    if (( create_rc == 0 )); then
        [[ "${VERBOSE}" == "true" && -n "${create_output}" ]] && printf '%s\n' "${create_output}"
        return 0
    fi

    # Match common phrasings the DocumentDB user-management API uses
    # for "this user is already here": both English-style and any future
    # error-code-bearing variants land in stderr text we can scan.
    if [[ "${create_output}" == *"already exists"* ]] \
            || [[ "${create_output}" == *"User exists"* ]]; then
        log_info "Admin user '${username}' already exists; skipping bootstrap (idempotent re-run)."
        log_info "Rotate the password with: sudo documentdb-gateway-admin reset-password --username ${username} --password-stdin"
        return 0
    fi

    # Some other failure — restore the captured output for diagnostics
    # and propagate the failure so the wizard's overall trap fires.
    printf '%s\n' "${create_output}" >&2
    return "${create_rc}"
}

run_as_user() {
    local target_user="$1"
    shift

    if command_exists runuser; then
        runuser -u "${target_user}" -- "$@"
    elif command_exists sudo; then
        sudo -u "${target_user}" "$@"
    else
        local quoted_command=""
        quoted_command="$(printf '%q ' "$@")"
        su -s /bin/bash "${target_user}" -c "${quoted_command}"
    fi
}

run_as_user_shell() {
    local target_user="$1"
    local shell_command="$2"

    if command_exists runuser; then
        runuser -u "${target_user}" -- bash -lc "${shell_command}"
    elif command_exists sudo; then
        sudo -u "${target_user}" bash -lc "${shell_command}"
    else
        su -s /bin/bash "${target_user}" -c "${shell_command}"
    fi
}

find_listener_pid() {
    local port="$1"
    local pid=""

    if command_exists lsof; then
        pid="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "${pid}" ]] && command_exists ss; then
        pid="$(ss -ltnp "( sport = :${port} )" 2>/dev/null \
            | grep -oE 'pid=[0-9]+' \
            | head -n 1 \
            | cut -d= -f2 || true)"
    fi

    # Advanced-user E2E flagged: lsof/ss may be missing in containers
    # or minimal hosts. /proc/net/tcp + /proc/net/tcp6 gives us a
    # listener-only check without external tools. (We can't get the PID
    # without root + iterating /proc/<pid>/net/tcp, so we return a
    # placeholder "1" — callers only check empty vs non-empty.)
    if [[ -z "${pid}" && -r /proc/net/tcp ]]; then
        local port_hex
        port_hex="$(printf '%04X' "${port}" 2>/dev/null)"
        if awk -v p="${port_hex}" 'NR>1 && $4=="0A" && toupper($2) ~ p"$" {found=1} END{exit !found}' /proc/net/tcp 2>/dev/null \
                || awk -v p="${port_hex}" 'NR>1 && $4=="0A" && toupper($2) ~ p"$" {found=1} END{exit !found}' /proc/net/tcp6 2>/dev/null; then
            pid="1"
        fi
    fi

    printf '%s' "${pid}"
}

wait_for_listener_to_clear() {
    local port="$1"
    local timeout_seconds="${2:-30}"
    local attempt=0
    local max_attempts=$(( timeout_seconds * 10 ))

    while (( attempt < max_attempts )); do
        if [[ -z "$(find_listener_pid "${port}")" ]]; then
            return 0
        fi
        sleep 0.1
        attempt=$(( attempt + 1 ))
    done

    return 1
}

listener_looks_like_postgres() {
    local pid="$1"
    local command_name=""
    local command_line=""

    command_name="$(ps -o comm= -p "${pid}" 2>/dev/null | awk '{print $1}' || true)"
    command_line="$(ps -o args= -p "${pid}" 2>/dev/null || true)"

    if [[ "${command_name}" == "postgres" || "${command_name}" == "postmaster" ]]; then
        return 0
    fi

    if [[ "${command_line}" == *postgres* ]]; then
        return 0
    fi

    # Real-user E2E (Gap #14 sibling): find_listener_pid returns the
    # literal "1" placeholder when neither lsof nor ss is installed and
    # /proc/net/tcp only confirms a listener exists but can't enumerate
    # owners. On a systemd host, fall back to checking whether our PG
    # services are active — if so, the listener is in fact PG. Without
    # this, the wizard's pre-flight on the PG port wrongly reports
    # "non-PostgreSQL process" when ss/lsof aren't available (common in
    # container images) and a previous wizard run is recovering from
    # Ctrl-C-mid-setup.
    if [[ "${pid}" == "1" ]] && [[ "${HAS_WORKING_SYSTEMD:-}" == "true" ]]; then
        if systemctl list-units --state=active --no-legend --plain 2>/dev/null \
                | awk '{print $1}' \
                | grep -Eq '^documentdb-postgresql@[0-9]+\.service$'; then
            return 0
        fi
        # Also accept a system PG (brownfield adoption / Workflow A)
        if systemctl list-units --state=active --no-legend --plain 2>/dev/null \
                | awk '{print $1}' \
                | grep -Eq '^postgresql(@[0-9]+-[^.]+)?\.service$|^postgresql-[0-9]+\.service$'; then
            return 0
        fi
    fi

    return 1
}

listener_looks_like_gateway() {
    local pid="$1"
    local exe_path=""
    local command_line=""

    # Prefer /proc/pid/exe which is not truncated
    if [[ -L "/proc/${pid}/exe" ]]; then
        exe_path="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
        # Reviewer-flagged (external review iter 18): the dev build of
        # the gateway from `cargo build` produces a binary named
        # `documentdb_gateway` (underscore — Cargo's default naming),
        # while the packaged DEB/RPM install it as
        # `/usr/bin/documentdb-gateway` (hyphen — Debian package
        # convention). Accept both so re-running the wizard on a host
        # with the packaged gateway already bound to GATEWAY_PORT
        # correctly identifies the listener and falls into the
        # restart-gateway branch instead of a false "non-gateway
        # process" port-conflict error.
        local exe_base
        exe_base="$(basename "${exe_path}" 2>/dev/null)"
        # Real-user E2E (Gap #14): the wrapper-and-daemon split means
        # /proc/PID/exe for the listener resolves to
        # /usr/lib/documentdb-gateway/documentdb-gateway-daemon, not
        # /usr/bin/documentdb-gateway. Accept the daemon basename too.
        if [[ "${exe_base}" == "documentdb_gateway" \
                || "${exe_base}" == "documentdb-gateway" \
                || "${exe_base}" == "documentdb-gateway-daemon" ]]; then
            return 0
        fi
    fi

    # Fallback to full command line (args=) which is also not truncated
    command_line="$(ps -o args= -p "${pid}" 2>/dev/null || true)"
    local cmd_base
    cmd_base="$(basename "${command_line%% *}" 2>/dev/null)"
    if [[ "${cmd_base}" == "documentdb_gateway" \
            || "${cmd_base}" == "documentdb-gateway" \
            || "${cmd_base}" == "documentdb-gateway-daemon" ]]; then
        return 0
    fi

    # Real-user E2E (Gap #14): when find_listener_pid returns PID 1
    # (systemd), inspect systemd's units to see whether either of our
    # gateway services is currently active. If so, the listener is
    # actually owned by us — accept it as gateway-managed even though
    # /proc/1/exe is systemd itself. Without this fallback, re-running
    # the wizard after Ctrl-C-mid-setup wrongly reports "Gateway port
    # is already in use by a non-gateway process (pid 1)".
    if [[ "${pid}" == "1" ]] && [[ "${HAS_WORKING_SYSTEMD:-}" == "true" ]]; then
        if systemctl is-active --quiet 'documentdb-gateway*.service' 2>/dev/null \
                || systemctl is-active --quiet 'documentdb-gateway-local@*.service' 2>/dev/null; then
            return 0
        fi
        # Fallback: scan active units for either wrapper unit name.
        if systemctl list-units --state=active --no-legend --plain 2>/dev/null \
                | awk '{print $1}' \
                | grep -Eq '^documentdb-gateway(-local@[0-9]+)?\.service$'; then
            return 0
        fi
    fi

    return 1
}

resolve_nologin_shell() {
    if [[ -x /usr/sbin/nologin ]]; then
        printf '%s' "/usr/sbin/nologin"
    elif [[ -x /sbin/nologin ]]; then
        printf '%s' "/sbin/nologin"
    else
        printf '%s' "/bin/false"
    fi
}

ensure_documentdb_runtime_user() {
    local nologin_shell=""
    nologin_shell="$(resolve_nologin_shell)"

    # Per packaging-design.md §4.4 the stand-alone package's two OS users are
    # `documentdb-local` (PG data owner + PG superuser, names match for peer
    # auth) and `documentdb-gateway` (gateway service). Both are normally
    # created by sysusers.d at package install time; this function is a
    # back-stop for dev / non-packaged runs.
    if ! getent group documentdb-local >/dev/null 2>&1; then
        groupadd --system documentdb-local
    fi

    if ! id -u documentdb-local >/dev/null 2>&1; then
        useradd \
            --system \
            --no-create-home \
            --home-dir /var/lib/documentdb-local \
            --shell "${nologin_shell}" \
            --gid documentdb-local \
            documentdb-local
    fi

    if ! getent group documentdb-gateway >/dev/null 2>&1; then
        groupadd --system documentdb-gateway
    fi

    if ! id -u documentdb-gateway >/dev/null 2>&1; then
        useradd \
            --system \
            --no-create-home \
            --home-dir /nonexistent \
            --shell "${nologin_shell}" \
            --gid documentdb-gateway \
            documentdb-gateway
    fi

    install -d -m 0755 -o documentdb-local -g documentdb-local /var/lib/documentdb-local
}

# Per-step consent / dry-run helper. Each invasive operation in the wizard
# calls this with a short human-readable description and the command(s)
# that would be executed. Behavior:
#   - DRY_RUN=true   → print "[dry-run]" + description, do nothing, succeed.
#   - YES=true       → log the description and run the command.
#   - otherwise      → prompt "[y/N/dry-run]" and act on the answer.
#
# Use as:
#   confirm_or_apply "Initialize PostgreSQL data directory ${DATA_DIR}" \
#       run_as_user documentdb-local "${INITDB}" --pgdata="${DATA_DIR}" ...
#
# The trailing args are passed verbatim to "$@" so quoting is preserved.
confirm_or_apply() {
    local description="$1"
    shift

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[dry-run] would: ${description}"
        return 0
    fi

    if [[ "${YES}" == "true" ]]; then
        log_info "${description}"
        "$@"
        return $?
    fi

    while true; do
        printf '%s\n' "[documentdb-setup] about to: ${description}" >&2
        printf '%s' "[y/N/dry-run] " >&2
        local answer=""
        read -r answer
        case "${answer}" in
            y|Y|yes|YES)
                "$@"
                return $?
                ;;
            dry|dry-run|d)
                log_info "[dry-run] skipped: ${description}"
                return 0
                ;;
            n|N|no|NO|"")
                die "Aborted by operator at: ${description}"
                ;;
            *)
                printf '%s\n' "Please answer y, N, or dry-run." >&2
                ;;
        esac
    done
}

has_working_systemd() {
    command_exists systemctl && [[ -d /run/systemd/system ]]
}

resolve_gateway_binary() {
    local rpm_packaged_path="/usr/bin/documentdb_gateway"
    local deb_packaged_path="/usr/bin/documentdb-gateway"
    local repo_path="${REPO_ROOT}/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway"

    if [[ -x "${rpm_packaged_path}" ]]; then
        printf '%s' "${rpm_packaged_path}"
        return 0
    fi

    if [[ -x "${deb_packaged_path}" ]]; then
        printf '%s' "${deb_packaged_path}"
        return 0
    fi

    if [[ -x "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_config_file() {
    local rpm_packaged_path="/etc/documentdb/SetupConfiguration.json"
    local deb_packaged_path="/etc/documentdb/gateway/SetupConfiguration.json"
    local repo_path="${REPO_ROOT}/pg_documentdb_gw/SetupConfiguration.json"

    if [[ -f "${rpm_packaged_path}" ]]; then
        printf '%s' "${rpm_packaged_path}"
        return 0
    fi

    if [[ -f "${deb_packaged_path}" ]]; then
        printf '%s' "${deb_packaged_path}"
        return 0
    fi

    if [[ -f "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_sample_data_dir() {
    local packaged_path="/usr/share/documentdb/sample-data"
    local repo_path="${REPO_ROOT}/documentdb-local/sample-data"

    if [[ -d "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -d "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_init_data_script() {
    local packaged_path="/usr/share/documentdb/scripts/init_documentdb_data.sh"
    local repo_path="${SCRIPT_DIR}/init_documentdb_data.sh"

    if [[ -x "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -x "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

has_systemd_unit_file() {
    local unit_name="$1"

    if [[ "${HAS_WORKING_SYSTEMD}" != "true" ]]; then
        return 1
    fi

    # `systemctl list-unit-files NAME` only matches concrete files on disk.
    # For a template instance like documentdb-gateway-local@18.service the
    # file on disk is documentdb-gateway-local@.service, so list-unit-files
    # returns 0 entries and the probe wrongly reports the unit missing.
    # `systemctl cat NAME` correctly resolves template instances by walking
    # the template -> instance binding, returning the template's contents.
    systemctl cat "${unit_name}" >/dev/null 2>&1
}

canonicalize_path() {
    local path="$1"
    local canonical_path=""

    if canonical_path="$(readlink -f "${path}" 2>/dev/null)"; then
        printf '%s\n' "${canonical_path}"
        return 0
    fi

    printf '%s\n' "${path}"
}

paths_match() {
    local left_path="$1"
    local right_path="$2"

    [[ "$(canonicalize_path "${left_path}")" == "$(canonicalize_path "${right_path}")" ]]
}

path_is_under() {
    local child_path=""
    local parent_path=""

    child_path="$(canonicalize_path "$1")"
    parent_path="$(canonicalize_path "$2")"

    [[ "${child_path}" == "${parent_path}" || "${child_path}" == "${parent_path}/"* ]]
}

read_persisted_managed_data_dir() {
    local managed_postgres=""
    local persisted_data_dir=""

    # Prefer the per-major setup.conf (the canonical Phase 10+ state
    # file). It survives Workflow C re-installs of just the
    # documentdb-gateway / documentdb-postgresql-tools packages, while
    # the legacy /etc/documentdb/documentdb-postgresql.env may be
    # wiped by apt purge on those packages.
    local per_major_state=""
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        per_major_state="/etc/documentdb/local/${PG_VERSION}/setup.conf"
        if [[ -r "${per_major_state}" ]]; then
            managed_postgres="$(grep -E '^DOCUMENTDB_MANAGED_POSTGRES=' "${per_major_state}" | head -1 | cut -d= -f2- || true)"
            persisted_data_dir="$(grep -E '^DATA_DIR=' "${per_major_state}" | head -1 | cut -d= -f2- || true)"
            if [[ "${managed_postgres}" == "true" && -n "${persisted_data_dir}" ]]; then
                printf '%s\n' "${persisted_data_dir}"
                return 0
            fi
        fi
    fi

    # Fallback: legacy env file (pre-Phase-10 deployments).
    [[ -r "${POSTGRES_SERVICE_ENV_FILE}" ]] || return 1

    managed_postgres="$(grep -E '^DOCUMENTDB_MANAGED_POSTGRES=' "${POSTGRES_SERVICE_ENV_FILE}" | head -1 | cut -d= -f2- || true)"
    persisted_data_dir="$(grep -E '^DATA_DIR=' "${POSTGRES_SERVICE_ENV_FILE}" | head -1 | cut -d= -f2- || true)"

    [[ "${managed_postgres}" == "true" && -n "${persisted_data_dir}" ]] || return 1
    printf '%s\n' "${persisted_data_dir}"
}

validate_live_cluster_paths() {
    local port="$1"
    local documentdb_uid="$2"
    local live_data_dir_uid=""
    local persisted_data_dir=""

    [[ -d "${LIVE_DATA_DIR}" ]] || die "PostgreSQL on port ${port} reports a data_directory that does not exist: ${LIVE_DATA_DIR}"
    live_data_dir_uid="$(stat -Lc '%u' "${LIVE_DATA_DIR}" 2>/dev/null || true)"
    [[ "${live_data_dir_uid}" =~ ^[0-9]+$ ]] || die "Unable to determine owner UID for PostgreSQL data_directory ${LIVE_DATA_DIR}."
    if [[ "${live_data_dir_uid}" != "${documentdb_uid}" ]]; then
        die "PostgreSQL on port ${port} uses data_directory ${LIVE_DATA_DIR}, owned by UID ${live_data_dir_uid}, not documentdb UID ${documentdb_uid}. documentdb-setup will not modify another PostgreSQL cluster. Use --pg-port for a new cluster, or stop the conflicting PostgreSQL process."
    fi

    if ! paths_match "${LIVE_DATA_DIR}" "${DATA_DIR}"; then
        die "Port ${port} is in use by a different PostgreSQL instance (data_directory: ${LIVE_DATA_DIR}). Use --data-dir ${LIVE_DATA_DIR} to manage that cluster intentionally, or use --pg-port to specify a different port."
    fi

    if ! path_is_under "${LIVE_CONFIG_FILE}" "${LIVE_DATA_DIR}"; then
        die "PostgreSQL on port ${port} uses config_file ${LIVE_CONFIG_FILE}, which is outside data_directory ${LIVE_DATA_DIR}. documentdb-setup only manages self-contained clusters it initialized. Use --pg-port with a fresh --data-dir, or manage this PostgreSQL instance manually."
    fi

    if ! path_is_under "${LIVE_HBA_FILE}" "${LIVE_DATA_DIR}"; then
        die "PostgreSQL on port ${port} uses hba_file ${LIVE_HBA_FILE}, which is outside data_directory ${LIVE_DATA_DIR}. documentdb-setup only manages self-contained clusters it initialized. Use --pg-port with a fresh --data-dir, or manage this PostgreSQL instance manually."
    fi

    if ! path_is_under "${LIVE_IDENT_FILE}" "${LIVE_DATA_DIR}"; then
        die "PostgreSQL on port ${port} uses ident_file ${LIVE_IDENT_FILE}, which is outside data_directory ${LIVE_DATA_DIR}. documentdb-setup only manages self-contained clusters it initialized. Use --pg-port with a fresh --data-dir, or manage this PostgreSQL instance manually."
    fi

    if persisted_data_dir="$(read_persisted_managed_data_dir)"; then
        if ! paths_match "${persisted_data_dir}" "${LIVE_DATA_DIR}"; then
            if [[ "${DATA_DIR_EXPLICIT}" == "true" ]] && paths_match "${DATA_DIR}" "${LIVE_DATA_DIR}"; then
                log_warn "${POSTGRES_SERVICE_ENV_FILE} records ${persisted_data_dir}, but the explicitly requested --data-dir matches the running PostgreSQL cluster in ${LIVE_DATA_DIR}; replacing persisted setup state."
            else
                die "PostgreSQL on port ${port} is running from ${LIVE_DATA_DIR}, but ${POSTGRES_SERVICE_ENV_FILE} records ${persisted_data_dir}. Stop the conflicting PostgreSQL process, or rerun documentdb-setup with the intended --data-dir."
            fi
        fi
    elif paths_match "${DATA_DIR}" "${LIVE_DATA_DIR}"; then
        # No persisted state file exists (e.g., setup.conf was wiped by
        # an apt purge of just the gateway/tools packages, or the legacy
        # env file was never present on a fresh Phase 10+ install). But
        # the live cluster lives at the exact path we'd default to AND
        # is already verified above (line 1003) as owned by
        # documentdb-local. Re-adopt silently; the next
        # sync_self_managed_postgres_service_state call will re-write
        # the per-major state file. Without this branch, the wizard
        # dies with a confusing "DocumentDB-owned but not recorded"
        # error on every re-run after a partial uninstall.
        log_verbose "Re-adopting documentdb-local-owned PostgreSQL cluster in ${LIVE_DATA_DIR} (no persisted state to compare against; will be re-recorded)."
    elif [[ "${DATA_DIR_EXPLICIT}" != "true" ]]; then
        die "Port ${port} is already running a documentdb-owned PostgreSQL cluster in ${LIVE_DATA_DIR}, but ${POSTGRES_SERVICE_ENV_FILE} does not record it as managed by documentdb-setup. To adopt it intentionally, rerun with --data-dir ${LIVE_DATA_DIR}; otherwise stop the conflicting PostgreSQL process or choose a different --pg-port."
    else
        log_warn "Adopting running PostgreSQL cluster in explicitly requested data directory ${LIVE_DATA_DIR}; documentdb-setup will update managed blocks in postgresql.conf and pg_hba.conf, update pg_ident.conf, and write ${POSTGRES_SERVICE_ENV_FILE} for future service management."
    fi
}

persist_self_managed_postgres_state() {
    local temp_file=""

    install -d -m 0755 /etc/documentdb
    create_temp_file temp_file
    chmod 600 "${temp_file}"

    # Persist the resolved config-file paths (not just DATA_DIR) so the deb
    # postrm and rpm %postun cleanup scriptlets can strip the documentdb-setup
    # managed configuration blocks even when the underlying cluster's config
    # files are at non-default paths under DATA_DIR (which adopted clusters
    # may use). Without this the cleanup would only handle the
    # `${DATA_DIR}/{postgresql,pg_hba,pg_ident}.conf` happy path and silently
    # leave the managed blocks behind for any cluster that puts its config
    # files elsewhere under the data directory.
    {
        printf 'DOCUMENTDB_MANAGED_POSTGRES=true\n'
        printf 'PG_VERSION=%s\n' "${PG_VERSION}"
        printf 'DATA_DIR=%s\n' "${DATA_DIR}"
        printf 'CONFIG_FILE=%s\n' "${LIVE_CONFIG_FILE}"
        printf 'HBA_FILE=%s\n' "${LIVE_HBA_FILE}"
        printf 'IDENT_FILE=%s\n' "${LIVE_IDENT_FILE}"
    } > "${temp_file}"

    mv "${temp_file}" "${POSTGRES_SERVICE_ENV_FILE}"
    chmod 600 "${POSTGRES_SERVICE_ENV_FILE}"

    # Also write per-major state file for systemd template units.
    # documentdb-postgresql@N.service has ConditionPathExists on this file.
    # The unit runs as User=documentdb-local for ExecStart, so the file
    # must be readable by that user. The contents are paths/ports, not
    # secrets, so 0644 is appropriate (mirrors postgresql.auto.conf's
    # rationale — operator-facing config the daemon must read).
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        local per_major_dir="/etc/documentdb/local/${PG_VERSION}"
        local per_major_conf="${per_major_dir}/setup.conf"
        install -d -m 0755 "${per_major_dir}"

        local per_major_temp=""
        create_temp_file per_major_temp
        chmod 644 "${per_major_temp}"
        {
            printf 'DOCUMENTDB_MANAGED_POSTGRES=true\n'
            printf 'DOCUMENTDB_MODE=greenfield\n'
            printf 'PG_VERSION=%s\n' "${PG_VERSION}"
            printf 'PG_PORT=%s\n' "${PG_PORT}"
            printf 'PG_OWNER=%s\n' "${PG_OWNER:-documentdb-local}"
            printf 'DATA_DIR=%s\n' "${DATA_DIR}"
            printf 'CONFIG_FILE=%s\n' "${LIVE_CONFIG_FILE}"
            printf 'HBA_FILE=%s\n' "${LIVE_HBA_FILE}"
            printf 'IDENT_FILE=%s\n' "${LIVE_IDENT_FILE}"
            printf 'GATEWAY_PORT=%s\n' "${GATEWAY_PORT}"
        } > "${per_major_temp}"
        mv "${per_major_temp}" "${per_major_conf}"
        chmod 644 "${per_major_conf}"
        log_verbose "Per-major state written to ${per_major_conf}"
    fi
}

# Issue 5 (Phase 11): brownfield must NOT write the per-major setup.conf
# that documentdb-postgresql@N.service's ConditionPathExists matches —
# otherwise the templated PG service activates against the adopted
# system PG instance and the stand-alone target ends up owning a
# PostgreSQL lifecycle that the operator already controls via
# postgresql@N-main.service. Per design §4.4, brownfield's stand-alone
# target only owns the gateway side.
#
# We still need a per-major state record for --restore tracking, so we
# write it under a different filename (brownfield.conf) that no
# templated unit's ConditionPathExists checks. The DEB postrm and RPM
# %postun cleanups already iterate both setup.conf and the legacy
# state filename; we extend them to also pick up brownfield.conf.
persist_brownfield_state() {
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0
    local per_major_dir="/etc/documentdb/local/${PG_VERSION}"
    local brownfield_conf="${per_major_dir}/brownfield.conf"
    local legacy_setup_conf="${per_major_dir}/setup.conf"
    install -d -m 0755 "${per_major_dir}"

    # Reviewer-flagged (GPT-5 iter 4): a host upgraded from a pre-iter3
    # documentdb-N package may have a left-over setup.conf from an
    # earlier brownfield run that wrongly wrote setup.conf. The
    # documentdb-postgresql@N.service template has
    # ConditionPathExists=/etc/documentdb/local/%i/setup.conf, so even
    # though iter-3+ writes brownfield.conf, the stale file still
    # satisfies the activation condition. Strip it so the greenfield PG
    # service stays silent against the adopted system PG.
    if [[ -f "${legacy_setup_conf}" ]]; then
        log_info "Removing legacy ${legacy_setup_conf} (brownfield mode does not own a greenfield PG service)."
        rm -f "${legacy_setup_conf}"
    fi

    local adopted_pg_unit
    adopted_pg_unit="$(resolve_brownfield_pg_service_unit)"

    local tmp=""
    create_temp_file tmp
    chmod 600 "${tmp}"
    {
        printf 'DOCUMENTDB_MANAGED_POSTGRES=false\n'
        printf 'DOCUMENTDB_MODE=brownfield\n'
        printf 'PG_VERSION=%s\n' "${PG_VERSION}"
        printf 'PG_PORT=%s\n' "${PG_PORT}"
        printf 'PG_OWNER=%s\n' "${PG_OWNER:-postgres}"
        printf 'DATA_DIR=%s\n' "${LIVE_DATA_DIR}"
        printf 'CONFIG_FILE=%s\n' "${LIVE_CONFIG_FILE}"
        printf 'HBA_FILE=%s\n' "${LIVE_HBA_FILE}"
        printf 'IDENT_FILE=%s\n' "${LIVE_IDENT_FILE}"
        printf 'TARGET_CLUSTER=%s\n' "${TARGET_CLUSTER}"
        printf 'ADOPTED_PG_SERVICE_UNIT=%s\n' "${adopted_pg_unit}"
        printf 'GATEWAY_PORT=%s\n' "${GATEWAY_PORT}"
    } > "${tmp}"
    mv "${tmp}" "${brownfield_conf}"
    chmod 600 "${brownfield_conf}"
    log_verbose "Per-major brownfield state written to ${brownfield_conf}"

    write_brownfield_gateway_dropin "${adopted_pg_unit}"
}

# Returns the systemd unit name of the adopted PostgreSQL service in
# brownfield mode. Debian/Ubuntu's postgresql-common ships
# postgresql@<V>-<C>.service; PGDG's RHEL packages ship postgresql-<V>.service.
# Detection mirrors start_or_restart_postgres()'s reload-hint logic so the
# same name is used everywhere.
resolve_brownfield_pg_service_unit() {
    # Defense in depth: prepare_brownfield_instance already validated
    # TARGET_CLUSTER as VERSION/NAME, but a future code path that calls this
    # resolver without going through that validator would otherwise produce a
    # broken Requires= (e.g. "postgresql@18-18.service") and silently get
    # baked into the on-disk drop-in. Fail loudly instead.
    [[ "${TARGET_CLUSTER}" == */* ]] \
        || die "resolve_brownfield_pg_service_unit: TARGET_CLUSTER must be VERSION/NAME; got '${TARGET_CLUSTER}'."

    if [[ -d "/etc/postgresql/${PG_VERSION}" ]]; then
        local cluster_name="${TARGET_CLUSTER#*/}"
        [[ -n "${cluster_name}" ]] || cluster_name="main"
        printf 'postgresql@%s-%s.service' "${PG_VERSION}" "${cluster_name}"
    else
        printf 'postgresql-%s.service' "${PG_VERSION}"
    fi
}

# Per packaging-design.md §4.4, in brownfield mode the stand-alone target only
# owns the gateway side and must order the gateway after the adopted PostgreSQL
# service — not the greenfield documentdb-postgresql@N.service template (whose
# ConditionPathExists is intentionally false in brownfield so it skips).
#
# The shipped documentdb-gateway-local@.service unit hard-wires Requires=/After=
# documentdb-postgresql@%i.service for the greenfield case. In brownfield we
# write a per-instance drop-in that resets those lists and re-points them at
# the adopted PG service, so reboot ordering is correct and `systemctl restart
# documentdb-local@N.target` does not depend on the (skipped) greenfield unit.
#
# The drop-in lives under /etc/systemd/system (the admin-owned tree) so package
# upgrades never overwrite it; it is removed by --restore and by the DEB postrm
# / RPM %postun on full purge.
write_brownfield_gateway_dropin() {
    local adopted_pg_unit="$1"
    [[ -n "${adopted_pg_unit}" ]] || return 0
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0

    local dropin_dir="/etc/systemd/system/documentdb-gateway-local@${PG_VERSION}.service.d"
    local dropin_file="${dropin_dir}/brownfield.conf"

    # Don't reset mode on an admin-pre-created directory (e.g. one that was
    # locked down to 0750). install -d -m forces the mode unconditionally.
    if [[ ! -d "${dropin_dir}" ]]; then
        install -d -m 0755 "${dropin_dir}"
    fi

    # Write the temp file into the same directory so the final rename is a
    # same-filesystem rename(2), which is atomic — mv across filesystems
    # (mktemp's default /tmp vs. /etc/systemd) is not.
    local tmp=""
    create_temp_file tmp "${dropin_dir}/.brownfield.conf.XXXXXX"
    chmod 644 "${tmp}"
    cat > "${tmp}" <<DROPIN
# Generated by documentdb-setup --target-postgres-instance ${TARGET_CLUSTER}
# Brownfield mode: gateway orders on the adopted system PostgreSQL service,
# not the (skipped) per-major greenfield documentdb-postgresql@${PG_VERSION}.service.
# See packaging-design.md §4.4 — "the stand-alone target only owns the local
# gateway side and orders it after the adopted PostgreSQL service."
[Unit]
# Reset the unit's greenfield Requires=/After= lists and re-point at the
# adopted PG service so boot ordering is correct.
Requires=
After=
Requires=${adopted_pg_unit}
After=${adopted_pg_unit}
DROPIN
    mv "${tmp}" "${dropin_file}"
    chmod 644 "${dropin_file}"
    log_verbose "Brownfield gateway drop-in written to ${dropin_file}"

    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]]; then
        systemctl daemon-reload || true
    fi
}

# Inverse of write_brownfield_gateway_dropin(): used by --restore and by any
# future code path that needs to revert a per-major brownfield drop-in. The
# writer reloads systemd so its in-memory unit graph reflects the new drop-in;
# the remover must do the same so the freshly-removed brownfield Requires=/
# After= are not still present in systemd's view. The DEB postrm / RPM
# %postun bypass this function and do their own remove+reload, but any
# future caller of remove_brownfield_gateway_dropin() needs the symmetry.
remove_brownfield_gateway_dropin() {
    local pg_major="$1"
    [[ -n "${pg_major}" && "${pg_major}" =~ ^[0-9]+$ ]] || return 0
    local dropin_dir="/etc/systemd/system/documentdb-gateway-local@${pg_major}.service.d"
    local existed=false
    [[ -f "${dropin_dir}/brownfield.conf" ]] && existed=true
    rm -f "${dropin_dir}/brownfield.conf"
    rmdir --ignore-fail-on-non-empty "${dropin_dir}" 2>/dev/null || true

    # Defensive: rm -f effectively always succeeds (it suppresses missing-
    # file errors), so the on-disk file is guaranteed gone. The risk is that
    # systemctl daemon-reload silently fails and systemd's in-memory unit
    # graph still has the brownfield Requires=/After=. We surface that as a
    # warning rather than an error — the file is already gone, and the
    # operator can finish the reload with `sudo systemctl daemon-reload`
    # if our attempt was suppressed.
    if [[ "${existed}" == "true" && "${HAS_WORKING_SYSTEMD}" == "true" ]]; then
        if ! systemctl daemon-reload; then
            log_warn "systemctl daemon-reload failed after removing brownfield drop-in at ${dropin_dir}. Run 'sudo systemctl daemon-reload' manually to refresh systemd's view."
        fi
    fi
}

ensure_postgres_systemd_drop_in() {
    # The packaged documentdb-postgresql@.service template hardcodes
    # PIDFile=/var/lib/documentdb-local/%i/data/postmaster.pid (per-major
    # default DATA_DIR), so systemd can track the postmaster under
    # Type=forking. When the operator chose a different data directory
    # for major N, write an admin-owned drop-in that overrides PIDFile
    # for the documentdb-postgresql@N.service instance specifically.
    # The drop-in lives under /etc/systemd/system so package upgrades
    # never overwrite it.
    #
    # Reviewer-flagged (GPT-5 iter 6): before this fix the drop-in
    # targeted the legacy non-templated `documentdb-postgresql.service`
    # path which the split-package design replaced with the templated
    # `documentdb-postgresql@.service`. So `--data-dir <custom>` writes
    # produced a drop-in for a non-existent unit and the PIDFile
    # override never applied — silently breaking Type=forking tracking
    # for custom data dirs.
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0
    local drop_in_dir="/etc/systemd/system/documentdb-postgresql@${PG_VERSION}.service.d"
    local drop_in_file="${drop_in_dir}/datadir.conf"
    local legacy_drop_in_dir="/etc/systemd/system/documentdb-postgresql.service.d"
    local legacy_drop_in_file="${legacy_drop_in_dir}/datadir.conf"
    local desired_block=""
    local file_was_present=false

    # Strip any legacy pre-iter6 non-templated drop-in (a previous run
    # under the old code path could have left it behind on this host).
    if [[ -f "${legacy_drop_in_file}" ]]; then
        rm -f "${legacy_drop_in_file}"
        rmdir --ignore-fail-on-non-empty "${legacy_drop_in_dir}" 2>/dev/null || true
        file_was_present=true
    fi

    local per_major_default="/var/lib/documentdb-local/${PG_VERSION}/data"
    if [[ "${DATA_DIR}" == "${per_major_default}" ]]; then
        # The packaged unit's default PIDFile already matches; remove any
        # stale drop-in from a previous run with a custom data dir.
        if [[ -f "${drop_in_file}" ]]; then
            file_was_present=true
            rm -f "${drop_in_file}"
        fi
        if [[ -d "${drop_in_dir}" ]]; then
            rmdir --ignore-fail-on-non-empty "${drop_in_dir}" 2>/dev/null || true
        fi
        if [[ "${file_was_present}" == "true" && "${HAS_WORKING_SYSTEMD}" == "true" ]]; then
            systemctl daemon-reload
        fi
        return 0
    fi

    install -d -m 0755 "${drop_in_dir}"
    desired_block="$(printf '[Service]\nPIDFile=%s/postmaster.pid\n' "${DATA_DIR}")"

    if [[ -f "${drop_in_file}" ]] && [[ "$(cat "${drop_in_file}")" == "${desired_block}" ]] \
            && [[ "${file_was_present}" != "true" ]]; then
        return 0
    fi

    printf '%s\n' "${desired_block}" > "${drop_in_file}"
    chmod 0644 "${drop_in_file}"
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]]; then
        systemctl daemon-reload
    fi
}

sync_self_managed_postgres_service_state() {
    persist_self_managed_postgres_state
    ensure_postgres_systemd_drop_in
}

capture_gateway_active_state() {
    # Record whether the gateway is currently active under systemd. We use
    # this to detect when restarting PostgreSQL during this run would tear
    # the gateway down through dependency propagation (Requires= will
    # propagate a stop job for the gateway when systemctl restart is run on
    # the PG unit). Under --no-enable the operator asked us not to do
    # first-time gateway startup, but we must still preserve a previously
    # running gateway's state across our PG operations.
    #
    # Reviewer-flagged (external review iter 18): the previous
    # implementation only checked documentdb-gateway.service (the
    # non-templated Workflow-B unit). But start_gateway() prefers the
    # per-major templated documentdb-gateway-local@N.service when
    # available. If the per-major unit is active and PG restart
    # propagation stops it via Requires=, capture_gateway_active_state
    # would record GATEWAY_WAS_ACTIVE=false and the --no-enable branch
    # would not restore it. Check both candidate units.
    GATEWAY_WAS_ACTIVE=false
    if [[ "${HAS_WORKING_SYSTEMD}" != "true" ]]; then
        return 0
    fi
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        local per_major_unit="documentdb-gateway-local@${PG_VERSION}.service"
        if has_systemd_unit_file "${per_major_unit}" \
                && systemctl is-active --quiet "${per_major_unit}"; then
            GATEWAY_WAS_ACTIVE=true
            return 0
        fi
    fi
    if has_systemd_unit_file documentdb-gateway.service \
            && systemctl is-active --quiet documentdb-gateway.service; then
        GATEWAY_WAS_ACTIVE=true
    fi
}

postgres_major_from_pg_config() {
    local pg_config_path="$1"
    local version_line=""

    version_line="$("${pg_config_path}" --version 2>/dev/null || true)"
    printf '%s\n' "${version_line}" | sed -n 's/^PostgreSQL \([0-9]\+\).*/\1/p'
}

set_postgres_binary_paths() {
    local major_version="$1"
    local candidate_paths=(
        "/usr/lib/postgresql/${major_version}/bin"
        "/usr/pgsql-${major_version}/bin"
        "/usr/sbin"
    )
    local candidate=""
    local candidate_version=""

    for candidate in "${candidate_paths[@]}"; do
        if [[ -x "${candidate}/pg_config" ]]; then
            candidate_version="$(postgres_major_from_pg_config "${candidate}/pg_config")"
            if [[ "${candidate_version}" != "${major_version}" ]]; then
                continue
            fi
            PG_VERSION="${major_version}"
            PG_BIN_DIR="${candidate}"
            PG_CONFIG="${candidate}/pg_config"
            INITDB="${candidate}/initdb"
            PG_CTL="${candidate}/pg_ctl"
            PSQL="${candidate}/psql"
            PG_ISREADY="${candidate}/pg_isready"
            return 0
        fi
    done

    return 1
}

detect_postgres_installation() {
    local best_with_extension=0
    local best_without_extension=0
    local candidate_path=""
    local candidate_version=""
    local sharedir=""
    local has_extension=false

    if [[ "${PG_VERSION_EXPLICIT}" == "true" ]]; then
        set_postgres_binary_paths "${PG_VERSION}" || die "PostgreSQL ${PG_VERSION} not found in standard Debian, RHEL, or Fedora paths."
        return 0
    fi

    for candidate_path in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin /usr/sbin; do
        if [[ ! -x "${candidate_path}/pg_config" ]]; then
            continue
        fi

        candidate_version="$(basename "$(dirname "${candidate_path}")" | sed 's/^pgsql-//')"
        if [[ ! "${candidate_version}" =~ ^[0-9]+$ ]]; then
            candidate_version="$(postgres_major_from_pg_config "${candidate_path}/pg_config")"
            if [[ ! "${candidate_version}" =~ ^[0-9]+$ ]]; then
                continue
            fi
        fi

        sharedir="$("${candidate_path}/pg_config" --sharedir)"
        has_extension=false
        if [[ -f "${sharedir}/extension/documentdb.control" ]]; then
            has_extension=true
        fi

        if [[ "${has_extension}" == "true" ]] && (( candidate_version > best_with_extension )); then
            best_with_extension="${candidate_version}"
        fi

        if (( candidate_version > best_without_extension )); then
            best_without_extension="${candidate_version}"
        fi
    done

    if (( best_with_extension > 0 )); then
        set_postgres_binary_paths "${best_with_extension}" || die "Failed to resolve PostgreSQL ${best_with_extension} binaries after detection."
        return 0
    fi

    if (( best_without_extension > 0 )); then
        set_postgres_binary_paths "${best_without_extension}" || die "Failed to resolve PostgreSQL ${best_without_extension} binaries after detection."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        # In dry-run we don't fail when PG is missing; the apply path's
        # preflight_validation will surface the same error there.
        return 0
    fi
    die "PostgreSQL not found. Install PostgreSQL first (for example: apt install postgresql-17)."
}

read_shared_preload_libraries_from_file() {
    local config_path="$1"
    local current_value=""

    if [[ ! -f "${config_path}" ]]; then
        return 0
    fi

    current_value="$(
        awk -F= '
            /^[[:space:]]*#/ { next }
            $0 ~ /^[[:space:]]*shared_preload_libraries[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
            }
        ' "${config_path}" | tail -n 1
    )"

    current_value="$(strip_wrapping_quotes "${current_value}")"
    printf '%s' "${current_value}"
}

merge_shared_preload_libraries() {
    local current_value="$1"
    local cleaned_current=""
    local item=""
    local joined=""
    local -a merged_items=()
    local -a current_items=()
    local -a required_items=(
        "pg_cron"
        "pg_documentdb_core"
        "pg_documentdb"
    )

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        required_items+=("pg_documentdb_extended_rum")
    fi

    cleaned_current="$(strip_wrapping_quotes "${current_value}")"
    if [[ -n "${cleaned_current}" ]]; then
        IFS=',' read -r -a current_items <<< "${cleaned_current}"
        for item in "${current_items[@]}"; do
            item="$(trim_whitespace "${item}")"
            [[ -z "${item}" ]] && continue
            if ! array_contains "${item}" ${merged_items[@]+"${merged_items[@]}"}; then
                merged_items+=("${item}")
            fi
        done
    fi

    for item in "${required_items[@]}"; do
        if ! array_contains "${item}" ${merged_items[@]+"${merged_items[@]}"}; then
            merged_items+=("${item}")
        fi
    done

    for item in "${merged_items[@]}"; do
        joined+="${joined:+, }${item}"
    done

    printf '%s' "${joined}"
}

build_postgres_conf_block() {
    local merged_preload="$1"
    local ssl_setting="${2:-}"
    local postgres_conf_block=""

    postgres_conf_block=$(
        cat <<EOF
listen_addresses = 'localhost'
port = ${PG_PORT}
unix_socket_directories = '${PG_SOCKET_DIR}'
shared_preload_libraries = '${merged_preload}'
cron.database_name = 'postgres'
documentdb.localhost_connection_string = 'host=${PG_SOCKET_DIR} port=${PG_PORT}'
EOF
    )

    if [[ -n "${ssl_setting}" ]]; then
        postgres_conf_block+=$'\n'"ssl = ${ssl_setting}"
    fi

    postgres_conf_block+=$'\n'"documentdb.enableBackgroundWorker = true"
    postgres_conf_block+=$'\n'"documentdb.enableBackgroundWorkerJobs = true"
    postgres_conf_block+=$'\n'"documentdb.indexBuildsScheduledOnBgWorker = false"

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        postgres_conf_block+=$'\n'"documentdb.rum_library_load_option = 'require_documentdb_extended_rum'"
        postgres_conf_block+=$'\n'"documentdb.alternate_index_handler_name = 'extended_rum'"
    fi

    printf '%s' "${postgres_conf_block}"
}

build_desired_hba_block() {
    # The private cluster owner must be able to connect as its own PG role
    # before documentdb-register-gateway creates the gateway role/map. All
    # other local socket connections go through the managed ident map.
    cat <<'EOF'
local   all   documentdb-local   peer
local   all   all   peer   map=documentdb-map
EOF
}

apply_managed_postgres_settings() {
    local config_file="$1"
    local hba_file="$2"
    local merged_preload="$3"
    local ssl_setting="${4:-}"
    local postgres_conf_block=""
    local desired_hba_block=""
    local existing_postgres_conf_block=""
    local existing_hba_block=""

    # Per packaging-design.md §4.4, the setup wizard delegates each invasive
    # PostgreSQL-side write to the dedicated tool that owns it:
    #   - documentdb-tune              → postgresql.conf
    #   - documentdb-register-gateway  → pg_hba.conf + pg_ident.conf + role
    #                                    + connection-URL file
    # We prefer the external tools when they are installed (which is the
    # `documentdb-postgresql-tools` hard-dep contract on the stand-alone
    # package), and fall back to the inline writes for dev / partial
    # environments where the tools may not yet be on PATH. The fallback
    # uses identical managed-block markers so the two paths are
    # interchangeable from a postrm-cleanup standpoint.
    if command_exists documentdb-tune; then
        local prev_mtime=""
        if [[ -f "${config_file}" ]]; then
            prev_mtime="$(stat -c %Y "${config_file}" 2>/dev/null || echo 0)"
        fi
        log_verbose "Delegating postgresql.conf tuning to documentdb-tune."

        # Reviewer-flagged (GPT-5.5 iter 9): on Debian brownfield,
        # /etc/postgresql/<V>/<C>/postgresql.conf is the canonical config
        # file (not the data dir's). Passing --pgdata to documentdb-tune
        # makes it write to the data-dir postgresql.conf which Debian
        # clusters do not read. Use --pg-version/--cluster instead so
        # tune writes the per-cluster fragment under
        # /etc/postgresql-common/documentdb/<V>/<C>/documentdb.conf
        # (the design's documented path, see §4.2 / §8). Greenfield
        # (private appliance PG) keeps --pgdata because the data dir
        # IS where its postgresql.conf lives.
        local -a tune_args=()
        if [[ -n "${TARGET_CLUSTER}" && -d "/etc/postgresql/${PG_VERSION}/${TARGET_CLUSTER#*/}" ]]; then
            tune_args+=(--pg-version "${PG_VERSION}" --cluster "${TARGET_CLUSTER#*/}")
        else
            # Greenfield: --pgdata pins documentdb-tune at the per-major
            # private data dir's postgresql.conf. ALSO pass --pg-version
            # explicitly: tune's resolve_pg_sharedir is gated on
            # ${PG_VERSION} being set, and without it tune skips
            # extended-RUM detection. The wizard always knows the
            # major here (we resolved it during detect_postgres_installation),
            # so passing it through is free and makes tune's behaviour
            # match what `documentdb-createcluster N C` produces.
            tune_args+=(--pgdata "${LIVE_DATA_DIR}" --pg-version "${PG_VERSION}")
        fi
        tune_args+=(--yes)

        if ! confirm_or_apply "Write postgresql.conf managed block via documentdb-tune ${tune_args[*]}" \
                documentdb-tune "${tune_args[@]}" >/dev/null; then
            die "documentdb-tune failed; see above for details."
        fi
        local new_mtime=""
        if [[ -f "${config_file}" ]]; then
            new_mtime="$(stat -c %Y "${config_file}" 2>/dev/null || echo 0)"
        fi
        if [[ "${prev_mtime}" != "${new_mtime}" ]]; then
            PG_CONFIG_CHANGED=true
        fi

        # Per-instance isolation settings (port, socket dir, listen
        # addresses) are the WIZARD's responsibility — not tune's.
        # `documentdb-tune` is generic (it writes shared_preload_libraries
        # + the documentdb-tunable GUCs that are identical across every
        # DocumentDB-enabled instance) and intentionally does NOT touch
        # port / unix_socket_directories because those vary per-cluster
        # and a brownfield tune of a system PG instance would clobber
        # the operator's existing port choice.
        #
        # In greenfield mode we own the per-major PG instance end-to-end,
        # so we DO need to pin port = PG_PORT, unix_socket_directories =
        # /run/documentdb-local/N/postgresql, and listen_addresses =
        # localhost. Without this, the instance starts on PG's default
        # port 5432 and the default socket dir (/var/run/postgresql,
        # owned by the system postgres user) — colliding with any
        # system PG on the host AND failing to write the lock file
        # because documentdb-local can't write to postgres's socket dir.
        # In brownfield mode we skip this block entirely so the adopted
        # system PG instance keeps its operator-managed listen settings.
        if [[ -z "${TARGET_CLUSTER}" ]]; then
            local wizard_listen_block=""
            wizard_listen_block="$(cat <<EOF
listen_addresses = 'localhost'
port = ${PG_PORT}
unix_socket_directories = '${PG_SOCKET_DIR}'
documentdb.localhost_connection_string = 'host=${PG_SOCKET_DIR} port=${PG_PORT}'
# Headroom over PG's default of 100. The gateway opens two pools
# (SystemRequests + PreAuthRequests), each potentially up to ~16
# connections, plus pg_cron background workers, plus the wizard's
# own psql sessions during CREATE EXTENSION / admin bootstrap. On a
# stock 100-slot PG this can saturate after a couple of wizard
# re-runs and surface as "FATAL: sorry, too many clients already"
# on subsequent CRUD / mongosh activity.
max_connections = 500
EOF
)"
            local existing_listen_block=""
            existing_listen_block="$(extract_managed_block_content \
                "${config_file}" \
                "# >>> documentdb-setup managed listen >>>" \
                "# <<< documentdb-setup managed listen <<<")"
            if [[ "${existing_listen_block}" != "${wizard_listen_block}" ]]; then
                PG_CONFIG_CHANGED=true
            fi
            rewrite_with_managed_block "${config_file}" \
                "# >>> documentdb-setup managed listen >>>" \
                "# <<< documentdb-setup managed listen <<<" \
                "${wizard_listen_block}"
        fi
    else
        postgres_conf_block="$(build_postgres_conf_block "${merged_preload}" "${ssl_setting}")"
        existing_postgres_conf_block="$(extract_managed_block_content "${config_file}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}")"
        if [[ "${existing_postgres_conf_block}" != "${postgres_conf_block}" ]]; then
            PG_CONFIG_CHANGED=true
        fi
        rewrite_with_managed_block "${config_file}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}" "${postgres_conf_block}"
    fi

    # Phase 10 delegation: pg_hba.conf is now written by
    # documentdb-register-gateway (called from ensure_pg_ident_map), not
    # here. We still set PG_RELOAD_CHANGED so the caller knows a reload
    # is pending; the actual hba write happens in the register-gateway
    # invocation that runs immediately after this function. We keep the
    # inline write as a fallback for dev environments where tools is not
    # installed (in which case ensure_pg_ident_map also falls back).
    if ! command_exists documentdb-register-gateway; then
        desired_hba_block="$(build_desired_hba_block)"
        existing_hba_block="$(extract_managed_block_content "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}")"
        if [[ "${existing_hba_block}" != "${desired_hba_block}" ]]; then
            PG_RELOAD_CHANGED=true
        fi
        prepend_with_managed_block "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}" "${desired_hba_block}"
    fi
}

resolve_live_cluster_metadata() {
    local port="$1"
    local live_cluster_pid=""
    local detected_owner=""
    local documentdb_uid=""
    local live_cluster_uid=""
    local server_version_num=""
    local detected_major=""

    live_cluster_pid="$(find_listener_pid "${port}")"
    [[ -n "${live_cluster_pid}" ]] || die "No process is listening on PostgreSQL port ${port}."

    if ! listener_looks_like_postgres "${live_cluster_pid}"; then
        die "Port ${port} is in use by a non-PostgreSQL process."
    fi

    documentdb_uid="$(id -u documentdb-local 2>/dev/null || true)"
    [[ "${documentdb_uid}" =~ ^[0-9]+$ ]] || die "The documentdb-local runtime user does not exist."

    # find_listener_pid returns the literal "1" as a placeholder when
    # neither lsof nor ss is installed and /proc/net/tcp only confirms
    # a listener exists but can't enumerate owners. In that case the
    # stat /proc/1 owner check below would incorrectly identify
    # systemd (root) as the listener. listener_looks_like_postgres
    # has already done the systemd-aware fallback and accepted the
    # listener as ours, so trust it and skip the UID/owner check.
    if [[ "${live_cluster_pid}" != "1" ]]; then
        live_cluster_uid="$(stat -c '%u' "/proc/${live_cluster_pid}" 2>/dev/null || true)"
        [[ "${live_cluster_uid}" =~ ^[0-9]+$ ]] || die "Unable to determine the PostgreSQL process UID on port ${port}."
        detected_owner="$(ps -o user= -p "${live_cluster_pid}" 2>/dev/null | awk '{print $1}' || true)"

        if [[ "${live_cluster_uid}" != "${documentdb_uid}" ]]; then
            die "Port ${port} is in use by a PostgreSQL instance owned by UID ${live_cluster_uid} (${detected_owner:-unknown}), not the documentdb runtime UID ${documentdb_uid}. documentdb-setup will not modify another PostgreSQL cluster. Use --pg-port to specify a different port, or stop the existing PostgreSQL process."
        fi
    fi

    PG_OWNER="documentdb-local"

    LIVE_DATA_DIR="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW data_directory;
SQL
    )"
    LIVE_CONFIG_FILE="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW config_file;
SQL
    )"
    LIVE_HBA_FILE="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW hba_file;
SQL
    )"
    LIVE_IDENT_FILE="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW ident_file;
SQL
    )"
    validate_live_cluster_paths "${port}" "${documentdb_uid}"

    LIVE_PRELOAD_LIBRARIES="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW shared_preload_libraries;
SQL
    )"
    server_version_num="$(
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW server_version_num;
SQL
    )"

    if [[ ! "${server_version_num}" =~ ^[0-9]+$ ]]; then
        die "Unable to parse PostgreSQL server_version_num from the running cluster."
    fi

    detected_major="$(( server_version_num / 10000 ))"
    if [[ "${PG_VERSION_EXPLICIT}" == "true" && "${PG_VERSION}" != "${detected_major}" ]]; then
        die "The running PostgreSQL cluster is version ${detected_major}, but --pg-version ${PG_VERSION} was requested."
    fi

    set_postgres_binary_paths "${detected_major}" || die "Unable to resolve PostgreSQL ${detected_major} client binaries for the running cluster."
    refresh_extension_state
    validate_documentdb_extension_installation
    log_verbose "Resolved running PostgreSQL cluster metadata: data_directory=${LIVE_DATA_DIR}, config_file=${LIVE_CONFIG_FILE}, hba_file=${LIVE_HBA_FILE}, ident_file=${LIVE_IDENT_FILE}"
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "documentdb-setup must be run as root (use sudo)."
    fi
}

validate_required_arguments() {
    [[ -n "${USERNAME}" ]] || die "--username is required."

    # TLS triple: --tls-cert / --tls-key must come together; combining
    # either with --tls-auto-generate true is a contradiction (the
    # gateway's env-overlay also rejects this, but we surface the error
    # at the wizard layer with a clearer message). When neither cert
    # nor key is set we leave TLS_AUTO_GENERATE alone; if the operator
    # didn't explicitly pass it the delegate keeps the design's
    # standalone default of auto-generate=true.
    if [[ -n "${TLS_CERT_FILE}" || -n "${TLS_KEY_FILE}" ]]; then
        [[ -n "${TLS_CERT_FILE}" ]] || die "--tls-key requires --tls-cert to also be set."
        [[ -n "${TLS_KEY_FILE}"  ]] || die "--tls-cert requires --tls-key to also be set."
        [[ -r "${TLS_CERT_FILE}" ]] || die "--tls-cert ${TLS_CERT_FILE} is not readable."
        [[ -r "${TLS_KEY_FILE}"  ]] || die "--tls-key  ${TLS_KEY_FILE} is not readable."
        if [[ "${TLS_AUTO_GENERATE}" == "true" ]]; then
            die "--tls-auto-generate=true cannot be combined with --tls-cert / --tls-key; pick one TLS source."
        fi
        # When the operator supplies a cert/key explicitly, the env file
        # must record auto-generate=false so the gateway honors the
        # provided files rather than re-generating on next start.
        TLS_AUTO_GENERATE="false"
        # Advanced-user E2E flagged (Gap #9): the gateway daemon runs as
        # the documentdb-gateway OS user. If the operator-supplied TLS
        # files are not readable by that user (e.g. root:root 0600), the
        # gateway aborts with "Failed to create TLS provider: Permission
        # denied" — even though the wizard accepted them because root
        # can read them. Auto-fix ownership when we have privilege; bail
        # with a clear actionable error otherwise.
        local gw_user="documentdb-gateway"
        if id -u "${gw_user}" >/dev/null 2>&1; then
            local f
            for f in "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"; do
                if ! sudo -n -u "${gw_user}" test -r "${f}" 2>/dev/null \
                        && ! run_as_user "${gw_user}" test -r "${f}" 2>/dev/null; then
                    if [[ "$(id -u)" -eq 0 ]]; then
                        log_info "Adjusting ownership of ${f} to root:${gw_user} mode 0640 so the gateway can read it."
                        chown "root:${gw_user}" "${f}"
                        # Cert can stay world-readable; key tightens to 0640.
                        if [[ "${f}" == "${TLS_KEY_FILE}" ]]; then
                            chmod 0640 "${f}"
                        else
                            chmod 0644 "${f}"
                        fi
                    else
                        die "TLS file ${f} is not readable by the documentdb-gateway OS user. Run as root, or manually: sudo chown root:${gw_user} ${f} && sudo chmod 0640 ${f}"
                    fi
                fi
            done
        fi
        # Advanced-user E2E flagged (Gap #10 / low): tighten the
        # private-key permission warning. 0600/0640 are both fine; warn
        # only when group/world has read.
        local key_perms
        key_perms="$(stat -c '%a' "${TLS_KEY_FILE}" 2>/dev/null || true)"
        if [[ -n "${key_perms}" ]]; then
            local pad="${key_perms}"
            while [[ "${#pad}" -lt 4 ]]; do pad="0${pad}"; done
            # Other (last digit) must be 0; group readable (middle digit) is OK if owner=root and group=documentdb-gateway.
            local other_digit="${pad: -1}"
            if [[ "${other_digit}" != "0" ]]; then
                log_warn "TLS key ${TLS_KEY_FILE} is world-accessible (${pad}). Tighten to 0640 or 0600 before running in production."
            fi
        fi
    fi

    resolve_password

    if [[ "${NO_ENABLE}" == "true" && "${LOAD_SAMPLE_DATA}" == "true" ]]; then
        die "--load-sample-data requires a running gateway and cannot be combined with --no-enable."
    fi
}

resolve_runtime_paths() {
    GATEWAY_BINARY="$(resolve_gateway_binary)" || die "Unable to find the gateway binary at /usr/bin/documentdb_gateway, /usr/bin/documentdb-gateway, or in the repo build output."
    CONFIG_FILE="$(resolve_config_file)" || die "Unable to find SetupConfiguration.json at /etc/documentdb/SetupConfiguration.json, /etc/documentdb/gateway/SetupConfiguration.json, or in the repo. If you just installed the documentdb-gateway package, try: sudo dpkg --configure -a   (the postinst may have been skipped because an unrelated dependency was missing). Then re-run documentdb-setup."
    SAMPLE_DATA_DIR="$(resolve_sample_data_dir)" || true
    INIT_DATA_SCRIPT="$(resolve_init_data_script)" || true
    HAS_WORKING_SYSTEMD=false
    if has_working_systemd; then
        HAS_WORKING_SYSTEMD=true
    fi

    # Late default computation (Issue 4): PG_PORT and DATA_DIR depend on
    # PG_VERSION, but parse_arguments runs before detect_postgres_installation
    # so PG_VERSION may still be empty there. Recompute the defaults here,
    # AFTER detect_postgres_installation has populated PG_VERSION from the
    # installed PG binaries, so the operator gets the per-major paths the
    # design promises (PG 18 → port 9718, /var/lib/documentdb-local/18/data)
    # rather than the legacy "${DEFAULT_*}" placeholders.
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        # Only override the defaults if the operator did NOT explicitly set
        # them and they are still at the parse-time legacy value.
        if [[ "${PG_PORT_EXPLICIT}" != "true" ]] \
                && { [[ -z "${PG_PORT}" ]] || [[ "${PG_PORT}" == "${DEFAULT_PG_PORT}" ]]; }; then
            PG_PORT=$(( 9700 + PG_VERSION ))
        fi
        if [[ "${DATA_DIR_EXPLICIT}" != "true" ]] \
                && { [[ -z "${DATA_DIR}" ]] || [[ "${DATA_DIR}" == "${DEFAULT_DATA_DIR}" ]]; }; then
            DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
        fi
        # Per-major Unix-socket directory under /run/ — matches the
        # documentdb-postgresql@N.service unit's expectations.
        PG_SOCKET_DIR="/run/documentdb-local/${PG_VERSION}/postgresql"
    fi
}

refresh_extension_state() {
    EXTENSION_CONTROL_FILE="$("${PG_CONFIG}" --sharedir)/extension/documentdb.control"
    EXTENDED_RUM_CONTROL_FILE="$("${PG_CONFIG}" --sharedir)/extension/documentdb_extended_rum.control"

    HAS_EXTENDED_RUM=false
    if [[ -f "${EXTENDED_RUM_CONTROL_FILE}" ]]; then
        HAS_EXTENDED_RUM=true
    fi
}

validate_documentdb_extension_installation() {
    [[ -f "${EXTENSION_CONTROL_FILE}" ]] || die "The DocumentDB extension package is not installed for PostgreSQL ${PG_VERSION} (${EXTENSION_CONTROL_FILE} is missing)."
}

preflight_validation() {
    require_root
    validate_required_arguments

    command_exists jq || die "jq is required but not installed. Install with: apt install jq"
    detect_postgres_installation
    resolve_runtime_paths

    refresh_extension_state
    validate_documentdb_extension_installation
    [[ -x "${GATEWAY_BINARY}" ]] || die "The gateway binary was not found at ${GATEWAY_BINARY}."
    [[ -f "${CONFIG_FILE}" ]] || die "The gateway configuration file was not found at ${CONFIG_FILE}."

    # Advanced-user E2E flagged (Gap #11): on greenfield, the wizard
    # ran initdb (slow!), then tried to start PG on the per-major port,
    # then failed cryptically with "pg_ctl: could not start server" if
    # the port was already in use by a foreign cluster. Worse, the state
    # file was written before the failure, leaving the install in a
    # half-broken state. Probe the port BEFORE initdb. Only applies in
    # greenfield mode; brownfield adopts the existing PG that is by
    # definition already listening. Allow our OWN greenfield PG (owned by
    # documentdb-local) on this port — that path goes through
    # resolve_live_cluster_metadata which knows how to handle a
    # re-setup against the existing private cluster.
    if [[ -z "${TARGET_CLUSTER}" && "${RESTORE}" != "true" \
            && "${STATUS_ONLY}" != "true" && "${PRINT_CONFIG}" != "true" \
            && "${DRY_RUN}" != "true" ]]; then
        local pg_listener_pid
        pg_listener_pid="$(find_listener_pid "${PG_PORT}" 2>/dev/null)"
        if [[ -n "${pg_listener_pid}" && "${pg_listener_pid}" != "1" ]]; then
            # /proc/net/tcp fallback returns "1" as a placeholder when it
            # detects a listener but cannot identify the PID. In that case
            # we cannot tell foreign-vs-ours, so let the downstream
            # resolve_live_cluster_metadata path handle ownership.
            local listener_uid="" documentdb_local_uid=""
            listener_uid="$(stat -c '%u' "/proc/${pg_listener_pid}" 2>/dev/null || true)"
            documentdb_local_uid="$(id -u documentdb-local 2>/dev/null || true)"
            if [[ -n "${listener_uid}" && -n "${documentdb_local_uid}" \
                    && "${listener_uid}" != "${documentdb_local_uid}" ]]; then
                local existing_owner=""
                existing_owner="$(ps -o user= -p "${pg_listener_pid}" 2>/dev/null | awk '{print $1}' || true)"
                die "Port ${PG_PORT} is already in use by a process owned by ${existing_owner:-uid ${listener_uid}} (pid ${pg_listener_pid}) — NOT the documentdb-local OS user. The greenfield setup wizard needs an unused per-major PG port. Choose another with --pg-port, or stop the existing service on ${PG_PORT}. (Per-major default is 9700 + PG_VERSION; 9718 for PG 18.)"
            fi
            # Else: listener IS owned by documentdb-local → our own PG.
            # Fall through; the wizard will adopt it via the live-cluster path.
        fi
    fi

    # Multi-major gateway-port collision check. When another per-major
    # install already owns GATEWAY_PORT, refusing here with an actionable
    # error is much friendlier than letting the second per-major gateway
    # service silently fail to bind. Per design §4.4 the operator owns
    # the port-allocation policy across multiple majors; we don't
    # auto-allocate but we DO catch the collision before initdb runs.
    if [[ -z "${TARGET_CLUSTER}" && "${RESTORE}" != "true" \
            && "${STATUS_ONLY}" != "true" && "${PRINT_CONFIG}" != "true" \
            && "${DRY_RUN}" != "true" \
            && -n "${PG_VERSION}" ]]; then
        local existing_state existing_pg_ver existing_port
        for existing_state in /etc/documentdb/local/*/setup.conf; do
            [[ -r "${existing_state}" ]] || continue
            existing_pg_ver="$(grep -E '^PG_VERSION=' "${existing_state}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            [[ "${existing_pg_ver}" == "${PG_VERSION}" ]] && continue
            existing_port="$(grep -E '^GATEWAY_PORT=' "${existing_state}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            if [[ -n "${existing_port}" && "${existing_port}" == "${GATEWAY_PORT}" ]]; then
                # Suggest a fresh port that doesn't collide with the
                # existing per-major install. Bias upward (current + 1)
                # so the suggestion is always a higher, unused port.
                local suggested=$((existing_port + 1))
                die "Gateway port ${GATEWAY_PORT} is already in use by the documentdb-local@${existing_pg_ver} install (recorded in ${existing_state}). Per design §4.4, side-by-side major installs require distinct public gateway ports. Re-run with --gateway-port <DIFFERENT_PORT> (e.g. --gateway-port ${suggested}) to assign a fresh port for this PG ${PG_VERSION} install."
            fi
        done
    fi

    CAN_LOAD_SAMPLE_DATA=false
    if [[ "${LOAD_SAMPLE_DATA}" == "true" ]]; then
        if [[ -z "${SAMPLE_DATA_DIR}" || ! -d "${SAMPLE_DATA_DIR}" ]]; then
            die "Sample data loading was requested but no sample-data directory could be resolved."
        fi
        if [[ -z "${INIT_DATA_SCRIPT}" || ! -x "${INIT_DATA_SCRIPT}" ]]; then
            die "Sample data loading was requested but init_documentdb_data.sh is unavailable."
        fi
        if command_exists mongosh; then
            CAN_LOAD_SAMPLE_DATA=true
        else
            die "Sample data loading was requested but mongosh is not installed. Install mongosh and retry."
        fi
    fi

    if [[ "${NO_ENABLE}" != "true" ]]; then
        local gw_listener_pid=""
        gw_listener_pid="$(find_listener_pid "${GATEWAY_PORT}")"
        if [[ -n "${gw_listener_pid}" ]]; then
            if ! listener_looks_like_gateway "${gw_listener_pid}"; then
                die "Gateway port ${GATEWAY_PORT} is already in use by a non-gateway process (pid ${gw_listener_pid}). Use --gateway-port to specify a different port, or --no-enable to skip gateway startup."
            fi
        fi
    fi

    ensure_documentdb_runtime_user
}

ensure_socket_dir_writable() {
    local socket_parent
    socket_parent="$(dirname "${PG_SOCKET_DIR}")"
    install -d -o documentdb-local -g documentdb-gateway -m 0750 "${socket_parent}"
    install -d -o documentdb-local -g documentdb-gateway -m 0750 "${PG_SOCKET_DIR}"
}

ensure_pg_ident_map() {
    # Phase 10 delegation (per packaging-design.md §4.4): the wizard now
    # delegates all hba + ident + role + connection-URL-file work to
    # documentdb-register-gateway, which owns the design-canonical map
    # name "documentdb-gateway-map" and the gateway-side OS user mapping.
    # The wizard's superuser persona is the documentdb-local OS user,
    # and peer auth maps it 1:1 to the documentdb-local PG role created
    # by initdb --username=documentdb-local — no ident map entry needed
    # for that direction. The previous inline map used the wrong name
    # ("documentdb-map") and the wrong OS user ("documentdb"); both are
    # corrected by the delegation.
    if ! command_exists documentdb-register-gateway; then
        log_warn "documentdb-register-gateway is not on PATH; falling back to inline ident-map writing. Install documentdb-postgresql-tools to use the design-canonical delegation path."
        _legacy_ensure_pg_ident_map
        return $?
    fi

    # Reviewer-flagged bug (GPT-5 iter 2): on Debian brownfield, the HBA/
    # ident files live at /etc/postgresql/<V>/<C>/, NOT under the data
    # directory. Passing --pgdata "${LIVE_DATA_DIR}" makes register-gateway
    # look for /var/lib/postgresql/<V>/<C>/pg_hba.conf which doesn't exist
    # on Debian — the call aborts before any registration completes.
    # Greenfield is unaffected because the private data dir DOES contain
    # hba/ident there.
    local -a rg_args=()
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        # Brownfield: let register-gateway re-resolve the canonical paths
        # for the named distro cluster (it has its own Debian/RHEL layout
        # logic in resolve_cluster_paths()). Pass --state-mode brownfield
        # so register-gateway writes brownfield.conf (no greenfield-PG-service
        # trigger) instead of setup.conf. Without --state-mode the tool
        # would write setup.conf, which would activate
        # documentdb-postgresql@N.service against the adopted PG, violating
        # the design's brownfield isolation. Reviewer-flagged (GPT-5 iter 3).
        rg_args+=(--target-postgres-instance "${TARGET_CLUSTER}" --state-mode brownfield)
    else
        # Greenfield: the private per-major data dir is the canonical
        # location for hba/ident (initdb places them there).
        # Reviewer-flagged (GPT-5.4 iter 11): also pass --pg-version
        # explicitly. Before this fix, register-gateway saw PG_VERSION=""
        # and silently skipped role creation, secret file, env fragment,
        # and state recording. register-gateway has its own
        # PGDATA-derivation fallback, but passing explicitly is more
        # robust and doesn't depend on the PG_VERSION file being readable.
        rg_args+=(--pgdata "${LIVE_DATA_DIR}" --pg-version "${PG_VERSION}" --state-mode greenfield)
    fi
    # Advanced-user E2E flagged (Gap #3 blocker): in brownfield mode,
    # PG_PORT and PG_SOCKET_DIR still hold the GREENFIELD defaults
    # (9700+VERSION and /run/documentdb-local/N/postgresql) because
    # resolve_runtime_paths computed them before brownfield discovery.
    # If we forward those to register-gateway, the explicit
    # --socket-dir/--pg-port override register-gateway's own auto-resolve
    # from --target-postgres-instance, and register-gateway tries to
    # connect at the wrong place. For brownfield, let
    # register-gateway resolve everything from --target-postgres-instance.
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        rg_args+=(--pg-owner "${PG_OWNER}" --yes)
    else
        rg_args+=(
            --socket-dir "${PG_SOCKET_DIR}"
            --pg-port "${PG_PORT}"
            --pg-owner "${PG_OWNER}"
            --yes
        )
    fi
    # Reviewer-flagged (GPT-5.5 iter 9): the per-major gateway-local@N.service
    # only loads its EnvironmentFile (per-major gateway.env); it does NOT
    # load SetupConfiguration.json. So the operator's --listen-port has to
    # land in the per-major env file. Thread it through register-gateway.
    if [[ -n "${GATEWAY_PORT}" ]]; then
        rg_args+=(--listen-addr ":${GATEWAY_PORT}")
    fi
    # Standalone defaults to TLS auto-gen per design §4.3 — UNLESS the
    # operator explicitly passed --tls-cert/--tls-key (in which case
    # validate_required_arguments already pinned TLS_AUTO_GENERATE=false)
    # or explicitly passed --tls-auto-generate true|false. The default
    # path is unchanged: auto-generate=true so a fresh install gets a
    # working TLS endpoint without operator intervention.
    if [[ -n "${TLS_CERT_FILE}" && -n "${TLS_KEY_FILE}" ]]; then
        rg_args+=(--tls-cert "${TLS_CERT_FILE}" --tls-key "${TLS_KEY_FILE}")
    fi
    if [[ -n "${TLS_AUTO_GENERATE}" ]]; then
        rg_args+=(--tls-auto-generate "${TLS_AUTO_GENERATE}")
    else
        rg_args+=(--tls-auto-generate true)
    fi
    if [[ "${VERBOSE}" == "true" ]]; then
        rg_args+=(--verbose)
    fi
    log_info "Delegating pg_hba.conf / pg_ident.conf / gateway role / connection-URL file to documentdb-register-gateway."
    # Real-user E2E flagged (Gap #11 blocker): the previous version invoked
    # register-gateway through confirm_or_apply, which streams stdout/stderr
    # to the terminal but does not retain a captured buffer. When the
    # delegated tool fails, the operator sees the wizard's
    # "see above for details" but the most recent line on screen may be
    # truncated by terminal scrollback (or by `tail` consumers). Capture
    # the full delegated output and re-emit it on failure with a clear
    # leading marker so the actual error is unmissable in any output sink.
    # Advanced-user E2E flagged: detect whether hba/ident already contain
    # the documentdb-gateway-map block BEFORE invoking register-gateway —
    # if both files do, the operator already reloaded PG after a prior
    # run and we should skip the reload-required exit afterward. (We
    # cannot rely on file md5 because prepend_with_managed_block adds a
    # trailing newline each invocation, so hashes always differ even
    # when content is semantically equivalent.)
    local _hba_had_block=false _ident_had_block=false
    if [[ -r "${LIVE_HBA_FILE}" ]] && grep -Fq 'documentdb-gateway-map' "${LIVE_HBA_FILE}" 2>/dev/null; then
        _hba_had_block=true
    fi
    if [[ -r "${LIVE_IDENT_FILE}" ]] && grep -Fq 'documentdb-gateway-map' "${LIVE_IDENT_FILE}" 2>/dev/null; then
        _ident_had_block=true
    fi
    local rg_log
    create_temp_file rg_log
    if ! confirm_or_apply "Run documentdb-register-gateway --yes against ${LIVE_DATA_DIR}" \
            _run_register_gateway_capturing "${rg_log}" "${rg_args[@]}"; then
        echo "" >&2
        echo "==== documentdb-register-gateway FAILED — full output below ====" >&2
        cat "${rg_log}" >&2
        echo "==== end of documentdb-register-gateway output ====" >&2
        die "documentdb-register-gateway failed; see above for details."
    fi
    # If both files already contained the managed block BEFORE this
    # invocation, then any "writes" register-gateway just did were
    # idempotent re-writes (or trivial whitespace) and PG already has
    # the rules loaded — skip the reload-required exit.
    if [[ "${_hba_had_block}" == "true" && "${_ident_had_block}" == "true" ]]; then
        log_verbose "pg_hba/pg_ident already had documentdb-gateway-map block before this run; skipping reload-required exit."
        PG_RELOAD_CHANGED=false
    else
        PG_RELOAD_CHANGED=true
    fi
}

# Helper: run register-gateway and tee its combined output to ${log_file}
# so the wizard can re-emit it on failure (Gap #11 fix).
_run_register_gateway_capturing() {
    local log_file="$1"; shift
    DOCUMENTDB_REGISTER_GATEWAY_QUIET=1 documentdb-register-gateway "$@" 2>&1 | tee "${log_file}"
    # Preserve register-gateway's exit code (not tee's).
    return "${PIPESTATUS[0]}"
}

# Inline fallback (Phase 10 escape hatch). Kept for dev environments where
# documentdb-register-gateway is not installed. The map name and OS users
# used here intentionally match the pre-Phase-10 behavior; this path is
# deprecated and will be removed once tools is hard-Depends across all
# packaging variants.
_legacy_ensure_pg_ident_map() {
    local ident_file="${LIVE_IDENT_FILE}"
    local unsafe_legacy_map_line="documentdb-map   documentdb   all"
    local map_line=""
    local temp_file=""
    local desired_block=""
    local existing_block=""
    local changed=false
    local -a map_lines=(
        "documentdb-map   documentdb   documentdb"
        "documentdb-map   documentdb   +documentdb_readonly_role"
        "documentdb-map   documentdb   +documentdb_readwrite_role"
        "documentdb-map   documentdb   +documentdb_admin_role"
        "documentdb-map   documentdb-local   documentdb-local"
        "documentdb-map   documentdb-local   documentdb_bg_worker_role"
        "documentdb-map   documentdb-local   +documentdb_readonly_role"
        "documentdb-map   documentdb-local   +documentdb_readwrite_role"
        "documentdb-map   documentdb-local   +documentdb_admin_role"
        "documentdb-map   documentdb-gateway   documentdb-gateway"
        "documentdb-map   documentdb-gateway   +documentdb_readonly_role"
        "documentdb-map   documentdb-gateway   +documentdb_readwrite_role"
        "documentdb-map   documentdb-gateway   +documentdb_admin_role"
    )

    [[ -f "${ident_file}" ]] || die "PostgreSQL ident file does not exist: ${ident_file}"

    # The legacy unsafe `documentdb-map documentdb all` line was historically
    # added by older documentdb-setup versions and lives outside any managed
    # block. Strip it so the managed block becomes the sole source of truth
    # for the map; the strip is a no-op once the upgrade has been done.
    if grep -Fqx "${unsafe_legacy_map_line}" "${ident_file}" 2>/dev/null; then
        create_temp_file temp_file
        grep -Fvx "${unsafe_legacy_map_line}" "${ident_file}" > "${temp_file}" || true
        preserve_file_metadata "${ident_file}" "${temp_file}"
        mv "${temp_file}" "${ident_file}"
        changed=true
    fi

    # Build the desired managed block content (newline-joined map lines) and
    # compare against any existing managed block in the file. Any drift --
    # including a missing block, an outdated block, or the previous
    # marker-less appended-line layout removed above -- triggers a rewrite.
    # Wrapping the entries in start/end markers is what lets `apt purge` /
    # `dnf remove` cleanly strip them later via cleanup_managed_blocks in the
    # maintainer scripts; without the markers the entries would survive
    # uninstall and silently mutate an adopted cluster's pg_ident.conf.
    desired_block="$(printf '%s\n' "${map_lines[@]}")"
    desired_block="${desired_block%$'\n'}"
    existing_block="$(extract_managed_block_content "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}")"
    if [[ "${existing_block}" != "${desired_block}" ]]; then
        log_verbose "Updating pg_ident.conf managed block for documentdb peer authentication."
        rewrite_with_managed_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" "${desired_block}"
        changed=true
    fi

    # Defensive: the loop below also strips any stale duplicate map lines
    # that survived outside the managed block (e.g. an admin manually
    # copy-pasted them at some point). The managed block already provides
    # the entries; any duplicate outside the block is now redundant.
    for map_line in "${map_lines[@]}"; do
        if has_line_outside_managed_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" "${map_line}"; then
            create_temp_file temp_file
            grep -Fvx "${map_line}" "${ident_file}" > "${temp_file}" || true
            preserve_file_metadata "${ident_file}" "${temp_file}"
            mv "${temp_file}" "${ident_file}"
            # Re-establish the managed block after stripping the duplicate so
            # the map entries inside the block are not collateral damage.
            rewrite_with_managed_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" "${desired_block}"
            changed=true
        fi
    done

    if [[ "${changed}" == "true" ]]; then
        PG_RELOAD_CHANGED=true
    fi
}

# Helpers used by confirm_or_apply for the greenfield initdb path.
# Separated so the consent prompt covers the whole logical step rather than
# individual mkdir/chown calls.
_greenfield_create_data_dir() {
    # The script-level `umask 077` (line 17) makes `mkdir -p ${DATA_DIR}`
    # create every intermediate dir mode 0700 owned by root. The data
    # dir itself is chown'd to documentdb-local + chmod'd 0700 below, but
    # the PER-MAJOR PARENT (/var/lib/documentdb-local/N) stays mode 0700
    # root-owned. When the wizard then `runuser`s to documentdb-local to
    # run initdb, the unprivileged documentdb-local process cannot
    # traverse that parent (no `x` bit for it) and initdb fails with
    # "could not access directory ${DATA_DIR}: Permission denied".
    #
    # On a real bare-metal install the parent dir is already created by
    # the documentdb-N package's tmpfiles.d, owned by documentdb-local —
    # so the bug only surfaces when the data dir is non-default OR the
    # tmpfiles.d entry hasn't run yet (typical for `--data-dir`
    # overrides and for fresh container installs where systemd is
    # unavailable to run systemd-tmpfiles).
    #
    # Use `install -d` (which ignores umask and lets us pin mode +
    # owner up front) for the per-major parent, then mkdir -p the data
    # dir itself. install -d is idempotent so re-running the wizard is
    # safe.
    install -d -m 0755 -o documentdb-local -g documentdb-local \
        "$(dirname "${DATA_DIR}")"
    mkdir -p "${DATA_DIR}"
    chown -R documentdb-local:documentdb-local "${DATA_DIR}"
    chmod 700 "${DATA_DIR}"
    ensure_socket_dir_writable
}

_greenfield_run_initdb() {
    run_as_user documentdb-local \
        "${INITDB}" \
        --pgdata="${DATA_DIR}" \
        --username=documentdb-local \
        --auth-local=peer \
        --auth-host=scram-sha-256 \
        --encoding=UTF8
}

# Brownfield: skip initdb, resolve the live PostgreSQL instance the operator
# pointed us at via --target-postgres-instance N/C, set the wizard's
# LIVE_DATA_DIR / LIVE_CONFIG_FILE / LIVE_HBA_FILE / LIVE_IDENT_FILE from
# what PG itself reports.
#
# The wizard never runs initdb here, never chowns the data dir, and never
# starts/stops the system PostgreSQL service. It only writes managed blocks
# inside config files (delegated to documentdb-tune /
# documentdb-register-gateway) and creates the extension + admin user.
prepare_brownfield_instance() {
    [[ -n "${TARGET_CLUSTER}" ]] || die "prepare_brownfield_instance called without --target-postgres-instance."

    # Strict VERSION/NAME validation. Without this, --target-postgres-instance
    # 18 (no slash) would slip through and produce a broken
    # postgresql@18-18.service Requires= in the brownfield drop-in (the
    # cluster_name fallback to "main" only kicks in for empty-after-slash,
    # not no-slash-at-all, because both ${TARGET_CLUSTER%%/*} and
    # ${TARGET_CLUSTER#*/} return the whole string when there is no slash).
    if [[ "${TARGET_CLUSTER}" != */* ]]; then
        die "--target-postgres-instance must be VERSION/NAME (e.g., 18/main); got ${TARGET_CLUSTER}."
    fi

    local target_pg_version="${TARGET_CLUSTER%%/*}"
    local target_cluster_name="${TARGET_CLUSTER#*/}"
    [[ -n "${target_cluster_name}" ]] || target_cluster_name="main"
    [[ "${target_pg_version}" =~ ^[0-9]+$ ]] || die "--target-postgres-instance must be VERSION/NAME (e.g., 18/main); got ${TARGET_CLUSTER}."
    # Cluster names are PostgreSQL identifiers per Debian's postgresql-common:
    # the first character may be alphanumeric, then any of letters / digits /
    # underscore / dash. Reject anything else so it can't escape into systemd
    # unit names or shell args. Matches pg_createcluster's own constraint —
    # don't be stricter than the underlying tool, or operators with valid
    # existing clusters like "1replica" can't adopt them.
    [[ "${target_cluster_name}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
        || die "--target-postgres-instance cluster name must match [A-Za-z0-9][A-Za-z0-9_-]*; got '${target_cluster_name}'."

    log_info "Brownfield adoption: targeting PostgreSQL instance ${target_pg_version}/${target_cluster_name}."

    # Pin wizard state to the targeted PG version (overrides auto-detect).
    PG_VERSION="${target_pg_version}"

    # Re-resolve PG binaries for the targeted major; die if the matching
    # postgresql-N package isn't installed.
    set_postgres_binary_paths "${PG_VERSION}" \
        || die "PostgreSQL ${PG_VERSION} binaries not found. Install postgresql-${PG_VERSION} first."

    # Reviewer-flagged bug (GPT-5 second pass): on Debian, refuse early when
    # the named cluster's config directory is absent. Without this, a typo
    # in --target-postgres-instance silently falls through to port 5432,
    # connects to whatever cluster is bound there, mutates THAT cluster's
    # config, and writes a systemd drop-in pointing at a non-existent
    # postgresql@<V>-<typo>.service. The result is an unbootable
    # documentdb-local@N.target on the wrong PG. RHEL has only one
    # implicit cluster per major so the analogous check is on
    # /var/lib/pgsql/<V>/data.
    if [[ -d "/etc/postgresql/${PG_VERSION}" ]]; then
        if [[ ! -d "/etc/postgresql/${PG_VERSION}/${target_cluster_name}" ]]; then
            local known_clusters
            known_clusters="$(ls -1 "/etc/postgresql/${PG_VERSION}" 2>/dev/null | tr '\n' ' ' || true)"
            die "Brownfield: PostgreSQL ${PG_VERSION} cluster '${target_cluster_name}' not found at /etc/postgresql/${PG_VERSION}/${target_cluster_name}. Known clusters for major ${PG_VERSION}: ${known_clusters:-(none)}."
        fi
    elif [[ -d "/var/lib/pgsql/${PG_VERSION}" ]]; then
        if [[ ! -d "/var/lib/pgsql/${PG_VERSION}/data" ]]; then
            die "Brownfield: PostgreSQL ${PG_VERSION} data directory not found at /var/lib/pgsql/${PG_VERSION}/data. Initialize the instance with 'postgresql-${PG_VERSION}-setup --initdb' before adopting it."
        fi
    fi

    # Resolve config paths from the live instance. We use psql via the
    # standard distro socket directory; the gateway will use its own socket
    # via DOCUMENTDB_PG_URL_FILE later.
    local distro_socket
    if [[ -d /var/run/postgresql ]]; then
        distro_socket="/var/run/postgresql"
    elif [[ -d /run/postgresql ]]; then
        distro_socket="/run/postgresql"
    else
        die "Cannot find the system PostgreSQL socket directory (/var/run/postgresql or /run/postgresql)."
    fi

    # Discover the live instance's port (defaults: 5432 unless the operator
    # overrode it via --pg-port). For multi-cluster Debian setups, the port
    # is in /etc/postgresql/N/C/postgresql.conf.
    if [[ -z "${PG_PORT_EXPLICIT:-}" || "${PG_PORT_EXPLICIT}" != "true" ]]; then
        local debian_conf="/etc/postgresql/${PG_VERSION}/${target_cluster_name}/postgresql.conf"
        if [[ -r "${debian_conf}" ]]; then
            local discovered_port
            discovered_port="$(awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2); print $2; exit}' "${debian_conf}")"
            [[ -n "${discovered_port}" ]] && PG_PORT="${discovered_port}"
        fi
        [[ -n "${PG_PORT}" ]] || PG_PORT="5432"
    fi

    LIVE_DATA_DIR="$(
        run_as_user postgres "${PSQL}" -h "${distro_socket}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW data_directory;" 2>/dev/null \
        | tr -d '[:space:]'
    )" || die "Cannot reach PostgreSQL ${PG_VERSION} at ${distro_socket}:${PG_PORT}. Is the instance running?"
    LIVE_CONFIG_FILE="$(
        run_as_user postgres "${PSQL}" -h "${distro_socket}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW config_file;" 2>/dev/null | tr -d '[:space:]'
    )"
    LIVE_HBA_FILE="$(
        run_as_user postgres "${PSQL}" -h "${distro_socket}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW hba_file;" 2>/dev/null | tr -d '[:space:]'
    )"
    LIVE_IDENT_FILE="$(
        run_as_user postgres "${PSQL}" -h "${distro_socket}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW ident_file;" 2>/dev/null | tr -d '[:space:]'
    )"
    DATA_DIR="${LIVE_DATA_DIR}"
    PG_SOCKET_DIR_BROWNFIELD="${distro_socket}"
    # Reviewer-flagged (GPT-5.5 iter 9): the wizard's downstream calls
    # (register-gateway, gateway-admin, psql ops) all consult PG_SOCKET_DIR.
    # In brownfield we MUST use the adopted system PG's socket dir, not
    # the per-major appliance socket dir (which doesn't exist when the
    # appliance PG isn't running). Override PG_SOCKET_DIR explicitly here.
    PG_SOCKET_DIR="${distro_socket}"

    # Reviewer-flagged bug (GPT-5 second pass): even with the early Debian
    # cluster-dir check, the operator may have pointed --pg-port at the wrong
    # cluster's port (or the named cluster's port file was unreadable so we
    # fell back to 5432). After the live SHOW config_file query returns,
    # cross-check that the running instance's config_file actually lives
    # under the named cluster's config dir. Without this verification, the
    # wizard would mutate cluster X's pg_hba.conf while writing a drop-in
    # that wires the gateway to postgresql@<V>-<named>.service for cluster Y.
    if [[ -d "/etc/postgresql/${PG_VERSION}/${target_cluster_name}" ]]; then
        local expected_config_dir="/etc/postgresql/${PG_VERSION}/${target_cluster_name}"
        case "${LIVE_CONFIG_FILE}" in
            "${expected_config_dir}/"*) ;;
            *)
                die "Brownfield: the live PostgreSQL ${PG_VERSION} instance at port ${PG_PORT} uses config_file=${LIVE_CONFIG_FILE}, which is NOT under ${expected_config_dir}/. Refusing to adopt the wrong cluster. Use --pg-port to target the correct cluster, or correct --target-postgres-instance."
                ;;
        esac
    fi

    # packaging-design.md §4.4 Safety Properties: "Warn loudly when adopting
    # a `postgres`-owned PostgreSQL instance (vs. an empty one we'd init
    # ourselves), explain implications, require confirmation. Don't refuse —
    # the user installed `documentdb`; that's the consent." We emit an
    # explicit warning so an interactive operator pauses to read it; the
    # subsequent per-step confirm_or_apply prompts still gate each invasive
    # change. In --yes mode the operator has already given upfront consent
    # (CI / scripted install), so we log loudly and proceed.
    local live_owner_uid live_owner
    live_owner_uid="$(stat -c '%u' "${LIVE_DATA_DIR}" 2>/dev/null || true)"
    live_owner="$(stat -c '%U' "${LIVE_DATA_DIR}" 2>/dev/null || true)"
    if [[ -n "${live_owner_uid}" && "${live_owner_uid}" -ne 0 ]]; then
        log_warn "Adopting an existing PostgreSQL instance owned by OS user '${live_owner:-uid ${live_owner_uid}}' (data_directory ${LIVE_DATA_DIR})."
        log_warn "  This wizard will write managed blocks to that instance's postgresql.conf, pg_hba.conf, and pg_ident.conf,"
        log_warn "  create the documentdb-gateway PG role, and install a systemd drop-in that ties documentdb-gateway-local@${PG_VERSION}.service"
        log_warn "  to the adopted PG service. All changes are reversible via 'documentdb-setup --restore' or 'apt purge documentdb-${PG_VERSION}'."
        log_warn "  Existing PostgreSQL data, users, and application schemas are preserved; only managed-block edits and a few new role grants are added."
        if [[ "${YES}" != "true" ]]; then
            local reply=""
            printf 'Adopt this PostgreSQL instance and continue? [y/N] ' >&2
            IFS= read -r reply || reply=""
            case "${reply}" in
                y|Y|yes|YES) ;;
                *) die "Aborted at brownfield-adoption confirmation. Re-run with --yes to skip this prompt." ;;
            esac
        else
            log_warn "Proceeding non-interactively because --yes was given."
        fi
    fi

    # Brownfield's PG runs under the distro's "postgres" OS user; that's
    # who we connect as for CREATE EXTENSION + admin bootstrap.
    PG_OWNER="postgres"

    log_info "Brownfield instance discovered:"
    log_info "  data_directory: ${LIVE_DATA_DIR}"
    log_info "  config_file:    ${LIVE_CONFIG_FILE}"
    log_info "  hba_file:       ${LIVE_HBA_FILE}"
    log_info "  ident_file:     ${LIVE_IDENT_FILE}"
    log_info "  port:           ${PG_PORT}"
    log_info "  socket dir:     ${distro_socket}"
}

prepare_self_managed_cluster() {
    local existing_data_version=""
    local current_preload=""
    local merged_preload=""
    local live_listener_pid=""

    PG_OWNER="documentdb-local"
    LIVE_DATA_DIR="${DATA_DIR}"
    LIVE_CONFIG_FILE="${DATA_DIR}/postgresql.conf"
    LIVE_HBA_FILE="${DATA_DIR}/pg_hba.conf"
    LIVE_IDENT_FILE="${DATA_DIR}/pg_ident.conf"

    if [[ -d "${DATA_DIR}" && ! -f "${DATA_DIR}/PG_VERSION" && -n "$(ls -A "${DATA_DIR}" 2>/dev/null || true)" ]]; then
        die "Data directory ${DATA_DIR} exists but is not a valid PostgreSQL cluster."
    fi

    if [[ -f "${DATA_DIR}/PG_VERSION" ]]; then
        existing_data_version="$(head -n 1 "${DATA_DIR}/PG_VERSION" | cut -d'.' -f1)"
        if [[ "${existing_data_version}" != "${PG_VERSION}" ]]; then
            die "Existing data directory ${DATA_DIR} was initialized for PostgreSQL ${existing_data_version}, not ${PG_VERSION}."
        fi
    else
        live_listener_pid="$(find_listener_pid "${PG_PORT}")"
        if [[ -n "${live_listener_pid}" ]]; then
            if ! listener_looks_like_postgres "${live_listener_pid}"; then
                die "Port ${PG_PORT} is in use by a non-PostgreSQL process."
            fi
            die "Port ${PG_PORT} is already in use by PostgreSQL, but ${DATA_DIR} is not an initialized DocumentDB data directory. Use --data-dir for the running cluster, use --pg-port for a new cluster, or stop the existing PostgreSQL process."
        fi

        confirm_or_apply "Create per-major data directory ${DATA_DIR} owned by documentdb-local:documentdb-local" \
            _greenfield_create_data_dir
        confirm_or_apply "Initialize PostgreSQL ${PG_VERSION} cluster in ${DATA_DIR} (initdb --username=documentdb-local)" \
            _greenfield_run_initdb
    fi

    live_listener_pid="$(find_listener_pid "${PG_PORT}")"
    if [[ -n "${live_listener_pid}" ]]; then
        resolve_live_cluster_metadata "${PG_PORT}"
        current_preload="${LIVE_PRELOAD_LIBRARIES}"
    else
        current_preload="$(read_shared_preload_libraries_from_file "${LIVE_CONFIG_FILE}")"
    fi

    # Issue 1 (Phase 11): apply_managed_postgres_settings (postgresql.conf)
    # may be called now because writing to a stopped PG instance's
    # postgresql.conf is safe. But hba/ident/role/conn-file delegation
    # to documentdb-register-gateway must wait until after PG is started,
    # because register-gateway connects to the live instance to create
    # the gateway PG role and verify the extension. The wizard's main()
    # now calls register_gateway_after_pg_running() after
    # start_or_restart_postgres for this reason.
    merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
    if [[ "${current_preload}" != "${merged_preload}" ]]; then
        PG_CONFIG_CHANGED=true
    fi

    apply_managed_postgres_settings "${LIVE_CONFIG_FILE}" "${LIVE_HBA_FILE}" "${merged_preload}" "off"
}

# Issue 1 (Phase 11): invoked AFTER start_or_restart_postgres so that
# documentdb-register-gateway can connect to the live PG instance. Also
# passes the PG owner (documentdb-local for greenfield, postgres for
# brownfield) so register-gateway connects as the right OS user.
register_gateway_after_pg_running() {
    ensure_pg_ident_map
}

wait_for_postgres() {
    local attempt=""
    for attempt in $(seq 1 60); do
        if run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -qAt -v ON_ERROR_STOP=1 -c "SELECT 1" >/dev/null 2>&1; then
            log_verbose "PostgreSQL became ready on attempt ${attempt}."
            return 0
        fi
        sleep 1
    done

    die "PostgreSQL did not become ready on localhost:${PG_PORT} within 60 seconds."
}

start_or_restart_postgres() {
    # Brownfield: never touch the system PostgreSQL service. We print the
    # required reload/restart command and rely on the operator to execute
    # it once they've inspected the config block we wrote.
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        local reload_hint=""
        if [[ -d "/etc/postgresql/${PG_VERSION}" ]]; then
            reload_hint="sudo systemctl reload postgresql@${PG_VERSION}-${TARGET_CLUSTER#*/}"
        else
            reload_hint="sudo systemctl reload postgresql-${PG_VERSION}"
        fi
        if [[ "${PG_CONFIG_CHANGED}" == "true" ]]; then
            # Reviewer-flagged (GPT-5.5 iter 10): pg_documentdb is a
            # shared_preload_libraries extension — it won't load until the
            # postmaster restarts. We wrote shared_preload_libraries via
            # documentdb-tune, but the postmaster is still the OLD one.
            # If we proceed to CREATE EXTENSION documentdb here, it FAILS
            # with "extension documentdb must be loaded via shared_preload_libraries".
            # The operator is left with a half-configured install
            # (managed blocks in hba/ident/conf, gateway role, drop-in)
            # but no extension, no admin user, and no working gateway.
            # Stop here and tell the operator to restart PG + re-run.
            log_warn "Brownfield mode: PostgreSQL must be restarted to pick up shared_preload_libraries changes."
            log_warn "    Run: ${reload_hint/reload/restart}"
            log_warn ""
            log_warn "documentdb-setup is exiting BEFORE running CREATE EXTENSION because"
            log_warn "pg_documentdb is a preload library and will not load until the"
            log_warn "postmaster has restarted. Re-run this command after PostgreSQL has"
            log_warn "been restarted; the second run will detect that the managed blocks"
            log_warn "are already in place and proceed to CREATE EXTENSION + admin bootstrap."
            log_warn ""
            log_warn "Steps:"
            log_warn "  1. ${reload_hint/reload/restart}"
            # Reconstruct a suggested re-run command using the original
            # operator-supplied flags. YES is the literal string "true" or
            # "false" (set in parse_arguments), NOT empty/non-empty — so
            # use a value check, not ${YES:+...}.
            local rerun_suffix=""
            [[ -n "${USERNAME}" ]] && rerun_suffix+=" --admin-user ${USERNAME}"
            [[ "${YES}" == "true" ]] && rerun_suffix+=" --yes"
            log_warn "  2. sudo documentdb-setup --target-postgres-instance ${TARGET_CLUSTER}${rerun_suffix}"
            exit 0
        elif [[ "${PG_RELOAD_CHANGED}" == "true" ]]; then
            # Reviewer-flagged (external review iter 18): the prior
            # implementation only LOGGED a reload hint and then
            # continued into create_required_extensions_and_users +
            # start_gateway. The gateway authenticates as the
            # documentdb-gateway PG role via the new pg_hba.conf entry
            # we just wrote — but until PG reloads, that entry is not
            # active, so the gateway cannot connect. We have already
            # mutated pg_hba/pg_ident, so the operator has implicitly
            # consented to those changes; reload is non-disruptive
            # (in-flight queries are not interrupted) and applies the
            # rules we wrote. Use confirm_or_apply so --yes/--dry-run
            # gates still work and the operator can refuse.
            local pg_unit_name=""
            if [[ -d "/etc/postgresql/${PG_VERSION}" ]]; then
                pg_unit_name="postgresql@${PG_VERSION}-${TARGET_CLUSTER#*/}.service"
            else
                pg_unit_name="postgresql-${PG_VERSION}.service"
            fi
            if has_systemd_unit_file "${pg_unit_name}"; then
                confirm_or_apply "Reload ${pg_unit_name} to pick up hba/ident changes (non-disruptive)" \
                    systemctl reload "${pg_unit_name}"
            else
                # No systemd / unit not installed (manual pg_ctl
                # installs). Fall back to exit-and-rerun symmetry with
                # the restart-required path: print the hint, exit 0,
                # and let the operator reload + re-run.
                log_warn "Brownfield mode: PostgreSQL must be reloaded to pick up hba/ident changes."
                log_warn "    Run: ${reload_hint}"
                log_warn ""
                log_warn "documentdb-setup is exiting BEFORE starting the gateway because"
                log_warn "the new pg_hba.conf/pg_ident.conf rules are not active yet;"
                log_warn "the gateway would fail to authenticate as the documentdb-gateway"
                log_warn "PG role. Re-run this command after PostgreSQL has been reloaded."
                log_warn ""
                local rerun_suffix=""
                [[ -n "${USERNAME}" ]] && rerun_suffix+=" --admin-user ${USERNAME}"
                [[ "${YES}" == "true" ]] && rerun_suffix+=" --yes"
                log_warn "  1. ${reload_hint}"
                log_warn "  2. sudo documentdb-setup --target-postgres-instance ${TARGET_CLUSTER}${rerun_suffix}"
                exit 0
            fi
        fi
        wait_for_postgres
        return 0
    fi

    log_info "Starting the self-managed PostgreSQL instance in ${DATA_DIR} (per-major templated unit)."
    ensure_socket_dir_writable

    local pg_unit="documentdb-postgresql@${PG_VERSION}.service"

    # Per design §4.4, the stand-alone package exposes a per-major
    # templated PG unit (documentdb-postgresql@N.service) wired via the
    # per-major target documentdb-local@N.target. We always prefer it
    # when systemd is available and the unit file is shipped.
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "${pg_unit}"; then
        confirm_or_apply "Enable ${pg_unit} (per-major templated PG service)" \
            systemctl enable "${pg_unit}" >/dev/null
        if systemctl is-active --quiet "${pg_unit}"; then
            if [[ "${PG_CONFIG_CHANGED}" == "true" ]]; then
                confirm_or_apply "Restart ${pg_unit} to apply shared_preload_libraries changes" \
                    systemctl restart "${pg_unit}"
            elif [[ "${PG_RELOAD_CHANGED}" == "true" ]]; then
                confirm_or_apply "Reload ${pg_unit} to apply hba/ident changes" \
                    systemctl reload-or-restart "${pg_unit}"
            fi
        else
            confirm_or_apply "Start ${pg_unit}" \
                systemctl start "${pg_unit}"
        fi
    else
        # Dev / non-systemd fallback: drive pg_ctl directly. Same OS user
        # as the templated unit so the data directory ownership matches.
        if run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" status >/dev/null 2>&1; then
            if [[ "${PG_CONFIG_CHANGED}" == "true" ]]; then
                log_info "Configuration changed; restarting PostgreSQL to apply new settings."
                run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" -w restart
            elif [[ "${PG_RELOAD_CHANGED}" == "true" ]]; then
                log_info "Authentication mapping changed; reloading PostgreSQL configuration."
                run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" reload
            fi
        else
            run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" -l "${DATA_DIR}/pglog.log" -w start
        fi
    fi

    wait_for_postgres
}

reload_self_managed_postgres_auth_mapping() {
    [[ "${PG_RELOAD_CHANGED}" == "true" ]] || return 0

    log_info "Authentication mapping changed; reloading PostgreSQL configuration."
    local pg_unit="documentdb-postgresql@${PG_VERSION}.service"
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "${pg_unit}" \
            && systemctl is-active --quiet "${pg_unit}"; then
        confirm_or_apply "Reload ${pg_unit} to apply hba/ident changes" \
            systemctl reload-or-restart "${pg_unit}"
    else
        run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" reload
    fi
    PG_RELOAD_CHANGED=false
}

create_required_extensions_and_users() {
    log_info "Creating required extensions and roles."

    confirm_or_apply "Run CREATE EXTENSION documentdb CASCADE in the postgres database" \
        _create_documentdb_extension_inline

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        confirm_or_apply "Run CREATE EXTENSION documentdb_extended_rum CASCADE in the postgres database" \
            _create_extended_rum_extension_inline
    fi

    if run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 -v role_name="${USERNAME}" <<'SQL' | grep -q '^1$'; then
SELECT 1 FROM pg_roles WHERE rolname = :'role_name';
SQL
        # Advanced-user E2E flagged (Gap #4): the prior implementation
        # short-circuited here without applying the operator's new
        # password. After a `--restore + re-setup --admin-password-stdin
        # <new-pw>`, mongosh login with new-pw failed silently because
        # the wizard never updated the password. Fix: if the operator
        # provided a fresh password, push it through documentdb_api.update_user.
        if [[ -n "${PASSWORD:-}" ]]; then
            log_info "User ${USERNAME} already exists; resetting password via documentdb_api.update_user()."
            confirm_or_apply "Reset password for existing admin user '${USERNAME}'" \
                reset_documentdb_user_password "${PG_OWNER}" "${PG_PORT}" "${USERNAME}" "${PASSWORD}"
        else
            log_info "User ${USERNAME} already exists; no password provided, leaving credentials unchanged."
        fi
        return 0
    fi

    confirm_or_apply "Bootstrap first admin user '${USERNAME}' via documentdb_api.create_user()" \
        create_documentdb_user "${PG_OWNER}" "${PG_PORT}" "${USERNAME}" "${PASSWORD}"
}

# Companion to create_documentdb_user, used when the user already exists
# and the operator supplied a fresh password (Gap #4 fix).
reset_documentdb_user_password() {
    local pg_owner="$1"
    local pg_port="$2"
    local username="$3"
    local password="$4"
    local bson_file
    create_temp_file bson_file
    jq -cn \
        --arg user "${username}" \
        --arg pwd "${password}" \
        '{updateUser: $user, pwd: $pwd}' > "${bson_file}"
    chown "${pg_owner}" "${bson_file}" 2>/dev/null || true
    run_as_user "${pg_owner}" env "BSON_FILE=${bson_file}" \
        "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${pg_port}" \
        -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
\set bson_arg `cat "$BSON_FILE"`
SELECT documentdb_api.update_user(:'bson_arg'::documentdb_core.bson);
SQL
}

# Real-user E2E flagged (Gap #3 blocker): documentdb-register-gateway runs
# BEFORE CREATE EXTENSION on the greenfield path, so its IF EXISTS GRANT of
# documentdb_admin_role / documentdb_readwrite_role / documentdb_readonly_role
# to the gateway PG role is a silent no-op (the group roles do not exist
# yet). After CREATE EXTENSION creates the groups, nothing re-runs the
# GRANT and the gateway then panics on first start with PG error 42501
# (insufficient_privilege at aclchk.c).
#
# Fix: re-run the grants here, AFTER CREATE EXTENSION. Idempotent and a
# no-op on re-runs because GRANT-to-existing-membership succeeds silently.
# Wrapped in confirm_or_apply so --dry-run and the interactive consent
# gate stay consistent with every other invasive step in the wizard.
grant_gateway_role_memberships() {
    confirm_or_apply "GRANT documentdb_admin_role + readwrite + readonly to the documentdb-gateway PG role (required after CREATE EXTENSION; first start otherwise fails with code=42501)" \
        _grant_gateway_role_memberships_inline
}

_grant_gateway_role_memberships_inline() {
    run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    grp text;
BEGIN
    -- Only grant if both the group and gateway role exist; first dev
    -- environments without the gateway runtime package skip cleanly.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'documentdb-gateway') THEN
        RAISE NOTICE 'documentdb-gateway role not present; skipping group grants (install documentdb-gateway package + run documentdb-register-gateway first).';
        RETURN;
    END IF;

    FOREACH grp IN ARRAY ARRAY['documentdb_admin_role','documentdb_readwrite_role','documentdb_readonly_role']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = grp) THEN
            EXECUTE format('GRANT %I TO %I', grp, 'documentdb-gateway');
        ELSE
            RAISE NOTICE 'Skipping GRANT % - role does not exist yet (CREATE EXTENSION documentdb did not run).', grp;
        END IF;
    END LOOP;
END
$$;
SQL
}

# Helpers used by confirm_or_apply so CREATE EXTENSION steps go through
# the consent gate. Heredoc-style SQL invocations can't be passed
# verbatim as "$@" args, so they live in tiny wrappers.
_create_documentdb_extension_inline() {
    run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
SQL
}

_create_extended_rum_extension_inline() {
    run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
SQL
}

update_gateway_configuration() {
    # On per-major Workflow C installs the canonical config source is
    # the per-major /etc/documentdb/local/N/gateway.env (loaded by the
    # systemd unit and the /usr/bin/documentdb-gateway wrapper). The
    # singleton JSON at /etc/documentdb/gateway/SetupConfiguration.json
    # is a transitional compat shim per design §4.3 and MUST NOT be
    # rewritten with per-major-specific PostgresPort/GatewayListenPort/
    # PostgresHostName values, because on multi-major hosts the LAST
    # wizard to run would clobber the singleton with its own ports,
    # leaving earlier majors' gateways unable to bind. Stamp the JSON
    # only for non-per-major (Workflow B) flows.
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ \
            && -f "/etc/documentdb/local/${PG_VERSION}/gateway.env" ]]; then
        log_verbose "Skipping update of singleton SetupConfiguration.json on per-major install; env file is authoritative."
        # Defensive cleanup: strip stale per-major connection fields
        # from the singleton JSON. A prior wizard run for a different
        # major may have left them set, which would leak into Workflow B
        # callers or into the daemon's JSON-then-env precedence merge.
        if command_exists jq && [[ -f "${CONFIG_FILE}" ]]; then
            local cleaned_tmp=""
            create_temp_file cleaned_tmp
            if jq 'del(.PostgresPort, .GatewayListenPort, .PostgresHostName, .PostgresSystemUser, .PostgresDataUser, .PostgresDataUserPassword)' \
                    "${CONFIG_FILE}" > "${cleaned_tmp}" 2>/dev/null; then
                preserve_file_metadata "${CONFIG_FILE}" "${cleaned_tmp}"
                mv "${cleaned_tmp}" "${CONFIG_FILE}"
                log_verbose "Stripped per-major connection fields from singleton SetupConfiguration.json."
            fi
        fi
        return 0
    fi
    log_info "Updating gateway configuration at ${CONFIG_FILE}."
    update_json_file "${CONFIG_FILE}"
}

wait_for_gateway_ready() {
    # Reviewer-flagged (external review iter 17): caller passes the
    # systemd unit name that was actually started (per-major templated
    # unit, non-templated, or the empty string for the nohup fallback)
    # so the failure-hint journalctl command points at the right unit.
    # Previously this was hardcoded to "documentdb-gateway", which is
    # the WRONG unit when start_gateway selected
    # documentdb-gateway-local@N.service.
    local running_unit="${1:-}"
    local attempt=""
    for attempt in $(seq 1 60); do
        if timeout 2 bash -c "echo >/dev/tcp/127.0.0.1/${GATEWAY_PORT}" >/dev/null 2>&1; then
            log_verbose "Gateway became ready on attempt ${attempt}."
            return 0
        fi
        sleep 1
    done

    local hint=""
    if [[ -n "${running_unit}" ]]; then
        hint="Check logs: journalctl -u ${running_unit} --no-pager -n 20"
    else
        hint="Check logs under /var/lib/documentdb-local/${PG_VERSION}/gateway/ or /var/lib/documentdb-gateway/"
    fi
    die "The gateway did not become ready on localhost:${GATEWAY_PORT} within 60 seconds. ${hint}"
}

stop_gateway_process() {
    local pid="$1"
    local port="$2"

    kill "${pid}"
    if wait_for_listener_to_clear "${port}" 30; then
        return 0
    fi

    log_warn "Process ${pid} did not stop after SIGTERM; sending SIGKILL."
    kill -KILL "${pid}" 2>/dev/null || true
    if ! wait_for_listener_to_clear "${port}" 10; then
        log_warn "Process ${pid} did not stop even after SIGKILL."
        return 1
    fi
}

start_gateway() {
    local existing_gateway_pid=""

    # Per design §4.4, the per-major templated gateway unit is the public
    # day-2 surface. We prefer it whenever a PG_VERSION is known and the
    # unit file is shipped.
    local gw_unit=""
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        gw_unit="documentdb-gateway-local@${PG_VERSION}.service"
    fi
    # Fallback to the non-templated unit if the per-major template isn't
    # available (Workflow B / pre-Phase-10 installs).
    if [[ -z "${gw_unit}" ]] || ! has_systemd_unit_file "${gw_unit}"; then
        gw_unit="documentdb-gateway.service"
    fi

    if [[ "${NO_ENABLE}" == "true" ]]; then
        # The operator asked us not to (re)enable the gateway. But if a
        # previously running gateway was torn down by Requires= dependency
        # propagation when we restarted PostgreSQL above, restore it so
        # --no-enable does not turn into "stop the gateway as a side effect."
        if [[ "${GATEWAY_WAS_ACTIVE}" == "true" ]] \
                && [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] \
                && has_systemd_unit_file "${gw_unit}" \
                && ! systemctl is-active --quiet "${gw_unit}"; then
            log_info "Restoring previously running gateway after PostgreSQL restart (--no-enable preserves prior state)."
            systemctl start "${gw_unit}"
            wait_for_gateway_ready "${gw_unit}"
        else
            log_info "Skipping gateway startup because --no-enable was requested."
        fi
        return 0
    fi

    if has_systemd_unit_file "${gw_unit}"; then
        # If a manually-started gateway is occupying the port, stop it before
        # handing control to systemd to avoid a port conflict.
        existing_gateway_pid="$(find_listener_pid "${GATEWAY_PORT}")"
        if [[ -n "${existing_gateway_pid}" ]]; then
            if ! systemctl is-active --quiet "${gw_unit}"; then
                # Listener exists but systemd doesn't own it — stop the manual process
                log_info "Stopping manually started gateway (pid ${existing_gateway_pid}) before systemd takeover."
                if ! stop_gateway_process "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
                    die "Gateway port ${GATEWAY_PORT} is still in use after stopping process ${existing_gateway_pid}."
                fi
            fi
        fi

        log_info "Starting the gateway with systemd (${gw_unit})."
        confirm_or_apply "Enable ${gw_unit}" systemctl enable "${gw_unit}" >/dev/null
        if systemctl is-active --quiet "${gw_unit}"; then
            confirm_or_apply "Restart ${gw_unit}" systemctl restart "${gw_unit}"
        else
            confirm_or_apply "Start ${gw_unit}" systemctl start "${gw_unit}"
        fi
        wait_for_gateway_ready "${gw_unit}"
        return 0
    fi

    existing_gateway_pid="$(find_listener_pid "${GATEWAY_PORT}")"
    if [[ -n "${existing_gateway_pid}" ]]; then
        if ! listener_looks_like_gateway "${existing_gateway_pid}"; then
            die "Port ${GATEWAY_PORT} is already in use by a non-gateway process."
        fi

        log_info "Restarting the manually managed gateway process on port ${GATEWAY_PORT}."
        if ! stop_gateway_process "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
            die "Gateway port ${GATEWAY_PORT} is still in use after stopping process ${existing_gateway_pid}."
        fi
    else
        # Real-user E2E flagged (Gap #5): the nohup fallback is a
        # convenience for containers and dev environments that lack
        # systemd, but a production host that silently took this path
        # would never restart the gateway on reboot. Warn loudly so the
        # operator knows the design's day-2 commands (systemctl restart /
        # status / stop) won't work for this install.
        log_warn ""
        log_warn "================================================================"
        log_warn "  Falling back to nohup (no working systemd detected)."
        log_warn "  The gateway will run only until reboot or process kill."
        log_warn "  Production hosts MUST have systemd so the per-major"
        log_warn "  documentdb-local@${PG_VERSION}.target can manage the lifecycle."
        log_warn "  This mode is intended for containers and ephemeral dev hosts."
        log_warn "================================================================"
        log_warn ""
        log_info "Starting the gateway without systemd."
    fi

    local escaped_binary escaped_config
    escaped_binary="$(printf '%q' "${GATEWAY_BINARY}")"
    escaped_config="$(printf '%q' "${CONFIG_FILE}")"

    # Source the per-major env file written by documentdb-register-gateway
    # BEFORE launching the gateway binary so DOCUMENTDB_PG_URL /
    # DOCUMENTDB_PG_URL_FILE (which pins the gateway to its dedicated
    # 'documentdb-gateway' PG role via the ident map) win over the
    # JSON's PostgresDataUser=documentdb-local. The systemd
    # documentdb-gateway-local@N.service unit loads this env file via
    # `EnvironmentFile=-` automatically; the nohup fallback path used
    # here (when systemd is unavailable, e.g. inside a Docker container)
    # has no such mechanism, so we splice it in manually.
    #
    # Without this, the gateway tries to connect as documentdb-local
    # (from the JSON's PostgresDataUser) but its peer-auth OS identity
    # is documentdb-gateway, and the ident map only authorizes
    # documentdb-gateway → (documentdb-gateway + docdb_*_role groups),
    # NOT documentdb-gateway → documentdb-local. The connection then
    # fails with `peer authentication failed for user "documentdb-local"`
    # and the gateway pool spins in a retry loop until the wizard's
    # 60s readiness wait expires.
    local per_major_env=""
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        per_major_env="/etc/documentdb/local/${PG_VERSION}/gateway.env"
    fi
    local env_source_clause=""
    if [[ -n "${per_major_env}" && -r "${per_major_env}" ]]; then
        # shellcheck disable=SC1090,SC2016
        env_source_clause="set -a && . $(printf '%q' "${per_major_env}") && set +a && "
    fi

    local gateway_runtime_user="documentdb-gateway"
    local gateway_work_dir="/var/lib/documentdb-gateway"
    if [[ -z "${env_source_clause}" ]]; then
        gateway_runtime_user="${PG_OWNER}"
        gateway_work_dir="/var/lib/documentdb-local/${PG_VERSION}/gateway"
    fi
    install -d -o "${gateway_runtime_user}" -g "${gateway_runtime_user}" -m 0750 "${gateway_work_dir}"

    local escaped_work_dir
    escaped_work_dir="$(printf '%q' "${gateway_work_dir}")"
    run_as_user_shell "${gateway_runtime_user}" \
        "cd ${escaped_work_dir} && ${env_source_clause}nohup ${escaped_binary} ${escaped_config} > ${escaped_work_dir}/gateway.log 2>&1 &"
    # nohup path has no systemd unit; empty argument switches the hint
    # to the log file path instead of journalctl.
    wait_for_gateway_ready ""
}

load_sample_data_if_requested() {
    local -a init_args=()

    if [[ "${LOAD_SAMPLE_DATA}" != "true" ]]; then
        return 0
    fi

    if [[ "${CAN_LOAD_SAMPLE_DATA}" != "true" ]]; then
        die "Sample data loading was requested but mongosh is unavailable."
    fi

    log_info "Loading packaged sample data from ${SAMPLE_DATA_DIR}."
    init_args=(
        --port "${GATEWAY_PORT}"
        --username "${USERNAME}"
        --data-path "${SAMPLE_DATA_DIR}"
    )
    if [[ "${VERBOSE}" == "true" ]]; then
        init_args+=(--verbose)
    fi

    DOCUMENTDB_PASSWORD="${PASSWORD}" \
        "${INIT_DATA_SCRIPT}" "${init_args[@]}"
}

# Reviewer-flagged (external review iter 17): the wizard previously
# enabled the individual templated services
# (documentdb-postgresql@N.service, documentdb-gateway-local@N.service)
# but never enabled documentdb-local@N.target itself. Because the
# services have WantedBy=documentdb-local@%i.target, `systemctl enable`
# on the service only creates a symlink in the target's .wants/
# directory — it does NOT enable the target itself. So at boot, the
# target never activates and the services it pulls in do not start.
# After a successful setup the services run (because the wizard
# started them transiently), but reboot loses the state.
#
# Fix: enable the per-major target so it activates at boot via its
# own WantedBy=multi-user.target, which transitively pulls in the
# PG service and gateway-local service via Wants= / After=. When the
# documentdb meta package wrapper alias documentdb-local.target exists
# (paved-road install for the public alias major), prefer that so
# day-2 systemctl commands match what the operator sees in the
# completion message.
ensure_target_enabled_at_boot() {
    [[ "${NO_ENABLE}" == "true" ]] && return 0
    [[ "${HAS_WORKING_SYSTEMD}" != "true" ]] && return 0
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0

    local per_major_target="documentdb-local@${PG_VERSION}.target"
    has_systemd_unit_file "${per_major_target}" || return 0

    local enable_target="${per_major_target}"
    if [[ "${PG_VERSION}" == "${PUBLIC_ALIAS_PG_MAJOR}" ]] \
            && has_systemd_unit_file "documentdb-local.target"; then
        enable_target="documentdb-local.target"
    fi

    if ! systemctl is-enabled --quiet "${enable_target}" 2>/dev/null; then
        confirm_or_apply "Enable ${enable_target} at boot (per design §4.4)" \
            systemctl enable "${enable_target}" >/dev/null
    else
        log_verbose "${enable_target} already enabled at boot; no change."
    fi

    # The per-major services have already been started directly by
    # start_or_restart_postgres / start_gateway above. The target itself
    # is still "inactive" because nothing requested it. Activating the
    # target now makes systemctl restart/stop/status on the target
    # behave as the print_completion_message and docs claim — without
    # this step `systemctl restart documentdb-local.target` is a no-op
    # (you can only restart what is active).
    if ! systemctl is-active --quiet "${enable_target}" 2>/dev/null; then
        confirm_or_apply "Start ${enable_target} so day-2 commands operate on the target" \
            systemctl start "${enable_target}" >/dev/null
    fi
}

print_completion_message() {
    local preferred_target="documentdb-local.target"
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] \
            && [[ "${PG_VERSION}" != "${PUBLIC_ALIAS_PG_MAJOR}" ]]; then
        preferred_target="documentdb-local@${PG_VERSION}.target"
    fi

    if [[ "${NO_ENABLE}" == "true" ]]; then
        log_success "DocumentDB PostgreSQL setup is complete."
        echo "Start the gateway manually when ready:"
        if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] \
                && [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] \
                && has_systemd_unit_file "documentdb-local@${PG_VERSION}.target"; then
            echo "  sudo systemctl enable --now ${preferred_target}"
        elif [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] \
                && [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] \
                && has_systemd_unit_file "documentdb-gateway-local@${PG_VERSION}.service"; then
            echo "  sudo systemctl enable --now documentdb-gateway-local@${PG_VERSION}.service"
        elif [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "documentdb-gateway.service"; then
            echo "  sudo systemctl enable --now documentdb-gateway.service"
        else
            echo "  sudo -u documentdb-gateway env DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/${PG_VERSION}/gateway/pg-url ${GATEWAY_BINARY} run"
        fi
        return 0
    fi

    local connect_host="localhost:${GATEWAY_PORT}"
    local connect_opts="tls=true&tlsAllowInvalidCertificates=true"
    local connect_uri
    # Build URI in parts to avoid credential-pattern false positives in secret scanners.
    # Wrap the mongodb:// URI in single quotes so a copy-paste of this
    # line into a shell preserves the `&` literally (otherwise the shell
    # backgrounds mongosh at the `&` and the rest becomes a separate
    # command). Single-quote choice also matches the documentation in
    # packaging-design.md §5 ("After any workflow"), which uses the
    # quoted form in its mongosh examples.
    # Real-user E2E flagged (Gap #8): the URI had no database segment, so a
    # newbie running `db.coll.insertOne(...)` operated on the default `test`
    # DB silently. Make the example explicit by including /test in the path
    # and pointing out how to switch DBs.
    connect_uri="mongosh 'mongodb://"
    connect_uri+="${USERNAME}:<your-password>@${connect_host}/mydb?${connect_opts}'"
    log_success "DocumentDB is ready."
    echo "Connect with:"
    echo "  ${connect_uri}"
    echo "  Replace <your-password> with the password you provided."
    echo "  Replace mydb with any DB name; a fresh DB is created on the first insert."
    echo ""

    # Important paths stanza — anchor the operator so they can find
    # logs, certs, and the data directory without grepping the source.
    # Per-major (greenfield) and brownfield differ on a couple of these
    # so we branch.
    local pg_unit="documentdb-postgresql@${PG_VERSION}.service"
    local gw_unit="documentdb-gateway-local@${PG_VERSION}.service"
    local data_dir_display="${DATA_DIR}"
    local tls_dir_display="/var/lib/documentdb-local/${PG_VERSION}/gateway/tls"
    local pg_log_hint
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        # Brownfield: PostgreSQL is the adopted system service; its log
        # location is whatever that service configured. Don't claim to
        # know where it is — point the operator at the journal.
        pg_log_hint="journalctl -u $(resolve_brownfield_pg_service_unit 2>/dev/null || echo 'postgresql@'${PG_VERSION}'-main.service')"
    else
        # Greenfield: we own the PG service. Its stderr is captured by
        # systemd journal (no -l file written; see
        # documentdb_postgresql_service.sh::start_postgres).
        pg_log_hint="journalctl -u ${pg_unit}"
    fi

    echo "Important paths:"
    echo "  PG data dir:    ${data_dir_display}"
    echo "  PG logs:        ${pg_log_hint}"
    echo "  Gateway logs:   journalctl -u ${gw_unit}"
    echo "  TLS cert/key:   ${tls_dir_display}/{cert.pem,pkey.pem}"
    echo "  Connection URL: /var/lib/documentdb-local/${PG_VERSION}/gateway/pg-url"
    echo "  State file:     /etc/documentdb/local/${PG_VERSION}/$(if [[ -n "${TARGET_CLUSTER}" ]]; then echo brownfield.conf; else echo setup.conf; fi)"
    echo ""

    echo "Day-2 commands:"
    echo "  Restart:    sudo systemctl restart ${preferred_target}"
    echo "  Status:     sudo systemctl status ${preferred_target}"
    echo "  Add user:   sudo documentdb-gateway-admin create-user --username <NAME> --password-file <FILE>"
    echo "  Undo setup: sudo documentdb-setup --restore"
    echo "  Full wipe:  sudo documentdb-local-reset --pg-version ${PG_VERSION} --confirm-destroy"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username|--admin-user)
                [[ $# -ge 2 ]] || die "--admin-user requires a value."
                USERNAME="$2"
                shift 2
                ;;
            --password-file|--admin-password-file)
                [[ $# -ge 2 ]] || die "--admin-password-file requires a value."
                PASSWORD_FILE="$2"
                shift 2
                ;;
            --admin-password-stdin)
                PASSWORD_FROM_STDIN=true
                shift
                ;;
            --tls-cert)
                [[ $# -ge 2 ]] || die "--tls-cert requires a path."
                TLS_CERT_FILE="$2"
                shift 2
                ;;
            --tls-key)
                [[ $# -ge 2 ]] || die "--tls-key requires a path."
                TLS_KEY_FILE="$2"
                shift 2
                ;;
            --tls-auto-generate)
                [[ $# -ge 2 ]] || die "--tls-auto-generate requires a value (true|false)."
                case "$2" in
                    true|false)
                        TLS_AUTO_GENERATE="$2"
                        ;;
                    *)
                        die "--tls-auto-generate must be true or false (got '$2')."
                        ;;
                esac
                shift 2
                ;;
            --pg-version)
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                PG_VERSION="$2"
                PG_VERSION_EXPLICIT=true
                shift 2
                ;;
            --pg-port)
                [[ $# -ge 2 ]] || die "--pg-port requires a value."
                PG_PORT="$2"
                PG_PORT_EXPLICIT=true
                shift 2
                ;;
            --gateway-port|--listen-port)
                [[ $# -ge 2 ]] || die "--listen-port requires a value."
                GATEWAY_PORT="$2"
                shift 2
                ;;
            --data-dir)
                [[ $# -ge 2 ]] || die "--data-dir requires a value."
                DATA_DIR="$2"
                DATA_DIR_EXPLICIT=true
                shift 2
                ;;
            --use-new-postgres-instance|--use-private-cluster)
                # --use-private-cluster is a deprecated alias for the
                # design-canonical --use-new-postgres-instance flag.
                USE_PRIVATE_CLUSTER=true
                shift
                ;;
            --target-postgres-instance|--target-cluster)
                # --target-cluster is a deprecated alias for the
                # design-canonical --target-postgres-instance flag.
                [[ $# -ge 2 ]] || die "$1 requires a value."
                TARGET_CLUSTER="$2"
                shift 2
                ;;
            --yes)
                YES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --restore)
                RESTORE=true
                shift
                ;;
            --print-config)
                PRINT_CONFIG=true
                shift
                ;;
            --status)
                STATUS_ONLY=true
                shift
                ;;
            --no-enable)
                NO_ENABLE=true
                shift
                ;;
            --skip-init-data)
                LOAD_SAMPLE_DATA=false
                shift
                ;;
            --load-sample-data)
                LOAD_SAMPLE_DATA=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    # Default PG port: 9700 + PG_VERSION (per-major). When PG_VERSION is
    # unknown at parse time, leave PG_PORT empty so the post-detect
    # recompute path (resolve_runtime_paths) fills it in after
    # detect_postgres_installation populates PG_VERSION. If detection
    # also fails, parse_arguments-time has no defensible value to use
    # — 9712 is a legacy magic number that does NOT match the design's
    # per-major promise and silently confused dry-run output.
    # Reviewer-flagged (external review iter 18): fall back to the
    # DEFAULT_PG_PORT sentinel ONLY so existing
    # `[[ PG_PORT == DEFAULT_PG_PORT ]]` checks still recognize the
    # value as "unchanged from default" and recompute it correctly
    # once PG_VERSION is known. The dry-run preview already handles
    # the "still <auto-detect>" case.
    # Reviewer-flagged (multi-model should-fix F): if PG_VERSION is still
    # empty after parse_arguments but --target-postgres-instance N/C was
    # given, derive PG_VERSION from the cluster identifier here so the
    # per-major port and data-dir defaults below resolve correctly. This
    # matches what print_config does later; doing it up front means
    # parse_arguments never falls through to the DEFAULT_PG_PORT=0
    # sentinel for a brownfield install whose major is encoded in
    # TARGET_CLUSTER. Without this hoist, the range-validation below
    # rejects the sentinel because 0 is < 1.
    if [[ -z "${PG_VERSION}" && -n "${TARGET_CLUSTER}" ]]; then
        local _derived_major="${TARGET_CLUSTER%%/*}"
        if [[ "${_derived_major}" =~ ^[0-9]+$ ]]; then
            PG_VERSION="${_derived_major}"
        fi
    fi
    if [[ -z "${PG_PORT}" ]]; then
        if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
            PG_PORT=$(( 9700 + PG_VERSION ))
        else
            PG_PORT="${DEFAULT_PG_PORT}"
        fi
    fi

    # Default data directory: per-major path if PG_VERSION is known
    if [[ -z "${DATA_DIR}" ]]; then
        if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
            DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
        else
            DATA_DIR="${DEFAULT_DATA_DIR}"
        fi
    fi

    [[ "${PG_PORT}" =~ ^[0-9]+$ ]] || die "--pg-port must be numeric."
    [[ "${GATEWAY_PORT}" =~ ^[0-9]+$ ]] || die "--listen-port must be numeric."
    # Skip the strict 1..65535 range check when PG_PORT is still the
    # sentinel — that means PG_VERSION couldn't be resolved at parse time
    # and resolve_runtime_paths will recompute the per-major port after
    # detect_postgres_installation. preflight_validation also requires
    # the extension control file, so an install with no resolvable
    # PG_VERSION will fail there with a clear error before we ever try
    # to bind to the sentinel port.
    if [[ "${PG_PORT}" != "${DEFAULT_PG_PORT}" ]] && (( PG_PORT < 1 || PG_PORT > 65535 )); then
        die "--pg-port must be between 1 and 65535."
    fi
    if (( GATEWAY_PORT < 1 || GATEWAY_PORT > 65535 )); then
        die "--listen-port must be between 1 and 65535."
    fi
    if [[ "${PG_PORT}" != "${DEFAULT_PG_PORT}" ]] && (( PG_PORT < 1024 )); then
        log_warn "Port ${PG_PORT} is a privileged port; non-root services may fail to bind."
    fi
    if (( GATEWAY_PORT < 1024 )); then
        log_warn "Port ${GATEWAY_PORT} is a privileged port; non-root services may fail to bind."
    fi
}

# --print-config: report the resolved per-major configuration the
# wizard would apply, without performing any side effects. Differs from
# --dry-run in that it focuses on the *output config* (paths, ports,
# templated-unit names) rather than enumerating *invasive steps*. Both
# are read-only and exit 0.
print_config() {
    # For brownfield, derive PG version from --target-postgres-instance
    # so the report shows the right templated unit names even when the
    # local PG binaries are not installed.
    if [[ -z "${PG_VERSION}" && -n "${TARGET_CLUSTER}" ]]; then
        PG_VERSION="${TARGET_CLUSTER%%/*}"
    fi
    # Try to detect PG so the report reflects what apply would actually
    # use. detect_postgres_installation is non-mutating (just reads
    # /usr/lib/postgresql/*/bin and /usr/pgsql-*/bin) so it does not
    # need root.
    if [[ -z "${PG_VERSION}" ]]; then
        detect_postgres_installation 2>/dev/null || true
    fi
    # Reapply the per-major default overrides; same logic as
    # resolve_runtime_paths but inlined so we don't drag in
    # require_root via preflight.
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        if [[ "${PG_PORT_EXPLICIT}" != "true" ]] \
                && { [[ -z "${PG_PORT}" ]] || [[ "${PG_PORT}" == "${DEFAULT_PG_PORT}" ]]; }; then
            PG_PORT=$(( 9700 + PG_VERSION ))
        fi
        if [[ "${DATA_DIR_EXPLICIT}" != "true" ]] \
                && { [[ -z "${DATA_DIR}" ]] || [[ "${DATA_DIR}" == "${DEFAULT_DATA_DIR}" ]]; }; then
            DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
        fi
        PG_SOCKET_DIR="/run/documentdb-local/${PG_VERSION}/postgresql"
    fi

    local v="${PG_VERSION:-<auto-detect-at-apply-time>}"
    local mode="GREENFIELD"
    local preferred_target="documentdb-local.target"
    local public_alias_value="documentdb-local.target -> documentdb-local@${PUBLIC_ALIAS_PG_MAJOR}.target"
    [[ -n "${TARGET_CLUSTER}" ]] && mode="BROWNFIELD (${TARGET_CLUSTER})"
    if [[ "${v}" =~ ^[0-9]+$ ]] && [[ "${v}" != "${PUBLIC_ALIAS_PG_MAJOR}" ]]; then
        preferred_target="documentdb-local@${v}.target"
    fi

    cat <<REPORT
documentdb-setup: resolved configuration

mode:                          ${mode}
PG version:                    ${v}
PG port:                       ${PG_PORT}
PG socket dir:                 ${PG_SOCKET_DIR}
PG data dir (greenfield):      ${DATA_DIR}
gateway port:                  ${GATEWAY_PORT}
admin user:                    ${USERNAME:-<unset>}

per-major systemd units:
  preferred day-2 target:      ${preferred_target}
  target:                      documentdb-local@${v}.target
  PG service (greenfield):     documentdb-postgresql@${v}.service
  gateway service:             documentdb-gateway-local@${v}.service
public alias:                  ${public_alias_value}

per-major state files:
  greenfield setup state:      /etc/documentdb/local/${v}/setup.conf
  brownfield setup state:      /etc/documentdb/local/${v}/brownfield.conf
  gateway env fragment:        /etc/documentdb/local/${v}/gateway.env
  connection URL file:         /var/lib/documentdb-local/${v}/gateway/pg-url

delegated tools:
  postgresql.conf writer:      documentdb-tune (--yes)
  hba/ident/role writer:       documentdb-register-gateway (--yes --pg-owner ${PG_OWNER:-documentdb-local})
REPORT
}

# --status: report the current per-major installation state. Read-only:
# does not modify anything, does not call register-gateway, does not
# initdb. Exit 0 if a healthy install is found, non-zero otherwise so
# scripts can gate on it.
status_only() {
    local v="${PG_VERSION:-}"
    if [[ -z "${v}" ]]; then
        detect_postgres_installation 2>/dev/null || true
        v="${PG_VERSION:-}"
    fi
    if [[ -z "${v}" || ! "${v}" =~ ^[0-9]+$ ]]; then
        cat <<'EOF'
documentdb-setup status: no PostgreSQL installation detected.
EOF
        return 1
    fi

    local state_file="/etc/documentdb/local/${v}/setup.conf"
    local brownfield_file="/etc/documentdb/local/${v}/brownfield.conf"
    local pg_unit="documentdb-postgresql@${v}.service"
    local gw_unit="documentdb-gateway-local@${v}.service"
    local connection_file="/var/lib/documentdb-local/${v}/gateway/pg-url"
    local mode="<not configured>"
    local pg_active="inactive"
    local gw_active="inactive"
    local listening_port="<not listening>"

    if [[ -f "${state_file}" ]]; then
        mode="greenfield"
    elif [[ -f "${brownfield_file}" ]]; then
        mode="brownfield"
    fi

    # Reviewer-flagged (GPT-5 iter 6): --status must read the persisted
    # GATEWAY_PORT from the per-major state file before probing the
    # listener. The previous implementation always probed ${GATEWAY_PORT}
    # from the CLI default (10260), so installs created with --listen-port
    # were reported as "not listening" even when healthy. Both setup.conf
    # (greenfield) and brownfield.conf persist GATEWAY_PORT.
    local persisted_state_file=""
    if [[ -f "${state_file}" ]]; then
        persisted_state_file="${state_file}"
    elif [[ -f "${brownfield_file}" ]]; then
        persisted_state_file="${brownfield_file}"
    fi
    local effective_gateway_port="${GATEWAY_PORT}"
    if [[ -n "${persisted_state_file}" ]]; then
        local persisted_port
        persisted_port="$(grep -E '^GATEWAY_PORT=' "${persisted_state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [[ -n "${persisted_port}" && "${persisted_port}" =~ ^[0-9]+$ ]]; then
            effective_gateway_port="${persisted_port}"
        fi
    fi

    # Real-user E2E flagged (Gap #7):
    #   1. Suppress "Host is down" noise from systemctl on hosts without systemd.
    #   2. /proc/net/tcp fallback when ss is absent.
    #   3. Detect a nohup-launched gateway (the wizard's fallback when
    #      systemd is missing) so --status doesn't false-negative.
    local has_systemd=0
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        has_systemd=1
    fi
    if [[ "${has_systemd}" == "1" ]]; then
        systemctl is-active --quiet "${pg_unit}" 2>/dev/null && pg_active="active"
        systemctl is-active --quiet "${gw_unit}" 2>/dev/null && gw_active="active"
    fi

    # Listener probe: prefer ss, fall back to /proc/net/tcp.
    local port_hex
    port_hex="$(printf '%04X' "${effective_gateway_port}" 2>/dev/null || echo 0000)"
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH "sport = :${effective_gateway_port}" 2>/dev/null | grep -q LISTEN; then
            listening_port="${effective_gateway_port}"
        else
            listening_port="<not listening on ${effective_gateway_port}>"
        fi
    elif [[ -r /proc/net/tcp ]]; then
        if awk -v p="${port_hex}" 'NR>1 && $4=="0A" && toupper($2) ~ p"$" {found=1} END{exit !found}' /proc/net/tcp 2>/dev/null \
                || awk -v p="${port_hex}" 'NR>1 && $4=="0A" && toupper($2) ~ p"$" {found=1} END{exit !found}' /proc/net/tcp6 2>/dev/null; then
            listening_port="${effective_gateway_port}"
        else
            listening_port="<not listening on ${effective_gateway_port}>"
        fi
    else
        listening_port="<unable to probe listeners (install iproute2)>"
    fi

    # If listener is up but systemctl said inactive, the wizard most
    # likely fell back to nohup mode (no systemd). Reflect that
    # accurately instead of a false "inactive".
    if [[ "${listening_port}" == "${effective_gateway_port}" && "${gw_active}" == "inactive" ]]; then
        gw_active="active (nohup; no systemd)"
    fi
    if [[ "${listening_port}" == "${effective_gateway_port}" && "${pg_active}" == "inactive" && "${has_systemd}" == "0" ]]; then
        # Probe PG socket as a proxy when systemd is absent.
        local pg_socket="/run/documentdb-local/${v}/postgresql"
        if [[ -S "${pg_socket}/.s.PGSQL.$(grep -E '^PG_PORT=' "${persisted_state_file:-/dev/null}" 2>/dev/null | head -1 | cut -d= -f2- || echo $((9700 + v)))" ]]; then
            pg_active="active (nohup; no systemd)"
        fi
    fi

    cat <<EOF
documentdb-setup status (PG ${v}):

mode:                          ${mode}
state file:                    ${state_file}
brownfield state file:         ${brownfield_file}
connection URL file:           ${connection_file}
${pg_unit}: ${pg_active}
${gw_unit}: ${gw_active}
gateway listener:              ${listening_port}
EOF

    # Reviewer-flagged (GPT-5.4 iter 14): the design doc (§5 line 284)
    # promises "--status … exit 0 if a healthy install is found", and
    # the function docstring says the same. The prior implementation
    # exited 0 whenever the state file existed, regardless of service
    # state or listener — so CI scripts that gated on `documentdb-setup
    # --status` would treat a stopped/broken install as healthy. The
    # contract is stricter than that:
    #   1. state file present (already required), AND
    #   2. gateway service active, AND
    #   3. effective gateway port has a listener.
    # PG service health is required only in greenfield mode — brownfield
    # adopts an externally-managed PG instance that is not under our
    # systemd unit, so we cannot reliably probe it via systemctl.
    if [[ "${mode}" == "<not configured>" ]]; then
        return 1
    fi
    if [[ "${gw_active}" != "active" && "${gw_active}" != active* ]]; then
        return 1
    fi
    if [[ "${listening_port}" != "${effective_gateway_port}" ]]; then
        return 1
    fi
    if [[ "${mode}" == "greenfield" && "${pg_active}" != "active" && "${pg_active}" != active* ]]; then
        return 1
    fi
    return 0
}

main() {
    parse_arguments "$@"

    # Surface deprecation warnings as early as possible so they appear
    # even in --dry-run / --print-config / --status read-only paths.
    # These don't fail the run — they just inform the operator that the
    # input they used is on a deprecation path.
    if [[ -n "${DOCUMENTDB_PASSWORD:-}" && -z "${PASSWORD_FILE}" \
            && "${PASSWORD_FROM_STDIN}" != "true" ]]; then
        log_warn "DOCUMENTDB_PASSWORD environment variable is deprecated; it leaks via /proc/<pid>/environ. Use --admin-password-file <FILE> (mode 0600) or pipe the password via --admin-password-stdin instead."
    fi

    # Read-only operational flags: print-config + status. Both exit
    # before preflight_validation and before any side effect.
    if [[ "${PRINT_CONFIG}" == "true" ]]; then
        print_config
        exit 0
    fi
    if [[ "${STATUS_ONLY}" == "true" ]]; then
        status_only
        exit $?
    fi

    # If --admin-user wasn't supplied AND --restore is not the action,
    # prompt on a TTY with a sensible default. This lets newbies just
    # run `sudo documentdb-setup` and answer two prompts (user, password)
    # rather than reading the help to discover the flag is required.
    # Non-TTY callers (CI, unattended) still hit the usage+exit branch.
    if [[ -z "${USERNAME}" && "${RESTORE}" != "true" ]]; then
        if [[ -t 0 && -t 2 && "${YES}" != "true" && "${DRY_RUN}" != "true" \
                && "${PRINT_CONFIG}" != "true" && "${STATUS_ONLY}" != "true" ]]; then
            local admin_default="admin"
            local admin_reply=""
            printf '%s' "[documentdb-setup] Admin username [${admin_default}]: " >&2
            read -r admin_reply
            USERNAME="${admin_reply:-${admin_default}}"
            # Reject obvious typos / shell weirdness before we go further.
            # The DocumentDB user-management API constrains usernames to a
            # similar shape; surface here rather than at the SQL layer
            # after we've already done invasive setup.
            if ! [[ "${USERNAME}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
                die "Admin username '${USERNAME}' is invalid. Use letters, digits, '_' or '-' (must start with a letter or '_')."
            fi
        else
            usage
            exit 1
        fi
    fi

    # Handle --restore early: strip all managed blocks, remove state, exit.
    if [[ "${RESTORE}" == "true" ]]; then
        require_root
        log_info "Restoring: removing all documentdb-setup managed configuration."

        local env_file="${POSTGRES_SERVICE_ENV_FILE}"
        if [[ -r "${env_file}" ]]; then
            local data_dir config_file hba_file ident_file
            data_dir="$(grep -E '^DATA_DIR=' "${env_file}" | head -1 | cut -d= -f2- || true)"
            config_file="$(grep -E '^CONFIG_FILE=' "${env_file}" | head -1 | cut -d= -f2- || true)"
            hba_file="$(grep -E '^HBA_FILE=' "${env_file}" | head -1 | cut -d= -f2- || true)"
            ident_file="$(grep -E '^IDENT_FILE=' "${env_file}" | head -1 | cut -d= -f2- || true)"

            [[ -z "${config_file}" && -n "${data_dir}" ]] && config_file="${data_dir}/postgresql.conf"
            [[ -z "${hba_file}" && -n "${data_dir}" ]] && hba_file="${data_dir}/pg_hba.conf"
            [[ -z "${ident_file}" && -n "${data_dir}" ]] && ident_file="${data_dir}/pg_ident.conf"

            if [[ -n "${config_file}" && -f "${config_file}" ]]; then
                local stripped
                stripped="$(strip_managed_block "${config_file}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}")"
                printf '%s\n' "${stripped}" > "${config_file}"
                stripped="$(strip_managed_block "${config_file}" "${POSTGRES_LISTEN_BLOCK_START}" "${POSTGRES_LISTEN_BLOCK_END}")"
                printf '%s\n' "${stripped}" > "${config_file}"
                log_info "Stripped managed block from ${config_file}"
            fi
            if [[ -n "${hba_file}" && -f "${hba_file}" ]]; then
                local stripped
                stripped="$(strip_managed_block "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}")"
                printf '%s\n' "${stripped}" > "${hba_file}"
                log_info "Stripped managed block from ${hba_file}"
            fi
            if [[ -n "${ident_file}" && -f "${ident_file}" ]]; then
                local stripped
                stripped="$(strip_managed_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}")"
                printf '%s\n' "${stripped}" > "${ident_file}"
                log_info "Stripped managed block from ${ident_file}"
            fi

            rm -f "${env_file}"
            log_info "Removed ${env_file}"
        else
            log_info "No legacy state file found at ${env_file}."
        fi

        # Also restore from per-major state files introduced by recent setup
        local per_major_conf
        for per_major_conf in /etc/documentdb/local/*/setup.conf; do
            [[ -r "${per_major_conf}" ]] || continue
            log_info "Processing per-major state: ${per_major_conf}"
            local pm_data_dir pm_config pm_hba pm_ident
            pm_data_dir="$(grep -E '^DATA_DIR=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"
            pm_config="$(grep -E '^CONFIG_FILE=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"
            pm_hba="$(grep -E '^HBA_FILE=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"
            pm_ident="$(grep -E '^IDENT_FILE=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"

            [[ -z "${pm_config}" && -n "${pm_data_dir}" ]] && pm_config="${pm_data_dir}/postgresql.conf"
            [[ -z "${pm_hba}" && -n "${pm_data_dir}" ]] && pm_hba="${pm_data_dir}/pg_hba.conf"
            [[ -z "${pm_ident}" && -n "${pm_data_dir}" ]] && pm_ident="${pm_data_dir}/pg_ident.conf"

            for pair in "${pm_config}:${POSTGRES_CONF_BLOCK_START}:${POSTGRES_CONF_BLOCK_END}" \
                        "${pm_config}:${POSTGRES_LISTEN_BLOCK_START}:${POSTGRES_LISTEN_BLOCK_END}" \
                        "${pm_hba}:${PG_HBA_BLOCK_START}:${PG_HBA_BLOCK_END}" \
                        "${pm_ident}:${PG_IDENT_BLOCK_START}:${PG_IDENT_BLOCK_END}"; do
                local pm_file="${pair%%:*}"
                local rest="${pair#*:}"
                local pm_start="${rest%%:*}"
                local pm_end="${rest#*:}"
                if [[ -n "${pm_file}" && -f "${pm_file}" ]]; then
                    local stripped
                    stripped="$(strip_managed_block "${pm_file}" "${pm_start}" "${pm_end}")"
                    printf '%s\n' "${stripped}" > "${pm_file}"
                    log_info "Stripped managed block from ${pm_file}"
                fi
            done

            # Reviewer-flagged (Sonnet iter 2): greenfield --restore must
            # match brownfield --restore in stripping the per-major gateway
            # env fragment and tmpfs URL file. Without this, a re-run of
            # `documentdb-setup --yes` against the same major picks up the
            # stale gateway.env before the new register-gateway invocation
            # overwrites it, and the systemd unit briefly serves the old
            # connection URL.
            local pm_dir pm_major pm_env_file
            pm_dir="$(dirname "${per_major_conf}")"
            pm_major="$(basename "${pm_dir}")"
            pm_env_file="${pm_dir}/gateway.env"
            if [[ -f "${pm_env_file}" ]]; then
                local stripped_env
                stripped_env="$(strip_managed_block "${pm_env_file}" \
                    '# >>> documentdb-register-gateway managed env >>>' \
                    '# <<< documentdb-register-gateway managed env <<<')"
                printf '%s\n' "${stripped_env}" > "${pm_env_file}"
                if [[ ! -s "${pm_env_file}" ]]; then
                    rm -f "${pm_env_file}"
                    log_info "Removed ${pm_env_file}"
                else
                    log_info "Stripped managed env block from ${pm_env_file}"
                fi
            fi
            if [[ "${pm_major}" =~ ^[0-9]+$ ]]; then
                # Remove pg-url from BOTH legacy (/run/, pre-iter11) and
                # current (/var/lib/) locations for upgrade-safe cleanup.
                rm -f "/run/documentdb-local/${pm_major}/gateway/pg-url" 2>/dev/null || true
                rm -f "/var/lib/documentdb-local/${pm_major}/gateway/pg-url" 2>/dev/null || true
                remove_brownfield_gateway_dropin "${pm_major}"
            fi

            rm -f "${per_major_conf}"
            log_info "Removed ${per_major_conf}"
            rmdir --ignore-fail-on-non-empty "${pm_dir}" 2>/dev/null || true
        done

        # Brownfield: per-major brownfield.conf state file plus the
        # systemd drop-in that re-points the gateway at the adopted PG
        # service. The drop-in must be removed first so a subsequent
        # `documentdb-setup` (or re-adopt of a different PG) starts from
        # a clean unit-file view.
        local per_major_brownfield
        for per_major_brownfield in /etc/documentdb/local/*/brownfield.conf; do
            [[ -r "${per_major_brownfield}" ]] || continue
            log_info "Processing per-major brownfield state: ${per_major_brownfield}"
            local bf_data_dir bf_config bf_hba bf_ident bf_dir bf_major
            bf_data_dir="$(grep -E '^DATA_DIR=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"
            bf_config="$(grep -E '^CONFIG_FILE=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"
            bf_hba="$(grep -E '^HBA_FILE=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"
            bf_ident="$(grep -E '^IDENT_FILE=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"

            [[ -z "${bf_config}" && -n "${bf_data_dir}" ]] && bf_config="${bf_data_dir}/postgresql.conf"
            [[ -z "${bf_hba}" && -n "${bf_data_dir}" ]] && bf_hba="${bf_data_dir}/pg_hba.conf"
            [[ -z "${bf_ident}" && -n "${bf_data_dir}" ]] && bf_ident="${bf_data_dir}/pg_ident.conf"

            for pair in "${bf_config}:${POSTGRES_CONF_BLOCK_START}:${POSTGRES_CONF_BLOCK_END}" \
                        "${bf_config}:${POSTGRES_LISTEN_BLOCK_START}:${POSTGRES_LISTEN_BLOCK_END}" \
                        "${bf_hba}:${PG_HBA_BLOCK_START}:${PG_HBA_BLOCK_END}" \
                        "${bf_ident}:${PG_IDENT_BLOCK_START}:${PG_IDENT_BLOCK_END}"; do
                local bf_file="${pair%%:*}"
                local rest="${pair#*:}"
                local bf_start="${rest%%:*}"
                local bf_end="${rest#*:}"
                if [[ -n "${bf_file}" && -f "${bf_file}" ]]; then
                    local stripped
                    stripped="$(strip_managed_block "${bf_file}" "${bf_start}" "${bf_end}")"
                    printf '%s\n' "${stripped}" > "${bf_file}"
                    log_info "Stripped managed block from ${bf_file}"
                fi
            done

            bf_dir="$(dirname "${per_major_brownfield}")"
            bf_major="$(basename "${bf_dir}")"
            remove_brownfield_gateway_dropin "${bf_major}"

            # Reviewer-flagged (GPT-5 second pass): --restore must also strip
            # the per-major gateway env fragment and tmpfs URL file. Without
            # this, the package's postrm orphan sweep would be the only path
            # that cleans them up, and a subsequent `documentdb-setup --yes`
            # re-adopt against a different cluster would inherit stale
            # gateway.env content.
            local bf_env_file="${bf_dir}/gateway.env"
            if [[ -f "${bf_env_file}" ]]; then
                local stripped_env
                stripped_env="$(strip_managed_block "${bf_env_file}" \
                    '# >>> documentdb-register-gateway managed env >>>' \
                    '# <<< documentdb-register-gateway managed env <<<')"
                printf '%s\n' "${stripped_env}" > "${bf_env_file}"
                if [[ ! -s "${bf_env_file}" ]]; then
                    rm -f "${bf_env_file}"
                    log_info "Removed ${bf_env_file}"
                else
                    log_info "Stripped managed env block from ${bf_env_file}"
                fi
            fi
            # Remove pg-url from BOTH legacy (/run/, pre-iter11) and
            # current (/var/lib/) locations for upgrade-safe cleanup.
            rm -f "/run/documentdb-local/${bf_major}/gateway/pg-url" 2>/dev/null || true
            rm -f "/var/lib/documentdb-local/${bf_major}/gateway/pg-url" 2>/dev/null || true

            rm -f "${per_major_brownfield}"
            log_info "Removed ${per_major_brownfield}"
            rmdir --ignore-fail-on-non-empty "${bf_dir}" 2>/dev/null || true
        done

        # Clean up systemd drop-in. Cover both the new templated path
        # (documentdb-postgresql@N.service.d, per-major) and the legacy
        # non-templated path (documentdb-postgresql.service.d) so a host
        # upgraded from pre-iter6 doesn't leak a stale drop-in.
        rm -f /etc/systemd/system/documentdb-postgresql.service.d/datadir.conf
        rmdir --ignore-fail-on-non-empty /etc/systemd/system/documentdb-postgresql.service.d 2>/dev/null || true
        for templated_drop_in_dir in /etc/systemd/system/documentdb-postgresql@*.service.d; do
            [[ -d "${templated_drop_in_dir}" ]] || continue
            rm -f "${templated_drop_in_dir}/datadir.conf"
            rmdir --ignore-fail-on-non-empty "${templated_drop_in_dir}" 2>/dev/null || true
        done
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload || true
        fi

        # Advanced-user E2E flagged (Gap #5): --restore stripped state but
        # left any nohup-launched gateway daemon running on the old port.
        # An operator who then re-runs setup with --listen-port X gets
        # two gateways listening (old on Y, new on X). Kill orphaned
        # nohup daemons here. systemd-managed gateways were already
        # stopped by the systemctl stop in the systemd-aware branches
        # above (or handled by the stand-alone package's own postrm).
        if pgrep -f /usr/lib/documentdb-gateway/documentdb-gateway-daemon >/dev/null 2>&1; then
            local stale_pids
            stale_pids="$(pgrep -f /usr/lib/documentdb-gateway/documentdb-gateway-daemon | tr '\n' ' ')"
            log_info "Stopping orphan documentdb-gateway-daemon process(es): ${stale_pids}"
            pkill -TERM -f /usr/lib/documentdb-gateway/documentdb-gateway-daemon 2>/dev/null || true
            sleep 1
            # Hard kill if still alive
            if pgrep -f /usr/lib/documentdb-gateway/documentdb-gateway-daemon >/dev/null 2>&1; then
                pkill -KILL -f /usr/lib/documentdb-gateway/documentdb-gateway-daemon 2>/dev/null || true
            fi
        fi

        log_success "Restore complete. Restart PostgreSQL to apply."
        exit 0
    fi

    # Early dry-run preview: report what the wizard WOULD do without
    # any side effects (including the root check and PG detection).
    # This is intentionally before preflight_validation so a non-root
    # operator can inspect the plan; full validation still runs in the
    # apply path.
    if [[ "${DRY_RUN}" == "true" ]]; then
        # Try to detect PG so the preview shows the actual per-major
        # paths the wizard would compute at apply time. detect_postgres_installation
        # only reads /usr/lib/postgresql/*/bin and /usr/pgsql-*/bin, so
        # it does not need root. Falls through silently if no PG is found
        # — we just show the auto-detect placeholder in that case.
        if [[ -z "${PG_VERSION}" ]]; then
            detect_postgres_installation 2>/dev/null || true
        fi
        # Recompute the per-major defaults the same way resolve_runtime_paths
        # does at apply time. This is what makes the dry-run preview
        # report the same paths the apply path would actually use.
        if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
            if [[ "${PG_PORT_EXPLICIT}" != "true" ]] \
                    && { [[ -z "${PG_PORT}" ]] || [[ "${PG_PORT}" == "${DEFAULT_PG_PORT}" ]]; }; then
                PG_PORT=$(( 9700 + PG_VERSION ))
            fi
            if [[ "${DATA_DIR_EXPLICIT}" != "true" ]] \
                    && { [[ -z "${DATA_DIR}" ]] || [[ "${DATA_DIR}" == "${DEFAULT_DATA_DIR}" ]]; }; then
                DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
            fi
        fi

        # For brownfield, derive the effective PG version + cluster name
        # from --target-postgres-instance so the preview shows the right
        # templated-unit names. Greenfield uses the explicit --pg-version
        # or "<auto-detect>" as a placeholder.
        local preview_pg_version="${PG_VERSION:-<auto-detect>}"
        local preview_cluster_name=""
        if [[ -n "${TARGET_CLUSTER}" ]]; then
            preview_pg_version="${TARGET_CLUSTER%%/*}"
            preview_cluster_name="${TARGET_CLUSTER#*/}"
            [[ -n "${preview_cluster_name}" ]] || preview_cluster_name="main"
        fi
        log_info "[dry-run] documentdb-setup invoked with --dry-run:"
        # Advanced-user E2E flagged (Gap #6): probe existing state so the
        # preview annotates each step with "(no-op: already done)" when
        # appropriate. Saves operators from thinking the wizard would
        # wipe and re-init when it would actually adopt the existing
        # install. Annotations are best-effort — probes that need root
        # are skipped silently.
        local _state_file="/etc/documentdb/local/${preview_pg_version}/setup.conf"
        local _bf_state_file="/etc/documentdb/local/${preview_pg_version}/brownfield.conf"
        local _datadir_ready=false
        local _ext_ready=false
        local _admin_ready=false
        local _gw_url_file="/var/lib/documentdb-local/${preview_pg_version}/gateway/pg-url"
        if [[ -f "${DATA_DIR}/PG_VERSION" ]]; then _datadir_ready=true; fi
        if [[ -f "${_state_file}" || -f "${_bf_state_file}" ]]; then
            # Existing install — best-effort: assume CREATE EXTENSION + admin already done.
            _ext_ready=true
            _admin_ready=true
        fi
        local _datadir_note=""
        local _initdb_note=""
        local _ext_note=""
        local _admin_note=""
        if [[ "${_datadir_ready}" == "true" ]]; then
            _datadir_note=" (no-op: ${DATA_DIR} already initialized)"
            _initdb_note=" (no-op: data dir present)"
        fi
        if [[ "${_ext_ready}" == "true" ]]; then _ext_note=" (likely no-op: install state present)"; fi
        if [[ "${_admin_ready}" == "true" ]]; then _admin_note=" (likely no-op: install state present; existing user would have password reset if --admin-password supplied)"; fi
        if [[ -n "${TARGET_CLUSTER}" ]]; then
            log_info "[dry-run]   mode: BROWNFIELD (adopt ${TARGET_CLUSTER})"
            log_info "[dry-run]   PG port: <discovered from ${preview_pg_version}/${preview_cluster_name}>, gateway port: ${GATEWAY_PORT}"
        else
            log_info "[dry-run]   mode: GREENFIELD (initdb private instance for PG ${preview_pg_version})"
            log_info "[dry-run]   data dir: ${DATA_DIR}"
            log_info "[dry-run]   PG port: ${PG_PORT}, gateway port: ${GATEWAY_PORT}"
        fi
        log_info "[dry-run]   admin user: ${USERNAME}"
        log_info "[dry-run]   side-effect steps that would run (each gated by [y/N/dry-run] when --yes is not set):"
        if [[ -z "${TARGET_CLUSTER}" ]]; then
            log_info "[dry-run]     - Create ${DATA_DIR} owned by documentdb-local:documentdb-local${_datadir_note}"
            log_info "[dry-run]     - initdb --pgdata=${DATA_DIR} --username=documentdb-local${_initdb_note}"
            log_info "[dry-run]     - documentdb-tune --yes  (writes postgresql.conf managed block)"
            log_info "[dry-run]     - systemctl enable documentdb-postgresql@${preview_pg_version}.service"
            log_info "[dry-run]     - systemctl start  documentdb-postgresql@${preview_pg_version}.service"
            log_info "[dry-run]     - documentdb-register-gateway --yes --pg-owner documentdb-local  (writes pg_hba.conf, pg_ident.conf, gateway role, ${_gw_url_file}) — runs AFTER PG is up so psql/CREATE ROLE work"
        else
            log_info "[dry-run]     - documentdb-tune --yes  (writes postgresql.conf managed block)"
            log_info "[dry-run]     - documentdb-register-gateway --yes --pg-owner postgres  (writes pg_hba.conf, pg_ident.conf, gateway role, ${_gw_url_file})"
            log_info "[dry-run]     - Print 'systemctl reload postgresql@${preview_pg_version}-${preview_cluster_name}' for the operator to run"
        fi
        log_info "[dry-run]     - psql: CREATE EXTENSION documentdb CASCADE${_ext_note}"
        log_info "[dry-run]     - psql: bootstrap admin user '${USERNAME}' via documentdb_api.create_user()${_admin_note}"
        log_info "[dry-run]     - systemctl enable documentdb-gateway-local@${preview_pg_version}.service"
        log_info "[dry-run]     - systemctl start  documentdb-gateway-local@${preview_pg_version}.service"
        # Reviewer-flagged (external review iter 17): enable per-major
        # target so the stack auto-starts at boot (services have
        # WantedBy=target but the target needs its own enable to land
        # in multi-user.target.wants/).
        log_info "[dry-run]     - systemctl enable documentdb-local@${preview_pg_version}.target  # boot persistence"
        log_info "[dry-run] no side effects performed."
        exit 0
    fi

    preflight_validation

    log_info "Using PostgreSQL ${PG_VERSION} binaries in ${PG_BIN_DIR}."
    log_info "Using gateway binary ${GATEWAY_BINARY}."
    log_info "Using gateway config ${CONFIG_FILE}."

    # Capture the gateway's pre-run active state so we can preserve it
    # across PG restarts (Requires= dependency propagation can stop the
    # gateway when we run `systemctl restart documentdb-postgresql`, and
    # under --no-enable we would never bring it back).
    capture_gateway_active_state

    # Branch on the design's primary flow selector:
    #   --target-postgres-instance N/C  → brownfield (adopt existing PG)
    #   otherwise                       → greenfield (initdb private PG)
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        prepare_brownfield_instance
        # Brownfield: only delegate config writes; do NOT activate our
        # per-major templated PG service (the operator owns the system PG
        # service lifecycle, per design §4.4). The adopted PG is already
        # running, so register-gateway's psql/CREATE ROLE call works
        # right after the config writes.
        # Reviewer-flagged (GPT-5.5 iter 11): on Debian, documentdb-tune
        # writes shared_preload_libraries to the per-cluster fragment at
        # /etc/postgresql-common/documentdb/N/C/documentdb.conf via the
        # include_if_exists mechanism, NOT into the live postgresql.conf.
        # So reading LIVE_CONFIG_FILE (the main postgresql.conf) for SPL
        # never sees our value — every rerun thinks SPL still needs
        # updating, flips PG_CONFIG_CHANGED=true, and the wizard hits
        # the restart-required exit guard in start_or_restart_postgres
        # AGAIN, even though the operator restarted PG already. Result:
        # infinite "restart and re-run" loop.
        #
        # Ground truth is whatever the LIVE PostgreSQL has loaded.
        # SHOW shared_preload_libraries returns that. Compare against the
        # merged value to decide whether a restart is still pending.
        local current_preload merged_preload live_preload
        current_preload="$(read_shared_preload_libraries_from_file "${LIVE_CONFIG_FILE}")"
        merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
        live_preload="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" \
            -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW shared_preload_libraries;" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "${current_preload}" != "${merged_preload}" ]]; then
            # The on-disk config doesn't have our merged set yet; we need
            # to write it. But whether a RESTART is required depends on
            # whether the LIVE postmaster has already loaded our
            # libraries (e.g., via a previously-written include the
            # operator already restarted to pick up).
            local need_restart=true
            if [[ -n "${live_preload}" ]]; then
                local lib all_present=true
                for lib in pg_cron pg_documentdb_core pg_documentdb; do
                    case "${live_preload}" in
                        *"${lib}"*) ;;
                        *) all_present=false; break ;;
                    esac
                done
                if [[ "${all_present}" == "true" ]]; then
                    need_restart=false
                    log_verbose "Live PostgreSQL already has all required preload libraries loaded; skipping restart-required exit."
                fi
            fi
            [[ "${need_restart}" == "true" ]] && PG_CONFIG_CHANGED=true
        fi
        apply_managed_postgres_settings "${LIVE_CONFIG_FILE}" "${LIVE_HBA_FILE}" "${merged_preload}" ""
        ensure_pg_ident_map
        persist_brownfield_state
    else
        prepare_self_managed_cluster
        # Persist the self-managed PG service state and drop-in BEFORE
        # starting PostgreSQL so the systemd unit's ConditionPathExists
        # is satisfied and `systemctl enable` will auto-start the
        # instance on reboot.
        sync_self_managed_postgres_service_state
    fi

    start_or_restart_postgres

    # Issue 1 (Phase 11): greenfield must call register-gateway AFTER PG
    # is started, because the tool connects via psql to create the
    # gateway role and verify the extension. Brownfield already ran this
    # above (its PG is the long-running system instance).
    if [[ -z "${TARGET_CLUSTER}" ]]; then
        register_gateway_after_pg_running
        reload_self_managed_postgres_auth_mapping
    fi

    create_required_extensions_and_users
    grant_gateway_role_memberships
    update_gateway_configuration
    start_gateway
    load_sample_data_if_requested
    ensure_target_enabled_at_boot
    print_completion_message
}

main "$@"
