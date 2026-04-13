#!/usr/bin/env python3

from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

ALLOWED_TEST_OUTCOMES = ("passed", "failed", "skipped")
SUMMARY_METADATA_KEYS = {"collected", "deselected", "total"}


class ReportValidationError(ValueError):
    """Raised when a pytest JSON report is malformed or incomplete."""


@dataclass(frozen=True)
class ParsedReport:
    counts: dict[str, int]
    failed_tests: list[str]
    exitcode: int


def _parse_int(value: object, *, field_name: str, path: Path) -> int:
    if isinstance(value, bool):
        raise ReportValidationError(
            f"{path}: expected integer for {field_name}, found boolean"
        )

    if isinstance(value, int):
        return value

    if isinstance(value, str):
        stripped = value.strip()
        if stripped.isdigit():
            return int(stripped)

    raise ReportValidationError(
        f"{path}: expected integer for {field_name}, found {value!r}"
    )


def _summary_count(summary: dict, key: str, path: Path, *, required: bool = False) -> int:
    value = summary.get(key)
    if value is None:
        if required:
            raise ReportValidationError(f"{path}: report summary missing {key!r}")
        return 0

    count = _parse_int(value, field_name=f"summary.{key}", path=path)
    if count < 0:
        raise ReportValidationError(
            f"{path}: report summary count {key!r} must be non-negative"
        )
    return count


def load_report(path: Path) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ReportValidationError(f"Missing report file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ReportValidationError(f"Could not parse JSON report {path}: {exc}") from exc

    if not isinstance(payload, dict):
        raise ReportValidationError(f"{path}: report root must be a JSON object")

    return payload


def load_and_validate_report(path: Path) -> ParsedReport:
    report = load_report(path)

    exitcode = _parse_int(report.get("exitcode"), field_name="exitcode", path=path)
    if exitcode not in (0, 1):
        raise ReportValidationError(
            f"{path}: pytest exited with {exitcode}; refusing to treat the report as a complete functional-test run"
        )

    summary = report.get("summary")
    if not isinstance(summary, dict):
        raise ReportValidationError(f"{path}: report summary must be a JSON object")

    collectors = report.get("collectors", [])
    if collectors is None:
        collectors = []
    if not isinstance(collectors, list):
        raise ReportValidationError(f"{path}: report collectors must be a list")

    collector_failures: list[str] = []
    for index, collector in enumerate(collectors, start=1):
        if not isinstance(collector, dict):
            raise ReportValidationError(
                f"{path}: collector #{index} must be a JSON object"
            )

        if collector.get("outcome") == "failed":
            nodeid = collector.get("nodeid")
            if isinstance(nodeid, str) and nodeid:
                collector_failures.append(nodeid)
            else:
                collector_failures.append("<root>")

    if collector_failures:
        failures = ", ".join(sorted(collector_failures))
        raise ReportValidationError(
            f"{path}: collection failed for {failures}; refusing to update state from an incomplete run"
        )

    tests = report.get("tests")
    if not isinstance(tests, list):
        raise ReportValidationError(f"{path}: report tests must be a list")

    outcome_counts: Counter[str] = Counter()
    failed_tests: list[str] = []
    seen_nodeids: set[str] = set()

    for index, test in enumerate(tests, start=1):
        if not isinstance(test, dict):
            raise ReportValidationError(f"{path}: test #{index} must be a JSON object")

        nodeid = test.get("nodeid")
        if not isinstance(nodeid, str) or not nodeid:
            raise ReportValidationError(
                f"{path}: test #{index} is missing a non-empty nodeid"
            )
        if nodeid in seen_nodeids:
            raise ReportValidationError(f"{path}: duplicate test nodeid {nodeid!r}")
        seen_nodeids.add(nodeid)

        outcome = test.get("outcome")
        if not isinstance(outcome, str) or not outcome:
            raise ReportValidationError(
                f"{path}: test {nodeid!r} is missing a non-empty outcome"
            )

        outcome_counts[outcome] += 1
        if outcome == "failed":
            failed_tests.append(nodeid)

    unsupported_outcomes = sorted(
        outcome for outcome in outcome_counts if outcome not in ALLOWED_TEST_OUTCOMES
    )
    if unsupported_outcomes:
        raise ReportValidationError(
            f"{path}: report contains unsupported test outcomes: {', '.join(unsupported_outcomes)}"
        )

    counts = {
        "passed": outcome_counts["passed"],
        "failed": outcome_counts["failed"],
        "skipped": outcome_counts["skipped"],
        "total": len(tests),
    }

    summary_total = _summary_count(summary, "total", path, required=True)
    if summary_total != counts["total"]:
        raise ReportValidationError(
            f"{path}: report summary total {summary_total} does not match {counts['total']} test entries"
        )

    for key in ("passed", "failed", "skipped"):
        summary_value = _summary_count(summary, key, path)
        if summary_value != counts[key]:
            raise ReportValidationError(
                f"{path}: report summary {key}={summary_value} does not match {counts[key]} test entries"
            )

    collected = _summary_count(summary, "collected", path, required=True)
    if collected < counts["total"]:
        raise ReportValidationError(
            f"{path}: report summary collected={collected} is smaller than total={counts['total']}"
        )

    unsupported_summary_keys = []
    for key, value in summary.items():
        if key in SUMMARY_METADATA_KEYS or key in ALLOWED_TEST_OUTCOMES:
            continue

        count = _parse_int(value, field_name=f"summary.{key}", path=path)
        if count != 0:
            unsupported_summary_keys.append(f"{key}={count}")

    if unsupported_summary_keys:
        raise ReportValidationError(
            f"{path}: report summary contains unsupported outcome counts: {', '.join(sorted(unsupported_summary_keys))}"
        )

    return ParsedReport(counts=counts, failed_tests=failed_tests, exitcode=exitcode)
