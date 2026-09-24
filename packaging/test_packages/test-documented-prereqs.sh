#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Prove the packaging/README.md RHEL prerequisite block is enough to install
# the extension RPM on a STOCK EL image (upstream documentdb/documentdb#75).
#
# The paved RHEL test images enable CRB in their own Dockerfiles, so they pass
# whatever the README says. This runs the README block verbatim (via
# extract-el-prereqs.sh), then `dnf install`s the built RPM. A negative control
# drops the CRB line and requires the install to fail on libqhull_r, so the
# suite cannot pass vacuously once a base image ships CRB enabled.
#
# Usage (on the host, needs docker):
#   ./packaging/test_packages/test-documented-prereqs.sh [--pg N] [--el 9|8]
#       [--packages-dir DIR] [--image IMG] [--skip-negative]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTRACT="${REPO_ROOT}/packaging/extract-el-prereqs.sh"

PG_MAJOR=18
EL_MAJOR=9
PACKAGES_DIR="${REPO_ROOT}/packaging"
BASE_IMAGE=""
RUN_NEGATIVE=1

PASS_COUNT=0
FAIL_COUNT=0
FAILED_IDS=()
WORK_DIR=""
LAST_LOG=""
trap '[[ -n "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"' EXIT

log()  { echo "[prereqs] $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo "FAIL $*"; }
die()  { echo "[prereqs] $*" >&2; exit 2; }
tail_log() { echo "--- tail of the failing run ---"; [[ -r "${LAST_LOG}" ]] && tail -n 25 "${LAST_LOG}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg)            PG_MAJOR="$2"; shift 2 ;;
        --el)            EL_MAJOR="$2"; shift 2 ;;
        --packages-dir)  PACKAGES_DIR="$2"; shift 2 ;;
        --image)         BASE_IMAGE="$2"; shift 2 ;;
        --skip-negative) RUN_NEGATIVE=0; shift ;;
        -h|--help)       sed -n '4,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)               die "unknown argument: $1" ;;
    esac
done

[[ "${EL_MAJOR}" == 9 || "${EL_MAJOR}" == 8 ]] || die "--el must be 9 or 8 (got ${EL_MAJOR})"
command -v docker >/dev/null 2>&1 || die "docker is required"
CRB_REPO=crb
[[ "${EL_MAJOR}" == 8 ]] && CRB_REPO=powertools
# Same base as the paved rhel-${EL_MAJOR} test images, minus their repo setup.
[[ -n "${BASE_IMAGE}" ]] || BASE_IMAGE="rockylinux:${EL_MAJOR}"

# The version glob skips debuginfo/debugsource siblings, which have no
# dependencies and would make both runs meaningless.
RPM_PATH="$(ls -t "${PACKAGES_DIR}"/rhel"${EL_MAJOR}"-postgresql"${PG_MAJOR}"-documentdb-[0-9]*.rpm 2>/dev/null | head -n 1)"
[[ -n "${RPM_PATH}" && -r "${RPM_PATH}" ]] || \
    die "no rhel${EL_MAJOR}-postgresql${PG_MAJOR}-documentdb-*.rpm in ${PACKAGES_DIR}; build it first: ./packaging/build_packages.sh --os rhel${EL_MAJOR} --pg ${PG_MAJOR}"
# docker reads a relative -v source as a named volume.
RPM_PATH="$(cd "$(dirname "${RPM_PATH}")" && pwd)/$(basename "${RPM_PATH}")"

case "${RPM_PATH}" in
    *.x86_64.rpm)  RPM_ARCH=x86_64;  PLATFORM=linux/amd64 ;;
    *.aarch64.rpm) RPM_ARCH=aarch64; PLATFORM=linux/arm64 ;;
    *)             die "cannot tell the arch of $(basename "${RPM_PATH}")" ;;
esac

PREREQ_CMDS="$("${EXTRACT}" --el "${EL_MAJOR}" --arch "${RPM_ARCH}")" || \
    die "could not extract the prerequisite block from packaging/README.md (see above)"

log "README block (EL${EL_MAJOR}, ${RPM_ARCH}):"
sed 's/^/    /' <<< "${PREREQ_CMDS}"
log "package: $(basename "${RPM_PATH}")"
log "image:   ${BASE_IMAGE} (${PLATFORM})"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prereqs-XXXXXX")" || die "mktemp failed"

# Only a depsolve failure says anything about the docs; anything else is a
# mirror or registry blip and gets one retry.
RESOLUTION_SIGNATURE='nothing provides|but none of the providers can be installed|cannot install the best candidate|conflicting requests|Depsolve Error'

# Returns dnf's exit status, 90 if the container never reached the install,
# or 91 if a README command itself failed. Sets LAST_LOG.
run_install_once() {
    local cmds="$2" runner="${WORK_DIR}/$1.sh" status
    LAST_LOG="${WORK_DIR}/$1.log"
    {
        # Stock images have no sudo; a function keeps the README lines verbatim.
        echo 'sudo() { "$@"; }'
        # Stop at the first failing README command, or a PGDG blip surfaces as
        # "nothing provides pg_cron_N" and is blamed on the docs.
        echo "trap 'st=\$?; echo \"PREREQ_EXIT=\${st}\"; exit \${st}' ERR"
        # -E: the ERR trap must also fire inside the sudo function.
        echo 'set -eEx'
        printf '%s\n' "${cmds}"
        echo 'set +eEx; trap - ERR'
        echo 'dnf install -y /tmp/documentdb.rpm; echo "INSTALL_EXIT=$?"'
    } > "${runner}"

    docker run --rm --platform "${PLATFORM}" \
        -v "${runner}:/runner.sh:ro" \
        -v "${RPM_PATH}:/tmp/documentdb.rpm:ro" \
        "${BASE_IMAGE}" bash /runner.sh 2>&1 | tee "${LAST_LOG}"

    # Anchored: xtrace echoes the trap text itself, prefixed with "+".
    grep -qE '^PREREQ_EXIT=' "${LAST_LOG}" && return 91
    status="$(grep -oE '^INSTALL_EXIT=[0-9]+' "${LAST_LOG}" | tail -n 1 | cut -d= -f2)"
    [[ -n "${status}" ]] || return 90
    return "${status}"
}

run_install() {
    local status
    run_install_once "$1" "$2"
    status=$?
    if (( status != 0 )) && { (( status == 91 )) || ! grep -qE "${RESOLUTION_SIGNATURE}" "${LAST_LOG}"; }; then
        log "failure has no depsolve signature; retrying once in case it was a mirror/registry blip"
        run_install_once "$1-retry" "$2"
        status=$?
    fi
    return "${status}"
}

# Name what broke: the docs, a README command, or the infrastructure.
infra_or_prereq_failure() {
    local id="$1" status="$2"
    case "${status}" in
        90) fail "${id}" "the container never reached the install (docker/network); this run proves nothing" ;;
        91) fail "${id}" "a README prerequisite command failed before the install (mirror trouble or a bad command in the block)" ;;
        *)  grep -qE "${RESOLUTION_SIGNATURE}" "${LAST_LOG}" && return 1
            fail "${id}" "install failed twice with no depsolve signature; infrastructure, not a documentation bug" ;;
    esac
    tail_log
    return 0
}

log "=== DOC-SUFFICIENT: README prerequisites, then dnf install ==="
run_install sufficient "${PREREQ_CMDS}"
status=$?
if (( status == 0 )); then
    pass "DOC-SUFFICIENT: the README prerequisites install postgresql${PG_MAJOR}-documentdb on stock EL${EL_MAJOR}/${RPM_ARCH}"
elif ! infra_or_prereq_failure DOC-SUFFICIENT "${status}"; then
    fail DOC-SUFFICIENT "the README prerequisites do NOT install the RPM on a stock EL${EL_MAJOR} host; the documented list is insufficient"
    tail_log
fi

if (( RUN_NEGATIVE )); then
    log "=== NEGATIVE-CONTROL: same block without ${CRB_REPO}, install must fail ==="
    run_install negative "$(grep -vF -- "--set-enabled ${CRB_REPO}" <<< "${PREREQ_CMDS}")"
    status=$?
    if (( status == 0 )); then
        fail NEGATIVE-CONTROL "install SUCCEEDED without ${CRB_REPO}; the base image or PGDG changed, so DOC-SUFFICIENT no longer proves CRB is documented"
    elif ! infra_or_prereq_failure NEGATIVE-CONTROL "${status}"; then
        # Checked after the depsolve signature: a download-phase failure prints
        # the resolved transaction, which lists libqhull_r from crb.
        if grep -q libqhull_r "${LAST_LOG}"; then
            pass "NEGATIVE-CONTROL: without ${CRB_REPO} the install fails on libqhull_r"
        else
            fail NEGATIVE-CONTROL "install fails without ${CRB_REPO}, but not on libqhull_r; update the README troubleshooting entry to the current error"
            tail_log
        fi
    fi
fi

echo
echo "passed: ${PASS_COUNT}   failed: ${FAIL_COUNT}${FAILED_IDS[*]:+ (${FAILED_IDS[*]})}"
(( FAIL_COUNT == 0 ))
