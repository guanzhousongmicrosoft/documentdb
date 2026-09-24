"""Contract tests for the release workflow's publishing guards and draft step."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


WORKFLOWS = Path(__file__).resolve().parents[1]
RELEASE_WORKFLOW = WORKFLOWS / "documentdb_release.yml"
GATEWAY_WORKFLOW = WORKFLOWS / "build_gateway.yml"
RELEASE_STEP = "Create or update draft GitHub Release"
REPOSITORY = "documentdb/documentdb"
TAG = "v0.117-0"
TARGET = "0123456789abcdef0123456789abcdef01234567"

_TOKEN = re.compile(r"\s*(\|\||&&|==|!=|!|\(|\)|,|'(?:[^']|'')*'|[A-Za-z_][\w.\-]*)")


def evaluate(expression: str, context: dict[str, object]) -> object:
    """Evaluate the subset of GitHub expression syntax these guards use.

    Evaluating the real YAML strings (rather than restating the policy in
    Python) is what lets these tests catch a guard that drifts.
    """
    expression = expression.strip()
    if expression.startswith("${{") and expression.endswith("}}"):
        expression = expression[3:-2]
    tokens, pos = [], 0
    while pos < len(expression.rstrip()):
        match = _TOKEN.match(expression, pos)
        if not match:
            raise ValueError(f"cannot tokenize {expression[pos:]!r}")
        tokens.append(match.group(1))
        pos = match.end()

    def take(expected: str | None = None) -> str:
        token = tokens.pop(0)
        if expected is not None and token != expected:
            raise ValueError(f"expected {expected!r}, got {token!r}")
        return token

    # && and || return an operand, not a bool, exactly as GitHub does.
    def parse_or() -> object:
        value = parse_and()
        while tokens and tokens[0] == "||":
            take()
            right = parse_and()
            value = value if value else right
        return value

    def parse_and() -> object:
        value = parse_unary()
        while tokens and tokens[0] == "&&":
            take()
            right = parse_unary()
            value = right if value else value
        return value

    def parse_unary() -> object:
        if tokens[0] == "!":
            take()
            return not parse_unary()
        left = parse_primary()
        if tokens and tokens[0] in ("==", "!="):
            op = take()
            right = parse_primary()
            return (left == right) if op == "==" else (left != right)
        return left

    def parse_primary() -> object:
        token = take()
        if token == "(":
            value = parse_or()
            take(")")
            return value
        if token.startswith("'"):
            return token[1:-1].replace("''", "'")
        if token in ("true", "false"):
            return token == "true"
        if token == "startsWith":
            take("(")
            haystack = parse_or()
            take(",")
            needle = parse_or()
            take(")")
            return str(haystack or "").lower().startswith(str(needle).lower())
        if token not in context:
            raise KeyError(f"unknown expression context {token!r}")
        return context[token]

    value = parse_or()
    if tokens:
        raise ValueError(f"trailing tokens {tokens!r}")
    return value


def github_context(event_name: str, ref: str, **inputs: object) -> dict[str, object]:
    context: dict[str, object] = {
        "github.event_name": event_name,
        "github.ref": ref,
        "github.ref_type": "tag" if ref.startswith("refs/tags/") else "branch",
    }
    # A push event has an empty inputs context, so every input reads as null.
    for name in ("create_release", "push_images"):
        context[f"inputs.{name}"] = inputs.get(name)
    return context


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def workflow_step(name: str) -> dict[str, object]:
    steps = load(RELEASE_WORKFLOW)["jobs"]["create-release"]["steps"]
    matches = [step for step in steps if step.get("name") == name]
    if not matches:
        raise AssertionError(f"create-release has no step named {name!r}")
    return matches[0]


def gateway_push_gates() -> list[str]:
    jobs = load(GATEWAY_WORKFLOW)["jobs"]
    gates = [
        step["if"]
        for step in jobs["build-and-push"]["steps"]
        if step.get("name", "").startswith("Push ")
    ]
    gates += [jobs["create-manifest"]["if"], jobs["create-manifest-latest"]["if"]]
    return gates


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


class SideEffectPolicyTests(unittest.TestCase):
    # (event, ref, create_release, expected to publish images and a release)
    RELEASE_CASES = (
        ("workflow_dispatch", "refs/heads/main", False, False),
        ("workflow_dispatch", f"refs/tags/{TAG}", False, False),
        ("workflow_dispatch", "refs/heads/main", True, True),
        ("workflow_dispatch", f"refs/tags/{TAG}", True, True),
        ("push", f"refs/tags/{TAG}", None, True),
    )

    def test_release_publishes_only_for_tag_push_or_confirmed_manual_release(self):
        jobs = load(RELEASE_WORKFLOW)["jobs"]
        push_images = jobs["build-gateway-images"]["with"]["push_images"]
        create_release_if = jobs["create-release"]["if"]
        gates = gateway_push_gates()
        self.assertEqual(len(gates), 3)

        for event_name, ref, create_release, expected in self.RELEASE_CASES:
            context = github_context(event_name, ref, create_release=create_release)
            with self.subTest(event=event_name, ref=ref, create_release=create_release):
                pushed = bool(evaluate(push_images, context))
                self.assertEqual(pushed, expected, "push_images passed to build_gateway")
                self.assertEqual(bool(evaluate(create_release_if, context)), expected,
                                 "create-release job condition")
                # build_gateway sees the caller's github context plus our input.
                called = github_context(event_name, ref, push_images=pushed)
                for gate in gates:
                    self.assertEqual(bool(evaluate(gate, called)), expected,
                                     f"build_gateway gate {gate!r}")

    def test_standalone_gateway_run_publishes_only_when_asked(self):
        cases = (
            ("workflow_dispatch", f"refs/tags/{TAG}", False, False),
            ("workflow_dispatch", "refs/heads/main", False, False),
            ("workflow_dispatch", f"refs/tags/{TAG}", True, True),
            ("push", "refs/heads/main", None, False),
        )
        for event_name, ref, push_images, expected in cases:
            context = github_context(event_name, ref, push_images=push_images)
            with self.subTest(event=event_name, ref=ref, push_images=push_images):
                for gate in gateway_push_gates():
                    self.assertEqual(bool(evaluate(gate, context)), expected, gate)

    def test_missing_tag_is_allowed_only_for_a_manual_branch_release(self):
        expression = workflow_step(RELEASE_STEP)["env"]["ALLOW_MISSING_RELEASE_TAG"]
        cases = (
            ("workflow_dispatch", "refs/heads/main", True, True),
            ("workflow_dispatch", f"refs/tags/{TAG}", True, False),
            ("workflow_dispatch", "refs/heads/main", False, False),
            ("push", f"refs/tags/{TAG}", None, False),
        )
        for event_name, ref, create_release, expected in cases:
            context = github_context(event_name, ref, create_release=create_release)
            with self.subTest(event=event_name, ref=ref, create_release=create_release):
                self.assertIs(evaluate(expression, context), expected)

    def test_release_uses_no_third_party_actions(self):
        # The documentdb org policy blocks third-party actions such as
        # softprops/action-gh-release, which left the release job unable to run.
        for step in load(RELEASE_WORKFLOW)["jobs"]["create-release"]["steps"]:
            uses = step.get("uses")
            if uses:
                self.assertTrue(uses.startswith(("actions/", "./")), uses)


class DraftReleaseStepTests(unittest.TestCase):
    def run_release_step(
        self,
        scenario: str,
        *,
        allow_missing_tag: bool = False,
        bundle: bool = True,
        debug_zip: bool = True,
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
        script = workflow_step(RELEASE_STEP)["run"]

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "bundle").mkdir()
            if bundle:
                (root / "bundle" / "documentdb.deb").write_text("package")
                (root / "bundle" / "SHA256SUMS").write_text("checksums")
            if debug_zip:
                (root / "documentdb-debug-symbols-0.117.0.zip").write_text("zip")
            (root / "changelog_excerpt.md").write_text("release notes")

            bin_path = root / "bin"
            bin_path.mkdir()
            write_executable(
                bin_path / "gh",
                """#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["MOCK_GH_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\\n")

scenario = os.environ["MOCK_SCENARIO"]
if args[:1] == ["api"]:
    endpoint = args[1]
    if "/releases/tags/" in endpoint:
        if scenario in (
            "new-draft",
            "new-draft-wrong-tag",
            "manual-new-draft-no-tag",
            "tag-trigger-missing-tag",
        ):
            print("gh: Not Found (HTTP 404)", file=sys.stderr)
            raise SystemExit(1)
        if scenario == "auth-error":
            print("gh: Resource not accessible by integration (HTTP 403)",
                  file=sys.stderr)
            raise SystemExit(1)
        draft = "false" if scenario == "published" else "true"
        print(f"{draft}\\t{os.environ['MOCK_TAG']}")
        raise SystemExit(0)
    if "/git/ref/tags/" in endpoint:
        if scenario in (
            "manual-new-draft-no-tag",
            "manual-existing-draft-no-tag",
            "tag-trigger-missing-tag",
        ):
            print("gh: Not Found (HTTP 404)", file=sys.stderr)
            raise SystemExit(1)
        if scenario == "tag-api-error":
            print("gh: API unavailable (HTTP 500)", file=sys.stderr)
            raise SystemExit(1)
        print(f"refs/tags/{os.environ['MOCK_TAG']}")
        raise SystemExit(0)
    if "/commits/refs/tags/" in endpoint:
        if scenario == "commit-resolution-error":
            print("gh: No commit found for SHA (HTTP 422)", file=sys.stderr)
            raise SystemExit(1)
        target = (
            "ffffffffffffffffffffffffffffffffffffffff"
            if scenario in ("target-mismatch", "new-draft-wrong-tag")
            else os.environ["EXPECTED_TARGET"]
        )
        print(target)
        raise SystemExit(0)
    print(f"unexpected API endpoint: {endpoint}", file=sys.stderr)
    raise SystemExit(64)

if args[:2] == ["release", "upload"] and scenario == "upload-failure":
    print("mock upload failed", file=sys.stderr)
    raise SystemExit(1)
if args[:2] in (
    ["release", "create"],
    ["release", "edit"],
    ["release", "upload"],
):
    raise SystemExit(0)

print(f"unexpected gh arguments: {args!r}", file=sys.stderr)
raise SystemExit(64)
""",
            )

            log_path = root / "gh.log"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_path}{os.pathsep}{env['PATH']}",
                    "VERSION_DASH": "0.117-0",
                    "RELEASE_NAME": "v0.117-0 (September 9, 2026)",
                    "RELEASE_REPOSITORY": REPOSITORY,
                    "RELEASE_TARGET": TARGET,
                    "ALLOW_MISSING_RELEASE_TAG": "true" if allow_missing_tag else "false",
                    "MOCK_SCENARIO": scenario,
                    "MOCK_GH_LOG": str(log_path),
                    "MOCK_TAG": TAG,
                    "EXPECTED_TARGET": TARGET,
                }
            )
            result = subprocess.run(
                ["bash", "-c", script],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
            )
            calls = (
                [json.loads(line) for line in log_path.read_text().splitlines()]
                if log_path.exists()
                else []
            )
            return result, calls

    @staticmethod
    def release_calls(calls: list[list[str]], command: str) -> list[list[str]]:
        return [call for call in calls if call[:2] == ["release", command]]

    def assert_no_mutation(self, calls: list[list[str]]) -> None:
        for command in ("create", "edit", "upload"):
            self.assertEqual(self.release_calls(calls, command), [], command)

    def test_existing_draft_is_updated_and_assets_are_reuploaded(self):
        result, calls = self.run_release_step("existing-draft")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.release_calls(calls, "create"), [])
        edits = self.release_calls(calls, "edit")
        self.assertEqual(len(edits), 1)
        self.assertIn("--draft", edits[0])
        self.assertIn("--prerelease", edits[0])
        self.assertIn("--verify-tag", edits[0])
        self.assertEqual(edits[0][edits[0].index("--target") + 1], TARGET)
        self.assertEqual(edits[0][edits[0].index("-R") + 1], REPOSITORY)
        self.assertIn(["api", f"repos/{REPOSITORY}/git/ref/tags/{TAG}", "--jq", ".ref"], calls)
        self.assertIn(["api", f"repos/{REPOSITORY}/commits/refs/tags/{TAG}", "--jq", ".sha"], calls)

        uploads = self.release_calls(calls, "upload")
        self.assertEqual(len(uploads), 1)
        self.assertIn("./bundle/documentdb.deb", uploads[0])
        self.assertIn("./bundle/SHA256SUMS", uploads[0])
        self.assertIn("./documentdb-debug-symbols-0.117.0.zip", uploads[0])
        self.assertIn("--clobber", uploads[0])

    def test_missing_release_creates_a_draft_at_the_exact_target(self):
        result, calls = self.run_release_step("new-draft")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        creates = self.release_calls(calls, "create")
        self.assertEqual(len(creates), 1)
        self.assertIn("--draft", creates[0])
        self.assertIn("--prerelease", creates[0])
        self.assertIn("--verify-tag", creates[0])
        self.assertEqual(creates[0][creates[0].index("--target") + 1], TARGET)
        self.assertEqual(creates[0][creates[0].index("-R") + 1], REPOSITORY)
        self.assertEqual(len(self.release_calls(calls, "upload")), 1)

    def test_missing_debug_symbols_zip_is_optional(self):
        # The debug-symbol artifact is not produced yet, so this is the normal path.
        result, calls = self.run_release_step("new-draft", debug_zip=False)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        uploads = self.release_calls(calls, "upload")
        self.assertEqual(len(uploads), 1)
        assets = [arg for arg in uploads[0] if arg.startswith("./")]
        self.assertEqual(sorted(assets), ["./bundle/SHA256SUMS", "./bundle/documentdb.deb"])

    def test_empty_bundle_is_refused_before_any_api_call(self):
        result, calls = self.run_release_step("new-draft", bundle=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundle is empty", result.stdout + result.stderr)
        self.assertEqual(calls, [])

    def test_published_release_is_never_changed_back_to_draft(self):
        result, calls = self.run_release_step("published")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stdout + result.stderr)
        self.assert_no_mutation(calls)

    def test_api_error_is_not_treated_as_release_not_found(self):
        result, calls = self.run_release_step("auth-error")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "refusing to treat an API or authentication error as a missing release",
            result.stdout + result.stderr,
        )
        self.assert_no_mutation(calls)

    def test_existing_tag_must_target_the_release_commit(self):
        result, calls = self.run_release_step("target-mismatch")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to create, update, or retarget the release",
                      result.stdout + result.stderr)
        self.assert_no_mutation(calls)

    def test_missing_release_with_wrong_tag_target_does_not_create(self):
        result, calls = self.run_release_step("new-draft-wrong-tag")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to create, update, or retarget the release",
                      result.stdout + result.stderr)
        self.assert_no_mutation(calls)

    def test_manual_branch_release_can_prepare_draft_before_tag_exists(self):
        result, calls = self.run_release_step("manual-new-draft-no-tag", allow_missing_tag=True)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        creates = self.release_calls(calls, "create")
        self.assertEqual(len(creates), 1)
        self.assertNotIn("--verify-tag", creates[0])
        self.assertEqual(creates[0][creates[0].index("--target") + 1], TARGET)
        self.assertEqual(len(self.release_calls(calls, "upload")), 1)

    def test_manual_branch_can_update_untagged_draft_metadata(self):
        result, calls = self.run_release_step("manual-existing-draft-no-tag", allow_missing_tag=True)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        edits = self.release_calls(calls, "edit")
        self.assertEqual(len(edits), 1)
        self.assertNotIn("--verify-tag", edits[0])
        self.assertEqual(edits[0][edits[0].index("--target") + 1], TARGET)
        self.assertEqual(self.release_calls(calls, "create"), [])
        self.assertEqual(len(self.release_calls(calls, "upload")), 1)

    def test_tag_trigger_with_deleted_tag_does_not_recreate_it(self):
        result, calls = self.run_release_step("tag-trigger-missing-tag")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Required remote tag", result.stdout + result.stderr)
        self.assert_no_mutation(calls)

    def test_tag_lookup_api_error_is_not_treated_as_missing(self):
        result, calls = self.run_release_step("tag-api-error")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "refusing to treat an API or authentication error as a missing tag",
            result.stdout + result.stderr,
        )
        self.assert_no_mutation(calls)

    def test_commit_resolution_error_does_not_allow_an_untagged_draft(self):
        result, calls = self.run_release_step("commit-resolution-error", allow_missing_tag=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to resolve the commit for remote tag", result.stdout + result.stderr)
        self.assert_no_mutation(calls)

    def test_asset_upload_failure_fails_the_release_job(self):
        result, calls = self.run_release_step("upload-failure")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to upload the verified release assets", result.stdout + result.stderr)
        self.assertEqual(len(self.release_calls(calls, "edit")), 1)
        self.assertEqual(len(self.release_calls(calls, "upload")), 1)


if __name__ == "__main__":
    unittest.main()
