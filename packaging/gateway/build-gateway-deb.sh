#!/bin/bash
# Build the documentdb_gateway DEB package from a pre-built binary.
#
# This script replaces cargo-deb for the gateway package, keeping all
# packaging control in oss/packaging/ and oss/documentdb-local/ without
# modifying the gateway crate's Cargo.toml.
#
# Usage:
#   build-gateway-deb.sh --binary <path> --version <version> [--output-dir <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BINARY_PATH=""
VERSION=""
OUTPUT_DIR="."
ARCH=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build-gateway-deb.sh --binary <path> --version <ver> [--output-dir <dir>]

Build the documentdb_gateway DEB package from a pre-built binary.

Required:
  --binary PATH      Path to the compiled documentdb_gateway binary
  --version VER      Package version (e.g., 0.114.0)

Optional:
  --output-dir DIR   Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY_PATH="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${BINARY_PATH}" ]] || die "--binary is required"
[[ -x "${BINARY_PATH}" ]] || die "Binary not found or not executable: ${BINARY_PATH}"
[[ -n "${VERSION}" ]] || die "--version is required"

ARCH="$(dpkg --print-architecture)"
# Debian policy requires the Package field to use only [a-z0-9.+-].
# The filename uses the same hyphen-separated form so dpkg's
# <package>_<version>_<arch>.deb convention parses cleanly.
DEB_PKG_NAME="documentdb-gateway"
FILE_PKG_NAME="documentdb-gateway"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb ..."

# ── Directory structure ─────────────────────────────────────────────
install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/bin"
install -d "${PKG_DIR}/lib/systemd/system"
install -d "${PKG_DIR}/usr/lib/sysusers.d"
install -d "${PKG_DIR}/usr/lib/tmpfiles.d"
install -d "${PKG_DIR}/etc/documentdb/gateway"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

install -d "${PKG_DIR}/usr/lib/documentdb-gateway"

# ── Binary + wrapper ────────────────────────────────────────────────
# Real-user E2E flagged (Gap #6): when an operator runs
# `documentdb-gateway --check` from a shell, the binary reads only its
# JSON config (which still encodes PostgresDataUser=documentdb-local
# for back-compat) and ignores the per-major gateway.env, producing a
# false-negative auth failure. The systemd path is fine because the
# unit sets EnvironmentFile= — but a manual smoke test should give the
# same result.
#
# Fix: install the Rust daemon at /usr/lib/documentdb-gateway/, ship a
# thin wrapper at /usr/bin/documentdb-gateway that auto-sources the
# right per-major or global env file before exec'ing the daemon, AND
# (for manual --check) downgrades to the documentdb-gateway OS user via
# runuser so the daemon's pg_hba peer-auth match succeeds. The wrapper
# is a pass-through for `run` so the systemd unit (which already sets
# User= and EnvironmentFile=) sees identical behavior.
install -m 0755 "${BINARY_PATH}" "${PKG_DIR}/usr/lib/documentdb-gateway/documentdb-gateway-daemon"

cat > "${PKG_DIR}/usr/bin/documentdb-gateway" <<'WRAPPER'
#!/bin/bash
# documentdb-gateway — thin wrapper that sources the per-major or global
# gateway.env before exec'ing the daemon binary. Fixes Gap #6 (manual
# --check using stale JSON config when the env file is the authoritative
# source) and Gap #16-adjacent (peer-auth failing because the wrapper
# ran as root instead of documentdb-gateway). The systemd units already
# handle both pieces; this wrapper makes manual CLI invocations behave
# the same way.

set -e
DAEMON="/usr/lib/documentdb-gateway/documentdb-gateway-daemon"
GW_OS_USER="documentdb-gateway"

_source_env_if_present() {
    local f="$1"
    if [[ -r "${f}" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "${f}"
        set +a
        return 0
    fi
    return 1
}

# Pick up env from the first matching source (most-specific wins).
# Advanced-user E2E flagged (Gap #2): on a multi-major host the caller
# (typically documentdb-setup) already sourced THE right per-major env
# before invoking us. If we auto-load /etc/documentdb/local/*/gateway.env
# we'd pick the FIRST alphabetically and clobber the caller's choice
# (e.g. install PG17 then PG18: setup18 sources its env, exec's wrapper,
# wrapper picks 17/gateway.env first, overwrites DOCUMENTDB_PG_URL_FILE
# and DOCUMENTDB_LISTEN_ADDR → daemon binds the wrong port).
# Guard: skip auto-load when the caller already set DOCUMENTDB_PG_URL_FILE
# or DOCUMENTDB_PG_URL.
_load_env() {
    if [[ -n "${DOCUMENTDB_PG_URL_FILE:-}" || -n "${DOCUMENTDB_PG_URL:-}" ]]; then
        # Caller already configured us; trust them.
        return 0
    fi
    local env_file
    for env_file in /etc/documentdb/local/*/gateway.env; do
        [[ -f "${env_file}" ]] || continue
        _source_env_if_present "${env_file}" && return 0
    done
    _source_env_if_present /etc/documentdb/gateway/gateway.env && return 0
    return 1
}

# Re-exec self as the gateway OS user so peer-auth via the documentdb-
# gateway-map ident map succeeds. Only applies when we are currently
# root AND the documentdb-gateway user exists AND we are NOT already
# running under systemd (which already set User=documentdb-gateway).
_under_systemd() {
    [[ "${INVOCATION_ID:-}" != "" ]]
}

_maybe_runuser_down() {
    if [[ "$(id -u)" -eq 0 ]] \
            && id -u "${GW_OS_USER}" >/dev/null 2>&1 \
            && ! _under_systemd; then
        # Preserve the env we just sourced.
        exec runuser -u "${GW_OS_USER}" \
            --whitelist-environment=DOCUMENTDB_PG_URL_FILE,DOCUMENTDB_PG_URL,DOCUMENTDB_LISTEN_ADDR,DOCUMENTDB_TLS_CERT_FILE,DOCUMENTDB_TLS_KEY_FILE,DOCUMENTDB_TLS_AUTO_GENERATE,DOCUMENTDB_TLS_STATE_DIR,DOCUMENTDB_LOG_LEVEL \
            -- "${DAEMON}" "$@"
    fi
    exec "${DAEMON}" "$@"
}

case "${1:-}" in
    run)
        # systemd path: env loaded by EnvironmentFile=, user set by
        # User=documentdb-gateway → just exec the daemon.
        # No-systemd path (containers, manual dev): we need to load env
        # AND downgrade ourselves before exec'ing the daemon, otherwise
        # peer auth as root fails. _maybe_runuser_down handles both.
        _load_env >/dev/null 2>&1 || true
        shift
        _maybe_runuser_down run "$@"
        ;;
    --check|--version)
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down "$@"
        ;;
    "")
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down
        ;;
    *)
        # Pass-through (e.g., Docker compat path that runs the daemon
        # with a JSON config arg). Load env + downgrade.
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down "$@"
        ;;
esac
WRAPPER
chmod 0755 "${PKG_DIR}/usr/bin/documentdb-gateway"

# ── Systemd / sysusers / tmpfiles ───────────────────────────────────
install -m 0644 "${REPO_ROOT}/packaging/gateway/systemd/documentdb-gateway.service" \
    "${PKG_DIR}/lib/systemd/system/documentdb-gateway.service"
install -m 0644 "${REPO_ROOT}/packaging/gateway/sysusers/documentdb-gateway.conf" \
    "${PKG_DIR}/usr/lib/sysusers.d/documentdb-gateway.conf"
install -m 0644 "${REPO_ROOT}/packaging/gateway/tmpfiles/documentdb-gateway.conf" \
    "${PKG_DIR}/usr/lib/tmpfiles.d/documentdb-gateway.conf"

# ── Config files ────────────────────────────────────────────────────
# Per packaging-design.md §4.3: ship the env sample under
# /usr/share/doc/.../examples/ (PostgreSQL convention) and let the
# administrator copy it to /etc/documentdb/gateway/gateway.env when they
# want non-default settings. The systemd unit uses EnvironmentFile=-
# so absence of the live file is fine. SetupConfiguration.json is still
# shipped at the historical path for back-compat with pre-Phase-3
# deployments; new installs are env-only.
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/examples"
install -m 0644 "${REPO_ROOT}/packaging/gateway/config/gateway.env" \
    "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/examples/gateway.env.sample"
install -d "${PKG_DIR}/etc/documentdb/gateway"
# Reviewer-flagged (external review iter 18): the dev-tree
# SetupConfiguration.json carries PostgresPort: 9712 / GatewayListenPort:
# 10260 for the local `cargo run` workflow. Shipping those values
# verbatim into the package contradicts the design's per-major port
# promise (PG 18 → 9718, etc.) AND the env-first/new-installs-env-only
# boundary. Strip the connection-pinning fields when packaging so
# fresh installs are env-driven; existing installs with operator
# edits are preserved by the conffile mechanism (administrator gets
# a dpkg prompt on upgrade if they had local edits).
#
# Also strip PostgresDataUserPassword — Track 1 is passwordless local
# peer auth; matches the runtime rejection in setup.rs.
PACKAGED_JSON="${PKG_DIR}/etc/documentdb/gateway/SetupConfiguration.json"
if command -v jq >/dev/null 2>&1; then
    jq 'del(.PostgresPort, .GatewayListenPort, .PostgresDataUserPassword, .PostgresHostName, .PostgresSystemUser, .PostgresDataUser)' \
        "${REPO_ROOT}/pg_documentdb_gw/SetupConfiguration.json" > "${PACKAGED_JSON}"
else
    # Fallback: line-level sed deletion. Fragile to formatting, but the
    # source file is hand-maintained with one field per line.
    sed -E '/"(PostgresPort|GatewayListenPort|PostgresDataUserPassword|PostgresHostName|PostgresSystemUser|PostgresDataUser)"[[:space:]]*:/d' \
        "${REPO_ROOT}/pg_documentdb_gw/SetupConfiguration.json" > "${PACKAGED_JSON}"
fi
chmod 0644 "${PACKAGED_JSON}"

# ── Maintainer scripts ──────────────────────────────────────────────
install -m 0755 "${REPO_ROOT}/documentdb-local/maintainer-scripts/gateway/postinst" \
    "${PKG_DIR}/DEBIAN/postinst"
install -m 0755 "${REPO_ROOT}/documentdb-local/maintainer-scripts/gateway/postrm" \
    "${PKG_DIR}/DEBIAN/postrm"
install -m 0755 "${REPO_ROOT}/documentdb-local/maintainer-scripts/gateway/prerm" \
    "${PKG_DIR}/DEBIAN/prerm"

# ── Conffiles (preserved on upgrade) ────────────────────────────────
# Only files that are actually shipped under /etc/. The env sample at
# /usr/share/doc/ is not a conffile (it's an example) so isn't listed.
cat > "${PKG_DIR}/DEBIAN/conffiles" <<'CONF'
/etc/documentdb/gateway/SetupConfiguration.json
CONF

# ── Auto-detect shared library dependencies ─────────────────────────
SHLIBDEPS=""
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
    # dpkg-shlibdeps needs a debian/control stub
    mkdir -p "${PKG_DIR}/debian"
    cat > "${PKG_DIR}/debian/control" <<CTRL
Source: ${DEB_PKG_NAME}
Package: ${DEB_PKG_NAME}
Architecture: ${ARCH}
CTRL
    SHLIBDEPS="$(cd "${PKG_DIR}" && dpkg-shlibdeps -O usr/bin/documentdb-gateway 2>/dev/null | sed 's/^shlibs:Depends=//' || true)"
    rm -rf "${PKG_DIR}/debian"
fi

# Append our explicit deps. Reviewer-flagged (Sonnet iter 7): jq is NOT
# a gateway runtime dep — only documentdb-gateway-admin uses it, and
# that ships in documentdb-postgresql-tools. Per packaging-design.md
# §4.3 the gateway package has "no product-specific runtime dependency
# beyond the OS/runtime libraries that the binary links to". jq has
# been removed; openssl stays because the gateway's TLS auto-gen flow
# shells out to it when DOCUMENTDB_TLS_AUTO_GENERATE=true.
if [[ -n "${SHLIBDEPS}" ]]; then
    DEPENDS="${SHLIBDEPS}, openssl"
else
    DEPENDS="openssl"
fi

# ── Copyright ───────────────────────────────────────────────────────
if [[ -f "${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_MIT" ]]; then
    cp "${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_MIT" "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"
else
    echo "MIT License" > "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"
fi

# ── Control file ────────────────────────────────────────────────────
INSTALLED_SIZE=$(du -sk "${PKG_DIR}" | cut -f1)

# Reviewer-flagged (Sonnet iter 9): the previous Suggests included
# postgresql-18-documentdb, the same misleading pattern iter-8 removed
# from the tools package. On PG 15/16/17 hosts the gateway is
# PG-major-agnostic at the binary level, but apt would suggest the wrong
# extension. Suggest only documentdb-postgresql-tools (PG-agnostic admin
# helpers); the postinst message points the operator at the right
# per-major extension package.
cat > "${PKG_DIR}/DEBIAN/control" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: documentdb-packaging-maintainers@microsoft.com
Installed-Size: ${INSTALLED_SIZE}
Depends: ${DEPENDS}
Suggests: documentdb-postgresql-tools
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: DocumentDB wire-protocol gateway daemon
 The DocumentDB gateway provides wire-protocol compatibility, enabling
 connections from compatible clients and drivers. This is the lean
 runtime package; PostgreSQL-side helpers ship in documentdb-postgresql-tools.
CONTROL

# ── Build ───────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_FILE}"

echo "Built: ${DEB_FILE}"
echo "Contents:"
dpkg-deb -c "${DEB_FILE}" | awk '{print "  " $NF}' | grep -v '/$'
