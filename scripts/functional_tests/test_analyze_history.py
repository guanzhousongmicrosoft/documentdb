#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from analyze_history import (
    build_history_analysis,
    load_report_run,
    parse_history_manifest,
    render_summary_markdown,
    RunMetadata,
)


def make_report(
    *,
    passed: list[str] | None = None,
    failed: list[str] | None = None,
    skipped: list[str] | None = None,
) -> dict:
    passed = passed or []
    failed = failed or []
    skipped = skipped or []

    tests = []
    for nodeid in passed:
        tests.append({"nodeid": nodeid, "outcome": "passed"})
    for nodeid in failed:
        tests.append({"nodeid": nodeid, "outcome": "failed"})
    for nodeid in skipped:
        tests.append({"nodeid": nodeid, "outcome": "skipped"})

    return {
        "exitcode": 1 if failed else 0,
        "summary": {
            "collected": len(tests),
            "total": len(tests),
            "passed": len(passed),
            "failed": len(failed),
            "skipped": len(skipped),
        },
        "collectors": [{"nodeid": "", "outcome": "passed", "result": []}],
        "tests": tests,
    }


def write_report(directory: Path, filename: str, payload: dict) -> Path:
    path = directory / filename
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


class ParseHistoryManifestTests(unittest.TestCase):
    def test_missing_manifest_returns_empty_list(self) -> None:
        self.assertEqual(parse_history_manifest(Path("/nonexistent/history.tsv")), [])

    def test_parses_entries(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        manifest_path = Path(temp_dir.name) / "history.tsv"
        manifest_path.write_text(
            "123\t2026-04-10T00:00:00Z\thttps://example.invalid/123\t/tmp/report-123.json\n",
            encoding="utf-8",
        )

        entries = parse_history_manifest(manifest_path)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].run_id, "123")
        self.assertEqual(entries[0].label, "2026-04-10 (run 123)")


class LoadReportRunTests(unittest.TestCase):
    def test_invalid_report_is_ignored(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        invalid_report = Path(temp_dir.name) / "invalid.json"
        invalid_report.write_text('{"exitcode": 5}', encoding="utf-8")
        metadata = RunMetadata(
            run_id="123",
            completed_at="2026-04-10T00:00:00Z",
            run_url="https://example.invalid/123",
            report_path=invalid_report,
            label="2026-04-10 (run 123)",
        )

        loaded_run, ignored_run = load_report_run(metadata)
        self.assertIsNone(loaded_run)
        self.assertIsNotNone(ignored_run)
        self.assertEqual(ignored_run["run_id"], "123")


class BuildHistoryAnalysisTests(unittest.TestCase):
    def load_run(self, metadata: RunMetadata) -> dict[str, object]:
        loaded_run, ignored_run = load_report_run(metadata)
        self.assertIsNotNone(loaded_run)
        self.assertIsNone(ignored_run)
        return loaded_run

    def test_classifies_stable_flaky_and_missing(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        directory = Path(temp_dir.name)

        previous_old = self.load_run(
            RunMetadata(
                run_id="111",
                completed_at="2026-04-08T00:00:00Z",
                run_url="https://example.invalid/111",
                report_path=write_report(
                    directory,
                    "report-111.json",
                    make_report(
                        passed=["test_stable_pass", "test_flaky", "test_missing"],
                        failed=["test_stable_fail"],
                    ),
                ),
                label="2026-04-08 (run 111)",
            )
        )
        previous_new = self.load_run(
            RunMetadata(
                run_id="112",
                completed_at="2026-04-09T00:00:00Z",
                run_url="https://example.invalid/112",
                report_path=write_report(
                    directory,
                    "report-112.json",
                    make_report(
                        passed=["test_stable_pass", "test_missing"],
                        failed=["test_stable_fail", "test_flaky"],
                        skipped=["test_skipped"],
                    ),
                ),
                label="2026-04-09 (run 112)",
            )
        )
        current_run = self.load_run(
            RunMetadata(
                run_id="current",
                completed_at=None,
                run_url="https://example.invalid/current",
                report_path=write_report(
                    directory,
                    "report-current.json",
                    make_report(
                        passed=["test_stable_pass", "test_flaky", "test_skipped"],
                        failed=["test_stable_fail"],
                    ),
                ),
                label="Current run",
                is_current=True,
            )
        )

        analysis = build_history_analysis(
            [previous_old, previous_new, current_run],
            requested_window=7,
            ignored_runs=[],
        )

        self.assertEqual(
            analysis["counts"],
            {
                "total_tests": 5,
                "stable_pass": 1,
                "stable_fail": 1,
                "flaky": 1,
                "missing_or_skipped": 2,
            },
        )
        self.assertEqual(
            [item["nodeid"] for item in analysis["categories"]["stable_pass"]],
            ["test_stable_pass"],
        )
        self.assertEqual(
            [item["nodeid"] for item in analysis["categories"]["stable_fail"]],
            ["test_stable_fail"],
        )
        self.assertEqual(
            [item["nodeid"] for item in analysis["categories"]["flaky"]],
            ["test_flaky"],
        )
        self.assertEqual(
            [item["nodeid"] for item in analysis["categories"]["missing_or_skipped"]],
            ["test_skipped", "test_missing"],
        )

    def test_summary_mentions_sparse_history_and_flaky_tests(self) -> None:
        analysis = {
            "requested_window": 7,
            "valid_run_count": 2,
            "ignored_run_count": 1,
            "runs": [
                {
                    "label": "2026-04-09 (run 112)",
                    "run_id": "112",
                    "completed_at": "2026-04-09T00:00:00Z",
                    "run_url": "https://example.invalid/112",
                    "report_path": "/tmp/report-112.json",
                    "is_current": False,
                },
                {
                    "label": "Current run",
                    "run_id": "current",
                    "completed_at": None,
                    "run_url": "https://example.invalid/current",
                    "report_path": "/tmp/report-current.json",
                    "is_current": True,
                },
            ],
            "counts": {
                "total_tests": 3,
                "stable_pass": 1,
                "stable_fail": 0,
                "flaky": 1,
                "missing_or_skipped": 1,
            },
            "categories": {
                "stable_pass": [{"nodeid": "test_ok"}],
                "stable_fail": [],
                "flaky": [
                    {
                        "nodeid": "test_flaky",
                        "passed": 1,
                        "failed": 1,
                        "skipped": 0,
                        "missing": 0,
                        "latest_outcome": "passed",
                        "transitions": 1,
                    }
                ],
                "missing_or_skipped": [
                    {
                        "nodeid": "test_missing",
                        "passed": 1,
                        "failed": 0,
                        "skipped": 0,
                        "missing": 1,
                        "latest_outcome": "passed",
                        "transitions": 1,
                    }
                ],
            },
            "ignored_runs": [
                {
                    "label": "2026-04-08 (run 111)",
                    "run_id": "111",
                    "run_url": "https://example.invalid/111",
                    "report_path": "/tmp/report-111.json",
                    "error": "Invalid report",
                }
            ],
        }

        markdown = render_summary_markdown(analysis)

        self.assertIn("Analyzed `2` valid daily run(s) out of the requested `7`.", markdown)
        self.assertIn("History is still sparse", markdown)
        self.assertIn("Ignored `1` historical run(s)", markdown)
        self.assertIn("`test_flaky` - passed 1, failed 1", markdown)


if __name__ == "__main__":
    unittest.main()
