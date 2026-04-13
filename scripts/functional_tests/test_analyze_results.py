#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from analyze_results import (
    load_baseline,
    parse_report,
    render_summary_markdown,
)


def make_report(
    failed: list[str],
    passed: list[str] | None = None,
    skipped: list[str] | None = None,
) -> dict:
    if passed is None:
        passed = []
    if skipped is None:
        skipped = []
    tests = []
    for nodeid in passed:
        tests.append({"nodeid": nodeid, "outcome": "passed"})
    for nodeid in failed:
        tests.append({"nodeid": nodeid, "outcome": "failed"})
    for nodeid in skipped:
        tests.append({"nodeid": nodeid, "outcome": "skipped"})

    total = len(tests)
    return {
        "exitcode": 1 if failed else 0,
        "summary": {
            "collected": total,
            "total": total,
            "passed": len(passed),
            "failed": len(failed),
            "skipped": len(skipped),
        },
        "collectors": [{"nodeid": "", "outcome": "passed", "result": []}],
        "tests": tests,
    }


def write_json(payload: dict, directory: Path, filename: str) -> Path:
    path = directory / filename
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


class ParseReportTests(unittest.TestCase):
    def test_returns_counts_and_failures(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        report = make_report(
            passed=["t/a.py::test_ok"],
            failed=["t/b.py::test_fail"],
            skipped=["t/c.py::test_skip"],
        )
        path = write_json(report, Path(temp_dir.name), "report.json")
        counts, failed = parse_report(path)

        self.assertEqual(counts["total"], 3)
        self.assertEqual(counts["passed"], 1)
        self.assertEqual(counts["failed"], 1)
        self.assertEqual(counts["skipped"], 1)
        self.assertEqual(failed, ["t/b.py::test_fail"])

    def test_invalid_report_exits(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        path = write_json({"exitcode": 5}, Path(temp_dir.name), "bad.json")
        with self.assertRaises(SystemExit):
            parse_report(path)


class LoadBaselineTests(unittest.TestCase):
    def test_none_path_returns_none(self) -> None:
        self.assertIsNone(load_baseline(None))

    def test_missing_file_returns_none(self) -> None:
        self.assertIsNone(load_baseline(Path("/nonexistent/baseline.json")))

    def test_valid_baseline(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        baseline = {"failed_tests": ["t/x.py::test_a", "t/y.py::test_b"]}
        path = write_json(baseline, Path(temp_dir.name), "baseline.json")
        result = load_baseline(path)

        self.assertIsNotNone(result)
        self.assertEqual(result["failed_tests"], ["t/x.py::test_a", "t/y.py::test_b"])

    def test_invalid_json_exits(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        path = Path(temp_dir.name) / "bad.json"
        path.write_text("not json", encoding="utf-8")
        with self.assertRaises(SystemExit):
            load_baseline(path)

    def test_missing_failed_tests_key_exits(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        path = write_json({"other": "data"}, Path(temp_dir.name), "no-key.json")
        with self.assertRaises(SystemExit):
            load_baseline(path)


class RenderSummaryMarkdownTests(unittest.TestCase):
    def test_applied_mode_without_baseline(self) -> None:
        analysis = {
            "scope": "full",
            "deselect_mode": "applied",
            "documentdb_image": "test:latest",
            "test_image": "ghcr.io/test:sha256:abc",
            "counts": {"total": 10, "passed": 9, "failed": 1, "skipped": 0},
            "failed_tests": ["t/a.py::test_fail"],
            "categories": {},
            "comparison": {
                "baseline_available": False,
                "baseline_run_url": None,
                "also_in_daily_baseline": [],
                "potential_regressions": [],
            },
        }
        md = render_summary_markdown(analysis)

        self.assertIn("## Functional Tests", md)
        self.assertIn("Deselect list: `applied`", md)
        self.assertIn("| 10 | 9 | 1 | 0 |", md)
        self.assertIn("`t/a.py::test_fail`", md)
        self.assertIn("No daily baseline artifact was available", md)

    def test_applied_mode_with_baseline(self) -> None:
        analysis = {
            "scope": "full",
            "deselect_mode": "applied",
            "documentdb_image": "test:latest",
            "test_image": "ghcr.io/test:sha256:abc",
            "counts": {"total": 5, "passed": 3, "failed": 2, "skipped": 0},
            "failed_tests": ["t/a.py::test_reg", "t/b.py::test_known"],
            "categories": {},
            "comparison": {
                "baseline_available": True,
                "baseline_run_url": "https://example.com/run/1",
                "also_in_daily_baseline": ["t/b.py::test_known"],
                "potential_regressions": ["t/a.py::test_reg"],
            },
        }
        md = render_summary_markdown(analysis)

        self.assertIn("### Daily baseline comparison", md)
        self.assertIn("| 1 |", md)
        self.assertIn("`t/a.py::test_reg`", md)
        self.assertIn("https://example.com/run/1", md)

    def test_excluded_mode(self) -> None:
        analysis = {
            "scope": "full",
            "deselect_mode": "excluded",
            "documentdb_image": "test:latest",
            "test_image": "ghcr.io/test:sha256:abc",
            "counts": {"total": 5, "passed": 3, "failed": 2, "skipped": 0},
            "failed_tests": ["t/a.py::test_one", "t/b.py::test_new"],
            "categories": {
                "unsupported_feature": ["t/a.py::test_one"],
                "known_product_bug": [],
                "needs_triage": [],
                "new_failures": ["t/b.py::test_new"],
            },
            "comparison": {},
        }
        md = render_summary_markdown(analysis)

        self.assertIn("excluded (running all tests)", md)
        self.assertIn("### Daily failure categories", md)
        self.assertIn("| 1 | 0 | 0 | 1 |", md)
        self.assertIn("### New failures not in deselect.list", md)
        self.assertIn("`t/b.py::test_new`", md)


class BaselineComparisonLogicTests(unittest.TestCase):
    """Test the core comparison logic inlined from analyze_results.main()."""

    def test_potential_regressions_vs_known(self) -> None:
        failed_tests = ["t/a.py::test_reg", "t/b.py::test_known", "t/c.py::test_both"]
        baseline_failed = {"t/b.py::test_known", "t/c.py::test_both", "t/d.py::test_old"}

        also_in_baseline = [n for n in failed_tests if n in baseline_failed]
        potential_regressions = [n for n in failed_tests if n not in baseline_failed]

        self.assertEqual(also_in_baseline, ["t/b.py::test_known", "t/c.py::test_both"])
        self.assertEqual(potential_regressions, ["t/a.py::test_reg"])

    def test_no_failures(self) -> None:
        failed_tests: list[str] = []
        baseline_failed = {"t/x.py::test_old"}

        also_in_baseline = [n for n in failed_tests if n in baseline_failed]
        potential_regressions = [n for n in failed_tests if n not in baseline_failed]

        self.assertEqual(also_in_baseline, [])
        self.assertEqual(potential_regressions, [])


if __name__ == "__main__":
    unittest.main()
