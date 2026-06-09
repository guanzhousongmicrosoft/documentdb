#!/bin/bash
# Build the three "extra" packages that complete the four-package shape from
# packaging-design.md §4:
#
#   - documentdb-postgresql-tools   (admin helpers; arch:all / noarch, PG-agnostic)
#   - documentdb-N                  (per-major stand-alone wrapper; arch:all / noarch)
#   - documentdb                    (meta package; arch:all / noarch; pinned to default PG major)
#
# The main extension build (packaging/build_packages.sh) and the gateway
# build (packaging/gateway/build_gateway_packages.sh) already cover the
# other two of the four packages. This orchestrator is the missing piece
# CI used to skip.
#
# Usage:
#   build_extra_packages.sh --type deb --pg N --version V [--output-dir DIR] [--default-pg-major N] [--os-prefix STR]
#   build_extra_packages.sh --type rpm --pg N --version V [--output-dir DIR] [--default-pg-major N]
#
# The --os-prefix is applied to .deb filenames so they sit alongside the
# extension/gateway outputs (which already use an OS-name prefix produced
# by packaging-entrypoint.sh / build-gateway-deb.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PACKAGE_TYPE=""
PG_VERSION=""
DOCUMENTDB_VERSION=""
OUTPUT_DIR="${SCRIPT_DIR}"
DEFAULT_PG_MAJOR="18"
OS_PREFIX=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build_extra_packages.sh --type {deb|rpm} --pg N --version V [OPTIONS]

Build documentdb-postgresql-tools, documentdb-<N>, and documentdb (meta).

Required:
  --type {deb|rpm}        Package format
  --pg N                  PostgreSQL major version the stand-alone wraps
  --version V             DocumentDB version string (e.g., 0.114.0)

Optional:
  --output-dir DIR        Drop directory for built artifacts (default: packaging/)
  --default-pg-major N    PG major the meta package pins to (default: 18)
  --os-prefix STR         Prefix prepended to DEB filenames (matches the
                          existing OS-name convention used by
                          packaging-entrypoint.sh / build-gateway-deb.sh)
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) PACKAGE_TYPE="$2"; shift 2 ;;
        --pg) PG_VERSION="$2"; shift 2 ;;
        --version) DOCUMENTDB_VERSION="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --default-pg-major) DEFAULT_PG_MAJOR="$2"; shift 2 ;;
        --os-prefix) OS_PREFIX="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${PACKAGE_TYPE}" ]] || die "--type is required"
[[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg must be a number (e.g., 18)"
[[ -n "${DOCUMENTDB_VERSION}" ]] || die "--version is required"

mkdir -p "${OUTPUT_DIR}"

if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
    echo "Building extras (DEB) for pg=${PG_VERSION} version=${DOCUMENTDB_VERSION} ..."

    # 1. documentdb-postgresql-tools (PG-agnostic; arch:all)
    "${SCRIPT_DIR}/postgresql-tools/build-postgresql-tools-deb.sh" \
        --version "${DOCUMENTDB_VERSION}" \
        --output-dir "${OUTPUT_DIR}"

    # 2. documentdb-N (per-major stand-alone)
    "${SCRIPT_DIR}/standalone/build-standalone-deb.sh" \
        --version "${DOCUMENTDB_VERSION}" \
        --pg-version "${PG_VERSION}" \
        --output-dir "${OUTPUT_DIR}"

    # 3. documentdb meta — only built when this PG version matches the
    # paved-road default. The meta package pins to one default major; building
    # it once per matrix cell would produce redundant identical artifacts (it
    # depends only on documentdb-<DEFAULT_PG_MAJOR>), and uploads would clash
    # on artifact name. Mirrors the RPM path below.
    if [[ "${PG_VERSION}" == "${DEFAULT_PG_MAJOR}" ]]; then
        "${SCRIPT_DIR}/standalone/build-meta-deb.sh" \
            --version "${DOCUMENTDB_VERSION}" \
            --default-pg-major "${DEFAULT_PG_MAJOR}" \
            --output-dir "${OUTPUT_DIR}"
    fi

    # Match the OS-name prefix convention used by the other DEB builders
    # so artifact paths are uniform across the four packages.
    if [[ -n "${OS_PREFIX}" ]]; then
        cd "${OUTPUT_DIR}"
        extras_to_rename=(
            "documentdb-postgresql-tools_${DOCUMENTDB_VERSION}_all.deb"
            "documentdb-${PG_VERSION}_${DOCUMENTDB_VERSION}_all.deb"
        )
        if [[ "${PG_VERSION}" == "${DEFAULT_PG_MAJOR}" ]]; then
            extras_to_rename+=("documentdb_${DOCUMENTDB_VERSION}_all.deb")
        fi
        for base in "${extras_to_rename[@]}"; do
            if [[ -f "${base}" ]]; then
                mv -f "${base}" "${OS_PREFIX}-${base}"
            fi
        done
        cd - >/dev/null
    fi

elif [[ "${PACKAGE_TYPE}" == "rpm" ]]; then
    echo "Building extras (RPM) for pg=${PG_VERSION} version=${DOCUMENTDB_VERSION} ..."

    command -v rpmbuild >/dev/null 2>&1 || die "rpmbuild not found on PATH"

    # rpmbuild needs a topdir tree. Use a tmpdir under the chosen output
    # directory so build artifacts are cleaned up automatically.
    RPM_TOPDIR="$(mktemp -d "${OUTPUT_DIR}/.rpmbuild.XXXXXX")"
    trap 'rm -rf "${RPM_TOPDIR}"' EXIT
    mkdir -p "${RPM_TOPDIR}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    # Source files that the three specs reference via %{_sourcedir}/
    SCRIPTS_SRC="${REPO_ROOT}/documentdb-local/scripts"
    APPLIANCE_SRC="${REPO_ROOT}/packaging/appliance"

    # 1. documentdb-postgresql-tools sources + spec
    cp "${SCRIPTS_SRC}/documentdb-tune.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-createcluster.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-register-gateway.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-gateway-admin.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPT_DIR}/postgresql-tools/documentdb.conf.sample" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPT_DIR}/rpm/spec/documentdb-tools.spec" "${RPM_TOPDIR}/SPECS/"
    sed -i "s/DOCUMENTDB_VERSION/${DOCUMENTDB_VERSION}/g" "${RPM_TOPDIR}/SPECS/documentdb-tools.spec"
    rpmbuild -bb "${RPM_TOPDIR}/SPECS/documentdb-tools.spec" --define "_topdir ${RPM_TOPDIR}"

    # 2. documentdb-<N> sources + spec
    cp "${SCRIPTS_SRC}/documentdb-setup.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-local-reset.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb_postgresql_service.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/init_documentdb_data.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${APPLIANCE_SRC}/systemd/documentdb-local@.target" "${RPM_TOPDIR}/SOURCES/"
    cp "${APPLIANCE_SRC}/systemd/documentdb-postgresql@.service" "${RPM_TOPDIR}/SOURCES/"
    cp "${APPLIANCE_SRC}/systemd/documentdb-gateway-local@.service" "${RPM_TOPDIR}/SOURCES/"
    cp "${APPLIANCE_SRC}/sysusers/documentdb-local.conf" "${RPM_TOPDIR}/SOURCES/documentdb-local-sysusers.conf"
    cp "${APPLIANCE_SRC}/tmpfiles/documentdb-local.conf" "${RPM_TOPDIR}/SOURCES/documentdb-local-tmpfiles.conf"
    mkdir -p "${RPM_TOPDIR}/SOURCES/sample-data"
    cp -r "${REPO_ROOT}/documentdb-local/sample-data/." "${RPM_TOPDIR}/SOURCES/sample-data/"

    cp "${SCRIPT_DIR}/rpm/spec/documentdb-local.spec" "${RPM_TOPDIR}/SPECS/documentdb-local.spec"
    sed -i "s/POSTGRES_VERSION/${PG_VERSION}/g; s/DOCUMENTDB_VERSION/${DOCUMENTDB_VERSION}/g" \
        "${RPM_TOPDIR}/SPECS/documentdb-local.spec"
    rpmbuild -bb "${RPM_TOPDIR}/SPECS/documentdb-local.spec" --define "_topdir ${RPM_TOPDIR}"

    # 3. documentdb meta — only build it when this PG version matches the
    # paved-road default. The meta package pins to one default major; building
    # it once per matrix cell would produce redundant identical artifacts and
    # uploads would clash on artifact name.
    if [[ "${PG_VERSION}" == "${DEFAULT_PG_MAJOR}" ]]; then
        cp "${SCRIPT_DIR}/rpm/spec/documentdb-local-meta.spec" "${RPM_TOPDIR}/SPECS/"
        sed -i "s/DOCUMENTDB_VERSION/${DOCUMENTDB_VERSION}/g" \
            "${RPM_TOPDIR}/SPECS/documentdb-local-meta.spec"
        rpmbuild -bb "${RPM_TOPDIR}/SPECS/documentdb-local-meta.spec" --define "_topdir ${RPM_TOPDIR}"
    fi

    # Move every produced RPM out to the output dir
    find "${RPM_TOPDIR}/RPMS" -type f -name '*.rpm' -exec cp -f {} "${OUTPUT_DIR}/" \;

else
    die "Unknown --type: ${PACKAGE_TYPE} (expected deb or rpm)"
fi

echo "Extras built into: ${OUTPUT_DIR}"
ls -1 "${OUTPUT_DIR}"/documentdb*postgresql-tools* "${OUTPUT_DIR}"/documentdb-${PG_VERSION}* "${OUTPUT_DIR}"/documentdb[._-]${DOCUMENTDB_VERSION}* 2>/dev/null || true
