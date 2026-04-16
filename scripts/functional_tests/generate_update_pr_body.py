#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

DISPLAY_LIMIT = 20


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate the pull request body for the update-test-image workflow."
    )
    parser.add_argument("--summary-json", required=True, type=Path)
    parser.add_argument("--current-image", required=True)
    parser.add_argument("--latest-image", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def render_list(items: list[str], empty_message: str, limit: int = DISPLAY_LIMIT) -> list[str]:
    if not items:
        return [f"- {empty_message}"]

    lines = [f"- `{item}`" for item in items[:limit]]
    if len(items) > limit:
        lines.append(f"- ... and {len(items) - limit} more")
    return lines


def render_pr_body(summary: dict, current_image: str, latest_image: str) -> str:
    new_failures = summary["new_failures"]
    removed = summary["removed"]
    unchanged_count = summary["counts"]["unchanged"]

    lines = [
        "## Test image update",
        "",
        f"**New image:** `{latest_image}`",
        f"**Previous image:** `{current_image}`",
        "",
        "### Deselect list changes",
        f"- {len(new_failures)} new failures added to `Needs triage`",
    ]
    lines.extend(render_list(new_failures, "No new failures were added."))
    lines.append(f"- {len(removed)} previously deselected tests now pass and were removed")
    lines.extend(render_list(removed, "No deselections were removed."))
    lines.append(f"- {unchanged_count} existing deselections remain unchanged")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    summary = json.loads(args.summary_json.read_text(encoding="utf-8"))
    args.output.write_text(
        render_pr_body(summary, args.current_image, args.latest_image),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
