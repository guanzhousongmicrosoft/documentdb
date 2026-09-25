"""Exercise the checked-in OSS baselines with the real pytest plugin."""

import shutil
from pathlib import Path

import pytest

pytest_plugins = ["pytester"]

FUNCTIONAL_TESTS = Path(__file__).resolve().parent.parent
CURRENT_OP_TEST = (
    "docdb_functional_tests/documentdb_tests/compatibility/tests/core/operator/"
    "system-stages/currentOp/test_system_stage_currentOp_live_state.py"
)


@pytest.mark.parametrize(
    ("body", "exit_code", "outcomes"),
    [
        ("assert False", pytest.ExitCode.OK, {"xfailed": 1}),
        ("pass", pytest.ExitCode.TESTS_FAILED, {"failed": 1}),
    ],
)
def test_oss_baselines_load_with_strict_current_op(pytester, body, exit_code, outcomes):
    shutil.copyfile(
        FUNCTIONAL_TESTS / "tools/conftest_known_failures.py",
        pytester.path / "conftest.py",
    )
    for source, target in (
        ("oss_ci_failing_tests.txt", "ci_failing_tests.txt"),
        ("oss_ci_flaky_tests.txt", "ci_flaky_tests.txt"),
        ("ci_crash_tests.txt", "ci_crash_tests.txt"),
    ):
        shutil.copyfile(FUNCTIONAL_TESTS / "config" / source, pytester.path / target)

    test_path = pytester.path / CURRENT_OP_TEST
    test_path.parent.mkdir(parents=True)
    test_path.write_text(
        "import pytest\n\n"
        '@pytest.mark.parametrize("state", ["documentdb-inactive_op_document_fields"])\n'
        "def test_currentOp_live_state(state):\n"
        f"    {body}\n",
        encoding="utf-8",
    )

    result = pytester.runpytest_subprocess("-q")
    assert result.ret == exit_code
    result.assert_outcomes(**outcomes)
    if exit_code == pytest.ExitCode.TESTS_FAILED:
        assert "[XPASS(strict)] Known failure" in result.stdout.str()
