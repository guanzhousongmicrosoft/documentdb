#!/bin/bash
# `docdb test` implementation. Sourced by docdb.sh; not a separate entry point
# (it does nothing on its own and is not executable).
#
# Two shapes of run, both delegated:
#
#   single engine   -> scripts/run-functional-tests.sh, which owns bringing an
#                      engine up (image build, container start, readiness) and
#                      the gate / single / smoke / full modes.
#   split legs      -> scripts/run_pytest_split.sh, the exact script
#                      .github/workflows/functional_tests.yml runs per matrix
#                      leg, through the same environment contract.
#
# Nothing about a run is reimplemented here. This file only chooses which of
# those to call and arranges the legs when more than one is requested.

# The split runner slices node IDs that carry the full prefix
# `docdb_functional_tests/documentdb_tests/`, so a target must too. Accept the
# short forms people actually type, and verify the path exists: handing an
# unresolvable target to pytest surfaces as "unrecognized arguments" (the
# suite's conftest never loads), which points nowhere near the real mistake.
_PFX="docdb_functional_tests/documentdb_tests/"
_normalize_target() {
  local raw="$1" require_exists="${2:-1}" candidate path
  raw="${raw#./}"; raw="${raw#"${ROOT}/"}"
  case "${raw}" in
    "${_PFX}"*|docdb_functional_tests/*) candidate="${raw}" ;;
    documentdb_tests/*) candidate="docdb_functional_tests/${raw}" ;;
    compatibility/*) candidate="${_PFX}${raw}" ;;
    *)
      if [ -e "${ROOT}/${raw%%::*}" ]; then candidate="${raw}"; else candidate="${_PFX}${raw}"; fi ;;
  esac
  # A dry run still needs the resolved form to be honest about what it would
  # run, but it must not require a suite checkout to be present, so the
  # existence check is skipped there.
  if [ "${require_exists}" = 1 ]; then
    path="${ROOT}/${candidate%%::*}"
    [ -e "${path}" ] || return 1
  fi
  printf '%s' "${candidate}"
}

_test_usage() {
  cat <<'EOF'
docdb test [options] [-- <extra pytest args>]

TARGETING
  --tests PATH        Run one directory, file or node id.
  --all               Run the whole suite.
                      One of --tests or --all is required.
  --smoke             Run the upstream smoke subset instead.

MODE
  --no-xfail          Ignore the known-failure lists and report raw pass/fail.
                      Use this to see what actually fails. It is a report, not
                      the gate's verdict.
  --collect-only      List matching test node ids and run nothing. Use it to
                      find the id to paste into `docdb xfail add`.
  --dry-run           Print what would be run and exit. Nothing is started and
                      no results are touched.

ENGINE
  --build-and-start   Build the image and start an engine for this run.
  --start             Start an engine from an existing image.
  --image REF         Use this image instead of building.
  --connection-string S
                      Point at an already-running engine. Also honoured from
                      the CONNECTION_STRING environment variable.
  --keep              Leave the engine running afterwards.

DISTRIBUTION (matches the CI matrix)
  --split-total N     Divide the parallel universe into N legs.
  --split-id M        Run only leg M.
  --mode all|parallel|noparallel
                      Which halves to run when splitting. Default all.
  --workers N         pytest-xdist workers for the single-engine modes.

OUTPUT
  --results-dir DIR   Where reports and logs land.

Anything after -- is passed through to the underlying runner.
EOF
}

cmd_test() {
  local TESTS="" ALL=0 SMOKE=0 NO_XFAIL=0 COLLECT_ONLY=0 DRY_RUN=0
  local SPLIT_TOTAL="" SPLIT_ID="" MODE=all
  local RESULTS_DIR="" WORKERS="" CONN="${CONNECTION_STRING:-}"
  local -a engine_args=() passthru=()

  local need; need() { [ "$2" -ge 2 ] || die "$1 needs a value"; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --tests) need "$1" $#; TESTS="$2"; shift 2 ;;
      --all) ALL=1; shift ;;
      --smoke) SMOKE=1; shift ;;
      --no-xfail) NO_XFAIL=1; shift ;;
      --collect-only) COLLECT_ONLY=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --split-total) need "$1" $#; SPLIT_TOTAL="$2"; shift 2 ;;
      --split-id) need "$1" $#; SPLIT_ID="$2"; shift 2 ;;
      --mode) need "$1" $#; MODE="$2"; shift 2 ;;
      --results-dir) need "$1" $#; RESULTS_DIR="$2"; shift 2 ;;
      --workers) need "$1" $#; WORKERS="$2"; shift 2 ;;
      --connection-string) need "$1" $#; CONN="$2"; shift 2 ;;
      --build-and-start) engine_args+=(--build-and-start-documentdb); shift ;;
      --start) engine_args+=(--start-documentdb); shift ;;
      --image) need "$1" $#; engine_args+=(--use-existing-documentdb-image "$2"); shift 2 ;;
      --keep) engine_args+=(--keep-documentdb); shift ;;
      -h|--help) _test_usage; return 0 ;;
      --) shift; passthru+=("$@"); break ;;
      -*) err "unknown option $1"
          err "arbitrary pytest flags go after --, so they cannot be confused with this command's own options."
          return 2 ;;
      *) [ -n "${TESTS}" ] && die "more than one target given"; TESTS="$1"; shift ;;
    esac
  done

  case "${MODE}" in all|parallel|noparallel) ;; *) die "--mode must be all, parallel or noparallel" ;; esac
  [ -n "${TESTS}" ] || [ "${ALL}" = 1 ] || [ "${SMOKE}" = 1 ] || {
    err "specify --tests <path> for the area you changed, --all for the whole suite, or --smoke."
    err "running everything by accident is expensive, so there is no implicit default."
    return 2
  }
  [ -z "${TESTS}" ] || [ "${ALL}" = 0 ] || die "--tests and --all are mutually exclusive"

  # Split legs run host-side against an already-running engine, so the options
  # that bring an engine up have no effect there. Silently ignoring them lets a
  # caller believe an engine was started for them.
  local splitting=0
  { [ -n "${SPLIT_TOTAL}" ] || [ -n "${SPLIT_ID}" ]; } && splitting=1
  if [ "${splitting}" = 1 ]; then
    [ "${#engine_args[@]}" -eq 0 ] || die "--build-and-start / --start / --image / --keep only apply to single-engine runs; split legs need an engine that is already up (--connection-string)"
    [ "${NO_XFAIL}" = 0 ] || die "--no-xfail does not apply to split legs: the split runner always applies the known-failure model. Drop --split-total for a raw run."
    [ "${SMOKE}" = 0 ] || die "--smoke is a single-engine mode and cannot be combined with --split-total"
  fi

  [ -n "${CONN}" ] && engine_args+=(--connection-string "${CONN}")
  [ -n "${WORKERS}" ] && engine_args+=(--workers "${WORKERS}")
  [ -n "${RESULTS_DIR}" ] && engine_args+=(--results-dir "${RESULTS_DIR}")

  # The suite checkout is only read host-side: by the split legs, by
  # --collect-only, and by target normalization. The single-engine modes run
  # pytest inside the pinned image, which carries its own copy, so requiring a
  # checkout for them would fail the documented one-command local run on a
  # fresh clone.
  local needs_suite=0
  { [ "${splitting}" = 1 ] || [ "${COLLECT_ONLY}" = 1 ] || [ -n "${TESTS}" ]; } && needs_suite=1
  if [ "${DRY_RUN}" = 0 ] && [ "${needs_suite}" = 1 ] && [ ! -d "${SUITE_DIR}" ]; then
    die "no functional-tests checkout at ${SUITE_DIR}. Run: docdb suite update"
  fi
  local pin loc; pin="$(pinned_sha)"; loc="$(local_sha)"
  if [ -n "${pin}" ] && [ -n "${loc}" ] && [ "${pin}" != "${loc}" ]; then
    warn "suite is at ${loc:0:12} but config/image.yml pins ${pin:0:12}; run 'docdb suite update' to match CI"
  fi

  # Resolve the target after the suite check, so a missing checkout is reported
  # as a missing checkout rather than as a bad path. A dry run resolves it too,
  # so what it prints is what a real run would use, but without requiring the
  # checkout to exist.
  if [ -n "${TESTS}" ]; then
    local normalized
    if normalized="$(_normalize_target "${TESTS}" "$([ "${DRY_RUN}" = 1 ] && echo 0 || echo 1)")"; then
      TESTS="${normalized}"; info "target: ${TESTS}"
    else
      die "target '${TESTS}' does not exist under ${ROOT} (looked directly and under ${_PFX})"
    fi
  fi

  # --- collect only ---
  if [ "${COLLECT_ONLY}" = 1 ]; then
    # Run from ROOT with the normalized path, exactly like the split runner, so
    # the prefix means the same thing in both. Running from SUITE_DIR instead
    # would need a different, silently incompatible form of the same target.
    local ctarget="${TESTS:-${_PFX}compatibility/tests}"
    # Honour the same --ignore set the split runner treats as source of truth.
    # Without it this lists node ids from ignored files, which can never run in
    # the gate; pasting one into `docdb xfail add` would add a dead entry that
    # then reconciles away on the next rebase.
    local -a ign=()
    if [ -f "${CONFIG}/oss_pytest.args" ]; then
      local line
      while IFS= read -r line; do
        [ -n "${line}" ] && ign+=("${line}")
      done < <(grep -- '--ignore=' "${CONFIG}/oss_pytest.args" 2>/dev/null)
    fi
    ( cd "${ROOT}" && python3 -m pytest --collect-only -q -o addopts="" \
        --rootdir="docdb_functional_tests/documentdb_tests" \
        "${ign[@]+"${ign[@]}"}" \
        --engine-name=documentdb "${ctarget}" )
    return $?
  fi

  # --- split legs: the CI matrix shape ---
  if [ -n "${SPLIT_TOTAL}" ] || [ -n "${SPLIT_ID}" ]; then
    [ -n "${SPLIT_TOTAL}" ] || die "--split-id needs --split-total"
    [[ "${SPLIT_TOTAL}" =~ ^[0-9]+$ ]] && [ "${SPLIT_TOTAL}" -ge 1 ] || die "--split-total must be a positive integer"
    if [ -n "${SPLIT_ID}" ]; then
      [[ "${SPLIT_ID}" =~ ^[0-9]+$ ]] && [ "${SPLIT_ID}" -lt "${SPLIT_TOTAL}" ] || die "--split-id must be in [0, ${SPLIT_TOTAL})"
    fi
    [ -f "${SPLIT_SH}" ] || die "missing ${SPLIT_SH}"
    [ -n "${CONN}" ] || die "split legs need an already-running engine; pass --connection-string or set CONNECTION_STRING"

    # run_pytest_split.sh takes the endpoint as user/pass/port, so unpack the
    # connection string rather than asking for it twice.
    #
    # One field per line, read one at a time: a single whitespace-delimited
    # `read -r u p prt` silently mangles two real cases. With an empty password
    # the port slides into the password slot (so the guard below passes and
    # CONN_PORT ends up empty), and a password containing a space splits across
    # the password and port fields. Both produce a confusing failure deep inside
    # the runner rather than here.
    local u p prt chost
    { read -r u; read -r p; read -r prt; read -r chost; } < <(python3 - "${CONN}" <<'PY'
import sys
from urllib.parse import unquote, urlsplit
q = urlsplit(sys.argv[1])
print(unquote(q.username or 'documentdb'))
print(unquote(q.password or ''))
print(q.port or 10260)
print(q.hostname or 'localhost')
PY
)
    [ -n "${p}" ] || die "connection string has no password; run_pytest_split.sh needs user, password and port"
    [ -n "${prt}" ] || die "connection string has no port"
    # run_pytest_split.sh builds its own URI against localhost, so a remote host
    # in the connection string is not honoured. Refuse rather than run against a
    # different engine than the caller named.
    case "${chost}" in
      localhost|127.0.0.1|::1|"") ;;
      *) die "split legs always connect to localhost (run_pytest_split.sh builds its own URI), but the connection string names '${chost}'. Use a single-engine run, or point the split legs at a local engine." ;;
    esac

    RESULTS_DIR="${RESULTS_DIR:-${ROOT}/local-gate-results}"
    local TMP_BASE="${RESULTS_DIR}/.tmp"
    local marker="${RESULTS_DIR}/.docdb-results"

    # Everything in this block writes to disk, so none of it may run under
    # --dry-run: a dry run that creates the results tree, or worse clears the
    # leg directories of a previous run, has destroyed exactly what the caller
    # asked it not to touch.
    if [ "${DRY_RUN}" = 0 ]; then
      mkdir -p "${RESULTS_DIR}" || die "cannot create ${RESULTS_DIR}"

      # Clearing leg directories means `rm -rf` inside a path the caller chose,
      # so only ever do it in a directory this command owns. A directory is
      # ours if it carries the marker, or if it is empty and we are about to
      # adopt it. Anything else is refused rather than pattern-matched: a
      # caller could plausibly point --results-dir at a tree that already has a
      # directory named np or p1, and losing it would be unforgivable for a
      # test runner.
      if [ ! -e "${marker}" ]; then
        if [ -n "$(ls -A "${RESULTS_DIR}" 2>/dev/null)" ]; then
          die "${RESULTS_DIR} is not empty and was not created by docdb (no .docdb-results marker). Point --results-dir at a new or empty directory."
        fi
        : > "${marker}" || die "cannot write ${marker}"
      fi

      mkdir -p "${TMP_BASE}" || die "cannot create ${TMP_BASE}"
      # Clear every leg dir, not just this run's: a leftover leg from a wider
      # run would otherwise be read as part of this run's evidence.
      local stale
      for stale in "${RESULTS_DIR}"/*; do
        [ -d "${stale}" ] || continue
        case "$(basename "${stale}")" in np|.tmp|p[0-9]|p[0-9][0-9]) rm -rf "${stale}" ;; esac
      done
    elif [ -e "${RESULTS_DIR}" ] && [ ! -e "${marker}" ] && [ -n "$(ls -A "${RESULTS_DIR}" 2>/dev/null)" ]; then
      # Report the same refusal a real run would hit, without writing anything.
      die "${RESULTS_DIR} is not empty and was not created by docdb (no .docdb-results marker). Point --results-dir at a new or empty directory."
    fi

    local -a TAGS=() MODES=() IDS=()
    if [ "${MODE}" != noparallel ]; then
      if [ -n "${SPLIT_ID}" ]; then TAGS+=("p${SPLIT_ID}"); MODES+=(parallel); IDS+=("${SPLIT_ID}")
      else
        local i; for ((i=0; i<SPLIT_TOTAL; i++)); do TAGS+=("p${i}"); MODES+=(parallel); IDS+=("${i}"); done
      fi
    fi
    # Never a slice: this leg runs every no_parallel test, so it is always 1/1.
    [ "${MODE}" != parallel ] && { TAGS+=(np); MODES+=(noparallel); IDS+=(0); }

    info "legs: ${TAGS[*]}; results in ${RESULTS_DIR}"
    [ "${#TAGS[@]}" -gt 1 ] && warn "legs run back to back against one engine, while CI gives each leg a fresh one; re-run a suspicious leg alone before believing it."

    local overall=0 executed=0 idx
    local -a STATUS=()
    for idx in "${!TAGS[@]}"; do
      local tag="${TAGS[$idx]}" m="${MODES[$idx]}" id="${IDS[$idx]}" total="${SPLIT_TOTAL}"
      [ "${m}" = noparallel ] && total=1
      local lres="${RESULTS_DIR}/${tag}" ltmp="${TMP_BASE}/${tag}"
      local -a env_pairs=(
        "SPLIT_MODE=${m}" "SPLIT_ID=${id}" "SPLIT_TOTAL=${total}" "SPLIT_TAG=${tag}"
        "RESULTS_DIR=${lres}" "TMPDIR=${ltmp}"
        "CONN_USER=${u}" "CONN_PASS=${p}" "CONN_PORT=${prt}"
      )
      [ -n "${TESTS}" ] && env_pairs+=("SPLIT_TESTPATH=${TESTS}")
      info "=== leg ${tag} (${m} ${id}/${total}) ==="
      if [ "${DRY_RUN}" = 1 ]; then
        info "would run: ${env_pairs[*]/CONN_PASS=*/CONN_PASS=<redacted>} -- bash ${SPLIT_SH}"
        continue
      fi
      mkdir -p "${lres}" "${ltmp}"
      # env -u: an exported SPLIT_TESTPATH would otherwise reach a full run and
      # silently disable the runner's minimum-universe floor.
      ( cd "${ROOT}" && env -u SPLIT_TESTPATH "${env_pairs[@]}" bash "${SPLIT_SH}" ) 2>&1 | tee "${lres}/leg.log"
      local rc="${PIPESTATUS[0]}" st=FAIL

      # A narrowed run can legitimately select nothing for a leg. The runner
      # reds that (right for CI, where an empty selection means the suite went
      # missing), but here it is an empty result. Matched narrowly: only with a
      # target, only on the runner's own error line, and only for the mode that
      # can emit it.
      local pat='::error::'
      if [ "${m}" = noparallel ]; then pat="${pat}.*no_parallel leg collected 0 tests"
      else pat="${pat}.*split ${id} slice empty"; fi

      if [ "${rc}" -eq 0 ]; then st=PASS; executed=$((executed+1))
      elif [ -n "${TESTS}" ] && grep -qE "${pat}" "${lres}/leg.log"; then
        info "leg ${tag}: target selects no tests for this leg"; rc=0; st=SKIP
      else executed=$((executed+1)); fi
      STATUS+=("${st}")
      [ "${rc}" -eq 0 ] || overall=1
      info "=== leg ${tag}: ${st} (exit ${rc}) ==="
    done

    # The cross-leg check CI runs as its own job: the stride slices only tile
    # the suite if every leg collected the same universe.
    if [ -z "${SPLIT_ID}" ] && [ "${MODE}" != noparallel ] && [ "${SPLIT_TOTAL}" -ge 2 ]; then
      local -a uargs=(); local missing=0 u2
      for idx in "${!TAGS[@]}"; do
        [ "${MODES[$idx]}" = parallel ] || continue
        u2="${RESULTS_DIR}/${TAGS[$idx]}/universe.txt"
        if [ -f "${u2}" ]; then uargs+=(--universe "${u2}"); else missing=1; fi
      done
      if [ "${missing}" = 1 ]; then
        info "split-universe check skipped: not every parallel leg reported a universe"
      else
        info "=== verifying the parallel legs collected one universe ==="
        python3 "${GATE_PY}" verify-split-universes "${uargs[@]}" --expected-splits "${SPLIT_TOTAL}" \
          || { err "split-universe check failed; the legs did not slice the same universe"; overall=1; }
      fi
    fi

    echo; info "---- summary ----"
    for idx in "${!TAGS[@]}"; do
      local st="${STATUS[$idx]:-?}"
      if [ "${st}" = FAIL ]; then
        printf '[docdb]   %-4s FAIL  residual: %s\n' "${TAGS[$idx]}" "${RESULTS_DIR}/${TAGS[$idx]}/gate-failures.txt"
      else
        printf '[docdb]   %-4s %s\n' "${TAGS[$idx]}" "${st}"
      fi
    done
    if [ "${executed}" -eq 0 ] && [ "${DRY_RUN}" = 0 ]; then
      err "no leg ran a single test: '${TESTS}' selects nothing. This is not a pass."; return 1
    fi
    if [ "${DRY_RUN}" = 1 ]; then info "plan only: nothing was run."; return 0; fi
    [ "${overall}" -eq 0 ] && info "PASS" || err "FAIL: residual failures remain after re-run recovery."
    return "${overall}"
  fi

  # --- single-engine modes, delegated to the local runner ---
  [ -f "${RUNNER}" ] || die "missing ${RUNNER}"

  # --smoke runs a fixed upstream subset, so a target cannot be honoured.
  # Silently dropping it would run something quite different from what was asked.
  [ "${SMOKE}" = 1 ] && [ -n "${TESTS}" ] && die "--smoke runs a fixed upstream subset and cannot be combined with --tests"

  local mode
  if [ "${SMOKE}" = 1 ]; then mode=smoke
  elif [ -n "${TESTS}" ]; then mode=single      # a target always implies a targeted run
  elif [ "${NO_XFAIL}" = 1 ]; then mode=full    # whole suite, raw
  else mode=gate; fi

  # The runner's targeted and raw modes execute pytest INSIDE the pinned image,
  # whose working directory holds documentdb_tests/ directly. The host-side form
  # carries the docdb_functional_tests/ prefix (that is what the split runner
  # slices on), so strip it before handing the target over. Leaving it on gives
  # the container a path it does not have.
  local container_target="${TESTS#"${_PFX%documentdb_tests/}"}"

  # Only `gate` applies the known-failure model; single/smoke/full report raw
  # pytest results. Say so rather than letting the caller assume a verdict.
  if [ "${mode}" != gate ]; then
    info "note: ${mode} reports raw pass/fail, not the xfail-gated verdict."
    [ "${mode}" = single ] && info "      for the gated verdict on a subset, add --split-total 1 (needs a running engine)."
    info "      to fold raw results back into the lists: docdb xfail reconcile --report <report.json>"
  fi
  info "delegating to run-functional-tests.sh (${mode})"
  if [ "${DRY_RUN}" = 1 ]; then
    info "would run: bash ${RUNNER} ${mode}${TESTS:+ --test ${container_target}} ${engine_args[*]+"${engine_args[*]}"} ${passthru[*]+"${passthru[*]}"}"
    info "plan only: nothing was run, so this says nothing about the gate."
    return 0
  fi
  if [ "${mode}" = single ]; then
    exec bash "${RUNNER}" single --test "${container_target}" "${engine_args[@]+"${engine_args[@]}"}" "${passthru[@]+"${passthru[@]}"}"
  fi
  exec bash "${RUNNER}" "${mode}" "${engine_args[@]+"${engine_args[@]}"}" "${passthru[@]+"${passthru[@]}"}"
}
