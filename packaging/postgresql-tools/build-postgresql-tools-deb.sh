#!/bin/bash
# Build the documentdb-postgresql-tools DEB package.
#
# This package ships the administrator helpers that mutate PostgreSQL
# state on behalf of DocumentDB: documentdb-tune (postgresql.conf),
# documentdb-register-gateway (pg_hba.conf / pg_ident.conf / gateway role
# / connection file), documentdb-createcluster (Debian/Ubuntu cluster
# wrapper), and documentdb-gateway-admin (user management helpers).
#
# Per packaging-design.md §4.2, the package is administrator scaffolding
# rather than a runtime artifact, so it has no dependency on the gateway
# or extension runtime packages — it only Suggests them.
#
# Usage:
#   build-postgresql-tools-deb.sh --version <version> [--output-dir <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VERSION=""
OUTPUT_DIR="."

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build-postgresql-tools-deb.sh --version <ver> [--output-dir <dir>]

Build the documentdb-postgresql-tools DEB package.

Required:
  --version VER      Package version (e.g., 0.114.0)

Optional:
  --output-dir DIR   Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version is required"

# Architecture is independent of host arch for a pure-script package, but
# dpkg requires an explicit value; use "all" to mark architecture-neutral.
ARCH="all"
DEB_PKG_NAME="documentdb-postgresql-tools"
FILE_PKG_NAME="documentdb-postgresql-tools"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb ..."

# ── Directory structure ─────────────────────────────────────────────
install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/bin"
install -d "${PKG_DIR}/etc/postgresql-common/createcluster.d"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

# ── Shell tools ─────────────────────────────────────────────────────
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-tune.sh" \
    "${PKG_DIR}/usr/bin/documentdb-tune"
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-createcluster.sh" \
    "${PKG_DIR}/usr/bin/documentdb-createcluster"
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-register-gateway.sh" \
    "${PKG_DIR}/usr/bin/documentdb-register-gateway"
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-gateway-admin.sh" \
    "${PKG_DIR}/usr/bin/documentdb-gateway-admin"

# ── createcluster.d hook (Debian/Ubuntu only) ───────────────────────
install -m 0644 "${REPO_ROOT}/documentdb-local/conf/99-documentdb.conf" \
    "${PKG_DIR}/etc/postgresql-common/createcluster.d/99-documentdb.conf"

# ── Inert config sample (PostgreSQL .sample convention) ─────────────
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/examples"
install -m 0644 "${REPO_ROOT}/packaging/postgresql-tools/documentdb.conf.sample" \
    "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/examples/documentdb.conf.sample"

# ── Copyright ───────────────────────────────────────────────────────
if [[ -f "${REPO_ROOT}/LICENSE" ]]; then
    cp "${REPO_ROOT}/LICENSE" "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"
elif [[ -f "${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_MIT" ]]; then
    cp "${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_MIT" "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"
else
    echo "MIT License" > "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"
fi

# ── Control file ────────────────────────────────────────────────────
INSTALLED_SIZE=$(du -sk "${PKG_DIR}" | cut -f1)

# Reviewer-flagged (GPT-5 iter 8): the previous Suggests included
# `postgresql-18-documentdb`, which misled operators on PG 15/16/17 hosts
# into apt-suggesting the wrong extension. The tools package is
# PG-agnostic per packaging-design.md §4.2 ("administrator scaffolding...
# useful even before those packages are installed"), so it now Suggests
# only the gateway runtime. Matches the RPM spec which never suggested
# the extension package either.
cat > "${PKG_DIR}/DEBIAN/control" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: documentdb-packaging-maintainers@microsoft.com
Installed-Size: ${INSTALLED_SIZE}
Depends: postgresql-common, jq
Suggests: documentdb-gateway
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: PostgreSQL administrator helpers for DocumentDB
 Ships documentdb-tune, documentdb-createcluster,
 documentdb-register-gateway, and documentdb-gateway-admin. These tools
 mutate PostgreSQL state (postgresql.conf, pg_hba.conf, pg_ident.conf,
 and the gateway PG role) on behalf of administrators. They are
 administrator scaffolding rather than a runtime artifact, so they only
 Suggest the gateway runtime package.
CONTROL

# ── Postinst (file-only; per design §6 maintainer scripts never mutate PG) ──
cat > "${PKG_DIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/bash
set -e

case "$1" in
    configure)
        echo "DocumentDB PostgreSQL administrator tools installed."
        echo ""
        echo "Available commands:"
        echo "  documentdb-tune --pg-version N --cluster C --yes"
        echo "  documentdb-createcluster N C --start    # Debian/Ubuntu"
        echo "  documentdb-register-gateway --target-postgres-instance N/C --yes"
        echo ""
        echo "documentdb-register-gateway requires the documentdb-gateway package"
        echo "to already be installed (the gateway OS user must exist before we"
        echo "write ident-map entries for it)."
        ;;
esac

exit 0
POSTINST
chmod 0755 "${PKG_DIR}/DEBIAN/postinst"

# ── Build ───────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_FILE}"

echo "Built: ${DEB_FILE}"
echo "Contents:"
dpkg-deb -c "${DEB_FILE}" | awk '{print "  " $NF}' | grep -v '/$'
