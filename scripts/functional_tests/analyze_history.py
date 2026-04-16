#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from report_utils import ReportValidationError, load_and_validate_report

DISPLAY_LIMIT = 20
EXPECTED_MANIFEST_FIELDS = 4


@dataclass(frozen=True)
class RunMetadata:
    run_id: str
    completed_at: str | None
    run_url: str | None
    report_path: Path
    label: str
    is_current: bool = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Analyze recent daily functional test history to identify stable, "
            "failing, and flaky tests."
        )
    )
    parser.add_argument("--current-report", required=True, type=Path)
    parser.add_argument("--current-run-url", required=True)
    parser.add_argument("--history-manifest", type=Path)
    parser.add_argument("--requested-window", required=True, type=int)
    parser.add_argument("--analysis-json", required=True, type=Path)
    parser.add_argument("--summary-markdown", required=True, type=Path)
    return parser.parse_args()


def parse_history_manifest(path: Path | None) -> list[RunMetadata]:
    if path is None or not path.exists():
        return []

    entries: list[RunMetadata] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not raw_line.strip():
            continue

        fields = raw_line.split("\t")
        if len(fields) != EXPECTED_MANIFEST_FIELDS:
            raise SystemExit(
                f"{path}:{line_number}: expected {EXPECTED_MANIFEST_FIELDS} tab-separated "
                f"fields, found {len(fields)}"
            )

        run_id, completed_at, run_url, report_path = fields
        entries.append(
            RunMetadata(
                run_id=run_id,
                completed_at=completed_at or None,
                run_url=run_url or None,
                report_path=Path(report_path),
                label=f"{completed_at[:10]} (run {run_id})" if completed_at else f"run {run_id}",
            )
        )

    return entries


def load_report_run(
    metadata: RunMetadata,
) -> tuple[dict[str, object] | None, dict[str, str] | None]:
    try:
        parsed = load_and_validate_report(metadata.report_path)
    except ReportValidationError as exc:
        return None, {
            "label": metadata.label,
            "run_id": metadata.run_id,
            "run_url": metadata.run_url or "",
            "report_path": str(metadata.report_path),
            "error": str(exc),
        }

    return (
        {
            "label": metadata.label,
            "run_id": metadata.run_id,
            "completed_at": metadata.completed_at,
            "run_url": metadata.run_url,
            "report_path": str(metadata.report_path),
            "is_current": metadata.is_current,
            "outcomes_by_nodeid": parsed.outcomes_by_nodeid,
        },
        None,
    )


def classify_test(
    nodeid: str, outcome_sequence: list[str]
) -> tuple[str, dict[str, object]]:
    passed = outcome_sequence.count("passed")
    failed = outcome_sequence.count("failed")
    skipped = outcome_sequence.count("skipped")
    missing = outcome_sequence.count("missing")
    transitions = sum(
        1 for previous, current in zip(outcome_sequence, outcome_sequence[1:]) if previous != current
    )

    details = {
        "nodeid": nodeid,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "missing": missing,
        "present": passed + failed + skipped,
        "latest_outcome": outcome_sequence[-1],
        "transitions": transitions,
        "outcome_sequence": outcome_sequence,
    }

    if passed > 0 and failed > 0:
        return "flaky", details
    if passed == len(outcome_sequence) and skipped == 0 and missing == 0:
        return "stable_pass", details
    if failed == len(outcome_sequence) and skipped == 0 and missing == 0:
        return "stable_fail", details
    return "missing_or_skipped", details


def build_history_analysis(
    runs: list[dict[str, object]],
    *,
    requested_window: int,
    ignored_runs: list[dict[str, str]],
) -> dict[str, object]:
    categories: dict[str, list[dict[str, object]]] = {
        "stable_pass": [],
        "stable_fail": [],
        "flaky": [],
        "missing_or_skipped": [],
    }

    all_nodeids = sorted(
        {
            nodeid
            for run in runs
            for nodeid in run["outcomes_by_nodeid"]  # type: ignore[index]
        }
    )

    for nodeid in all_nodeids:
        outcome_sequence = [
            run["outcomes_by_nodeid"].get(nodeid, "missing")  # type: ignore[index]
            for run in runs
        ]
        category, details = classify_test(nodeid, outcome_sequence)
        categories[category].append(details)

    categories["stable_pass"].sort(key=lambda item: item["nodeid"])
    categories["stable_fail"].sort(key=lambda item: item["nodeid"])
    categories["flaky"].sort(
        key=lambda item: (
            -item["transitions"],
            -item["failed"],
            -item["passed"],
            -item["missing"],
            item["nodeid"],
        )
    )
    categories["missing_or_skipped"].sort(
        key=lambda item: (
            -item["missing"],
            -item["skipped"],
            -item["failed"],
            item["nodeid"],
        )
    )

    return {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "requested_window": requested_window,
        "valid_run_count": len(runs),
        "ignored_run_count": len(ignored_runs),
        "runs": [
            {
                "label": run["label"],
                "run_id": run["run_id"],
                "completed_at": run["completed_at"],
                "run_url": run["run_url"],
                "report_path": run["report_path"],
                "is_current": run["is_current"],
            }
            for run in runs
        ],
        "ignored_runs": ignored_runs,
        "counts": {
            "total_tests": len(all_nodeids),
            "stable_pass": len(categories["stable_pass"]),
            "stable_fail": len(categories["stable_fail"]),
            "flaky": len(categories["flaky"]),
            "missing_or_skipped": len(categories["missing_or_skipped"]),
        },
        "categories": categories,
    }


def render_detail_lines(
    title: str,
    tests: list[dict[str, object]],
    *,
    empty_message: str,
    formatter,
) -> list[str]:
    lines = ["", f"### {title}"]
    if not tests:
        lines.append(empty_message)
        return lines

    for item in tests[:DISPLAY_LIMIT]:
        lines.append(formatter(item))
    if len(tests) > DISPLAY_LIMIT:
        lines.append(f"- ... and {len(tests) - DISPLAY_LIMIT} more")
    return lines


def render_summary_markdown(analysis: dict[str, object]) -> str:
    counts = analysis["counts"]
    valid_run_count = analysis["valid_run_count"]
    requested_window = analysis["requested_window"]
    ignored_run_count = analysis["ignored_run_count"]

    lines = [
        "## Functional Test History",
        "",
        (
            f"Analyzed `{valid_run_count}` valid daily run(s) out of the requested "
            f"`{requested_window}`."
        ),
        "",
        "| Stable pass | Stable fail | Flaky | Missing or skipped |",
        "| --- | --- | --- | --- |",
        (
            f"| {counts['stable_pass']} | {counts['stable_fail']} | "
            f"{counts['flaky']} | {counts['missing_or_skipped']} |"
        ),
        "",
        f"Unique tests seen across the analyzed runs: `{counts['total_tests']}`.",
    ]

    if valid_run_count < requested_window:
        lines.append(
            "History is still sparse, so treat stable/flaky labels as lower-confidence until "
            "more daily runs accumulate."
        )

    if ignored_run_count:
        lines.append(
            f"Ignored `{ignored_run_count}` historical run(s) because their reports were "
            "missing or invalid."
        )

    lines.extend(["", "### Runs analyzed"])
    for run in analysis["runs"]:
        run_label = run["label"]
        run_url = run["run_url"]
        if run["is_current"]:
            run_label = f"{run_label} (current run)"
        if run_url:
            lines.append(f"- {run_label}: {run_url}")
        else:
            lines.append(f"- {run_label}")

    lines.extend(
        render_detail_lines(
            "Flaky tests",
            analysis["categories"]["flaky"],
            empty_message="No flaky tests were detected in the analyzed window.",
            formatter=lambda item: (
                f"- `{item['nodeid']}` - passed {item['passed']}, failed {item['failed']}, "
                f"skipped {item['skipped']}, missing {item['missing']}, transitions {item['transitions']}"
            ),
        )
    )
    lines.extend(
        render_detail_lines(
            "Always failing tests",
            analysis["categories"]["stable_fail"],
            empty_message="No tests failed in every analyzed run.",
            formatter=lambda item: (
                f"- `{item['nodeid']}` - failed in all {valid_run_count} analyzed run(s)"
            ),
        )
    )
    lines.extend(
        render_detail_lines(
            "Missing or skipped tests",
            analysis["categories"]["missing_or_skipped"],
            empty_message="No tests were skipped or missing across the analyzed runs.",
            formatter=lambda item: (
                f"- `{item['nodeid']}` - latest outcome {item['latest_outcome']}, "
                f"passed {item['passed']}, failed {item['failed']}, skipped {item['skipped']}, "
                f"missing {item['missing']}"
            ),
        )
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()

    history_runs = parse_history_manifest(args.history_manifest)
    ordered_history_runs = sorted(history_runs, key=lambda item: item.completed_at or "")
    run_metadata = ordered_history_runs + [
        RunMetadata(
            run_id="current",
            completed_at=None,
            run_url=args.current_run_url,
            report_path=args.current_report,
            label="Current run",
            is_current=True,
        )
    ]

    valid_runs: list[dict[str, object]] = []
    ignored_runs: list[dict[str, str]] = []
    for metadata in run_metadata:
        loaded_run, ignored_run = load_report_run(metadata)
        if loaded_run is not None:
            valid_runs.append(loaded_run)
        if ignored_run is not None:
            ignored_runs.append(ignored_run)

    analysis = build_history_analysis(
        valid_runs,
        requested_window=args.requested_window,
        ignored_runs=ignored_runs,
    )

    args.analysis_json.write_text(
        json.dumps(analysis, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    args.summary_markdown.write_text(
        render_summary_markdown(analysis),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
