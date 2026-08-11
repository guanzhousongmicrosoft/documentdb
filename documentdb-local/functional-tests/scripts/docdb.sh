#!/bin/bash
# docdb: one entry point for documentdb-local functional testing and packaging.
#
# Everything a developer needs is a subcommand here, so there is one thing to
# learn and one thing to keep in sync with CI:
#
#   docdb test      run functional tests (a subset, or the whole suite)
#   docdb suite     manage the functional-tests checkout and its pinned revision
#   docdb xfail     manage the known-failure (xfail) lists
#   docdb build     build the documentdb-local image and the OS packages
#   docdb env       start / stop / inspect the local engine
#   docdb selftest  run this harness's own tests
#
# DESIGN RULE, and the reason this file is a dispatcher rather than an
# implementation: nothing here reimplements a run. The workflow in
# .github/workflows/functional_tests.yml drives scripts/run_pytest_split.sh, so
# the split legs here invoke exactly that script through exactly the same
# environment contract, and the single-engine modes invoke
# scripts/run-functional-tests.sh. The slice arithmetic, the crash-cascade
# recovery, the collection guards and the verdict (functional_gate.py
# recover-and-gate) therefore match CI by construction rather than by copy.
# The same holds for the rest: `suite` wraps setup_functional_tests.sh, `xfail`
# wraps functional_gate.py, and `build` wraps the packaging scripts.
#
# Those wrapped scripts are CI entry points and keep working on their own; they
# are implementation details of this command, not competing front doors.
#
# Usage: documentdb-local/functional-tests/scripts/docdb.sh <command> [options]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FT="$(cd "${SCRIPT_DIR}/.." && pwd)"                     # .../functional-tests
LOCAL_ROOT="$(cd "${FT}/.." && pwd)"                     # .../documentdb-local
ROOT="$(cd "${LOCAL_ROOT}/.." && pwd)"                   # the tree holding documentdb-local/

CONFIG="${FT}/config"
TOOLS="${FT}/tools"
GATE_PY="${TOOLS}/functional_gate.py"
RUNNER="${SCRIPT_DIR}/run-functional-tests.sh"
SPLIT_SH="${DOCDB_SPLIT_SH:-${SCRIPT_DIR}/run_pytest_split.sh}"
SETUP_SH="${SCRIPT_DIR}/setup_functional_tests.sh"
IMAGE_YML="${CONFIG}/image.yml"
PACKAGING="${ROOT}/packaging"
SUITE_DIR="${DOCDB_SUITE_DIR:-${ROOT}/docdb_functional_tests}"

FAILING_LIST="${CONFIG}/oss_ci_failing_tests.txt"
FLAKY_LIST="${CONFIG}/oss_ci_flaky_tests.txt"
CRASH_LIST="${CONFIG}/ci_crash_tests.txt"

info() { printf '[docdb] %s\n' "$*"; }
warn() { printf '[docdb] WARNING: %s\n' "$*" >&2; }
err()  { printf '[docdb] ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# `shift 2` does not shift when only one argument remains, and this script runs
# without `set -e`, so an option missing its value would spin its parsing loop
# forever. Every option that consumes a value must guard with this first.
need_arg() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

usage() {
  cat <<'EOF'
docdb: one entry point for documentdb-local functional testing and packaging.

USAGE
  documentdb-local/functional-tests/scripts/docdb.sh <command> [options]

COMMANDS
  test        Run functional tests (subset or full suite)
  suite       Manage the functional-tests checkout and its pinned revision
  xfail       Manage the known-failure (xfail) lists
  build       Build the documentdb-local image and the OS packages
  env         Start / stop / inspect the local engine
  selftest    Run this harness's own tests
  help        Show this text, or `docdb <command> --help`

COMMON WORKFLOWS
  # iterate on the area you changed
  docdb.sh test --tests compatibility/tests/core/cursors

  # feature finished: the full suite under the xfail model (the CI gate)
  docdb.sh test --all

  # what actually fails, ignoring the xfail lists
  docdb.sh test --all --no-xfail

  # build the image and packages, then test against them end to end
  docdb.sh build --target both
  docdb.sh test --all --build-and-start

  # move the suite pin, then re-baseline the lists from a full run
  docdb.sh suite pin --sha <commit>
  docdb.sh suite update
  docdb.sh test --all --results-dir /tmp/rebase
  docdb.sh xfail reconcile --report /tmp/rebase/report.json --prune-uncollected

Set CONNECTION_STRING, or pass --build-and-start, to point the run at an engine.
EOF
}

# =============================================================================
# suite: the functional-tests checkout and its pin
# =============================================================================
pinned_sha()   { awk '/^source_sha:/ {print $2; exit}' "${IMAGE_YML}" 2>/dev/null; }
local_sha()    { git -C "${SUITE_DIR}" rev-parse HEAD 2>/dev/null; }

SUITE_REGISTRY="${DOCDB_SUITE_REGISTRY:-ghcr.io}"
SUITE_IMAGE_REPO="${DOCDB_SUITE_IMAGE_REPO:-documentdb/functional-tests}"

# config/image.yml names ONE thing: the suite commit. Both ways of running the
# suite are derived from it.
#
#   host checkout   setup_functional_tests.sh clones that commit. The split legs
#                   run from it, and so does CI.
#   suite image     run-functional-tests.sh resolves the image upstream
#                   publishes for that commit, tagged sha-<short7>. gate, full,
#                   single and smoke run inside it.
#
# Deriving both is the point. When the image was recorded as a second field it
# could name a different suite version than source_sha, so a local gate answered
# a different question than CI while every status line still read "in sync".
# There is now nothing to disagree with.
#
# This formula is duplicated in run-functional-tests.sh, which cannot source
# this file; tests/test_docdb.sh asserts the two stay identical.
derived_image() {
  local sha="${1:-$(pinned_sha)}"
  [ -n "${sha}" ] || return 1
  printf '%s/%s:sha-%s' "${SUITE_REGISTRY}" "${SUITE_IMAGE_REPO}" "${sha:0:7}"
}

_registry_lookup() {  # $1 = tag or digest -> prints digest then revision
  # Overridable so the parity tests can exercise the pin and drift logic without
  # a network round trip, the same way DOCDB_SPLIT_SH stubs the run.
  if [ -n "${DOCDB_REGISTRY_LOOKUP:-}" ]; then
    bash "${DOCDB_REGISTRY_LOOKUP}" "$1"
    return $?
  fi
  python3 - "${SUITE_REGISTRY}" "${SUITE_IMAGE_REPO}" "$1" <<'PY'
import json, sys, urllib.error, urllib.request

registry, repo, ref = sys.argv[1], sys.argv[2], sys.argv[3]
ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def get(url, headers, raw=False):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=25) as r:
        return (r.read(), dict(r.headers)) if raw else json.load(r)


try:
    token = get(f"https://{registry}/token?scope=repository:{repo}:pull&service={registry}", {})["token"]
except Exception as exc:
    sys.exit(f"cannot obtain a pull token for {repo}: {exc}")

head = {"Authorization": f"Bearer {token}", "Accept": ACCEPT}
base = f"https://{registry}/v2/{repo}"

try:
    body, headers = get(f"{base}/manifests/{ref}", head, raw=True)
except urllib.error.HTTPError as exc:
    sys.exit(f"'{ref}' not found in {repo} (HTTP {exc.code})")
except Exception as exc:
    sys.exit(f"cannot reach {registry}: {exc}")

digest = headers.get("Docker-Content-Digest") or headers.get("docker-content-digest") or ref
manifest = json.loads(body)
# A multi-platform index carries no config of its own, but every child was built
# from one commit, so any child's labels answer the question.
if "manifests" in manifest:
    manifest = get(f"{base}/manifests/{manifest['manifests'][0]['digest']}", head)
labels = (get(f"{base}/blobs/{manifest['config']['digest']}", head).get("config") or {}).get("Labels") or {}
print(digest)
print(labels.get("org.opencontainers.image.revision", ""))
PY
}

cmd_suite() {
  local sub="${1:-status}"; shift || true
  case "${sub}" in
    status)
      local pin loc img
      pin="$(pinned_sha)"; loc="$(local_sha)"; img="$(derived_image)"
      echo "pinned   (config/image.yml source_sha): ${pin:-<none>}"
      echo "checkout (${SUITE_DIR}): ${loc:-<not a checkout>}"
      echo "image    (derived from source_sha):     ${img:-<none>}"

      local rc=0
      if [ -z "${loc}" ]; then
        echo "checkout state: MISSING, run 'docdb suite update'"; rc=1
      elif [ "${pin}" != "${loc}" ]; then
        echo "checkout state: DRIFTED, run 'docdb suite update'"; rc=1
      else
        echo "checkout state: in sync"
      fi

      # The image reference cannot name a different commit than source_sha, so
      # the only remaining question is whether upstream actually published one
      # for this commit. A commit with no image leaves gate/full/single/smoke
      # unable to run at all, which is worth knowing before a run rather than
      # from a docker pull failure mid-suite. Offline is not a failure: report
      # that it could not be checked rather than inventing a verdict.
      if [ -z "${pin}" ]; then
        warn "config/image.yml has no source_sha"
        rc=1
      else
        local out revision
        if out="$(_registry_lookup "sha-${pin:0:7}" 2>&1)"; then
          revision="$(printf '%s\n' "${out}" | sed -n 2p)"
          if [ -z "${revision}" ]; then
            echo "image state: published (carries no revision label to cross-check)"
          elif [ "${revision}" = "${pin}" ]; then
            echo "image state: published, built from ${revision:0:12}"
          else
            # Only reachable if upstream moved a per-commit tag onto other
            # content, which would be an upstream integrity problem.
            echo "image state: MISMATCH"
            err "tag sha-${pin:0:7} resolves to an image built from ${revision:0:12}, not ${pin:0:12}."
            rc=1
          fi
        else
          warn "could not check the image against the registry: ${out}"
        fi
      fi
      return "${rc}"
      ;;
    update)
      info "fetching the suite at the pinned revision into ${SUITE_DIR}"
      info "(this removes the directory first)"
      bash "${SETUP_SH}" "${SUITE_DIR}" "${IMAGE_YML}" || die "setup_functional_tests.sh failed"
      cmd_suite status
      ;;
    pin)
      local sha="" ref=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --sha) need_arg "$1" $#; sha="$2"; shift 2 ;;
          --ref) need_arg "$1" $#; ref="$2"; shift 2 ;;
          *) die "unknown option for 'suite pin': $1" ;;
        esac
      done
      if { [ -n "${sha}" ] && [ -n "${ref}" ]; } || { [ -z "${sha}" ] && [ -z "${ref}" ]; }; then
        die "give exactly one of --sha <commit> or --ref <tag>"
      fi

      local lookup
      if [ -n "${sha}" ]; then
        [[ "${sha}" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "--sha must be a hex commit id (got '${sha}')"
        lookup="sha-${sha:0:7}"
      else
        lookup="${ref}"
      fi

      # Resolving before writing is what makes the single pin safe: a commit
      # upstream never published has no image, and gate/full/single/smoke could
      # not run. Fail here rather than at test time.
      info "resolving ${lookup} in ${SUITE_REGISTRY}/${SUITE_IMAGE_REPO}"
      local out new_sha
      # 2>&1: the lookup reports why it failed on stderr, and without folding it
      # in, `die "${out}"` prints an empty reason for every registry error.
      out="$(_registry_lookup "${lookup}" 2>&1)" || die "${out}"
      new_sha="$(printf '%s\n' "${out}" | sed -n 2p)"
      [ -n "${new_sha}" ] || die "the image for ${lookup} carries no org.opencontainers.image.revision label, so the commit cannot be confirmed. Pin with --sha <commit> if you are sure."

      # Trust the label over the tag. A tag can be moved; the label is baked in
      # at build time and is the only statement of what the image contains.
      if [ -n "${sha}" ] && [ "${new_sha}" != "${sha}" ] && [ "${new_sha:0:${#sha}}" != "${sha}" ]; then
        die "tag ${lookup} resolves to an image built from ${new_sha}, not ${sha}."
      fi

      local old_sha; old_sha="$(pinned_sha)"
      if [ "${new_sha}" = "${old_sha}" ]; then
        info "already pinned there; nothing to do"
        return 0
      fi

      python3 - "${IMAGE_YML}" "${new_sha}" "$(git config user.email 2>/dev/null || true)" <<'PY'
import re, sys
path, sha = sys.argv[1], sys.argv[2]
who = (sys.argv[3] if len(sys.argv) > 3 else '').split('@')[0].strip()
text = open(path, encoding='utf-8').read()
text, n = re.subn(r'(?m)^source_sha:.*$', f'source_sha: {sha}', text)
if n != 1:
    sys.exit(f"expected exactly one source_sha line in {path}, found {n}")
# Only claim authorship when git actually knows who this is; overwriting a real
# name with a placeholder loses information the file is meant to carry.
if who:
    text = re.sub(r'(?m)^updated_by:.*$', f'updated_by: {who}', text)
open(path, 'w', encoding='utf-8', newline='\n').write(text)
PY
      [ $? -eq 0 ] || die "failed to update ${IMAGE_YML}"
      info "source_sha: ${old_sha:0:12} -> ${new_sha:0:12}"
      info "image:      $(derived_image "${new_sha}")"
      info "next: docdb suite update"
      info "      docdb test --all --results-dir /tmp/rebase"
      info "      docdb xfail reconcile --report /tmp/rebase/report.json --prune-uncollected"
      ;;
    -h|--help|help)
      cat <<'EOF'
docdb suite <status|update|pin>

  status              Compare the pinned commit against the local checkout, and
                      confirm an image was published for that commit.
  update              Fetch the checkout at the pinned commit. Removes the
                      existing directory first.
  pin --sha <commit>  Move the pin to a suite commit.
      --ref <tag>     Move it to whatever a tag publishes now (e.g. main).

config/image.yml pins ONE thing: the suite commit. The host checkout and the
suite image are both derived from it, so they cannot name different versions.
pin resolves the commit against the registry before writing, because a commit
with no published image would leave gate/full/single/smoke unable to run. With
--ref, the commit is taken from the image's own
org.opencontainers.image.revision label rather than from the tag, because a tag
can be moved and the label cannot.
EOF
      ;;
    *) die "unknown 'suite' subcommand: ${sub} (try: status, update, pin)" ;;
  esac
}

# =============================================================================
# xfail: the known-failure lists
# =============================================================================
cmd_xfail() {
  local sub="${1:-status}"; shift || true
  case "${sub}" in
    status)
      printf '  %-46s %s entries\n' "config/oss_ci_failing_tests.txt" "$(grep -c '::' "${FAILING_LIST}" 2>/dev/null || true)"
      printf '  %-46s %s entries\n' "config/oss_ci_flaky_tests.txt"   "$(grep -c '::' "${FLAKY_LIST}" 2>/dev/null || true)"
      printf '  %-46s %s entries\n' "config/ci_crash_tests.txt"       "$(grep -cv '^\s*\(#\|$\)' "${CRASH_LIST}" 2>/dev/null || true)"
      echo
      echo "failing = xfail(strict): must fail, and an unexpected pass fails the gate."
      echo "flaky   = xfail(non-strict): may pass or fail."
      echo "crash   = skip: never executed, because a crasher cascades onto concurrent tests."
      ;;
    add|remove)
      local id="${1:-}" list="${FAILING_LIST}"
      [ -n "${id}" ] || die "usage: docdb xfail ${sub} <test-node-id>"
      if [ "${sub}" = add ]; then
        grep -qxF "${id}" "${list}" && { info "already listed"; return 0; }
        printf '%s\n' "${id}" >> "${list}"; info "added to config/$(basename "${list}")"
      else
        grep -qxF "${id}" "${list}" || { info "not listed"; return 0; }
        # grep -v exits 1 when it selects nothing, which happens when the entry
        # being removed is the list's only line. Without treating that as
        # success the mv is skipped, the list keeps the entry, a stale .tmp is
        # left behind, and the message below still claims the removal happened.
        local tmp="${list}.tmp.$$"
        grep -vxF "${id}" "${list}" > "${tmp}"
        local grc=$?
        if [ "${grc}" -le 1 ]; then
          mv "${tmp}" "${list}" || { rm -f "${tmp}"; die "cannot update ${list}"; }
          info "removed from config/$(basename "${list}")"
        else
          rm -f "${tmp}"
          die "failed to read ${list} (grep exit ${grc})"
        fi
      fi
      ;;
    reconcile)
      # The list-maintenance path after a pin bump: feed a report in, get lists
      # that match observed behavior out. functional_gate.py owns the logic.
      local report="" extra=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --report) need_arg "$1" $#; report="$2"; shift 2 ;;
          *) extra+=("$1"); shift ;;
        esac
      done
      [ -n "${report}" ] || die "usage: docdb xfail reconcile --report <report.json> [--prune-uncollected]"
      [ -f "${report}" ] || die "no such report: ${report}"
      # --prune-uncollected is only valid on a full-suite report; on a single
      # leg it would prune every other leg's entries.
      if printf '%s\n' "${extra[@]+"${extra[@]}"}" | grep -q -- '--prune-uncollected'; then
        warn "--prune-uncollected assumes a FULL-suite report. On one leg's report it deletes the other legs' entries."
      fi
      python3 "${GATE_PY}" reconcile \
        --report "${report}" --failing "${FAILING_LIST}" --flaky "${FLAKY_LIST}" \
        "${extra[@]+"${extra[@]}"}"
      ;;
    combine)
      # Fold per-leg reports into one full-suite report, which is what
      # reconcile --prune-uncollected needs.
      local out="" ; local -a reports=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --out) need_arg "$1" $#; out="$2"; shift 2 ;;
          *) reports+=("$1"); shift ;;
        esac
      done
      [ -n "${out}" ] || die "usage: docdb xfail combine --out <combined.json> <report.json> [<report.json>...]"
      [ "${#reports[@]}" -ge 1 ] || die "give at least one report to combine"
      cp "${reports[0]}" "${out}" || die "cannot write ${out}"
      local i
      for ((i=1; i<${#reports[@]}; i++)); do
        python3 "${GATE_PY}" merge-reports --base "${out}" --overlay "${reports[$i]}" --out "${out}" \
          || die "merge-reports failed on ${reports[$i]}"
      done
      info "combined ${#reports[@]} report(s) into ${out}"
      ;;
    -h|--help|help)
      cat <<'EOF'
docdb xfail <status|add|remove|reconcile|combine>

  status                    Show the three lists and what each one means.
  add <node-id>             Append a test to the failing list.
  remove <node-id>          Drop a test from the failing list.
  combine --out C R1 R2...  Merge per-leg reports into one full-suite report.
  reconcile --report R      Rewrite the failing/flaky lists so they match the
                            observed report. Add --prune-uncollected only when
                            R covers the whole suite.

After reconciling, re-run the gate: strict xfail proves the lists are exactly
right, because an over- or under-edited list cannot pass.
EOF
      ;;
    *) die "unknown 'xfail' subcommand: ${sub}" ;;
  esac
}

# =============================================================================
# build: the documentdb-local image and the OS packages
# =============================================================================
cmd_build() {
  local target=both os="" pg="" passthru=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) need_arg "$1" $#; target="$2"; shift 2 ;;
      --os) need_arg "$1" $#; os="$2"; shift 2 ;;
      --pg) need_arg "$1" $#; pg="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
docdb build [--target image|packages|both] [--os <os>] [--pg <version>] [-- <extra args>]

  packages  Build the OS packages with packaging/build_packages.sh.
            --os and --pg are required for this target.
  image     Build the documentdb-local container image, then run the smoke
            suite against it. The verdict is whether the image was produced:
            smoke is ungated by design and reports real engine gaps, so its
            failures do not fail the build. The runner rebuilds the packages as
            part of this, so --os and --pg are forwarded to it.
  both      Packages first, then the image (default).

Extra arguments after -- are passed through to the underlying script.
EOF
        return 0 ;;
      --) shift; passthru+=("$@"); break ;;
      *) passthru+=("$1"); shift ;;
    esac
  done

  case "${target}" in
    packages|both)
      [ -f "${PACKAGING}/build_packages.sh" ] || die "missing ${PACKAGING}/build_packages.sh"
      [ -n "${os}" ] && [ -n "${pg}" ] || die "--os and --pg are required to build packages (see packaging/README.md)"
      info "building packages for os=${os} pg=${pg}"
      # Run from the repo root, not packaging/: build_packages.sh resolves most
      # paths from its own location but reads
      # pg_documentdb_core/documentdb_core.control relative to the working
      # directory, so invoking it from packaging/ fails on a missing control file.
      ( cd "${ROOT}" && ./packaging/build_packages.sh --os "${os}" --pg "${pg}" "${passthru[@]+"${passthru[@]}"}" ) \
        || die "build_packages.sh failed"
      [ "${target}" = packages ] && return 0
      ;;
  esac

  case "${target}" in
    image|both)
      [ -f "${RUNNER}" ] || die "missing ${RUNNER}"
      info "building the documentdb-local image, then running the smoke suite against it"
      # The runner owns the docker build (Dockerfile path, base image, package
      # argument), so reuse it rather than duplicating that invocation. It has
      # no build-only mode, so the smallest test mode comes along for the ride.
      #
      # It also rebuilds the packages itself from its own defaults, so forward
      # --os/--pg. Without this, `--target both --os X --pg Y` builds packages
      # twice and ships an image containing packages for a different OS and
      # PostgreSQL version than the flags asked for.
      local -a img_args=()
      [ -n "${os}" ] && img_args+=(--package-os "${os}")
      [ -n "${pg}" ] && img_args+=(--pg-version "${pg}")
      ( cd "${ROOT}" && bash "${RUNNER}" smoke --build-documentdb --keep-documentdb \
          "${img_args[@]+"${img_args[@]}"}" "${passthru[@]+"${passthru[@]}"}" )
      local runner_rc=$?
      # The verdict is whether the IMAGE exists, not whether smoke passed.
      # `smoke` is ungated on purpose (see the README), so it reports real
      # feature gaps in the engine; treating those as a build failure would
      # make `docdb build` fail on a perfectly good image.
      if docker image inspect "${DOCUMENTDB_IMAGE:-documentdb-local:functional-tests}" >/dev/null 2>&1; then
        info "image built: ${DOCUMENTDB_IMAGE:-documentdb-local:functional-tests}"
        [ "${runner_rc}" -ne 0 ] && info "the smoke suite reported failures (it is ungated and records known gaps); see .test-results/functional-tests/smoke/"
      else
        die "image build failed: ${DOCUMENTDB_IMAGE:-documentdb-local:functional-tests} does not exist"
      fi
      ;;
  esac

  case "${target}" in
    image|packages|both) ;;
    *) die "unknown --target: ${target}" ;;
  esac
}

# =============================================================================
# env: the local engine
# =============================================================================
cmd_env() {
  local sub="${1:-status}"; shift || true
  # Default to the name run-functional-tests.sh actually uses, so status and
  # stop find the engine a `--build-and-start --keep` run left behind.
  local container="${DOCUMENTDB_CONTAINER:-documentdb-functional-tests}"
  local port="${DOCUMENTDB_PORT:-10260}"
  case "${sub}" in
    status)
      local reachable=1 in_container=1
      timeout 3 bash -c "echo > /dev/tcp/localhost/${port}" 2>/dev/null && reachable=0
      if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${container}"; then
        in_container=0
        echo "engine container '${container}': running"
        docker ps --filter "name=^${container}$" --format '  {{.Image}}  {{.Status}}  {{.Ports}}'
      fi
      # An engine started from source (the way the CI workflow does it) has no
      # container, so port reachability is the honest signal either way.
      if [ "${reachable}" -eq 0 ]; then
        echo "engine endpoint localhost:${port}: reachable"
        [ "${in_container}" -ne 0 ] && echo "  (no '${container}' container; started from source or elsewhere)"
        return 0
      fi
      echo "engine endpoint localhost:${port}: not reachable"
      echo "start one with: docdb test --all --build-and-start"
      return 1
      ;;
    stop)
      if command -v docker >/dev/null 2>&1; then
        # `docker rm -f` on a missing container exits 0, so its status cannot
        # tell us whether anything was removed. Check first.
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${container}"; then
          docker rm -f "${container}" >/dev/null 2>&1 && info "removed ${container}" || err "failed to remove ${container}"
        else
          info "no ${container} container to stop"
        fi
      else
        info "docker not available; nothing to stop"
      fi
      ;;
    -h|--help|help) echo "docdb env <status|stop>   (start an engine with 'docdb test ... --build-and-start')" ;;
    *) die "unknown 'env' subcommand: ${sub}" ;;
  esac
}

cmd_selftest() {
  local rc=0
  if [ -f "${FT}/tests/test_docdb.sh" ]; then
    bash "${FT}/tests/test_docdb.sh" || rc=1
  else
    warn "no tests/test_docdb.sh found"
  fi
  if [ -f "${FT}/tests/test_run_pytest_split.sh" ]; then
    echo; info "--- split-runner guard tests ---"
    bash "${FT}/tests/test_run_pytest_split.sh" || rc=1
  fi
  return "${rc}"
}

# =============================================================================
# dispatch
# =============================================================================
main() {
  local cmd="${1:-help}"; shift || true
  case "${cmd}" in
    help|-h|--help) usage ;;
    test|suite|xfail|build|env|selftest) "cmd_${cmd}" "$@" ;;
    *) err "unknown command: ${cmd}"; usage; return 2 ;;
  esac
}

# cmd_test lives beside this file purely to keep the dispatcher readable; it is
# sourced, not executed, so there is still one entry point.
# shellcheck source=documentdb-local/functional-tests/scripts/docdb_test_cmd.sh
. "${SCRIPT_DIR}/docdb_test_cmd.sh"

main "$@"
