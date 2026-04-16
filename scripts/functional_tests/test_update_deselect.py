#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from update_deselect import (
    parse_deselect_list,
    render_deselect_list,
    parse_report,
)

SAMPLE_DESELECT = """\
# One pytest node id per line. Blank lines and comments are ignored.

# Use node IDs relative to the functional-tests pytest rootdir (`documentdb_tests`).

# Unsupported feature in documentdb-local today.
tests/test_unsupported.py::test_one

# Known product bug in documentdb-local today.
tests/test_bug.py::test_two

# Needs triage -- added by update-test-image workflow on 2026-01-01.
# Categorize these as "Unsupported feature" or "Known product bug" before merging.
tests/test_triage.py::test_three
"""


class ParseDeselectListTests(unittest.TestCase):
    def write_deselect(self, content: str) -> Path:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        path = Path(temp_dir.name) / "deselect.list"
        path.write_text(content, encoding="utf-8")
        return path

    def test_parses_all_sections(self) -> None:
        sections = parse_deselect_list(self.write_deselect(SAMPLE_DESELECT))

        self.assertEqual(sections["unsupported_feature"], ["tests/test_unsupported.py::test_one"])
        self.assertEqual(sections["known_product_bug"], ["tests/test_bug.py::test_two"])
        self.assertEqual(sections["needs_triage"], ["tests/test_triage.py::test_three"])

    def test_rejects_duplicate_entries(self) -> None:
        content = """\
# Unsupported feature in documentdb-local today.
tests/test_dup.py::test_one

# Known product bug in documentdb-local today.
tests/test_dup.py::test_one
"""
        with self.assertRaises(SystemExit):
            parse_deselect_list(self.write_deselect(content))

    def test_rejects_entry_without_section_header(self) -> None:
        content = "tests/test_orphan.py::test_one\n"
        with self.assertRaises(SystemExit):
            parse_deselect_list(self.write_deselect(content))

    def test_empty_sections(self) -> None:
        content = """\
# Unsupported feature in documentdb-local today.

# Known product bug in documentdb-local today.

# Needs triage -- added by update-test-image workflow when a newly pinned image introduces failures.
# Categorize these as "Unsupported feature" or "Known product bug" before merging.
"""
        sections = parse_deselect_list(self.write_deselect(content))
        for section in ("unsupported_feature", "known_product_bug", "needs_triage"):
            self.assertEqual(sections[section], [])

    def test_missing_file_raises(self) -> None:
        with self.assertRaises(SystemExit):
            parse_deselect_list(Path("/nonexistent/deselect.list"))


class RenderDeselectListTests(unittest.TestCase):
    def test_round_trip_stability(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        original_path = Path(temp_dir.name) / "original.list"
        original_path.write_text(SAMPLE_DESELECT, encoding="utf-8")
        sections = parse_deselect_list(original_path)

        rendered = render_deselect_list(sections, "2026-01-01")
        round_trip_path = Path(temp_dir.name) / "round_trip.list"
        round_trip_path.write_text(rendered, encoding="utf-8")
        round_trip_sections = parse_deselect_list(round_trip_path)

        self.assertEqual(sections, round_trip_sections)

    def test_empty_needs_triage_uses_placeholder_header(self) -> None:
        sections = {
            "unsupported_feature": ["tests/a.py::test_a"],
            "known_product_bug": [],
            "needs_triage": [],
        }
        rendered = render_deselect_list(sections, "2026-04-01")
        self.assertIn("Needs triage -- added by update-test-image workflow when a newly pinned", rendered)

    def test_nonempty_needs_triage_uses_dated_header(self) -> None:
        sections = {
            "unsupported_feature": [],
            "known_product_bug": [],
            "needs_triage": ["tests/b.py::test_b"],
        }
        rendered = render_deselect_list(sections, "2026-04-13")
        self.assertIn("Needs triage -- added by update-test-image workflow on 2026-04-13", rendered)


class IntegrationTests(unittest.TestCase):
    """End-to-end: given a report and deselect list, verify updated output."""

    def make_report(self, failed: list[str], passed: list[str] | None = None) -> dict:
        if passed is None:
            passed = []
        tests = []
        for nodeid in passed:
            tests.append({"nodeid": nodeid, "outcome": "passed"})
        for nodeid in failed:
            tests.append({"nodeid": nodeid, "outcome": "failed"})

        total = len(tests)
        return {
            "exitcode": 1 if failed else 0,
            "summary": {
                "collected": total,
                "total": total,
                "passed": len(passed),
                "failed": len(failed),
            },
            "collectors": [{"nodeid": "", "outcome": "passed", "result": []}],
            "tests": tests,
        }

    def test_new_failures_added_to_needs_triage(self) -> None:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        deselect_path = Path(temp_dir.name) / "deselect.list"
        deselect_path.write_text(SAMPLE_DESELECT, encoding="utf-8")

        report_path = Path(temp_dir.name) / "report.json"
        report = self.make_report(
            failed=[
                "tests/test_unsupported.py::test_one",  # existing unsupported
                "tests/test_bug.py::test_two",           # existing bug
                "tests/test_new.py::test_new",           # new failure
            ],
            passed=["tests/test_triage.py::test_three"],  # previously triage, now passes
        )
        report_path.write_text(json.dumps(report), encoding="utf-8")

        failed = parse_report(report_path)
        sections = parse_deselect_list(deselect_path)

        # Simulate the update logic
        retained = {
            section: [n for n in sections[section] if n in failed]
            for section in ("unsupported_feature", "known_product_bug", "needs_triage")
        }
        existing = {n for vals in sections.values() for n in vals}
        new_failures = sorted(failed - existing)
        retained["needs_triage"].extend(new_failures)

        self.assertEqual(retained["unsupported_feature"], ["tests/test_unsupported.py::test_one"])
        self.assertEqual(retained["known_product_bug"], ["tests/test_bug.py::test_two"])
        self.assertIn("tests/test_new.py::test_new", retained["needs_triage"])
        self.assertNotIn("tests/test_triage.py::test_three", retained["needs_triage"])


if __name__ == "__main__":
    unittest.main()
