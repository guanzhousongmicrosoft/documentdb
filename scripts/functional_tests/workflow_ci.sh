#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

cd "${repo_root}"

function die {
    echo "$1" >&2
    exit 1
}

function require_option_value {
    local flag="$1"
    local value="${2-}"

    if [[ -z "${value}" || "${value}" == --* ]]; then
        die "Missing value for ${flag}"
    fi
}

function append_output {
    local output_file="$1"
    local key="$2"
    local value="${3-}"

    printf '%s=%s\n' "${key}" "${value}" >> "${output_file}"
}

function run_logged_command {
    local log_path="$1"
    local label="$2"
    shift 2

    mkdir -p "$(dirname "${log_path}")"
    echo "${label}; full output is being captured to ${log_path}."

    set +e
    "$@" 2>&1 | tee "${log_path}"
    local exit_code=${PIPESTATUS[0]}
    set -e

    return "${exit_code}"
}

function verify_results {
    local results_dir="$1"
    local missing_results=false

    for required_file in functional-report.json functional-results.xml; do
        if [[ ! -f "${results_dir}/${required_file}" ]]; then
            echo "Missing expected test result file: ${results_dir}/${required_file}" >&2
            missing_results=true
        fi
    done

    if [[ "${missing_results}" == true ]]; then
        echo "Functional tests did not produce the expected result files. Check the test container output for the earlier failure." >&2
        return 1
    fi

    find "${results_dir}" -maxdepth 1 -type f | sort
}

function resolve_functional_test_image {
    local pin_file=""
    local github_env=""
    local github_output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pin-file)
                shift
                require_option_value "--pin-file" "${1-}"
                pin_file="$1"
                ;;
            --github-env)
                shift
                require_option_value "--github-env" "${1-}"
                github_env="$1"
                ;;
            --github-output)
                shift
                require_option_value "--github-output" "${1-}"
                github_output="$1"
                ;;
            *)
                die "Unknown argument for resolve-functional-test-image: $1"
                ;;
        esac
        shift
    done

    [[ -n "${pin_file}" ]] || die "--pin-file is required"
    [[ -n "${github_env}" ]] || die "--github-env is required"

    local test_image
    test_image="$(bash ./scripts/functional_tests/read_pin.sh "${pin_file}")"

    case "${test_image}" in
        ghcr.io/documentdb/functional-tests@sha256:*)
            ;;
        *)
            echo "Pinned test image must use an immutable ghcr.io/documentdb/functional-tests@sha256:<digest> reference." >&2
            echo "Found: ${test_image}" >&2
            exit 1
            ;;
    esac

    printf 'TEST_IMAGE=%s\n' "${test_image}" >> "${github_env}"
    if [[ -n "${github_output}" ]]; then
        append_output "${github_output}" "test_image" "${test_image}"
    fi
    echo "Resolved functional test image: ${test_image}"
}

function resolve_update_test_image {
    local pin_file=""
    local github_output=""
    local github_step_summary=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pin-file)
                shift
                require_option_value "--pin-file" "${1-}"
                pin_file="$1"
                ;;
            --github-output)
                shift
                require_option_value "--github-output" "${1-}"
                github_output="$1"
                ;;
            --github-step-summary)
                shift
                require_option_value "--github-step-summary" "${1-}"
                github_step_summary="$1"
                ;;
            *)
                die "Unknown argument for resolve-update-test-image: $1"
                ;;
        esac
        shift
    done

    [[ -n "${pin_file}" ]] || die "--pin-file is required"
    [[ -n "${github_output}" ]] || die "--github-output is required"
    [[ -n "${github_step_summary}" ]] || die "--github-step-summary is required"

    local current_image latest_digest latest_image
    current_image="$(bash ./scripts/functional_tests/read_pin.sh "${pin_file}")"
    latest_digest="$(docker buildx imagetools inspect ghcr.io/documentdb/functional-tests:latest --format '{{.Manifest.Digest}}')"

    if [[ -z "${latest_digest}" ]]; then
        die "Could not resolve the latest functional test image digest."
    fi

    latest_image="ghcr.io/documentdb/functional-tests@${latest_digest}"

    append_output "${github_output}" "current_image" "${current_image}"
    append_output "${github_output}" "current_digest" "${current_image##*@}"
    append_output "${github_output}" "latest_image" "${latest_image}"
    append_output "${github_output}" "latest_digest" "${latest_digest}"

    if [[ "${current_image}" == "${latest_image}" ]]; then
        append_output "${github_output}" "pin_changed" "false"
        {
            echo "## Test image update"
            echo
            echo "Pinned test image already up to date: \`${current_image}\`"
        } >> "${github_step_summary}"
        return 0
    fi

    append_output "${github_output}" "pin_changed" "true"
    echo "Current pinned image: ${current_image}"
    echo "Latest available image: ${latest_image}"
}

function run_functional_test_stack {
    local logs_dir=""
    local build_test_image=""
    local pg_version=""
    local package_output_dir=""
    local documentdb_image=""
    local test_image=""
    local results_dir=""
    local username=""
    local password=""
    local scope=""
    local github_output=""
    local exclude_deselect_file=false
    local allow_test_exit_code_1=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --logs-dir)
                shift
                require_option_value "--logs-dir" "${1-}"
                logs_dir="$1"
                ;;
            --build-test-image)
                shift
                require_option_value "--build-test-image" "${1-}"
                build_test_image="$1"
                ;;
            --pg)
                shift
                require_option_value "--pg" "${1-}"
                pg_version="$1"
                ;;
            --output-dir)
                shift
                require_option_value "--output-dir" "${1-}"
                package_output_dir="$1"
                ;;
            --documentdb-image)
                shift
                require_option_value "--documentdb-image" "${1-}"
                documentdb_image="$1"
                ;;
            --test-image)
                shift
                require_option_value "--test-image" "${1-}"
                test_image="$1"
                ;;
            --results-dir)
                shift
                require_option_value "--results-dir" "${1-}"
                results_dir="$1"
                ;;
            --username)
                shift
                require_option_value "--username" "${1-}"
                username="$1"
                ;;
            --password)
                shift
                require_option_value "--password" "${1-}"
                password="$1"
                ;;
            --scope)
                shift
                require_option_value "--scope" "${1-}"
                scope="$1"
                ;;
            --github-output)
                shift
                require_option_value "--github-output" "${1-}"
                github_output="$1"
                ;;
            --exclude-deselect-file)
                exclude_deselect_file=true
                ;;
            --allow-test-exit-code-1)
                allow_test_exit_code_1=true
                ;;
            *)
                die "Unknown argument for run-functional-test-stack: $1"
                ;;
        esac
        shift
    done

    [[ -n "${logs_dir}" ]] || die "--logs-dir is required"
    [[ -n "${pg_version}" ]] || die "--pg is required"
    [[ -n "${package_output_dir}" ]] || die "--output-dir is required"
    [[ -n "${documentdb_image}" ]] || die "--documentdb-image is required"
    [[ -n "${test_image}" ]] || die "--test-image is required"
    [[ -n "${results_dir}" ]] || die "--results-dir is required"
    [[ -n "${username}" ]] || die "--username is required"
    [[ -n "${password}" ]] || die "--password is required"
    [[ -n "${scope}" ]] || die "--scope is required"
    [[ -n "${github_output}" ]] || die "--github-output is required"

    append_output "${github_output}" "build_success" "false"
    append_output "${github_output}" "test_exit_code" ""
    append_output "${github_output}" "results_ready" "false"
    append_output "${github_output}" "report_valid" "false"

    local build_log="${logs_dir}/build.log"
    local build_command=(
        bash ./scripts/functional_tests/run_with_compose.sh build
        --pg "${pg_version}"
        --output-dir "${package_output_dir}"
        --documentdb-image "${documentdb_image}"
    )
    if [[ -n "${build_test_image}" ]]; then
        build_command=(env TEST_IMAGE="${build_test_image}" "${build_command[@]}")
    fi

    if run_logged_command "${build_log}" "Building ${documentdb_image}" "${build_command[@]}"; then
        echo "Build completed."
        append_output "${github_output}" "build_success" "true"
    else
        local build_exit=$?
        echo "Build failed with exit code ${build_exit}." >&2
        return 0
    fi

    local test_log="${logs_dir}/test.log"
    local test_command=(
        bash ./scripts/functional_tests/run_with_compose.sh test
        --pg "${pg_version}"
        --output-dir "${package_output_dir}"
        --documentdb-image "${documentdb_image}"
        --test-image "${test_image}"
        --results-dir "${results_dir}"
        --username "${username}"
        --password "${password}"
        --scope "${scope}"
    )

    if [[ "${exclude_deselect_file}" == true ]]; then
        echo "Running without deselect.list."
        test_command+=(--exclude-deselect-file)
    fi

    local test_exit_code=0
    if run_logged_command "${test_log}" "Running functional tests" "${test_command[@]}"; then
        echo "Functional test run completed."
    else
        test_exit_code=$?
        if [[ "${test_exit_code}" -eq 1 && "${allow_test_exit_code_1}" == true ]]; then
            echo "Functional test run reported failures; continuing because exit code 1 is allowed."
        elif [[ "${test_exit_code}" -eq 1 ]]; then
            echo "Functional test run reported failures."
        else
            echo "Functional test run failed with unexpected exit code ${test_exit_code}." >&2
        fi
    fi
    append_output "${github_output}" "test_exit_code" "${test_exit_code}"

    if verify_results "${results_dir}"; then
        append_output "${github_output}" "results_ready" "true"
    else
        return 0
    fi

    if python3 ./scripts/functional_tests/validate_report.py --report "${results_dir}/functional-report.json"; then
        append_output "${github_output}" "report_valid" "true"
    fi
}

function download_daily_baseline {
    local event_name=""
    local repository=""
    local artifact_name=""
    local output_dir=""
    local github_output=""
    local server_url=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event-name)
                shift
                require_option_value "--event-name" "${1-}"
                event_name="$1"
                ;;
            --repository)
                shift
                require_option_value "--repository" "${1-}"
                repository="$1"
                ;;
            --artifact-name)
                shift
                require_option_value "--artifact-name" "${1-}"
                artifact_name="$1"
                ;;
            --output-dir)
                shift
                require_option_value "--output-dir" "${1-}"
                output_dir="$1"
                ;;
            --github-output)
                shift
                require_option_value "--github-output" "${1-}"
                github_output="$1"
                ;;
            --server-url)
                shift
                require_option_value "--server-url" "${1-}"
                server_url="$1"
                ;;
            *)
                die "Unknown argument for download-daily-baseline: $1"
                ;;
        esac
        shift
    done

    [[ -n "${event_name}" ]] || die "--event-name is required"
    [[ -n "${repository}" ]] || die "--repository is required"
    [[ -n "${artifact_name}" ]] || die "--artifact-name is required"
    [[ -n "${output_dir}" ]] || die "--output-dir is required"
    [[ -n "${github_output}" ]] || die "--github-output is required"
    [[ -n "${server_url}" ]] || die "--server-url is required"

    append_output "${github_output}" "baseline_available" "false"
    append_output "${github_output}" "baseline_path" ""
    append_output "${github_output}" "baseline_run_url" ""

    if [[ "${event_name}" == "schedule" ]]; then
        return 0
    fi

    local zip_path="${output_dir}.zip"
    local run_ids_file="${output_dir}-run-ids.txt"
    local artifact_id=""
    local baseline_run_url=""

    rm -rf "${output_dir}" "${zip_path}" "${run_ids_file}"
    mkdir -p "${output_dir}"

    if ! gh api \
        "/repos/${repository}/actions/workflows/functional_tests.yml/runs?branch=main&event=schedule&status=completed&per_page=20" \
        --jq '.workflow_runs[].id' > "${run_ids_file}" 2>/dev/null; then
        echo "Could not fetch scheduled workflow runs; skipping baseline comparison."
        rm -f "${run_ids_file}"
        return 0
    fi

    while IFS= read -r run_id; do
        [[ -n "${run_id}" ]] || continue

        if ! [[ "${run_id}" =~ ^[0-9]+$ ]]; then
            continue
        fi

        local candidate_artifact_id
        candidate_artifact_id="$(gh api \
            "/repos/${repository}/actions/runs/${run_id}/artifacts" \
            --jq ".artifacts[] | select(.name == \"${artifact_name}\" and .expired == false) | .id" 2>/dev/null | head -n 1 || true)"

        if [[ -z "${candidate_artifact_id}" ]]; then
            continue
        fi

        if ! gh api "/repos/${repository}/actions/artifacts/${candidate_artifact_id}/zip" > "${zip_path}" 2>/dev/null; then
            rm -f "${zip_path}"
            continue
        fi

        unzip -o -q "${zip_path}" -d "${output_dir}"

        local baseline_path="${output_dir}/functional-test-daily-baseline.json"
        if [[ ! -f "${baseline_path}" ]]; then
            rm -f "${zip_path}"
            continue
        fi

        artifact_id="${candidate_artifact_id}"
        baseline_run_url="${server_url}/${repository}/actions/runs/${run_id}"
        append_output "${github_output}" "baseline_available" "true"
        append_output "${github_output}" "baseline_path" "${baseline_path}"
        append_output "${github_output}" "baseline_run_url" "${baseline_run_url}"
        break
    done < "${run_ids_file}"

    rm -f "${run_ids_file}" "${zip_path}"

    if [[ -z "${artifact_id}" ]]; then
        echo "No daily baseline artifact found."
    fi
}

function analyze_results_for_workflow {
    local report=""
    local deselect_list=""
    local analysis_json=""
    local summary_markdown=""
    local scope=""
    local deselect_mode=""
    local documentdb_image=""
    local test_image=""
    local run_url=""
    local baseline_input=""
    local baseline_output=""
    local github_output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report)
                shift
                require_option_value "--report" "${1-}"
                report="$1"
                ;;
            --deselect-list)
                shift
                require_option_value "--deselect-list" "${1-}"
                deselect_list="$1"
                ;;
            --analysis-json)
                shift
                require_option_value "--analysis-json" "${1-}"
                analysis_json="$1"
                ;;
            --summary-markdown)
                shift
                require_option_value "--summary-markdown" "${1-}"
                summary_markdown="$1"
                ;;
            --scope)
                shift
                require_option_value "--scope" "${1-}"
                scope="$1"
                ;;
            --deselect-mode)
                shift
                require_option_value "--deselect-mode" "${1-}"
                deselect_mode="$1"
                ;;
            --documentdb-image)
                shift
                require_option_value "--documentdb-image" "${1-}"
                documentdb_image="$1"
                ;;
            --test-image)
                shift
                require_option_value "--test-image" "${1-}"
                test_image="$1"
                ;;
            --run-url)
                shift
                require_option_value "--run-url" "${1-}"
                run_url="$1"
                ;;
            --baseline-input)
                shift
                if [[ $# -eq 0 ]]; then
                    die "--baseline-input requires a value"
                fi
                baseline_input="$1"
                ;;
            --baseline-output)
                shift
                if [[ $# -eq 0 ]]; then
                    die "--baseline-output requires a value"
                fi
                baseline_output="$1"
                ;;
            --github-output)
                shift
                require_option_value "--github-output" "${1-}"
                github_output="$1"
                ;;
            *)
                die "Unknown argument for analyze-results: $1"
                ;;
        esac
        shift
    done

    [[ -n "${report}" ]] || die "--report is required"
    [[ -n "${deselect_list}" ]] || die "--deselect-list is required"
    [[ -n "${analysis_json}" ]] || die "--analysis-json is required"
    [[ -n "${summary_markdown}" ]] || die "--summary-markdown is required"
    [[ -n "${scope}" ]] || die "--scope is required"
    [[ -n "${deselect_mode}" ]] || die "--deselect-mode is required"
    [[ -n "${documentdb_image}" ]] || die "--documentdb-image is required"
    [[ -n "${test_image}" ]] || die "--test-image is required"
    [[ -n "${run_url}" ]] || die "--run-url is required"
    [[ -n "${github_output}" ]] || die "--github-output is required"

    append_output "${github_output}" "analysis_json" "${analysis_json}"
    append_output "${github_output}" "summary_markdown" "${summary_markdown}"
    append_output "${github_output}" "baseline_output" ""

    python3 ./scripts/functional_tests/analyze_results.py \
        --report "${report}" \
        --deselect-list "${deselect_list}" \
        --analysis-json "${analysis_json}" \
        --summary-markdown "${summary_markdown}" \
        --scope "${scope}" \
        --deselect-mode "${deselect_mode}" \
        --documentdb-image "${documentdb_image}" \
        --test-image "${test_image}" \
        --run-url "${run_url}" \
        --baseline-input "${baseline_input}" \
        --baseline-output "${baseline_output}"

    if [[ -n "${baseline_output}" && -f "${baseline_output}" ]]; then
        append_output "${github_output}" "baseline_output" "${baseline_output}"
    fi
}

function enforce_stack_outcome {
    local build_success=""
    local test_exit_code=""
    local report_valid=""
    local allow_test_exit_code_1=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-success)
                shift
                require_option_value "--build-success" "${1-}"
                build_success="$1"
                ;;
            --test-exit-code)
                shift
                require_option_value "--test-exit-code" "${1-}"
                test_exit_code="$1"
                ;;
            --report-valid)
                shift
                require_option_value "--report-valid" "${1-}"
                report_valid="$1"
                ;;
            --allow-test-exit-code-1)
                allow_test_exit_code_1=true
                ;;
            *)
                die "Unknown argument for enforce-stack-outcome: $1"
                ;;
        esac
        shift
    done

    if [[ "${build_success}" != "true" ]]; then
        die "Functional test stack build did not complete successfully."
    fi

    if [[ "${report_valid}" != "true" ]]; then
        die "Functional test report was missing or invalid."
    fi

    case "${test_exit_code}" in
        0)
            ;;
        1)
            if [[ "${allow_test_exit_code_1}" == true ]]; then
                return 0
            fi
            die "Functional tests reported failures."
            ;;
        *)
            die "Functional tests exited with unexpected code ${test_exit_code}."
            ;;
    esac
}

function collect_logs {
    local compose_path=""
    local project_name=""
    local logs_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --compose-path)
                shift
                require_option_value "--compose-path" "${1-}"
                compose_path="$1"
                ;;
            --project-name)
                shift
                require_option_value "--project-name" "${1-}"
                project_name="$1"
                ;;
            --logs-dir)
                shift
                require_option_value "--logs-dir" "${1-}"
                logs_dir="$1"
                ;;
            *)
                die "Unknown argument for collect-logs: $1"
                ;;
        esac
        shift
    done

    [[ -n "${compose_path}" ]] || die "--compose-path is required"
    [[ -n "${project_name}" ]] || die "--project-name is required"
    [[ -n "${logs_dir}" ]] || die "--logs-dir is required"

    mkdir -p "${logs_dir}"

    local container_id
    container_id="$(docker compose -f "${compose_path}" -p "${project_name}" ps -q documentdb-local || true)"
    if [[ -n "${container_id}" ]]; then
        docker compose -f "${compose_path}" -p "${project_name}" logs documentdb-local > "${logs_dir}/documentdb-local.log" 2>&1 || true
        docker logs "${container_id}" > "${logs_dir}/documentdb-local-container.log" 2>&1 || true
        docker cp "${container_id}:/var/log/documentdb/." "${logs_dir}/" || true
    fi
}

function show_log_tail {
    local logs_dir=""
    local files=()
    local found_log=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --logs-dir)
                shift
                require_option_value "--logs-dir" "${1-}"
                logs_dir="$1"
                ;;
            --file)
                shift
                require_option_value "--file" "${1-}"
                files+=("$1")
                ;;
            *)
                die "Unknown argument for show-log-tail: $1"
                ;;
        esac
        shift
    done

    [[ -n "${logs_dir}" ]] || die "--logs-dir is required"
    [[ ${#files[@]} -gt 0 ]] || die "At least one --file is required"

    for log_file in "${files[@]}"; do
        local log_path="${logs_dir}/${log_file}"
        if [[ -f "${log_path}" ]]; then
            found_log=true
            echo "::group::${log_file} (tail -n 200)"
            tail -n 200 "${log_path}" || true
            echo "::endgroup::"
        fi
    done

    if [[ "${found_log}" == false ]]; then
        echo "No requested logs were captured."
    fi
}

function cleanup_stack {
    local logs_dir=""
    local test_image=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --logs-dir)
                shift
                require_option_value "--logs-dir" "${1-}"
                logs_dir="$1"
                ;;
            --test-image)
                shift
                require_option_value "--test-image" "${1-}"
                test_image="$1"
                ;;
            *)
                die "Unknown argument for cleanup-stack: $1"
                ;;
        esac
        shift
    done

    [[ -n "${logs_dir}" ]] || die "--logs-dir is required"

    local cleanup_log="${logs_dir}/cleanup.log"
    local cleanup_command=(bash ./scripts/functional_tests/run_with_compose.sh down)
    if [[ -n "${test_image}" ]]; then
        cleanup_command=(env TEST_IMAGE="${test_image}" "${cleanup_command[@]}")
    fi

    if run_logged_command "${cleanup_log}" "Cleaning up local functional test stack" "${cleanup_command[@]}"; then
        echo "Cleanup completed."
    else
        return $?
    fi
}

function update_pin_file {
    local pin_file=""
    local image=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pin-file)
                shift
                require_option_value "--pin-file" "${1-}"
                pin_file="$1"
                ;;
            --image)
                shift
                require_option_value "--image" "${1-}"
                image="$1"
                ;;
            *)
                die "Unknown argument for update-pin-file: $1"
                ;;
        esac
        shift
    done

    [[ -n "${pin_file}" ]] || die "--pin-file is required"
    [[ -n "${image}" ]] || die "--image is required"

    {
        echo "# Pinned digest of ghcr.io/documentdb/functional-tests"
        echo "# Updated automatically by the update-test-image workflow."
        echo "# Do not edit manually -- changes will be overwritten."
        echo "${image}"
    } > "${pin_file}"
}

function create_or_update_update_test_image_pr {
    local body_file=""
    local github_output=""
    local branch="automation/update-functional-test-image"
    local title="Update functional test image pin"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --body-file)
                shift
                require_option_value "--body-file" "${1-}"
                body_file="$1"
                ;;
            --github-output)
                shift
                require_option_value "--github-output" "${1-}"
                github_output="$1"
                ;;
            *)
                die "Unknown argument for create-or-update-update-test-image-pr: $1"
                ;;
        esac
        shift
    done

    [[ -n "${body_file}" ]] || die "--body-file is required"
    [[ -n "${github_output}" ]] || die "--github-output is required"

    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

    git checkout -B "${branch}"

    git add scripts/functional_tests/deselect.list scripts/functional_tests/test-image-pin.txt
    if git diff --cached --quiet; then
        echo "No changes to commit."
        append_output "${github_output}" "pr_url" ""
        return 0
    fi

    git commit -s -m "Update functional test image pin" \
        -m "Refresh scripts/functional_tests/test-image-pin.txt and deselect.list
from the latest functional test image."

    # This branch is fully machine-managed and recreated from main on every run.
    # Keep --force here: the workflow only checks out main, so
    # --force-with-lease would not add a meaningful lease for this branch
    # and can still reject based on stale local tracking state.
    git push --force origin "${branch}"

    local existing_pr
    existing_pr="$(gh pr list --head "${branch}" --base main --json url --jq '.[0].url' || true)"
    if [[ -n "${existing_pr}" ]]; then
        gh pr edit "${existing_pr}" --body-file "${body_file}"
        append_output "${github_output}" "pr_url" "${existing_pr}"
    else
        local pr_url
        pr_url="$(gh pr create \
            --head "${branch}" \
            --base main \
            --title "${title}" \
            --body-file "${body_file}")"
        append_output "${github_output}" "pr_url" "${pr_url}"
    fi
}

function write_update_summary {
    local current_image=""
    local latest_image=""
    local pr_url=""
    local step_summary_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --current-image)
                shift
                require_option_value "--current-image" "${1-}"
                current_image="$1"
                ;;
            --latest-image)
                shift
                require_option_value "--latest-image" "${1-}"
                latest_image="$1"
                ;;
            --pr-url)
                shift
                if [[ $# -eq 0 ]]; then
                    die "--pr-url requires a value"
                fi
                pr_url="$1"
                ;;
            --step-summary-file)
                shift
                require_option_value "--step-summary-file" "${1-}"
                step_summary_file="$1"
                ;;
            *)
                die "Unknown argument for write-update-summary: $1"
                ;;
        esac
        shift
    done

    [[ -n "${current_image}" ]] || die "--current-image is required"
    [[ -n "${latest_image}" ]] || die "--latest-image is required"
    [[ -n "${step_summary_file}" ]] || die "--step-summary-file is required"

    {
        echo "## Test image update"
        echo
        echo "**New image:** \`${latest_image}\`"
        echo "**Previous image:** \`${current_image}\`"
        if [[ -n "${pr_url}" ]]; then
            echo
            echo "Pull request: ${pr_url}"
        fi
    } >> "${step_summary_file}"
}

subcommand="${1:-}"
if [[ -z "${subcommand}" ]]; then
    die "A subcommand is required."
fi
shift

case "${subcommand}" in
    resolve-functional-test-image)
        resolve_functional_test_image "$@"
        ;;
    resolve-update-test-image)
        resolve_update_test_image "$@"
        ;;
    run-functional-test-stack)
        run_functional_test_stack "$@"
        ;;
    download-daily-baseline)
        download_daily_baseline "$@"
        ;;
    analyze-results)
        analyze_results_for_workflow "$@"
        ;;
    enforce-stack-outcome)
        enforce_stack_outcome "$@"
        ;;
    collect-logs)
        collect_logs "$@"
        ;;
    show-log-tail)
        show_log_tail "$@"
        ;;
    cleanup-stack)
        cleanup_stack "$@"
        ;;
    update-pin-file)
        update_pin_file "$@"
        ;;
    create-or-update-update-test-image-pr)
        create_or_update_update_test_image_pr "$@"
        ;;
    write-update-summary)
        write_update_summary "$@"
        ;;
    *)
        die "Unknown subcommand: ${subcommand}"
        ;;
esac
