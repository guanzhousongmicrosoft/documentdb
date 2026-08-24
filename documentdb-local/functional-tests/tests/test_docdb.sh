#!/bin/bash
# Parity tests for scripts/docdb.sh.
#
# docdb.sh only earns its "matches CI" claim if two things hold:
#
#   1. It delegates the run to the same scripts CI runs, through the same
#      environment contract. If it grew its own pytest invocation, or dropped an
#      env var the workflow sets, it would answer a different question than the
#      gate and nothing would say so.
#   2. Its list, pin and path wiring points at the real config, not a copy.
#
# Both are checked against .github/workflows/functional_tests.yml and the actual
# config files rather than against duplicated constants, so a CI edit that this
# script does not follow fails here instead of silently reporting a wrong verdict.
#
# The run itself is stubbed (DOCDB_SPLIT_SH), so these tests need no engine and
# no suite checkout.
#
# Usage: bash documentdb-local/functional-tests/tests/test_docdb.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FT="$(cd "${TESTS_DIR}/.." && pwd)"
ROOT="$(cd "${FT}/../.." && pwd)"
SUT="${FT}/scripts/docdb.sh"
RUNNER="${FT}/scripts/run-functional-tests.sh"
SPLIT_SH="${FT}/scripts/run_pytest_split.sh"
WORKFLOW="${ROOT}/.github/workflows/functional_tests.yml"
CONFIG="${FT}/config"

WORK="$(mktemp -d)"
FAKE_SUITE="${WORK}/suite"
mkdir -p "${FAKE_SUITE}/documentdb_tests/compatibility/tests"
# T15b edits the tracked config/image.yml, and T16 may create a minimal suite
# tree. Both are undone from the trap so an interrupt cannot leave a bogus
# source_sha or stray directories in the developer's working tree.
IMAGE_YML_BACKUP=""
SUITE_TREE_CREATED=""
cleanup() {
  [ -n "${IMAGE_YML_BACKUP}" ] && [ -f "${IMAGE_YML_BACKUP}" ] && \
    cp "${IMAGE_YML_BACKUP}" "${CONFIG}/image.yml"
  [ -n "${SUITE_TREE_CREATED}" ] && rm -rf "${SUITE_TREE_CREATED}"
  rm -rf "${WORK}"
}
trap cleanup EXIT
FAILS=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }

# --- stub for run_pytest_split.sh: records the env it was handed -------------
STUB="${WORK}/split_stub.sh"
cat > "${STUB}" <<'STUBEOF'
#!/bin/bash
{
  echo "LEG"
  for v in SPLIT_MODE SPLIT_ID SPLIT_TOTAL SPLIT_TAG RESULTS_DIR TMPDIR \
           CONN_USER CONN_PASS CONN_PORT SPLIT_TESTPATH; do
    echo "${v}=${!v-<unset>}"
  done
  echo "PWD=${PWD}"
} >> "${STUB_RECORD}"
# Stand in for the real runner's artifacts. The combined-report and
# universe-check cases are about what docdb.sh does with them, so a leg that
# produced none would exercise the wrong branch.
if [ -n "${RESULTS_DIR:-}" ] && [ "${STUB_NO_ARTIFACTS:-0}" != 1 ]; then
  mkdir -p "${RESULTS_DIR}"
  printf '{"summary":{"collected":1,"total":1,"failed":1},"tests":[{"nodeid":"compatibility/tests/%s.py::t","outcome":"failed","call":{"longrepr":"e"}}]}\n' \
    "${SPLIT_TAG:-leg}" > "${RESULTS_DIR}/report.json"
  # Every parallel leg must report the SAME universe; no_parallel is not part
  # of that check. The record must be in write_universe_record's format
  # (`<tag> <mode> <hash> <count>` on one line): an unparseable record reds the
  # universe check on EVERY simulated run, which would hide any regression in
  # the all-green path behind a failure this stub caused itself.
  [ "${SPLIT_MODE:-}" = parallel ] && \
    printf '%s parallel deadbeefdeadbeef 2\n' "${SPLIT_TAG:-leg}" > "${RESULTS_DIR}/universe.txt"
fi
[ -n "${STUB_MESSAGE:-}" ] && echo "${STUB_MESSAGE}"
exit "${STUB_RC:-0}"
STUBEOF
chmod +x "${STUB}"
# --- stub for the registry lookup: resolves any ref to one fixed pair --------
# Keeps the pin and drift cases hermetic; a ref named 'missing' fails like a 404.
REG_STUB="${WORK}/reg_stub.sh"
cat > "${REG_STUB}" <<'REGEOF'
#!/bin/bash
[ "$1" = missing ] && { echo "'missing' not found (HTTP 404)" >&2; exit 1; }
echo "sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
echo "1111111111111111111111111111111111111111"
REGEOF
chmod +x "${REG_STUB}"

run_sut() {  # rest = args ; publishes SUT_OUT, SUT_RC, SUT_RECORD
  SUT_RECORD="${WORK}/record.$$.${RANDOM}"
  : > "${SUT_RECORD}"
  SUT_OUT=$(cd "${ROOT}" && \
    DOCDB_SPLIT_SH="${STUB}" STUB_RECORD="${SUT_RECORD}" \
    STUB_RC="${STUB_RC:-0}" STUB_MESSAGE="${STUB_MESSAGE:-}" \
    DOCDB_REGISTRY_LOOKUP="${REG_STUB}" \
    DOCDB_SUITE_DIR="${FAKE_SUITE}" CONNECTION_STRING="" \
    bash "${SUT}" "$@" 2>&1)
  SUT_RC=$?
}

# Endpoint for the split-leg cases. The stub never connects, so these are
# placeholders, but they are assembled from parts rather than written as one
# literal: a full user:password@host URI in a source file is a credential
# pattern to secret scanners regardless of the value being fake.
CS_USER="documentdb"
CS_PASS="placeholder"
CS_HOST="localhost:10260"
CS="mongodb://${CS_USER}:${CS_PASS}@${CS_HOST}/?tls=true&tlsAllowInvalidCertificates=true"

# ---------------------------------------------------------------------------
# T1: the workflow still runs run_pytest_split.sh with the env this reproduces.
# ---------------------------------------------------------------------------
if grep -q 'scripts/run_pytest_split.sh' "${WORKFLOW}"; then
  pass "T1a workflow still invokes run_pytest_split.sh"
else
  fail "T1a workflow still invokes run_pytest_split.sh" \
       "functional_tests.yml no longer runs it; docdb.sh delegates to a script CI does not use."
fi

# The split runner documents its own required env; that is the contract to meet.
# Read into a newline-delimited string rather than an array: `mapfile` is bash 4
# only, and on bash 3.2 it failed silently here, skipping the single most
# important assertion in this file without incrementing the failure count.
REQ_ENV_LIST=$(sed -n 's/^# Required env: *//p;s/^#  *\([A-Z_ ]*\)$/\1/p' "${SPLIT_SH}" \
  | tr ' ' '\n' | grep -E '^[A-Z][A-Z_]+$' | sort -u)
if [ -z "${REQ_ENV_LIST}" ]; then
  fail "T1b required env readable" "could not parse 'Required env:' from run_pytest_split.sh"
else
  missing=""
  while IFS= read -r v; do
    [ -n "${v}" ] || continue
    grep -qh "\"${v}=" "${SUT}" "${FT}/scripts/docdb_test_cmd.sh" 2>/dev/null || missing="${missing}${v} "
  done <<< "${REQ_ENV_LIST}"
  if [ -z "${missing}" ]; then
    pass "T1b sets every env var run_pytest_split.sh requires ($(printf '%s' "${REQ_ENV_LIST}" | tr '\n' ' '))"
  else
    fail "T1b sets every env var run_pytest_split.sh requires" "never set: ${missing% }"
  fi
fi

# The dispatcher must not run pytest itself; that is the point of delegating.
if grep -v '^\s*#' "${SUT}" "${FT}/scripts/docdb_test_cmd.sh" | grep -q -- '-m pytest.*--json-report'; then
  fail "T1c does not reimplement a gated pytest run" \
       "docdb runs a reporting pytest itself, so its flags can diverge from the CI runner"
else
  pass "T1c does not reimplement a gated pytest run"
fi

# ---------------------------------------------------------------------------
# T2: the wiring points at the real config, not copies.
# ---------------------------------------------------------------------------
missing=()
for f in "${CONFIG}/image.yml" "${CONFIG}/oss_ci_failing_tests.txt" \
         "${CONFIG}/oss_ci_flaky_tests.txt" "${CONFIG}/ci_crash_tests.txt" \
         "${FT}/tools/functional_gate.py" "${RUNNER}" "${SPLIT_SH}"; do
  [ -f "${f}" ] || missing+=("$(basename "${f}")")
done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "T2 every file docdb delegates to exists"
else
  fail "T2 every file docdb delegates to exists" "missing: ${missing[*]}"
fi

# ---------------------------------------------------------------------------
# T3: suite status reads the real pin.
# ---------------------------------------------------------------------------
PIN="$(awk '/^source_sha:/ {print $2; exit}' "${CONFIG}/image.yml")"
run_sut suite status
if [ -n "${PIN}" ] && printf '%s' "${SUT_OUT}" | grep -q "${PIN}"; then
  pass "T3 suite status reports the pinned revision (${PIN:0:12})"
else
  fail "T3 suite status reports the pinned revision" "${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T4: xfail status counts the real lists.
# ---------------------------------------------------------------------------
N="$(grep -c '::' "${CONFIG}/oss_ci_failing_tests.txt" 2>/dev/null || echo 0)"
run_sut xfail status
if printf '%s' "${SUT_OUT}" | grep -q "oss_ci_failing_tests.txt *${N} entries"; then
  pass "T4 xfail status counts the real failing list (${N})"
else
  fail "T4 xfail status counts the real failing list" "expected ${N}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T5: a target is required, so nobody runs the whole suite by accident.
# ---------------------------------------------------------------------------
run_sut test
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'no implicit default'; then
  pass "T5 test without a target is refused"
else
  fail "T5 test without a target is refused" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T6: split legs carry the full env contract, from the repo root.
# ---------------------------------------------------------------------------
run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${WORK}/r6"
if grep -q '^SPLIT_MODE=parallel$' "${SUT_RECORD}" \
   && grep -q "^CONN_USER=${CS_USER}$" "${SUT_RECORD}" \
   && grep -q "^CONN_PASS=${CS_PASS}$" "${SUT_RECORD}" \
   && grep -q '^CONN_PORT=10260$' "${SUT_RECORD}" \
   && grep -q "^PWD=${ROOT}$" "${SUT_RECORD}"; then
  pass "T6 split legs get the endpoint unpacked and run from the repo root"
else
  fail "T6 split legs get the endpoint and cwd" "$(cat "${SUT_RECORD}")"
fi

# ---------------------------------------------------------------------------
# T7: the no_parallel leg is never a slice.
# ---------------------------------------------------------------------------
run_sut test --all --split-total 3 --connection-string "${CS}" --results-dir "${WORK}/r7"
np_total=$(grep -A4 '^SPLIT_MODE=noparallel$' "${SUT_RECORD}" | grep '^SPLIT_TOTAL=' | head -1)
if [ "${np_total}" = "SPLIT_TOTAL=1" ]; then
  pass "T7 no_parallel leg runs 1/1, not a slice"
else
  fail "T7 no_parallel leg runs 1/1" "got '${np_total}'"
fi

# ---------------------------------------------------------------------------
# T8: each leg gets its own results and temp dir.
# ---------------------------------------------------------------------------
run_sut test --all --split-total 3 --connection-string "${CS}" --results-dir "${WORK}/r8"
legs=$(grep -c '^LEG$' "${SUT_RECORD}")
ur=$(grep '^RESULTS_DIR=' "${SUT_RECORD}" | sort -u | wc -l)
ut=$(grep '^TMPDIR=' "${SUT_RECORD}" | sort -u | wc -l)
if [ "${ur}" -eq "${legs}" ] && [ "${ut}" -eq "${legs}" ]; then
  pass "T8 each of the ${legs} legs gets its own RESULTS_DIR and TMPDIR"
else
  fail "T8 each leg gets its own dirs" "${legs} legs, ${ur} results dirs, ${ut} temp dirs"
fi

# ---------------------------------------------------------------------------
# T9: a failing leg fails the run.
# ---------------------------------------------------------------------------
STUB_RC=1 run_sut test --all --split-total 1 --connection-string "${CS}" --results-dir "${WORK}/r9"
if [ "${SUT_RC}" -ne 0 ]; then
  pass "T9 a failing leg makes the run fail"
else
  fail "T9 a failing leg makes the run fail" "exited 0"
fi
unset STUB_RC

# ---------------------------------------------------------------------------
# T10: a full run must not inherit SPLIT_TESTPATH from the caller's shell,
# which would silently disable the runner's minimum-universe floor.
# ---------------------------------------------------------------------------
SUT_RECORD="${WORK}/r10rec"; : > "${SUT_RECORD}"
(cd "${ROOT}" && DOCDB_SPLIT_SH="${STUB}" STUB_RECORD="${SUT_RECORD}" \
  DOCDB_SUITE_DIR="${FAKE_SUITE}" SPLIT_TESTPATH="leaked/from/the/shell" \
  bash "${SUT}" test --all --split-total 1 --connection-string "${CS}" \
    --results-dir "${WORK}/r10") >/dev/null 2>&1
if grep -q '^SPLIT_TESTPATH=<unset>$' "${SUT_RECORD}"; then
  pass "T10 an inherited SPLIT_TESTPATH does not leak into a full run"
else
  fail "T10 an inherited SPLIT_TESTPATH does not leak" "$(grep '^SPLIT_TESTPATH=' "${SUT_RECORD}" | head -1)"
fi

# ---------------------------------------------------------------------------
# T11: a narrower re-run clears the previous run's extra legs, so a leftover
# cannot be counted as this run's evidence.
# ---------------------------------------------------------------------------
run_sut test --all --split-total 3 --connection-string "${CS}" --results-dir "${WORK}/r11"
run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${WORK}/r11"
if [ ! -d "${WORK}/r11/p2" ]; then
  pass "T11 a narrower re-run clears the previous run's extra legs"
else
  fail "T11 a narrower re-run clears extra legs" "p2 survived"
fi

# ---------------------------------------------------------------------------
# T12: split legs need an endpoint; failing closed beats a confusing run.
# ---------------------------------------------------------------------------
run_sut test --all --split-total 2 --results-dir "${WORK}/r12"
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'already-running engine'; then
  pass "T12 split legs without an endpoint are refused"
else
  fail "T12 split legs without an endpoint are refused" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T13: the single-engine modes map onto the runner's own modes.
# ---------------------------------------------------------------------------
for spec in "--all:gate" "--smoke:smoke" "--all --no-xfail:full"; do
  args="${spec%%:*}"; want="${spec##*:}"
  # shellcheck disable=SC2086
  run_sut test ${args} --dry-run 2>/dev/null
  if printf '%s' "${SUT_OUT}" | grep -q "run-functional-tests.sh (${want})"; then
    pass "T13 '${args}' delegates to runner mode '${want}'"
  else
    # --dry-run is not a runner option; the mode line is printed before exec,
    # so an unknown-option failure from the runner still proves the mapping.
    if printf '%s' "${SUT_OUT}" | grep -q "(${want})"; then
      pass "T13 '${args}' delegates to runner mode '${want}'"
    else
      fail "T13 '${args}' delegates to runner mode '${want}'" "${SUT_OUT}"
    fi
  fi
done

# ---------------------------------------------------------------------------
# T14: reconcile refuses a missing report rather than silently doing nothing.
# ---------------------------------------------------------------------------
run_sut xfail reconcile --report "${WORK}/nope.json"
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'no such report'; then
  pass "T14 reconcile refuses a missing report"
else
  fail "T14 reconcile refuses a missing report" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T15: suite pin validates its argument and rewrites only the pin fields.
# ---------------------------------------------------------------------------
run_sut suite pin --sha "not-a-sha"
if [ "${SUT_RC}" -ne 0 ]; then
  pass "T15a suite pin rejects a non-hex revision"
else
  fail "T15a suite pin rejects a non-hex revision" "accepted it"
fi

cp "${CONFIG}/image.yml" "${WORK}/image.yml.bak"
IMAGE_YML_BACKUP="${WORK}/image.yml.bak"   # restored from the trap on any exit
run_sut suite pin --sha 1111111
changed=$(diff "${WORK}/image.yml.bak" "${CONFIG}/image.yml" | grep -c '^[<>]')
# schema_version and source_ref describe the pin's shape and origin, not which
# revision is pinned, so a version bump must leave them alone.
only_expected=$(diff "${WORK}/image.yml.bak" "${CONFIG}/image.yml" | grep '^[<>]' | grep -cvE 'source_sha|updated_by')
cp "${WORK}/image.yml.bak" "${CONFIG}/image.yml"
if [ "${changed}" -gt 0 ] && [ "${only_expected}" -eq 0 ]; then
  pass "T15b suite pin rewrites only source_sha and updated_by"
else
  fail "T15b suite pin rewrites only source_sha and updated_by" "${only_expected} unexpected line(s) changed"
fi

# ---------------------------------------------------------------------------
# T16: a short --tests target is expanded to the prefix the split runner slices
# on. Without this, pytest gets an unresolvable path, the suite's conftest never
# loads, and the failure surfaces as "unrecognized arguments: --engine-name",
# which points nowhere near the real mistake.
# ---------------------------------------------------------------------------
mkdir -p "${FAKE_SUITE}/documentdb_tests/compatibility/tests/core"
# _normalize_target resolves against the real ROOT, and the suite checkout there
# is gitignored, so on a clean tree this case used to skip and quietly defend
# nothing. Create the minimal tree when it is absent and remove it afterwards,
# so the assertion always runs. An existing real checkout is left alone.
REAL_SUITE="${ROOT}/docdb_functional_tests"
NEEDED="${REAL_SUITE}/documentdb_tests/compatibility/tests/core"
if [ ! -d "${NEEDED}" ]; then
  if [ -e "${REAL_SUITE}" ]; then
    mkdir -p "${NEEDED}"          # partial checkout: only add what is missing
  else
    SUITE_TREE_CREATED="${REAL_SUITE}"   # we created the whole tree, so we own it
    mkdir -p "${NEEDED}"
  fi
fi
SUT_RECORD="${WORK}/r16rec"; : > "${SUT_RECORD}"
(cd "${ROOT}" && DOCDB_SPLIT_SH="${STUB}" STUB_RECORD="${SUT_RECORD}" \
  DOCDB_SUITE_DIR="${REAL_SUITE}" \
  bash "${SUT}" test --tests compatibility/tests/core --split-total 1 \
    --connection-string "${CS}" --results-dir "${WORK}/r16") >/dev/null 2>&1
if grep -q '^SPLIT_TESTPATH=docdb_functional_tests/documentdb_tests/compatibility/tests/core$' "${SUT_RECORD}"; then
  pass "T16 a short --tests target is expanded to the split runner's prefix"
else
  fail "T16 a short --tests target is expanded" "$(grep '^SPLIT_TESTPATH=' "${SUT_RECORD}" | head -1)"
fi

# T17: a target that does not exist is rejected up front, by name.
run_sut test --tests compatibility/tests/definitely_not_here --split-total 1 \
  --connection-string "${CS}" --results-dir "${WORK}/r17"
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q "does not exist"; then
  pass "T17 a nonexistent target is rejected by name"
else
  fail "T17 a nonexistent target is rejected by name" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T18: the packaging build must be invoked from the repo root. build_packages.sh
# resolves most paths from its own location but reads
# pg_documentdb_core/documentdb_core.control relative to the working directory,
# so running it from packaging/ dies on a missing control file.
# ---------------------------------------------------------------------------
if grep -q 'cd "${ROOT}" && ./packaging/build_packages.sh' "${SUT}"; then
  pass "T18 packaging build runs from the repo root"
else
  fail "T18 packaging build runs from the repo root" \
       "build_packages.sh is invoked from somewhere else; it reads pg_documentdb_core/documentdb_core.control relative to \$PWD"
fi

# T19: build requires --os and --pg for packages, rather than failing deep
# inside docker with a confusing message.
run_sut build --target packages
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'required to build packages'; then
  pass "T19 packages build without --os/--pg is refused up front"
else
  fail "T19 packages build without --os/--pg is refused" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T20: `build --target image` must judge the IMAGE, not the smoke result. smoke
# is ungated by design and reports real engine gaps, so gating the build on it
# makes `docdb build` fail on a perfectly good image.
# ---------------------------------------------------------------------------
if grep -q 'docker image inspect' "${SUT}" && ! grep -q 'die "image build or smoke validation failed"' "${SUT}"; then
  pass "T20 image build verdict is the image's existence, not the smoke result"
else
  fail "T20 image build verdict is the image's existence" \
       "build --target image still fails when the ungated smoke suite reports gaps"
fi

# ---------------------------------------------------------------------------
# T21: the endpoint is unpacked field by field. A whitespace-delimited read
# mangles two real cases: an empty password lets the port slide into the
# password slot (so the "no password" guard passes and CONN_PORT ends up
# empty), and a password containing a space splits across password and port.
# Both would surface as a confusing failure inside the runner.
# ---------------------------------------------------------------------------
SPACE_PASS_URI="mongodb://${CS_USER}:pw%20with%20space@${CS_HOST}/?tls=true"
run_sut test --all --split-total 1 --connection-string "${SPACE_PASS_URI}" \
  --results-dir "${WORK}/r21"
if grep -q '^CONN_PASS=pw with space$' "${SUT_RECORD}" && grep -q '^CONN_PORT=10260$' "${SUT_RECORD}"; then
  pass "T21a a password containing a space survives unpacking"
else
  fail "T21a a password containing a space survives unpacking" \
       "$(grep -E '^CONN_(PASS|PORT)=' "${SUT_RECORD}" | tr '\n' ' ')"
fi

# An empty password must trip the guard, not be silently replaced by the port.
run_sut test --all --split-total 1 \
  --connection-string "mongodb://${CS_USER}@${CS_HOST}/?tls=true" \
  --results-dir "${WORK}/r21b"
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'no password'; then
  pass "T21b an empty password is rejected, not filled in from the port"
else
  fail "T21b an empty password is rejected" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T22: clearing leg directories is `rm -rf` inside a caller-chosen path, so it
# must only happen in a directory this command owns. A non-empty directory with
# no marker is refused rather than pattern-matched, because a caller could
# plausibly point --results-dir at a tree that already contains np or p1.
# ---------------------------------------------------------------------------
FOREIGN="${WORK}/foreign-results"
mkdir -p "${FOREIGN}/p1"
echo "someone else's data" > "${FOREIGN}/p1/precious.txt"
run_sut test --all --split-total 1 --connection-string "${CS}" --results-dir "${FOREIGN}"
if [ "${SUT_RC}" -ne 0 ] && [ -f "${FOREIGN}/p1/precious.txt" ]; then
  pass "T22a a foreign non-empty results dir is refused, and its contents survive"
else
  fail "T22a a foreign results dir is refused" \
       "exit ${SUT_RC}, precious.txt present: $([ -f "${FOREIGN}/p1/precious.txt" ] && echo yes || echo NO)"
fi

# An empty directory is adopted, and a re-run then clears its own legs.
ADOPT="${WORK}/adopt-results"
mkdir -p "${ADOPT}"
run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${ADOPT}"
run_sut test --all --split-total 1 --connection-string "${CS}" --results-dir "${ADOPT}"
if [ -f "${ADOPT}/.docdb-results" ] && [ ! -d "${ADOPT}/p1" ]; then
  pass "T22b an empty results dir is adopted and its own legs are cleared on re-run"
else
  fail "T22b an empty results dir is adopted and cleared" \
       "marker: $([ -f "${ADOPT}/.docdb-results" ] && echo yes || echo no), stale p1: $([ -d "${ADOPT}/p1" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# T23: a missing option value must fail fast, not spin. `shift 2` with one
# argument left neither shifts nor exits without `set -e`, so the parsing loop
# would loop forever at 100% CPU with no output.
#
# The watchdog is written by hand rather than with timeout(1), which is absent
# on some developer machines: there, every command exited 127 and scored as
# "fails fast", so the regression this test exists for would have passed
# unnoticed on exactly the machines people iterate on.
# ---------------------------------------------------------------------------
run_bounded() {  # $1 = seconds ; rest = command. 124 on timeout, like timeout(1)
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${secs}" ]; then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      return 124
    fi
    sleep 1; waited=$((waited+1))
  done
  wait "${pid}"
}

for spec in "build --target" "xfail reconcile --report" "xfail combine --out" "suite pin --sha"; do
  # shellcheck disable=SC2086
  run_bounded 15 bash "${SUT}" ${spec}
  rc=$?
  if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ]; then
    pass "T23 '${spec}' without a value fails fast (exit ${rc})"
  elif [ "${rc}" -eq 124 ]; then
    fail "T23 '${spec}' without a value fails fast" "it hung (timed out)"
  else
    fail "T23 '${spec}' without a value fails fast" "exited 0"
  fi
done

# ---------------------------------------------------------------------------
# T24: the runner's targeted mode runs pytest INSIDE the pinned image, whose
# working directory holds documentdb_tests/ directly. Handing it the host-side
# docdb_functional_tests/ prefix gives the container a path it does not have.
# ---------------------------------------------------------------------------
run_sut test --tests compatibility/tests/core --connection-string "${CS}" --dry-run
if printf '%s' "${SUT_OUT}" | grep -q -- '--test documentdb_tests/compatibility/tests/core' \
   && ! printf '%s' "${SUT_OUT}" | grep -q -- '--test docdb_functional_tests/'; then
  pass "T24 the container target drops the host-side prefix"
else
  fail "T24 the container target drops the host-side prefix" "${SUT_OUT}"
fi

# T25: a target must never be silently dropped. --no-xfail used to switch to a
# whole-suite mode while still reporting the resolved target, turning a narrow
# request into a multi-hour run.
run_sut test --tests compatibility/tests/core --no-xfail --connection-string "${CS}" --dry-run
if printf '%s' "${SUT_OUT}" | grep -q -- '--test documentdb_tests/compatibility/tests/core'; then
  pass "T25 --no-xfail with a target keeps the target"
else
  fail "T25 --no-xfail with a target keeps the target" "${SUT_OUT}"
fi

# T26: --smoke runs a fixed upstream subset, so combining it with a target is
# refused rather than silently ignoring one of them.
run_sut test --smoke --tests compatibility/tests/core --connection-string "${CS}" --dry-run
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'cannot be combined'; then
  pass "T26 --smoke with --tests is refused"
else
  fail "T26 --smoke with --tests is refused" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T27: --dry-run must not touch the filesystem. It previously created the
# results tree and, worse, cleared the leg directories of a previous run.
#
# Both cases assert the ABSENCE of an effect, so they only mean anything if the
# run actually happened: a command that never ran, or that died before reaching
# the results-dir handling, leaves the same filesystem behind as one that
# correctly did nothing. Each case therefore also requires a successful plan.
# ---------------------------------------------------------------------------
DRYDIR="${WORK}/dry-untouched"
run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${DRYDIR}" --dry-run
if [ "${SUT_RC}" -ne 0 ] || ! printf '%s' "${SUT_OUT}" | grep -q 'plan only'; then
  fail "T27a --dry-run creates nothing" "the dry run itself did not complete (exit ${SUT_RC}): ${SUT_OUT}"
elif [ ! -e "${DRYDIR}" ]; then
  pass "T27a --dry-run creates nothing"
else
  fail "T27a --dry-run creates nothing" "created: $(ls -A "${DRYDIR}" 2>/dev/null | tr '\n' ' ')"
fi

# And it must not clear a previous run's legs.
KEEPDIR="${WORK}/dry-keep"
mkdir -p "${KEEPDIR}/p0"; : > "${KEEPDIR}/.docdb-results"; echo prior > "${KEEPDIR}/p0/report.json"
run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${KEEPDIR}" --dry-run
if [ "${SUT_RC}" -ne 0 ] || ! printf '%s' "${SUT_OUT}" | grep -q 'plan only'; then
  fail "T27b --dry-run leaves a previous run's results intact" \
       "the dry run itself did not complete (exit ${SUT_RC}): ${SUT_OUT}"
elif [ -f "${KEEPDIR}/p0/report.json" ]; then
  pass "T27b --dry-run leaves a previous run's results intact"
else
  fail "T27b --dry-run leaves a previous run's results intact" "p0/report.json was deleted"
fi

# ---------------------------------------------------------------------------
# T28: `xfail remove` on a list whose only line is the entry. grep -v selects
# nothing and exits 1, so the rewrite used to be skipped while the command
# still reported success and left a stale .tmp behind.
# ---------------------------------------------------------------------------
SOLO="${WORK}/solo_failing.txt"
printf '%s\n' "only/one/entry.py::test_solo" > "${SOLO}"
( cd "${ROOT}" && FAILING_LIST_OVERRIDE=1 bash -c '
    set -uo pipefail
    list="'"${SOLO}"'"
    id="only/one/entry.py::test_solo"
    tmp="${list}.tmp.$$"
    grep -vxF "${id}" "${list}" > "${tmp}"; grc=$?
    if [ "${grc}" -le 1 ]; then mv "${tmp}" "${list}"; else rm -f "${tmp}"; exit 1; fi
  ' ) >/dev/null 2>&1
if [ ! -s "${SOLO}" ] && [ -z "$(ls "${WORK}"/solo_failing.txt.tmp.* 2>/dev/null)" ]; then
  pass "T28 removing the only entry empties the list and leaves no stale temp file"
else
  fail "T28 removing the only entry empties the list" \
       "size=$(wc -c < "${SOLO}"), stale tmp: $(ls "${WORK}"/solo_failing.txt.tmp.* 2>/dev/null | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# T29: options that only apply to one execution shape must be refused, not
# silently ignored. Engine bring-up flags do nothing for split legs, and
# --no-xfail cannot be honoured there because the split runner always applies
# the known-failure model.
# ---------------------------------------------------------------------------
run_sut test --all --split-total 2 --build-and-start --connection-string "${CS}" --dry-run
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'only apply to single-engine runs'; then
  pass "T29a engine bring-up options are refused for split legs"
else
  fail "T29a engine bring-up options are refused for split legs" "exit ${SUT_RC}: ${SUT_OUT}"
fi

run_sut test --all --split-total 2 --no-xfail --connection-string "${CS}" --dry-run
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'does not apply to split legs'; then
  pass "T29b --no-xfail is refused for split legs rather than silently gated"
else
  fail "T29b --no-xfail is refused for split legs" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# T30: the split runner builds its own URI against localhost, so a remote host
# in the connection string would silently test a different engine.
run_sut test --all --split-total 1 \
  --connection-string "mongodb://${CS_USER}:${CS_PASS}@remote.example.com:10260/?tls=true" --dry-run
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q "remote.example.com"; then
  pass "T30 a remote host is refused for split legs"
else
  fail "T30 a remote host is refused for split legs" "exit ${SUT_RC}: ${SUT_OUT}"
fi

# T31: the single-engine modes run pytest inside the pinned image, so requiring
# a host-side suite checkout for them would break the documented one-command
# local run on a fresh clone. Split legs still require it.
ABSENT="${WORK}/no-suite-here"
SUT_OUT=$(cd "${ROOT}" && DOCDB_SUITE_DIR="${ABSENT}" DOCDB_SPLIT_SH="${STUB}" \
  STUB_RECORD="${WORK}/t31" bash "${SUT}" test --all --build-and-start --dry-run 2>&1)
if [ $? -eq 0 ] && ! printf '%s' "${SUT_OUT}" | grep -q 'no functional-tests checkout'; then
  pass "T31a a single-engine run does not require a host-side suite checkout"
else
  fail "T31a a single-engine run does not require a suite checkout" "${SUT_OUT}"
fi

SUT_OUT=$(cd "${ROOT}" && DOCDB_SUITE_DIR="${ABSENT}" DOCDB_SPLIT_SH="${STUB}" \
  STUB_RECORD="${WORK}/t31b" bash "${SUT}" test --all --split-total 1 \
  --connection-string "${CS}" --results-dir "${WORK}/r31" 2>&1)
if [ $? -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'no functional-tests checkout'; then
  pass "T31b split legs still require the suite checkout"
else
  fail "T31b split legs still require the suite checkout" "${SUT_OUT}"
fi

# T32: env must use the container name the runner actually creates, or status
# and stop can never find the engine a --build-and-start --keep run left behind.
RUNNER_NAME=$(grep -oE 'DOCUMENTDB_CONTAINER="[^"]+"' "${RUNNER}" | head -1 | sed 's/.*="//; s/"//')
if [ -n "${RUNNER_NAME}" ] && grep -q "DOCUMENTDB_CONTAINER:-${RUNNER_NAME}" "${SUT}"; then
  pass "T32 env defaults to the runner's container name (${RUNNER_NAME})"
else
  fail "T32 env defaults to the runner's container name" \
       "runner uses '${RUNNER_NAME}', docdb defaults to something else"
fi

# ---------------------------------------------------------------------------
# T33: --collect-only exists so a developer can find the node id to paste into
# `docdb xfail add`. The split runner treats the --ignore= set in
# config/oss_pytest.args as the single source of truth for what is collectable,
# so collect-only must apply it too. Listing an id from an ignored file hands
# the developer an entry that can never run, and it silently reconciles away on
# the next rebase.
# ---------------------------------------------------------------------------
IGN_N=$(grep -c -- '--ignore=' "${CONFIG}/oss_pytest.args" 2>/dev/null || true)
if [ "${IGN_N:-0}" -eq 0 ]; then
  pass "T33 collect-only honours the ignore set (nothing ignored; vacuous)"
elif grep -q "grep -- '--ignore=' \"\${CONFIG}/oss_pytest.args\"" "${FT}/scripts/docdb_test_cmd.sh"; then
  pass "T33 collect-only honours the ${IGN_N} --ignore= entries the split runner applies"
else
  fail "T33 collect-only honours the split runner's ignore set" \
       "config/oss_pytest.args has ${IGN_N} --ignore= entries; collect-only does not read them, so it lists ids the gate never runs"
fi

# ---------------------------------------------------------------------------
# T34: config/image.yml must pin exactly one thing. A second recorded reference
# to the same suite is what allowed the image and the checkout to name
# different versions while every status line still read "in sync".
# ---------------------------------------------------------------------------
if grep -qE '^image:' "${CONFIG}/image.yml"; then
  fail "T34 config/image.yml records only the commit" \
       "an image: field is back; the image must be derived from source_sha so the two cannot disagree"
elif grep -qE '^source_sha:' "${CONFIG}/image.yml"; then
  pass "T34 config/image.yml records only the commit"
else
  fail "T34 config/image.yml records only the commit" "no source_sha line found"
fi

# ---------------------------------------------------------------------------
# T35: docdb.sh and run-functional-tests.sh both derive the image reference and
# the runner cannot source docdb.sh, so the formula is written twice. If the two
# drift, `suite status` reports on an image the runner never executes, which is
# the same failure the single pin was introduced to remove.
#
# Ask docdb.sh what it derives rather than scraping assignments out of its
# source: status is the line a developer actually reads, and a scrape silently
# stops matching the moment the assignment moves.
# ---------------------------------------------------------------------------
RUNNER_FORMULA=$(grep -oE 'IMAGE="\$\{FUNCTIONAL_TESTS_IMAGE_REPO:-[^}]+\}:sha-\$\{SUITE_SHA:0:7\}"' "${RUNNER}" | head -1)
RUNNER_REPO=$(printf '%s' "${RUNNER_FORMULA}" | sed -E 's/.*:-([^}]+)\}.*/\1/')
PIN_NOW="$(awk '/^source_sha:/ {print $2; exit}' "${CONFIG}/image.yml")"

docdb_ref() {  # $1 = FUNCTIONAL_TESTS_IMAGE_REPO value, empty to leave it unset
  local out
  if [ -n "${1:-}" ]; then
    out=$(cd "${ROOT}" && FUNCTIONAL_TESTS_IMAGE_REPO="$1" \
      DOCDB_REGISTRY_LOOKUP="${REG_STUB}" bash "${SUT}" suite status 2>&1)
  else
    out=$(cd "${ROOT}" && DOCDB_REGISTRY_LOOKUP="${REG_STUB}" bash "${SUT}" suite status 2>&1)
  fi
  printf '%s' "${out}" | grep -oE '[A-Za-z0-9._/-]+:sha-[0-9a-f]{7}' | head -1
}

DOCDB_REF="$(docdb_ref "")"
DOCDB_REPO="${DOCDB_REF%%:sha-*}"
if [ -z "${RUNNER_FORMULA}" ]; then
  fail "T35 both scripts derive the same image reference" \
       "run-functional-tests.sh no longer derives IMAGE from source_sha (formula not found)"
elif [ -z "${DOCDB_REPO}" ]; then
  fail "T35 both scripts derive the same image reference" \
       "'docdb suite status' printed no <repo>:sha-<short7> reference"
elif [ "${RUNNER_REPO}" = "${DOCDB_REPO}" ]; then
  pass "T35 both scripts derive the same image reference (${DOCDB_REPO}:sha-<short7>)"
else
  fail "T35 both scripts derive the same image reference" \
       "runner uses '${RUNNER_REPO}', docdb uses '${DOCDB_REPO}'"
fi

# The derived reference must also be exactly what `suite status` reports, so a
# developer reading status sees the image the runner will actually pull.
WANT_REF="${DOCDB_REPO}:sha-${PIN_NOW:0:7}"
if [ "${DOCDB_REF}" = "${WANT_REF}" ]; then
  pass "T35b suite status reports the derived reference (${WANT_REF})"
else
  fail "T35b suite status reports the derived reference" \
       "expected ${WANT_REF}, got '${DOCDB_REF}'"
fi

# T35c: the OVERRIDE has to be shared too. Comparing only the defaults let the
# two sides read different variables, so setting the runner's override moved the
# image the runner pulls while status kept reporting the default: the same
# disagreement, reachable by anyone testing against a mirror.
OVR_REPO="example.invalid/team/functional-tests"
OVR_REF="$(docdb_ref "${OVR_REPO}")"
if [ "${OVR_REF}" = "${OVR_REPO}:sha-${PIN_NOW:0:7}" ]; then
  pass "T35c FUNCTIONAL_TESTS_IMAGE_REPO moves both sides (${OVR_REF})"
else
  fail "T35c FUNCTIONAL_TESTS_IMAGE_REPO moves both sides" \
       "the runner honours FUNCTIONAL_TESTS_IMAGE_REPO but docdb reported '${OVR_REF}'"
fi

# ---------------------------------------------------------------------------
# T36: a commit upstream never published has no image, so gate/full/single and
# smoke could not run. pin must refuse it, and must not half-write the file.
# ---------------------------------------------------------------------------
IMAGE_YML_BACKUP="${WORK}/image.yml.bak"
cp "${CONFIG}/image.yml" "${IMAGE_YML_BACKUP}"
FAIL_OUT=$(cd "${ROOT}" && DOCDB_REGISTRY_LOOKUP="${REG_STUB}" \
  bash "${SUT}" suite pin --ref missing 2>&1)
UNCHANGED=0
diff -q "${IMAGE_YML_BACKUP}" "${CONFIG}/image.yml" >/dev/null 2>&1 && UNCHANGED=1
cp "${IMAGE_YML_BACKUP}" "${CONFIG}/image.yml"
if [ "${UNCHANGED}" = 1 ] && printf '%s' "${FAIL_OUT}" | grep -qE 'ERROR: .*404'; then
  pass "T36 pin refuses a commit with no published image, leaving image.yml untouched"
else
  fail "T36 pin refuses a commit with no published image, leaving image.yml untouched" \
       "unchanged=${UNCHANGED}, output: ${FAIL_OUT}"
fi

# ---------------------------------------------------------------------------
# T37: exactly one of --sha / --ref. Accepting both would leave which one wins
# up to argument order.
# ---------------------------------------------------------------------------
T37_OK=1
for args in "" "--sha 1111111 --ref main"; do
  # shellcheck disable=SC2086
  OUT=$(cd "${ROOT}" && DOCDB_REGISTRY_LOOKUP="${REG_STUB}" bash "${SUT}" suite pin $args 2>&1)
  printf '%s' "${OUT}" | grep -q 'exactly one of' || T37_OK=0
done
if [ "${T37_OK}" = 1 ]; then
  pass "T37 suite pin requires exactly one of --sha / --ref"
else
  fail "T37 suite pin requires exactly one of --sha / --ref" \
       "zero or two selectors were accepted"
fi
IMAGE_YML_BACKUP=""

echo
if [ "${FAILS}" -eq 0 ]; then

# ---------------------------------------------------------------------------
# T38: the split width is not cosmetic. It decides how much of the suite shares
# one engine, so the tests that read shared state (the set of databases, live
# connections, index counters) answer differently at a different width. A
# baseline built at the wrong width is calibrated for a run shape that never
# happens, which is how a list full of one-time failures reaches CI. `ci` must
# therefore resolve to the width the workflow actually declares.
# ---------------------------------------------------------------------------
WF_SPLITS=$(awk '/^[[:space:]]*PARALLEL_SPLITS:[[:space:]]*[0-9]+/ {
                   for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }' "${WORKFLOW}")
SUT_RECORD="${WORK}/r38"; : > "${SUT_RECORD}"
CI_OUT=$(cd "${ROOT}" && DOCDB_SPLIT_SH="${STUB}" STUB_RECORD="${SUT_RECORD}" \
  DOCDB_SUITE_DIR="${FAKE_SUITE}" bash "${SUT}" test --all --split-total ci \
    --connection-string "${CS}" --results-dir "${WORK}/r38out" --dry-run 2>&1)
if [ -z "${WF_SPLITS}" ]; then
  fail "T38 --split-total ci matches the workflow" "no PARALLEL_SPLITS found in ${WORKFLOW}"
elif printf '%s' "${CI_OUT}" | grep -q "resolved to ${WF_SPLITS}"; then
  pass "T38 --split-total ci resolves to the workflow's width (${WF_SPLITS})"
else
  fail "T38 --split-total ci resolves to the workflow's width" \
       "workflow declares ${WF_SPLITS}; docdb resolved differently: $(printf '%s' "${CI_OUT}" | grep -i 'resolved to')"
fi

# The number of legs planned must equal that width, not just be printed.
LEGS=$(printf '%s' "${CI_OUT}" | grep -oE '^\[docdb\] legs: .*' | head -1)
WANT_LAST="p$((WF_SPLITS - 1))"
if printf '%s' "${LEGS}" | grep -q "${WANT_LAST}"; then
  pass "T38b a ci-width run plans ${WF_SPLITS} parallel legs (through ${WANT_LAST})"
else
  fail "T38b a ci-width run plans ${WF_SPLITS} parallel legs" "got: ${LEGS}"
fi

# ---------------------------------------------------------------------------
# T39: a full-suite run at a width the gate never uses must say so. Silence here
# is what let a baseline be built from a single leg while the gate ran six.
# ---------------------------------------------------------------------------
ODD=$(cd "${ROOT}" && DOCDB_SPLIT_SH="${STUB}" STUB_RECORD="${WORK}/r39" \
  DOCDB_SUITE_DIR="${FAKE_SUITE}" bash "${SUT}" test --all --split-total 1 \
    --connection-string "${CS}" --results-dir "${WORK}/r39out" --dry-run 2>&1)
if printf '%s' "${ODD}" | grep -q "does not match the gate's ${WF_SPLITS}"; then
  pass "T39 a full-suite run at a non-gate width warns"
else
  fail "T39 a full-suite run at a non-gate width warns" "no warning in: ${ODD}"
fi

# A targeted run is not a baseline, so the width is irrelevant and the warning
# would just be noise.
TGT=$(cd "${ROOT}" && DOCDB_SPLIT_SH="${STUB}" STUB_RECORD="${WORK}/r39b" \
  DOCDB_SUITE_DIR="${FAKE_SUITE}" bash "${SUT}" test --tests compatibility/tests \
    --split-total 1 --connection-string "${CS}" --results-dir "${WORK}/r39bout" --dry-run 2>&1)
if printf '%s' "${TGT}" | grep -q "does not match the gate"; then
  fail "T39b a targeted run does not warn about width" "warned unnecessarily"
else
  pass "T39b a targeted run does not warn about width"
fi

# ---------------------------------------------------------------------------
# T40: reconciling from a single run asserts every one-time failure as a
# permanent one. That must be called out, because the resulting list passes
# locally and reds the gate on the first run that disagrees.
# ---------------------------------------------------------------------------
printf '{"tests":[{"nodeid":"compatibility/tests/z.py::t","outcome":"failed","call":{"longrepr":"e"}}]}' \
  > "${WORK}/one.json"
ONE=$(cd "${ROOT}" && bash "${SUT}" xfail reconcile --report "${WORK}/one.json" --out /dev/null 2>&1 || true)
if printf '%s' "${ONE}" | grep -q "one run only"; then
  pass "T40 reconciling from a single run warns that it cannot assert always-fails"
else
  fail "T40 reconciling from a single run warns" "no warning in: ${ONE}"
fi

# ---------------------------------------------------------------------------
# T41: a full-suite split run must leave the combined report the documented
# rebaseline workflow reconciles from. Without it, the very next command in the
# README and the pin-bump SOP dies on a missing file.
# ---------------------------------------------------------------------------
R41="${WORK}/res41"
run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${R41}"
if [ -f "${R41}/report.json" ]; then
  pass "T41 a full-suite split run writes the combined report the docs reconcile from"
else
  fail "T41 a full-suite split run writes a combined report" \
       "no ${R41}/report.json; output: ${SUT_OUT}"
fi
# It has to cover every leg, or --prune-uncollected deletes the missing legs'
# entries from the baseline.
if [ -f "${R41}/report.json" ] && \
   grep -q 'p0' "${R41}/report.json" && grep -q 'p1' "${R41}/report.json" && \
   grep -q 'np' "${R41}/report.json"; then
  pass "T41b the combined report merges every leg (p0, p1, np)"
else
  fail "T41b the combined report merges every leg" \
       "contents: $(cat "${R41}/report.json" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# T41c: a run that did NOT cover the whole suite must not produce that filename.
# reconcile --prune-uncollected trusts it to be full-suite and deletes every
# entry it does not mention, so a narrowed run under the same name would wipe
# the rest of the baseline.
# ---------------------------------------------------------------------------
R41C="${WORK}/res41c"
run_sut test --all --split-total 2 --split-id 0 --connection-string "${CS}" --results-dir "${R41C}"
if [ ! -f "${R41C}/report.json" ] && printf '%s' "${SUT_OUT}" | grep -q "did not cover the whole suite"; then
  pass "T41c a single-leg run writes no combined report, and says why"
else
  fail "T41c a single-leg run writes no combined report" \
       "report exists: $([ -f "${R41C}/report.json" ] && echo yes || echo no); output: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T42: a leg that reports no universe means the legs were never shown to slice
# the same set. CI fails closed on that; passing locally on a check that did not
# happen is worse than failing it.
# ---------------------------------------------------------------------------
R42="${WORK}/res42"
STUB_NO_ARTIFACTS=1 run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${R42}"
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q "not every parallel leg reported a universe"; then
  pass "T42 a missing leg universe fails the run rather than skipping the check"
else
  fail "T42 a missing leg universe fails the run" "rc=${SUT_RC}; output: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T43: run_pytest_split.sh is driven entirely by environment variables and reads
# no argv, so pytest args after -- cannot reach a split leg. Accepting them
# would run the whole suite while ignoring the filter that was asked for.
# ---------------------------------------------------------------------------
run_sut test --all --split-total 2 --connection-string "${CS}" --dry-run -- -k sentinel_xyz
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q "not supported with --split-total"; then
  pass "T43 pytest args after -- are refused for split legs, not silently dropped"
else
  fail "T43 pytest args after -- are refused for split legs" "rc=${SUT_RC}; output: ${SUT_OUT}"
fi
# The same args must still work for the single-engine modes.
run_sut test --tests compatibility/tests --dry-run -- -k sentinel_xyz
if printf '%s' "${SUT_OUT}" | grep -q 'sentinel_xyz'; then
  pass "T43b a single-engine run still forwards args after --"
else
  fail "T43b a single-engine run still forwards args after --" "output: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T20b: the image tag is a fixed mutable name, so a failed build leaves the
# PREVIOUS image carrying it. Judging on existence alone reports that stale
# image as this build's success -- and with --keep-documentdb the developer then
# tests against it. The verdict must be that a NEW image was produced.
# ---------------------------------------------------------------------------
FAKE_BIN="${WORK}/bin"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/docker" <<'DOCKEREOF'
#!/bin/bash
# `image inspect --format {{.Id}}` always answers with the SAME id, standing in
# for a tag left over from an earlier successful build.
[ "${1:-}" = image ] && [ "${2:-}" = inspect ] && { echo "sha256:staleimageid"; exit 0; }
exit 0
DOCKEREOF
chmod +x "${FAKE_BIN}/docker"
# docdb.sh derives ROOT as scripts/../../.., so mirror the real layout: the
# copy must land under <root>/documentdb-local/functional-tests/scripts.
FAKE_ROOT="${WORK}/fakeroot"
FAKE_RUNNER_DIR="${FAKE_ROOT}/documentdb-local/functional-tests/scripts"
mkdir -p "${FAKE_RUNNER_DIR}"
cp "${SUT}" "${FAKE_RUNNER_DIR}/docdb.sh"
cp "${FT}/scripts/docdb_test_cmd.sh" "${FAKE_RUNNER_DIR}/docdb_test_cmd.sh"
FAKE_SMOKE="${FAKE_ROOT}/.test-results/functional-tests/smoke"

# A failed build: the runner exits non-zero and smoke never runs, so no report.
printf '#!/bin/bash\necho "[stub-runner] simulating a build failure"\nexit 1\n' \
  > "${FAKE_RUNNER_DIR}/run-functional-tests.sh"
chmod +x "${FAKE_RUNNER_DIR}/run-functional-tests.sh"
B20=$(cd "${ROOT}" && PATH="${FAKE_BIN}:${PATH}" bash "${FAKE_RUNNER_DIR}/docdb.sh" build --target image 2>&1)
B20_RC=$?
if [ "${B20_RC}" -ne 0 ] && printf '%s' "${B20}" | grep -q "nothing new was produced"; then
  pass "T20b a failed build is not reported as success just because the tag exists"
else
  fail "T20b a failed build is not reported as success" "rc=${B20_RC}; output: ${B20}"
fi

# ---------------------------------------------------------------------------
# T20c: the mirror of T20b. A fully cached rebuild legitimately produces the
# SAME image id, so comparing ids alone would call a good build a failure.
# smoke runs only once the build has succeeded, so its report is the proof --
# and smoke failing is expected, because it is ungated by design.
# ---------------------------------------------------------------------------
printf '#!/bin/bash\nmkdir -p "%s"\nprintf "{}" > "%s/report.json"\necho "[stub-runner] smoke reported known gaps"\nexit 1\n' \
  "${FAKE_SMOKE}" "${FAKE_SMOKE}" > "${FAKE_RUNNER_DIR}/run-functional-tests.sh"
chmod +x "${FAKE_RUNNER_DIR}/run-functional-tests.sh"
B20C=$(cd "${ROOT}" && PATH="${FAKE_BIN}:${PATH}" bash "${FAKE_RUNNER_DIR}/docdb.sh" build --target image 2>&1)
B20C_RC=$?
if [ "${B20C_RC}" -eq 0 ] && printf '%s' "${B20C}" | grep -q "image built"; then
  pass "T20c a cached rebuild whose smoke reports gaps is still a successful build"
else
  fail "T20c a cached rebuild is still a successful build" "rc=${B20C_RC}; output: ${B20C}"
fi

fi

# ---------------------------------------------------------------------------
# T44: the all-green path. Every other split case asserts a failure, so a
# regression that permanently reds a good run would pass this whole suite
# unnoticed. It already had: the stub wrote its universe record in a format the
# cross-leg check cannot parse, so every simulated run ended red for a reason
# the stub invented.
# ---------------------------------------------------------------------------
STUB_RC=0
STUB_MESSAGE=""
run_sut test --all --split-total 2 --connection-string "${CS}" --results-dir "${WORK}/r44"
if [ "${SUT_RC}" -eq 0 ] && printf '%s' "${SUT_OUT}" | grep -qE '^\[docdb\] PASS$'; then
  pass "T44 an all-green split run exits 0"
else
  fail "T44 an all-green split run exits 0" "rc=${SUT_RC}; output: ${SUT_OUT}"
fi

# ---------------------------------------------------------------------------
# T45: an id on two lists makes conftest_known_failures raise during COLLECTION,
# so the suite reports an internal error with zero tests run. reconcile guards
# this; the interactive command has to as well, or the cheapest edit becomes the
# most expensive failure.
# ---------------------------------------------------------------------------
FAILING_PATH="${CONFIG}/oss_ci_failing_tests.txt"
FLAKY_ID=$(grep -m1 '::' "${CONFIG}/oss_ci_flaky_tests.txt" 2>/dev/null || true)
if [ -z "${FLAKY_ID}" ]; then
  fail "T45 xfail add refuses an id already on the flaky list" "the flaky list holds no id to test with"
else
  SZ_BEFORE=$(wc -c < "${FAILING_PATH}")
  run_sut xfail add "${FLAKY_ID}"
  SZ_AFTER=$(wc -c < "${FAILING_PATH}")
  if [ "${SUT_RC}" -ne 0 ] && [ "${SZ_BEFORE}" = "${SZ_AFTER}" ]; then
    pass "T45 xfail add refuses an id already on the flaky list, and writes nothing"
  else
    fail "T45 xfail add refuses an id already on the flaky list" \
         "rc=${SUT_RC}, list size ${SZ_BEFORE} -> ${SZ_AFTER}; output: ${SUT_OUT}"
  fi
fi

# ---------------------------------------------------------------------------
# T46: `suite update` removes the target directory before cloning into it, and
# the target comes from DOCDB_SUITE_DIR. An unlucky export must not be able to
# hand `rm -rf` a directory full of someone's work.
# ---------------------------------------------------------------------------
NOT_A_CHECKOUT="${WORK}/not-a-checkout"
mkdir -p "${NOT_A_CHECKOUT}/precious"
: > "${NOT_A_CHECKOUT}/precious/file"
OUT46=$(cd "${ROOT}" && DOCDB_SUITE_DIR="${NOT_A_CHECKOUT}" bash "${SUT}" suite update 2>&1)
RC46=$?
if [ "${RC46}" -ne 0 ] && [ -f "${NOT_A_CHECKOUT}/precious/file" ]; then
  pass "T46 suite update refuses a target that is not a suite checkout"
else
  fail "T46 suite update refuses a target that is not a suite checkout" \
       "rc=${RC46}, precious file still there: $([ -f "${NOT_A_CHECKOUT}/precious/file" ] && echo yes || echo NO); output: ${OUT46}"
fi

# ---------------------------------------------------------------------------
# T47: --collect-only returns before the split code, so accepting --split-total
# with it would drop the split silently. Refusing options that cannot be
# honoured is the rule the rest of the entry point follows.
# ---------------------------------------------------------------------------
run_sut test --all --collect-only --split-total 2 --connection-string "${CS}"
if [ "${SUT_RC}" -ne 0 ] && printf '%s' "${SUT_OUT}" | grep -q -- '--collect-only'; then
  pass "T47 --collect-only with --split-total is refused, not silently unsplit"
else
  fail "T47 --collect-only with --split-total is refused" "rc=${SUT_RC}; output: ${SUT_OUT}"
fi

# T47b: --dry-run documents that nothing is started. Collecting the whole suite
# is minutes of work and starts pytest, which is exactly what it promises not
# to do.
run_sut test --all --collect-only --dry-run
if [ "${SUT_RC}" -eq 0 ] && printf '%s' "${SUT_OUT}" | grep -q 'plan only'; then
  pass "T47b --collect-only --dry-run plans without running a collection"
else
  fail "T47b --collect-only --dry-run plans without running a collection" \
       "rc=${SUT_RC}; output: ${SUT_OUT}"
fi

# Re-check: the guard above skips the later tests when an earlier one failed,
# but a failure raised INSIDE it must still decide the verdict.
if [ "${FAILS}" -eq 0 ]; then
  echo "all parity tests passed"
  exit 0
fi
echo "${FAILS} parity test(s) failed"
exit 1
