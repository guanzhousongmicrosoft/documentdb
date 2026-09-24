#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Print the RHEL prerequisite block from packaging/README.md, rewritten for one
# EL major and arch the way the README's prose says to. The README is the only
# copy consumers generate from: test_packages/test-documented-prereqs.sh runs
# the output on a stock EL image and build_all_packages.yml prints it next to
# the .rpm download. The RPM %description and release-footer copies are pinned
# by RhelPrerequisitePinTests instead, which also checks this parser agrees.
#
# Usage: ./packaging/extract-el-prereqs.sh [--el 9|8] [--arch x86_64|aarch64]

set -euo pipefail

README="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/README.md"
HEADING='> **RHEL / Rocky / AlmaLinux prerequisite'
EL_MAJOR=9
ARCH=x86_64

die() { echo "[el-prereqs] $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --el)   EL_MAJOR="${2:-}"; shift 2 ;;
        --arch) ARCH="${2:-}"; shift 2 ;;
        -h|--help) sed -n '4,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ "${EL_MAJOR}" == 9 || "${EL_MAJOR}" == 8 ]] || die "--el must be 9 or 8 (got ${EL_MAJOR})"
[[ "${ARCH}" == x86_64 || "${ARCH}" == aarch64 ]] || die "--arch must be x86_64 or aarch64 (got ${ARCH})"
[[ -r "${README}" ]] || die "cannot read ${README}"

# A second heading would silently pick the wrong block.
count="$(grep -cF -- "${HEADING}" "${README}" || true)"
[[ "${count}" == 1 ]] || die "expected one '${HEADING}' blockquote in ${README}, found ${count}"

# First ```bash fence inside that blockquote, with the "> " prefix stripped.
CMDS="$(awk -v heading="${HEADING}" '
    !quote && index($0, heading) == 1 { quote = 1; next }
    quote && !/^>/ { exit }
    quote {
        line = $0; sub(/^> ?/, "", line)
        if (!fence && line ~ /^```bash[ \t]*$/) { fence = 1; next }
        if (fence && line ~ /^```[ \t]*$/) exit
        if (fence) print line
    }
' "${README}")"

[[ -n "${CMDS}" ]] || die "no \`\`\`bash fence under '${HEADING}' in ${README}"

# CI executes these and users paste them, so a mis-parse must not get through.
while IFS= read -r line; do
    [[ "${line}" == "sudo "* ]] || die "the README prerequisite fence may hold only 'sudo' lines, got: '${line}'"
done <<< "${CMDS}"

# One tripwire per line: a deletion reaches every pinned copy at once, and the
# stock-host install cannot notice `module disable postgresql` going, since the
# RPM Requires versioned PGDG names the AppStream module never shadows.
for required in dnf-plugins-core pgdg-redhat-repo epel-release "--set-enabled crb" "module disable postgresql"; do
    grep -qF -- "${required}" <<< "${CMDS}" || die "the README prerequisite block no longer contains '${required}'"
done

CRB_REPO=crb
[[ "${EL_MAJOR}" == 8 ]] && CRB_REPO=powertools

OUT="$(sed -E \
    -e "s#/EL-[0-9]+-(x86_64|aarch64)/#/EL-${EL_MAJOR}-${ARCH}/#g" \
    -e "s#epel-release-latest-[0-9]+\\.#epel-release-latest-${EL_MAJOR}.#g" \
    -e "s#codeready-builder-for-rhel-[0-9]+-(x86_64|aarch64)-#codeready-builder-for-rhel-${EL_MAJOR}-${ARCH}-#g" \
    -e "s#--set-enabled crb( |\$)#--set-enabled ${CRB_REPO}\\1#g" \
    <<< "${CMDS}")"

# Fail closed: a new URL shape must not yield an EL9 URL beside `powertools`.
for expected in "/EL-${EL_MAJOR}-${ARCH}/" "epel-release-latest-${EL_MAJOR}." \
                "codeready-builder-for-rhel-${EL_MAJOR}-${ARCH}-" "--set-enabled ${CRB_REPO}"; do
    grep -qF -- "${expected}" <<< "${OUT}" || die "the EL${EL_MAJOR}/${ARCH} rewrite did not produce '${expected}'; the README block changed shape, update $(basename "$0")"
done
stale="$(grep -oE '(EL|rhel|latest)-[0-9]+|x86_64|aarch64' <<< "${OUT}" | grep -vxE "(EL|rhel|latest)-${EL_MAJOR}|${ARCH}" || true)"
[[ -z "${stale}" ]] || die "the EL${EL_MAJOR}/${ARCH} rewrite left '$(head -n 1 <<< "${stale}")' behind"

printf '%s\n' "${OUT}"
