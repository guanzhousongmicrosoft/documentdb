#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from report_utils import ReportValidationError, load_and_validate_report


class LoadAndValidateReportTests(unittest.TestCase):
    def write_report(self, payload: dict) -> Path:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        path = Path(temp_dir.name) / "functional-report.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def make_report(self, **overrides: object) -> dict:
        report = {
            "exitcode": 1,
            "summary": {
                "collected": 2,
                "total": 2,
                "passed": 1,
                "failed": 1,
            },
            "collectors": [
                {
                    "nodeid": "",
                    "outcome": "passed",
                    "result": [],
                }
            ],
            "tests": [
                {
                    "nodeid": "compatibility/tests/test_one.py::test_passes",
                    "outcome": "passed",
                },
                {
                    "nodeid": "compatibility/tests/test_two.py::test_fails",
                    "outcome": "failed",
                },
            ],
        }
        report.update(overrides)
        return report

    def test_accepts_complete_report(self) -> None:
        parsed = load_and_validate_report(self.write_report(self.make_report()))

        self.assertEqual(
            parsed.counts,
            {"passed": 1, "failed": 1, "skipped": 0, "total": 2},
        )
        self.assertEqual(
            parsed.failed_tests,
            ["compatibility/tests/test_two.py::test_fails"],
        )

    def test_rejects_non_test_failure_exit_code(self) -> None:
        path = self.write_report(self.make_report(exitcode=3))

        with self.assertRaisesRegex(ReportValidationError, "pytest exited with 3"):
            load_and_validate_report(path)

    def test_rejects_collection_failures(self) -> None:
        path = self.write_report(
            self.make_report(
                collectors=[
                    {
                        "nodeid": "compatibility/tests/test_broken.py",
                        "outcome": "failed",
                        "result": [],
                        "longrepr": "SyntaxError: invalid syntax",
                    }
                ]
            )
        )

        with self.assertRaisesRegex(ReportValidationError, "collection failed"):
            load_and_validate_report(path)

    def test_rejects_unsupported_test_outcomes(self) -> None:
        path = self.write_report(
            self.make_report(
                summary={"collected": 1, "total": 1, "error": 1},
                tests=[
                    {
                        "nodeid": "compatibility/tests/test_error.py::test_errors",
                        "outcome": "error",
                    }
                ],
            )
        )

        with self.assertRaisesRegex(ReportValidationError, "unsupported test outcomes"):
            load_and_validate_report(path)


if __name__ == "__main__":
    unittest.main()
