# Shared helpers for the validation scripts. Source it.
set -uo pipefail
VAL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(dirname "$VAL")
OUT=${OUT:-$ROOT/validation-out}; mkdir -p "$OUT"
D=${DOCKER:-docker}
case "$(uname -m)" in x86_64) ARCH=amd64; RARCH=x86_64 ;; *) ARCH=arm64; RARCH=aarch64 ;; esac
GH_REPO_LC=$(tr '[:upper:]' '[:lower:]' <<<"${GITHUB_REPOSITORY:-guanzhousongmicrosoft/documentdb}")
NEW_REPO=ghcr.io/$GH_REPO_LC/documentdb-local;    NEW_TAG=${NEW_TAG:-1.2-rc1}; NEW_EXT=1.2-0
OLD_REPO=ghcr.io/documentdb/documentdb/documentdb-local; OLD_TAG=${OLD_TAG:-1.0.0};   OLD_EXT=1.0-0
BUNDLE_RUN=${BUNDLE_RUN:-42905966702}; BUNDLE_NAME='documentdb-packages-1.2~rc1'
PW='Val-Pw-7719-xK'; USR=valadmin
TLSQ='tls=true&tlsAllowInvalidCertificates=true'
img() { # new|old pg
    if [ "$1" = new ]; then echo "$NEW_REPO:pg$2-$NEW_TAG"; else echo "$OLD_REPO:pg$2-$OLD_TAG"; fi
}
# rec <id> <P0|P1|P2> <PASS|FAIL|INFO> <target> <detail>
rec() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" | tee -a "$OUT/results.tsv"; }
# chk <id> <pri> <target> <detail> <cmd...>: PASS when the command succeeds
chk() { local id=$1 pri=$2 tgt=$3 det=$4; shift 4
    if "$@" >>"$OUT/chk.log" 2>&1; then rec "$id" "$pri" PASS "$tgt" "$det"; else rec "$id" "$pri" FAIL "$tgt" "$det"; return 1; fi; }
eq() { [ "$1" = "$2" ] || { echo "expected [$2] got [$1]"; return 1; }; }
fetch_new_pkgs() { mkdir -p "$1"; [ -n "$(ls "$1" 2>/dev/null)" ] || gh run download "$BUNDLE_RUN" -R "$GH_REPO_LC" -n "$BUNDLE_NAME" -D "$1"; }
fetch_old_pkgs() { mkdir -p "$1"; [ -n "$(ls "$1" 2>/dev/null)" ] || gh release download v1.0-0 -R documentdb/documentdb -D "$1"; }
wait_ready() { # container [timeout s] [since]
    local c=$1 t=${2:-300} i=0
    while [ $i -lt "$t" ]; do
        [ "$($D logs ${3:+--since "$3"} "$c" 2>&1 | grep -c 'Gateway ready to accept connections')" -gt 0 ] && return 0
        [ "$($D inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || return 1
        sleep 2; i=$((i + 2))
    done; return 1
}
# msh <container> <eval>  /  mshf <container> <file in container>
uri() { echo "mongodb://$USR:$PW@localhost:${1:-10260}/?$TLSQ"; }
msh() { local c=$1; shift; $D exec "$c" mongosh "$(uri)" --quiet --eval "$@" 2>&1; }
mshf() { local c=$1 f=$2; shift 2; $D exec "$c" mongosh "$(uri)" --quiet "$@" --file "$f" 2>&1; }
psqlc() { local c=$1; shift; $D exec "$c" psql -p 9712 -d postgres -XAtc "$@" 2>&1; }
start() { # name image [docker args...] -- [image args...]
    local name=$1 image=$2; shift 2; local dargs=() iargs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do dargs+=("$1"); shift; done; [ $# -gt 0 ] && shift; iargs=("$@")
    $D rm -f "$name" >/dev/null 2>&1
    $D run -d --name "$name" -e DOCUMENTDB_USAGE_TELEMETRY=false "${dargs[@]}" "$image" --username "$USR" --password "$PW" "${iargs[@]}" >/dev/null
}
dumplogs() { $D logs "$1" > "$OUT/$1.log" 2>&1 || true; }
