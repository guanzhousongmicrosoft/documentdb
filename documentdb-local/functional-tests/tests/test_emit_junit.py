"""Tests for `emit-junit` — the gate's verdict rendered for the results view.

Publishing pytest's own JUnit is what forced `failTaskOnFailedTests: false` onto
the functional lanes. That file is the MAIN pass, frozen before recover-and-gate
rewrites report.json, so it disagrees with the verdict in both directions:

  over-reports   a transient crash victim the sequential re-run rescued still
                 reads `failed`, so a green build shows red tests;
  under-reports  a test lost with a dying xdist worker is simply ABSENT, so the
                 view looks clean on exactly the id the gate fails the build for.

Suppressing the first hid the second. These tests pin the mapping so the
published document and the build status stay the same statement.
"""

import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(__file__)
TOOL = os.path.join(HERE, "..", "tools", "functional_gate.py")
sys.path.insert(0, os.path.join(HERE, "..", "tools"))

from functional_gate import render_gate_junit  # noqa: E402

PREFIX = "docdb_functional_tests/documentdb_tests/"


def _report(tmp_path, tests, name="report.json"):
    path = tmp_path / name
    payload = {"tests": []}
    for entry in tests:
        nid, outcome = entry[0], entry[1]
        detail = entry[2] if len(entry) > 2 else ""
        record = {"nodeid": PREFIX + nid, "outcome": outcome,
                  "duration": 0.5, "call": {"longrepr": detail}}
        if len(entry) > 3 and entry[3]:
            record["_docdb_recovered_pass"] = entry[3]
        payload["tests"].append(record)
    path.write_text(json.dumps(payload))
    return str(path)


def _list(tmp_path, name, entries):
    path = tmp_path / name
    path.write_text("\n".join(entries) + "\n")
    return str(path)


def _cases(xml_bytes):
    root = ET.fromstring(xml_bytes)
    out = {}
    for case in root.iter("testcase"):
        kind = "passed"
        message = ""
        if case.find("failure") is not None:
            kind, message = "failed", case.find("failure").get("message", "")
        elif case.find("skipped") is not None:
            kind, message = "skipped", case.find("skipped").get("message", "")
        sysout = case.find("system-out")
        out[f"{case.get('classname')}::{case.get('name')}"] = (
            kind, message, sysout.text if sysout is not None else "")
    return out


class TestVerdictMapping:
    def test_expected_failure_is_skipped_not_failed(self, tmp_path):
        report = _report(tmp_path, [("compatibility/tests/a.py::t_known", "xfailed")])
        failing = _list(tmp_path, "failing.txt", ["compatibility/tests/a.py::t_known"])
        xml, counts = render_gate_junit(report, failing_path=failing)
        kind, message, _ = list(_cases(xml).values())[0]
        assert kind == "skipped"
        assert "strict xfail" in message and "failing.txt" in message
        assert counts["failures"] == 0

    def test_residual_failure_is_a_failure(self, tmp_path):
        report = _report(tmp_path, [
            ("compatibility/tests/b.py::t_broken", "failed", "AssertionError: boom"),
        ])
        xml, counts = render_gate_junit(report)
        kind, message, _ = list(_cases(xml).values())[0]
        assert kind == "failed"
        assert "boom" in message
        assert counts["failures"] == 1

    def test_xpass_strict_names_the_remediation(self, tmp_path):
        # The reader cannot reconstruct this from the outcome word alone: the
        # test PASSED, and it is reported as failed only because it is listed.
        report = _report(tmp_path, [
            ("compatibility/tests/c.py::t_fixed", "failed", "[XPASS(strict)] ..."),
        ])
        failing = _list(tmp_path, "failing.txt", ["compatibility/tests/c.py::t_fixed"])
        xml, _ = render_gate_junit(report, failing_path=failing)
        kind, message, _ = list(_cases(xml).values())[0]
        assert kind == "failed"
        assert "XPASS(strict)" in message and "remove the entry" in message.lower()

    def test_flaky_entry_is_skipped_either_way(self, tmp_path):
        report = _report(tmp_path, [
            ("compatibility/tests/d.py::t_flaky", "xfailed"),
            ("compatibility/tests/d.py::t_flaky2", "xpassed"),
        ])
        flaky = _list(tmp_path, "flaky.txt", [
            "compatibility/tests/d.py::t_flaky", "compatibility/tests/d.py::t_flaky2"])
        xml, counts = render_gate_junit(report, flaky_path=flaky)
        assert counts["failures"] == 0
        assert all(k == "skipped" for k, _, _ in _cases(xml).values())

    def test_crash_listed_test_says_why_it_never_ran(self, tmp_path):
        report = _report(tmp_path, [("compatibility/tests/e.py::t_crasher", "skipped")])
        crash = _list(tmp_path, "crash.txt", ["compatibility/tests/e.py::t_crasher"])
        xml, _ = render_gate_junit(report, crash_path=crash)
        kind, message, _ = list(_cases(xml).values())[0]
        assert kind == "skipped"
        assert "cascades" in message

    def test_unknown_outcome_fails_rather_than_passing_silently(self, tmp_path):
        report = _report(tmp_path, [("compatibility/tests/f.py::t", "banana")])
        xml, counts = render_gate_junit(report)
        assert counts["failures"] == 1
        assert "banana" in list(_cases(xml).values())[0][1]


class TestTheTwoDisagreementsWithTheMainPass:
    """The exact cases pytest's own JUnit gets wrong."""

    def test_recovered_victim_is_a_pass_with_evidence(self, tmp_path):
        # over-reporting: results.xml still shows this failed.
        report = _report(tmp_path, [
            ("compatibility/tests/g.py::t_victim", "passed", "", 2),
        ])
        xml, counts = render_gate_junit(report)
        kind, _, sysout = list(_cases(xml).values())[0]
        assert kind == "passed"
        assert counts["recovered"] == 1
        assert "re-run 2" in sysout, "a recovered test must say it needed a retry"

    def test_assigned_but_unrecorded_test_is_a_failure(self, tmp_path):
        # under-reporting: results.xml has no row at all for this id, so the
        # view reads clean while the gate reds the build.
        report = _report(tmp_path, [("compatibility/tests/h.py::t_ran", "passed")])
        xml, counts = render_gate_junit(report, expected_ids=[
            "compatibility/tests/h.py::t_ran",
            "compatibility/tests/h.py::t_vanished",
        ])
        cases = _cases(xml)
        vanished = [v for k, v in cases.items() if "t_vanished" in k]
        assert len(vanished) == 1
        assert vanished[0][0] == "failed"
        assert "no outcome recorded" in vanished[0][1]
        assert counts["failures"] == 1


class TestRobustness:
    def test_control_bytes_in_a_longrepr_do_not_corrupt_the_document(self, tmp_path):
        # A crashed backend can quote raw bytes. Serialising them yields a
        # document the results parser rejects, losing the whole report.
        report = _report(tmp_path, [
            ("compatibility/tests/i.py::t", "failed", "boom \x00\x08 <&> end"),
        ])
        xml, _ = render_gate_junit(report)
        root = ET.fromstring(xml)          # must parse
        assert root.tag == "testsuites"

    def test_counts_are_consistent_with_the_cases(self, tmp_path):
        report = _report(tmp_path, [
            ("compatibility/tests/j.py::t_pass", "passed"),
            ("compatibility/tests/j.py::t_known", "xfailed"),
            ("compatibility/tests/j.py::t_bad", "failed", "err"),
        ])
        failing = _list(tmp_path, "failing.txt", ["compatibility/tests/j.py::t_known"])
        xml, counts = render_gate_junit(report, failing_path=failing)
        suite = ET.fromstring(xml).find("testsuite")
        assert suite.get("tests") == "3"
        assert suite.get("failures") == "1"
        assert suite.get("skipped") == "1"
        assert counts["passed"] == 1


class TestCli:
    def test_cli_writes_the_file_and_never_fails_the_build(self, tmp_path):
        report = _report(tmp_path, [("compatibility/tests/k.py::t", "failed", "err")])
        out = str(tmp_path / "gate-results.xml")
        proc = subprocess.run(
            [sys.executable, TOOL, "emit-junit", "--report", report, "--out", out],
            capture_output=True, text=True)
        # Reporting must not decide the verdict: recover-and-gate already did.
        assert proc.returncode == 0, proc.stderr
        assert os.path.exists(out)
        assert "1 failed" in proc.stdout

    def test_an_unreadable_report_does_not_red_a_passing_gate(self, tmp_path):
        proc = subprocess.run(
            [sys.executable, TOOL, "emit-junit",
             "--report", str(tmp_path / "missing.json"),
             "--out", str(tmp_path / "out.xml")],
            capture_output=True, text=True)
        assert proc.returncode == 0
        assert "could not render" in proc.stdout


class TestRecoveryReachesTheReport:
    """The recovery tag has to survive recover-and-gate, or the note never appears.

    This is the link that makes the retry visible instead of silent: without the
    tag a rescued crash victim is indistinguishable from a test that passed
    first time, and an engine crashing more often reads as a clean run.
    """

    def _rerun_stub(self, tmp_path):
        # Stands in for the serial pytest re-run: reports every requested id as
        # passing, which is exactly what a transient crash victim does.
        stub = tmp_path / "rerun_stub.py"
        stub.write_text(
            "import json, sys\n"
            "out, ids = None, []\n"
            "for a in sys.argv[1:]:\n"
            "    if a.startswith('--json-report-file='):\n"
            "        out = a.split('=', 1)[1]\n"
            "    elif a.startswith('@'):\n"
            "        ids = [l.strip() for l in open(a[1:]) if l.strip()]\n"
            "json.dump({'tests': [{'nodeid': i, 'outcome': 'passed',\n"
            "                      'duration': 0.1, 'call': {'longrepr': ''}}\n"
            "                     for i in ids]}, open(out, 'w'))\n")
        return str(stub)

    def test_a_recovered_test_is_tagged_and_shows_the_note(self, tmp_path):
        report = _report(tmp_path, [
            ("compatibility/tests/v.py::t_victim", "failed", "ConnectionError: server closed"),
            ("compatibility/tests/v.py::t_ok", "passed"),
        ])
        proc = subprocess.run([
            sys.executable, TOOL, "recover-and-gate",
            "--report", report, "--strip-prefix", PREFIX, "--prefix", PREFIX,
            "--workdir", str(tmp_path), "--settle-seconds", "0",
            "--output", str(tmp_path / "gate-failures.txt"),
            "--", sys.executable, self._rerun_stub(tmp_path),
        ], capture_output=True, text=True)

        assert proc.returncode == 0, f"the victim should have been recovered:\n{proc.stdout}\n{proc.stderr}"
        merged = json.load(open(report))
        tagged = {t["nodeid"]: t.get("_docdb_recovered_pass")
                  for t in merged["tests"]}
        assert tagged[PREFIX + "compatibility/tests/v.py::t_victim"] == 1
        assert tagged[PREFIX + "compatibility/tests/v.py::t_ok"] is None, \
            "a test that never needed a retry must not be marked recovered"

        xml, counts = render_gate_junit(report)
        assert counts["failures"] == 0
        assert counts["recovered"] == 1
        victim = [v for k, v in _cases(xml).items() if "t_victim" in k][0]
        assert victim[0] == "passed"
        assert "re-run 1" in victim[2]

    def test_a_genuine_failure_survives_recovery_and_is_reported_failed(self, tmp_path):
        # The stub reports passes, so drive the real path: no re-run command that
        # can rescue it means the residual must still red, and must show as a
        # failure in the rendered verdict.
        report = _report(tmp_path, [
            ("compatibility/tests/w.py::t_real", "failed", "AssertionError: genuinely broken"),
        ])
        stub = tmp_path / "noop_stub.py"
        stub.write_text("import sys\nsys.exit(1)\n")
        proc = subprocess.run([
            sys.executable, TOOL, "recover-and-gate",
            "--report", report, "--strip-prefix", PREFIX, "--prefix", PREFIX,
            "--workdir", str(tmp_path), "--settle-seconds", "0",
            "--output", str(tmp_path / "gate-failures.txt"),
            "--", sys.executable, str(stub),
        ], capture_output=True, text=True)

        assert proc.returncode == 1, proc.stdout
        xml, counts = render_gate_junit(report)
        assert counts["failures"] == 1
        assert counts["recovered"] == 0
