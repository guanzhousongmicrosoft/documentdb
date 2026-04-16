#!/usr/bin/env python3

from __future__ import annotations

import unittest

from generate_update_pr_body import render_pr_body


class RenderPrBodyTests(unittest.TestCase):
    def test_renders_summary_sections(self) -> None:
        summary = {
            "new_failures": ["tests/new_failure.py::test_new"],
            "removed": ["tests/fixed.py::test_fixed"],
            "counts": {"unchanged": 3},
        }

        body = render_pr_body(
            summary,
            "ghcr.io/documentdb/functional-tests@sha256:old",
            "ghcr.io/documentdb/functional-tests@sha256:new",
        )

        self.assertIn("## Test image update", body)
        self.assertIn("`ghcr.io/documentdb/functional-tests@sha256:new`", body)
        self.assertIn("`ghcr.io/documentdb/functional-tests@sha256:old`", body)
        self.assertIn("`tests/new_failure.py::test_new`", body)
        self.assertIn("`tests/fixed.py::test_fixed`", body)
        self.assertIn("- 3 existing deselections remain unchanged", body)

    def test_truncates_long_lists(self) -> None:
        summary = {
            "new_failures": [f"tests/new_{index}.py::test_case" for index in range(25)],
            "removed": [],
            "counts": {"unchanged": 0},
        }

        body = render_pr_body(summary, "old", "new")

        self.assertIn("- ... and 5 more", body)
        self.assertIn("- No deselections were removed.", body)


if __name__ == "__main__":
    unittest.main()
