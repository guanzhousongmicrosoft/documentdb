"""Tests that a failed `reconcile` leaves the baselines exactly as it found them.

Reconcile rewrites the file it reads, and it is deliberately non-idempotent:
under strict xfail a listed test that passes is reported as ``failed``, so a
second application swaps the added and removed sets. The duplicate-report guard
exists to stop that, and it works by recording a provenance marker in the list.

Those two facts make a partial write uniquely bad. If the strict list is written
before every output has been validated, a command that then exits non-zero has
already rewritten the baseline AND stamped the marker, so the obvious retry is
refused and the only documented way forward is --force -- which performs exactly
the corrupting second application the marker was added to prevent. Every failure
path must therefore leave both lists byte-for-byte unchanged.
"""

import json
import os
import stat
import subprocess
import sys

import pytest

HERE = os.path.dirname(__file__)
TOOL = os.path.join(HERE, "..", "tools", "functional_gate.py")
PREFIX = "docdb_functional_tests/documentdb_tests/"


def _report(tmp_path, name, tests):
    p = tmp_path / name
    p.write_text(json.dumps({"tests": [
        {"nodeid": PREFIX + nid, "outcome": oc, "call": {"longrepr": detail}}
        for nid, oc, detail in tests]}))
    return str(p)


def _list(tmp_path, name, lines):
    p = tmp_path / name
    p.write_text("\n".join(lines) + "\n")
    return str(p)


def _disagreeing_runs(tmp_path):
    """Two runs where one test disagrees, so a demotion to flaky is required."""
    r1 = _report(tmp_path, "r1.json", [
        ("a.py::t_flaky", "failed", "AssertionError"),
        ("b.py::t_always", "failed", "AssertionError"),
    ])
    r2 = _report(tmp_path, "r2.json", [
        ("a.py::t_flaky", "passed", ""),
        ("b.py::t_always", "failed", "AssertionError"),
    ])
    return r1, r2


def _run(args):
    return subprocess.run([sys.executable, TOOL, "reconcile"] + args,
                          capture_output=True, text=True)


class TestFailedReconcileLeavesInputsUntouched:
    def test_missing_flaky_option_does_not_touch_the_strict_list(self, tmp_path):
        r1, r2 = _disagreeing_runs(tmp_path)
        failing = _list(tmp_path, "failing.txt", ["# known failures"])
        before = open(failing).read()

        proc = _run(["--report", r1, "--report", r2, "--failing", failing])

        assert proc.returncode != 0
        assert "--flaky was not given" in (proc.stderr + proc.stdout)
        assert open(failing).read() == before, \
            "a refused reconcile must not rewrite the baseline"
        assert "reconciled-from-report" not in open(failing).read(), \
            "a refused reconcile must not stamp the duplicate-report marker"

    def test_the_corrected_retry_then_succeeds(self, tmp_path):
        # The point of leaving the inputs alone: adding the missing option is
        # enough to recover, with no --force and no re-run of the suite.
        r1, r2 = _disagreeing_runs(tmp_path)
        failing = _list(tmp_path, "failing.txt", ["# known failures"])
        flaky = _list(tmp_path, "flaky.txt", ["# none"])

        assert _run(["--report", r1, "--report", r2, "--failing", failing]).returncode != 0
        proc = _run(["--report", r1, "--report", r2,
                     "--failing", failing, "--flaky", flaky])

        assert proc.returncode == 0, proc.stderr
        assert "b.py::t_always" in open(failing).read()
        assert "a.py::t_flaky" in open(flaky).read()

    def test_unreadable_flaky_path_does_not_touch_the_strict_list(self, tmp_path):
        r1, r2 = _disagreeing_runs(tmp_path)
        failing = _list(tmp_path, "failing.txt", ["# known failures"])
        before = open(failing).read()
        missing_flaky = str(tmp_path / "no-such-dir" / "flaky.txt")

        proc = _run(["--report", r1, "--report", r2,
                     "--failing", failing, "--flaky", missing_flaky])

        assert proc.returncode != 0
        assert open(failing).read() == before

    def test_unwritable_summary_json_does_not_touch_the_lists(self, tmp_path):
        # Reachable even in single-report mode, where no demotion is involved.
        report = _report(tmp_path, "r.json", [("b.py::t_new", "failed", "AssertionError")])
        failing = _list(tmp_path, "failing.txt", ["# known failures"])
        flaky = _list(tmp_path, "flaky.txt", ["# none"])
        before_failing, before_flaky = open(failing).read(), open(flaky).read()

        proc = _run(["--report", report, "--failing", failing, "--flaky", flaky,
                     "--summary-json", str(tmp_path / "no-such-dir" / "s.json")])

        assert proc.returncode != 0
        assert open(failing).read() == before_failing
        assert open(flaky).read() == before_flaky

    def test_a_valid_single_report_run_still_writes(self, tmp_path):
        # Guard against the validation refusing everything.
        report = _report(tmp_path, "r.json", [("b.py::t_new", "failed", "AssertionError")])
        failing = _list(tmp_path, "failing.txt", ["# known failures"])
        summary = str(tmp_path / "s.json")

        proc = _run(["--report", report, "--failing", failing, "--summary-json", summary])

        assert proc.returncode == 0, proc.stderr
        assert "b.py::t_new" in open(failing).read()
        assert json.load(open(summary))["added"] == ["b.py::t_new"]


class TestWriteThroughDoesNotChangeTheDestination:
    """Staging through a temp file must not alter what the destination IS.

    Replacing a path is not the same as writing to it: a rename cannot target a
    character device, and it carries the temp file's own permissions rather than
    the destination's.
    """

    @pytest.mark.skipif(sys.platform == "win32", reason="POSIX device node")
    def test_out_devnull_is_written_through(self, tmp_path):
        # `--out /dev/null` is the "classify, but keep the list" idiom.
        report = _report(tmp_path, "r.json", [("b.py::t_new", "failed", "AssertionError")])
        failing = _list(tmp_path, "failing.txt", ["# known failures"])
        before = open(failing).read()

        proc = _run(["--report", report, "--failing", failing, "--out", os.devnull])

        assert proc.returncode == 0, proc.stderr
        assert open(failing).read() == before

    @pytest.mark.skipif(sys.platform == "win32", reason="POSIX file modes")
    def test_existing_permissions_survive(self, tmp_path):
        report = _report(tmp_path, "r.json", [("b.py::t_new", "failed", "AssertionError")])
        failing = _list(tmp_path, "failing.txt", ["# known failures"])
        os.chmod(failing, 0o644)

        proc = _run(["--report", report, "--failing", failing])

        assert proc.returncode == 0, proc.stderr
        assert stat.S_IMODE(os.stat(failing).st_mode) == 0o644, \
            "a reconcile must not turn a shared baseline into an owner-only file"
