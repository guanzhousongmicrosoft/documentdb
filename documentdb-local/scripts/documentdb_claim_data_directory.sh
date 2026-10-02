#!/bin/bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

# "PID START_TIME" (postmaster.pid lines 1 and 3), which tells two postmasters apart.
postmaster_identity() {
    local pid start
    pid="$(sed -n 1p "$1" 2>/dev/null | tr -dc 0-9)"
    start="$(sed -n 3p "$1" 2>/dev/null | tr -dc 0-9)"
    [ -n "$pid" ] && [ -n "$start" ] && printf '%s %s\n' "$pid" "$start"
}

postmaster_owner_file() {
    printf '%s/.documentdb-local/postmaster-owner' "$1"
}

# Record the running postmaster when it holds this directory's lock itself, so a
# later claim that finds the lock free knows that postmaster is gone. A pidfile
# from an image without the lock never matches and still refuses (ADO PR 2267891).
record_postmaster_owner() {
    local owner file
    [ "$1" -ef /proc/self/fd/200 ] && flock -n 200 || return 0
    owner="$(postmaster_identity "$1/postmaster.pid")" || return 0
    [ "$1" -ef "/proc/${owner%% *}/fd/200" ] || return 0
    file="$(postmaster_owner_file "$1")"
    if ! { mkdir -p "${file%/*}" && printf '%s\n' "$owner" >"$file.tmp" && mv -f "$file.tmp" "$file"; } 2>/dev/null; then
        echo "Warning: cannot record the postmaster in $file; after an unclean stop this volume will need DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true to start." >&2
    fi
}

claim_data_directory() {
    local pidfile="$1/postmaster.pid" pid owner notice
    if [ ! -d "$1" ]; then
        echo "Error: data directory $1 does not exist or is inaccessible." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
        exit 1
    fi
    if [ ! -r "$1" ] || [ ! -x "$1" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            echo "Error: cannot access data directory $1." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
            exit 1
        fi
        exec sudo -E bash "${BASH_SOURCE[0]}" "$1" "${BASH_SOURCE[1]}" "$PATH" "$(id -G)"
    fi
    if ! [ "$1" -ef /proc/self/fd/200 ]; then
        exec 200<"$1" || exit 1
    fi
    flock -n 200 || {
        echo "Error: another DocumentDB container is already using the data directory $1. Refusing to start: two PostgreSQL instances on one data directory would corrupt it, and taking it over would shut the running container's database down too. Give this container its own volume, or stop the container already serving $1." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
        exit 1
    }
    [ -f "$pidfile" ] || return 0
    pid="$(sed -n 1p "$pidfile" 2>/dev/null | tr -dc 0-9)"
    owner="$(postmaster_identity "$pidfile")"
    if [ -n "$owner" ] && [ "$owner" = "$(cat "$(postmaster_owner_file "$1")" 2>/dev/null)" ]; then
        # That postmaster held this lock, and the lock is free, so it is gone.
        notice="Warning: removing $pidfile (PID ${pid}) left by an unclean stop of the previous container; PostgreSQL will run crash recovery."
    elif [ "${DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID:-false}" = "true" ]; then
        notice="Warning: removing $pidfile because DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true bypassed the in-use check; PostgreSQL may need crash recovery. Unset the variable once this container is up, it stays in force on every later start."
    else
        echo "Error: $pidfile exists (PID ${pid:-unknown}) and another container may still be serving this data directory, including one running an older image that takes no lock. Refusing to start. Stop every other container using $1, then create or recreate this container with DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true (docker start cannot add it) to remove the file and start." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
        exit 1
    fi
    if [ ! -w "$1" ]; then
        chmod u+w "$1" 2>/dev/null || sudo chmod u+w "$1" || {
            echo "Error: cannot make $1 writable to remove stale $pidfile." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
            exit 1
        }
    fi
    echo "$notice" | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
    rm -f "$pidfile" || { echo "Error: cannot remove stale $pidfile." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2; exit 1; }
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

set -euo pipefail
data_path="${1:?}"
entrypoint="${2:?}"
original_path="${3:?}"
original_groups="${4:?}"
runtime_uid="${SUDO_UID:?}"
runtime_gid="${SUDO_GID:?}"
runtime_user="${SUDO_USER:?}"

claim_data_directory "$data_path"
if [ "$(stat -c '%u' "$data_path")" != "$runtime_uid" ]; then
    chown "$runtime_uid:$runtime_gid" "$data_path"
    export DOCUMENTDB_FORCE_OWNERSHIP_REPAIR=true
fi
chmod u+rwx "$data_path"
exec setpriv --reuid="$runtime_uid" --regid="$runtime_gid" --groups="${original_groups// /,}" \
    env PATH="$original_path" USER="$runtime_user" LOGNAME="$runtime_user" \
    bash "$entrypoint"
