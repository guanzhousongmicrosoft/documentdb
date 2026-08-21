#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# extract-el-prereqs.sh — print the RHEL/EL prerequisite commands, extracted
# from the ONE authoritative copy in packaging/README.md.
#
# packaging/README.md fences that copy with <!-- BEGIN/END:el-prereqs -->. Every
# other place that shows a user these commands calls this script instead of
# restating them, so the copies cannot drift:
#
#   - packaging/test_packages/test-documented-prereqs.sh   (executes them)
#   - .github/workflows/documentdb_release.yml             (release body)
#   - .github/workflows/build_all_packages.yml             (bundle job summary)
#
# Three copies cannot be generated -- the two RPM %description blocks are baked
# in at package build time, and the gateway design doc is prose-of-record. For
# those, --check-copies asserts they still carry every documented prerequisite.
#
# Usage:
#   ./packaging/extract-el-prereqs.sh [--el 9|8] [--arch x86_64|aarch64] [--no-sudo]
#   ./packaging/extract-el-prereqs.sh --check-copies

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${REPO_ROOT}/packaging/README.md"

EL_MAJOR=9
ARCH=x86_64
STRIP_SUDO=0
CHECK_COPIES=0

die() { echo "[el-prereqs] $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --el)          EL_MAJOR="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --no-sudo)     STRIP_SUDO=1; shift ;;
        --check-copies) CHECK_COPIES=1; shift ;;
        -h|--help)     sed -n '1,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)             die "unknown argument: $1" ;;
    esac
done

[[ "${EL_MAJOR}" == "9" || "${EL_MAJOR}" == "8" ]] || die "--el must be 9 or 8 (got ${EL_MAJOR})"
[[ "${ARCH}" == "x86_64" || "${ARCH}" == "aarch64" ]] || die "--arch must be x86_64 or aarch64 (got ${ARCH})"
[[ -r "${README}" ]] || die "cannot read ${README}"

# EL8 calls the CodeReady Builder repo "powertools"; EL9 renamed it to "crb".
CRB_REPO=crb
[[ "${EL_MAJOR}" == "8" ]] && CRB_REPO=powertools

# Take the ```bash fence between the markers and strip the blockquote prefix.
CMDS="$(awk '
    /BEGIN:el-prereqs/      { inblock = 1; next }
    /END:el-prereqs/        { inblock = 0; next }
    inblock && /^> ```/     { infence = !infence; next }
    inblock && infence      { sub(/^> ?/, ""); print }
' "${README}")"

[[ -n "${CMDS}" ]] || die "no commands found between BEGIN/END:el-prereqs markers in ${README} — did the block move or lose its markers?"

# Guard the extraction: a silent mis-parse that yielded prose would otherwise
# be published to users (or "executed" and pass trivially).
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^sudo[[:space:]]+dnf[[:space:]] ]] || \
        die "extracted a non-dnf line from the README block: '${line}'"
done <<< "${CMDS}"

# The two lines users most often omit, and the reason GitHub issue #75 existed.
grep -q -- "--set-enabled crb" <<< "${CMDS}" || \
    die "the README prerequisite block no longer enables CRB — that is exactly the regression this tooling exists to catch (GitHub issue #75)"
grep -q -- "epel-release" <<< "${CMDS}" || \
    die "the README prerequisite block no longer installs epel-release — PGDG's postgis36_N needs hdf5 and xerces-c from EPEL"

# --check-copies: verify (rather than generate) the copies that cannot be
# generated -- the two RPM %description blocks and the gateway design doc.
if (( CHECK_COPIES )); then
    # Whitespace-normalise both sides. `sed -E` (not BRE `\+`) because BSD sed
    # on macOS treats `\+` as a literal plus and silently normalises nothing.
    normalise() { sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }
    status=0
    for spec in "${REPO_ROOT}/packaging/rpm/spec/documentdb.spec" \
                "${REPO_ROOT}/packaging/rpm/spec/documentdb-local-meta.spec" \
                "${REPO_ROOT}/packaging/gateway/packaging-design.md"; do
        [[ -r "${spec}" ]] || { echo "[el-prereqs] cannot read ${spec}" >&2; status=1; continue; }
        spec_norm="$(normalise < "${spec}")"
        missing=()
        # PRESENCE, not set equality or ordering: a copy may legitimately carry
        # other dnf lines (documentdb-local-meta.spec documents `dnf remove`) or
        # list these in a different order (packaging-design.md does). The
        # invariant is only that every documented prerequisite still appears.
        while IFS= read -r cmd; do
            [[ -z "${cmd}" ]] && continue
            cmd="$(normalise <<< "${cmd}")"
            grep -qF -- "${cmd}" <<< "${spec_norm}" || missing+=("${cmd}")
        done <<< "${CMDS}"

        if (( ${#missing[@]} == 0 )); then
            echo "[el-prereqs] OK  $(basename "${spec}") carries every documented prerequisite"
        else
            echo "[el-prereqs] DRIFT  $(basename "${spec}") is missing prerequisite lines that packaging/README.md documents:" >&2
            printf '    %s\n' "${missing[@]}" >&2
            status=1
        fi
    done
    exit "${status}"
fi

# Apply exactly the substitutions the README documents for other EL majors and
# architectures.
sed -e "s#/EL-9-#/EL-${EL_MAJOR}-#" \
    -e "s#-${EL_MAJOR}-x86_64/#-${EL_MAJOR}-${ARCH}/#" \
    -e "s/--set-enabled crb/--set-enabled ${CRB_REPO}/" \
    <<< "${CMDS}" \
| if (( STRIP_SUDO )); then sed 's/^sudo //'; else cat; fi
