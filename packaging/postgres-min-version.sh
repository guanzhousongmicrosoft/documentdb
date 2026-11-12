# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Packages and images take PostgreSQL from PGDG at build time, so they must not
# be built on an older minor than the one the test suites build from source
# (POSTGRES_<major>_REF in scripts/setup_versions.sh). Sourced by bash.

# REL_17_12 -> 17.12. Prints nothing when the pin is not a release tag, such as
# REL_19_STABLE before 19.0 ships.
documentdb_postgres_min_version() {
    local major=$1 setup_versions=$2 ref
    [[ "$major" =~ ^[0-9]+$ ]] \
        || { echo "ERROR: '$major' is not a PostgreSQL major version" >&2; return 1; }
    ref=$(bash -c 'set -e; . "$1"; GetPostgresSourceRef "$2"' _ "$setup_versions" "$major") \
        || { echo "ERROR: no PostgreSQL $major pin in $setup_versions" >&2; return 1; }
    if [[ "$ref" =~ ^REL_${major}_([0-9]+)$ ]]; then
        echo "${major}.${BASH_REMATCH[1]}"
    fi
}

# <found> is what the package manager reports, e.g. 17.12-1.pgdg24.04+1 or
# 17.12-1PGDG.rhel9.8.
documentdb_check_postgres_version() {
    local major=$1 found=$2 setup_versions=$3 min
    min=$(documentdb_postgres_min_version "$major" "$setup_versions") || return 1
    if [[ -z "$min" ]]; then
        echo "PostgreSQL $major is not pinned to a release in $setup_versions; not checking $found"
        return 0
    fi
    if [[ ! "${found#*:}" =~ ^${major}\.([0-9]+)([^0-9]|$) ]]; then
        echo "ERROR: cannot read a PostgreSQL $major minor version from '$found'" >&2
        return 1
    fi
    if (( 10#${BASH_REMATCH[1]} < 10#${min#*.} )); then
        echo "ERROR: PostgreSQL $found is older than $min, the release the tests run on" \
             "(scripts/setup_versions.sh). Wait until PGDG serves $min for this platform." >&2
        return 1
    fi
    echo "PostgreSQL $found is at least $min, the release the tests run on"
}
