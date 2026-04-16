#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin_file="${1:-${TEST_IMAGE_PIN_FILE:-${script_dir}/test-image-pin.txt}}"

if [[ ! -f "${pin_file}" ]]; then
    echo "Missing pinned test image file: ${pin_file}" >&2
    exit 1
fi

pinned_image="$(
    sed \
        -e 's/[[:space:]]*#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' \
        -e '/^[[:space:]]*$/d' \
        "${pin_file}"
)"

line_count="$(echo "${pinned_image}" | wc -l | tr -d ' ')"
if [[ "${line_count}" -ne 1 ]]; then
    echo "Expected exactly one pinned image in ${pin_file}, found ${line_count} non-comment lines" >&2
    exit 1
fi

if [[ -z "${pinned_image}" ]]; then
    echo "No pinned test image found in ${pin_file}" >&2
    exit 1
fi

printf '%s\n' "${pinned_image}"
