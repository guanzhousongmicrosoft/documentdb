#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

from report_utils import ReportValidationError, load_and_validate_report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a pytest JSON report before consuming it in CI automation."
    )
    parser.add_argument("--report", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        parsed = load_and_validate_report(args.report)
    except ReportValidationError as exc:
        raise SystemExit(f"Invalid functional test report {args.report}: {exc}") from exc

    print(
        f"Validated functional test report: {parsed.counts['total']} tests, {parsed.counts['failed']} failed."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
