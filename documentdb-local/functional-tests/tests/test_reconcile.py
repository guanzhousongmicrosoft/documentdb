"""Tests for functional_gate.py reconcile — folding a gate run's outcomes back
into a known-failures list (the source_sha-bump maintenance operation)."""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

from functional_gate import _normalize_node_id, reconcile_failing_list  # noqa: E402

PREFIX = "docdb_functional_tests/documentdb_tests/"


def _write_report(tmp_path, tests, filename="report.json"):
    path = tmp_path / filename
    payload = {"tests": [
        {"nodeid": nid, "outcome": outcome,
         "call": {"longrepr": detail}}
        for nid, outcome, detail in tests
    ]}
    path.write_text(json.dumps(payload))
    return str(path)


def _write_list(tmp_path, name, lines):
    path = tmp_path / name
    path.write_text("\n".join(lines) + "\n")
    return str(path)


class TestNormalizeNodeId:
    def test_prefixed_entry_normalizes_to_rootdir_relative(self):
        assert _normalize_node_id(PREFIX + "compatibility/tests/a.py::t") == \
            "compatibility/tests/a.py::t"

    def test_bare_entry_unchanged(self):
        assert _normalize_node_id("compatibility/tests/a.py::t") == \
            "compatibility/tests/a.py::t"


class TestReconcile:
    def test_new_failure_is_added(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/new.py::t_new", "failed", "AssertionError"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "# header comment",
            "compatibility/tests/old.py::t_old",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["added"] == ["compatibility/tests/new.py::t_new"]
        assert result["removed"] == []
        assert "compatibility/tests/new.py::t_new" in result["lines"]
        assert "# header comment" in result["lines"]

    def test_xpass_strict_entry_is_removed(self, tmp_path):
        # A listed test that now passes is reported by pytest as 'failed'
        # with an XPASS(strict) repr under the strict-xfail plugin.
        report = _write_report(tmp_path, [
            ("compatibility/tests/fixed.py::t_fixed", "failed", "[XPASS(strict)] Known failure"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/fixed.py::t_fixed",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["removed"] == ["compatibility/tests/fixed.py::t_fixed"]
        assert "compatibility/tests/fixed.py::t_fixed" not in result["lines"]

    def test_still_failing_listed_entry_is_kept(self, tmp_path):
        # Still-failing listed tests come back as 'xfailed' — untouched.
        report = _write_report(tmp_path, [
            ("compatibility/tests/known.py::t_known", "xfailed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/known.py::t_known",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["added"] == [] and result["removed"] == []
        assert "compatibility/tests/known.py::t_known" in result["lines"]

    def test_prefixed_list_matches_bare_report_ids(self, tmp_path):
        # Backend-gate style lists carry the repo prefix; report node IDs are
        # rootdir-relative. They must compare equal.
        report = _write_report(tmp_path, [
            ("compatibility/tests/fixed.py::t", "failed", "[XPASS(strict)]"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            PREFIX + "compatibility/tests/fixed.py::t",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["removed"] == ["compatibility/tests/fixed.py::t"]
        assert all("fixed.py" not in l for l in result["lines"])

    def test_additions_follow_dominant_prefixed_style(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/new.py::t_new", "failed", "boom"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            PREFIX + "compatibility/tests/a.py::t1",
            PREFIX + "compatibility/tests/b.py::t2",
        ])
        result = reconcile_failing_list(report, failing)
        assert PREFIX + "compatibility/tests/new.py::t_new" in result["lines"]

    def test_flaky_listed_failure_is_skipped_not_added(self, tmp_path):
        # Adding it would trip the plugin's failing/flaky overlap ValueError.
        report = _write_report(tmp_path, [
            ("compatibility/tests/f.py::t_flaky", "failed", "boom"),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        flaky = _write_list(tmp_path, "flaky.txt", [
            "compatibility/tests/f.py::t_flaky",
        ])
        result = reconcile_failing_list(report, failing, flaky)
        assert result["added"] == []
        assert result["skipped_flaky"] == ["compatibility/tests/f.py::t_flaky"]

    def test_listed_setup_error_is_kept_for_inspection(self, tmp_path):
        # xfail does not cover setup errors: a listed test that ERRORS is not
        # an XPASS and must not be dropped from the list silently.
        report = _write_report(tmp_path, [
            ("compatibility/tests/e.py::t_err", "error", "fixture blew up"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/e.py::t_err",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["removed"] == []
        assert result["kept_errored"] == ["compatibility/tests/e.py::t_err"]
        assert "compatibility/tests/e.py::t_err" in result["lines"]

    def test_uncollected_entry_reported_but_kept_by_default(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/present.py::t", "passed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/gone.py::t_gone",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["uncollected"] == ["compatibility/tests/gone.py::t_gone"]
        assert result["pruned"] == []
        assert "compatibility/tests/gone.py::t_gone" in result["lines"]

    def test_uncollected_entry_pruned_when_requested(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/present.py::t", "passed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/gone.py::t_gone",
        ])
        result = reconcile_failing_list(report, failing, prune_uncollected=True)
        assert result["pruned"] == ["compatibility/tests/gone.py::t_gone"]
        assert "compatibility/tests/gone.py::t_gone" not in result["lines"]

    def test_flaky_pass_is_reported_as_pruning_candidate(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/f.py::t_flaky", "xpassed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        flaky = _write_list(tmp_path, "flaky.txt", [
            "compatibility/tests/f.py::t_flaky",
        ])
        result = reconcile_failing_list(report, failing, flaky)
        assert result["flaky_passes"] == ["compatibility/tests/f.py::t_flaky"]


class TestDoubleApplyGuard:
    """Reconcile is not idempotent and cannot be.

    Under strict xfail a LISTED test that passes is reported as ``failed``, so
    the classification is "failed and on the list -> remove" vs "failed and not
    on the list -> add". One pass flips the list membership of every failed
    test, so applying the same report again swaps the two sets: the second run
    re-adds exactly what the first removed, and nothing in its output says so.
    A recorded report id is what makes that detectable.
    """

    def _report_and_list(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/a.py::t_listed_now_passes", "failed", "XPASS(strict)"),
            ("compatibility/tests/b.py::t_new_failure", "failed", "AssertionError"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/a.py::t_listed_now_passes",
        ])
        return report, failing

    def test_first_pass_records_the_report_id(self, tmp_path):
        report, failing = self._report_and_list(tmp_path)
        result = reconcile_failing_list(report, failing)
        assert result["added"] == ["compatibility/tests/b.py::t_new_failure"]
        assert result["removed"] == ["compatibility/tests/a.py::t_listed_now_passes"]
        marker = [l for l in result["lines"] if l.startswith("# reconciled-from-report: ")]
        assert len(marker) == 1
        assert marker[0].split(": ", 1)[1] == result["report_id"]

    def test_same_report_twice_is_refused(self, tmp_path):
        import pytest
        report, failing = self._report_and_list(tmp_path)
        first = reconcile_failing_list(report, failing)
        with open(failing, "w", newline="\n") as f:
            f.write("\n".join(first["lines"]) + "\n")
        before = open(failing).read()
        with pytest.raises(SystemExit) as exc:
            reconcile_failing_list(report, failing)
        assert "already reconciled" in str(exc.value)
        assert open(failing).read() == before, "the refused call must not rewrite the list"

    def test_force_overrides_the_refusal(self, tmp_path):
        report, failing = self._report_and_list(tmp_path)
        first = reconcile_failing_list(report, failing)
        with open(failing, "w", newline="\n") as f:
            f.write("\n".join(first["lines"]) + "\n")
        second = reconcile_failing_list(report, failing, force=True)
        # Proves the corruption the guard prevents: the sets swap.
        assert second["added"] == first["removed"]
        assert second["removed"] == first["added"]

    def test_a_different_report_is_allowed(self, tmp_path):
        report, failing = self._report_and_list(tmp_path)
        first = reconcile_failing_list(report, failing)
        with open(failing, "w", newline="\n") as f:
            f.write("\n".join(first["lines"]) + "\n")
        fresh = _write_report(tmp_path, [
            ("compatibility/tests/b.py::t_new_failure", "failed", "AssertionError"),
            ("compatibility/tests/c.py::t_another", "failed", "AssertionError"),
        ])
        result = reconcile_failing_list(fresh, failing)
        assert "compatibility/tests/c.py::t_another" in result["added"]

    def test_only_one_marker_survives_repeated_reconciles(self, tmp_path):
        report, failing = self._report_and_list(tmp_path)
        first = reconcile_failing_list(report, failing)
        with open(failing, "w", newline="\n") as f:
            f.write("\n".join(first["lines"]) + "\n")
        fresh = _write_report(tmp_path, [
            ("compatibility/tests/c.py::t_another", "failed", "AssertionError"),
        ])
        second = reconcile_failing_list(fresh, failing)
        markers = [l for l in second["lines"] if l.startswith("# reconciled-from-report: ")]
        assert len(markers) == 1

class TestCrashListPrecedence:
    """A crash-listed test is SKIPPED, so it must never also be xfailed.

    conftest_known_failures refuses any exact id present in both the crash list
    and the failing/flaky pair, and that refusal happens during collection, so
    the whole suite fails to run. Reconcile therefore has to know about the
    crash list: without it, a rebaseline adds the crash-listed failures straight
    back and the next run cannot collect at all.
    """

    def test_crash_listed_failure_is_not_added(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/c.py::t_crasher", "failed", "boom"),
            ("compatibility/tests/n.py::t_normal", "failed", "AssertionError"),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        crash = _write_list(tmp_path, "crash.txt", [
            "compatibility/tests/c.py::t_crasher",
        ])
        result = reconcile_failing_list(report, failing, crash_path=crash)
        assert result["added"] == ["compatibility/tests/n.py::t_normal"]
        assert result["skipped_crash"] == ["compatibility/tests/c.py::t_crasher"]

    def test_existing_entry_colliding_with_crash_list_is_dropped(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/c.py::t_crasher", "passed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/c.py::t_crasher",
        ])
        crash = _write_list(tmp_path, "crash.txt", [
            "compatibility/tests/c.py::t_crasher",
        ])
        result = reconcile_failing_list(report, failing, crash_path=crash)
        assert result["crash_collisions"] == ["compatibility/tests/c.py::t_crasher"]
        assert "compatibility/tests/c.py::t_crasher" not in result["lines"]

    def test_file_and_directory_crash_entries_do_not_collide(self, tmp_path):
        # Only exact ids can collide. Prefix entries are how the crash list
        # covers a whole family, and they must not suppress unrelated adds.
        report = _write_report(tmp_path, [
            ("compatibility/tests/d.py::t_one", "failed", "AssertionError"),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        crash = _write_list(tmp_path, "crash.txt", [
            "compatibility/tests/other.py",
            "compatibility/tests/somedir/",
        ])
        result = reconcile_failing_list(report, failing, crash_path=crash)
        assert result["added"] == ["compatibility/tests/d.py::t_one"]
        assert result["skipped_crash"] == []

    def test_no_crash_list_is_backward_compatible(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/n.py::t_normal", "failed", "AssertionError"),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        result = reconcile_failing_list(report, failing)
        assert result["added"] == ["compatibility/tests/n.py::t_normal"]
        assert result["skipped_crash"] == []
        assert result["crash_collisions"] == []

class TestTwoRunClassification:
    """A strict entry asserts a test ALWAYS fails, which one run cannot show.

    This is the failure this mode exists to prevent. A baseline taken from a
    single run marks every one-time failure strict; the next run under a
    different shape passes some of them, and each of those becomes an
    XPASS(strict) that reds the gate. Comparing runs makes "always" observable:
    consistent failures earn strict, disagreements go to flaky, which accepts
    either outcome.
    """

    def _two_runs(self, tmp_path, first, second):
        return (_write_report(tmp_path, first, filename="r1.json"),
                _write_report(tmp_path, second, filename="r2.json"))

    def test_failing_in_both_runs_becomes_strict(self, tmp_path):
        r1, r2 = self._two_runs(tmp_path,
            [("compatibility/tests/a.py::t", "failed", "AssertionError")],
            [("compatibility/tests/a.py::t", "failed", "AssertionError")])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["added"] == ["compatibility/tests/a.py::t"]
        assert res["demoted_flaky"] == []

    def test_failing_in_only_one_run_becomes_flaky(self, tmp_path):
        r1, r2 = self._two_runs(tmp_path,
            [("compatibility/tests/a.py::t", "failed", "AssertionError")],
            [("compatibility/tests/a.py::t", "passed", "")])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["added"] == [], "a test that passed once must not be asserted as always failing"
        assert res["demoted_flaky"] == ["compatibility/tests/a.py::t"]

    def test_listed_test_that_disagrees_loses_its_strict_entry(self, tmp_path):
        # Listed, so 'xfailed' means it failed and 'failed' means XPASS. This is
        # the exact shape that produced the CI reds: strict, but not always.
        r1, r2 = self._two_runs(tmp_path,
            [("compatibility/tests/a.py::t", "xfailed", "")],
            [("compatibility/tests/a.py::t", "failed", "XPASS(strict)")])
        failing = _write_list(tmp_path, "failing.txt", ["compatibility/tests/a.py::t"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["demoted_flaky"] == ["compatibility/tests/a.py::t"]
        assert "compatibility/tests/a.py::t" not in res["lines"]

    def test_listed_test_failing_in_both_runs_is_left_alone(self, tmp_path):
        r1, r2 = self._two_runs(tmp_path,
            [("compatibility/tests/a.py::t", "xfailed", "")],
            [("compatibility/tests/a.py::t", "xfailed", "")])
        failing = _write_list(tmp_path, "failing.txt", ["compatibility/tests/a.py::t"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["added"] == [] and res["removed"] == [] and res["demoted_flaky"] == []
        assert "compatibility/tests/a.py::t" in res["lines"]

    def test_listed_test_passing_in_both_runs_is_removed(self, tmp_path):
        r1, r2 = self._two_runs(tmp_path,
            [("compatibility/tests/a.py::t", "failed", "XPASS(strict)")],
            [("compatibility/tests/a.py::t", "failed", "XPASS(strict)")])
        failing = _write_list(tmp_path, "failing.txt", ["compatibility/tests/a.py::t"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["removed"] == ["compatibility/tests/a.py::t"]
        assert "compatibility/tests/a.py::t" not in res["lines"]

    def test_a_test_absent_from_one_run_is_judged_on_the_runs_that_saw_it(self, tmp_path):
        # Split legs each cover a slice, so a test legitimately appears in only
        # one report. Treating "absent" as "passed" would demote every entry
        # that only one leg ran.
        r1, r2 = self._two_runs(tmp_path,
            [("compatibility/tests/a.py::t", "failed", "AssertionError")],
            [("compatibility/tests/b.py::other", "passed", "")])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["added"] == ["compatibility/tests/a.py::t"]
        assert res["demoted_flaky"] == []

    def test_three_runs_require_all_three(self, tmp_path):
        r1 = _write_report(tmp_path, [("compatibility/tests/a.py::t", "failed", "e")], filename="r1.json")
        r2 = _write_report(tmp_path, [("compatibility/tests/a.py::t", "failed", "e")], filename="r2.json")
        r3 = _write_report(tmp_path, [("compatibility/tests/a.py::t", "passed", "")], filename="r3.json")
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2, r3])
        assert res["runs"] == 3
        assert res["demoted_flaky"] == ["compatibility/tests/a.py::t"]

    def test_crash_listed_test_is_never_demoted_or_added(self, tmp_path):
        r1, r2 = self._two_runs(tmp_path,
            [("compatibility/tests/c.py::t", "failed", "boom")],
            [("compatibility/tests/c.py::t", "passed", "")])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        crash = _write_list(tmp_path, "crash.txt", ["compatibility/tests/c.py::t"])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2], crash_path=crash)
        assert res["added"] == [] and res["demoted_flaky"] == []

    def test_single_report_keeps_the_original_behaviour(self, tmp_path):
        # The bot and CI call this with one report; that path must not change.
        report = _write_report(tmp_path, [
            ("compatibility/tests/a.py::t", "failed", "AssertionError"),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        res = reconcile_failing_list(report, failing)
        assert res["added"] == ["compatibility/tests/a.py::t"]
        assert res["demoted_flaky"] == [] and res["runs"] == 1
    def test_adding_a_second_run_is_not_mistaken_for_a_repeat(self, tmp_path):
        # Reconciling from run A, then from runs A and B, are different
        # operations. If the recorded id covered only the first report the
        # second would be refused as a repeat, which is exactly backwards:
        # adding a run is how a baseline is corrected.
        from functional_gate import reconcile_identity
        r1 = _write_report(tmp_path, [("compatibility/tests/a.py::t", "failed", "e")], filename="r1.json")
        r2 = _write_report(tmp_path, [("compatibility/tests/a.py::t", "passed", "")], filename="r2.json")
        assert reconcile_identity([r1]) != reconcile_identity([r1, r2])

        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        first = reconcile_failing_list(r1, failing)
        with open(failing, "w", newline="\n") as f:
            f.write("\n".join(first["lines"]) + "\n")
        # Must not raise: this is a different operation, not a repeat.
        second = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert second["runs"] == 2

class TestMultiRunUsesEveryReportsCollection:
    """Pruning and flaky-pass detection must look at ALL the reports given.

    A run can lose tests it really executed: an xdist worker death drops its
    assigned tests from that run's report. If only the primary report is
    consulted, an entry the primary lost but another run collected AND failed
    looks uncollected, and --prune-uncollected deletes it. The next gate run
    fails it unlisted and reds.
    """

    def test_entry_present_only_in_an_extra_report_is_not_pruned(self, tmp_path):
        r1 = _write_report(tmp_path, [
            ("compatibility/tests/z.py::t_other", "failed", "AssertionError"),
        ], filename="r1.json")
        r2 = _write_report(tmp_path, [
            ("compatibility/tests/z.py::t_other", "failed", "AssertionError"),
            ("compatibility/tests/a.py::t_listed", "xfailed", ""),
        ], filename="r2.json")
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/a.py::t_listed",
        ])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2],
                                     prune_uncollected=True)
        assert res["uncollected"] == []
        assert res["pruned"] == []
        assert any("t_listed" in line for line in res["lines"]), \
            "an entry another run collected and failed must survive pruning"

    def test_entry_no_report_collected_is_still_pruned(self, tmp_path):
        # The genuine case pruning exists for: deleted upstream, so absent
        # everywhere.
        r1 = _write_report(tmp_path, [
            ("compatibility/tests/z.py::t_other", "failed", "AssertionError"),
        ], filename="r1.json")
        r2 = _write_report(tmp_path, [
            ("compatibility/tests/z.py::t_other", "failed", "AssertionError"),
        ], filename="r2.json")
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/gone.py::t_deleted",
        ])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2],
                                     prune_uncollected=True)
        assert res["pruned"] == ["compatibility/tests/gone.py::t_deleted"]

    def test_flaky_xpass_in_an_extra_report_is_reported(self, tmp_path):
        r1 = _write_report(tmp_path, [
            ("compatibility/tests/z.py::t_other", "failed", "AssertionError"),
        ], filename="r1.json")
        r2 = _write_report(tmp_path, [
            ("compatibility/tests/f.py::t_flaky", "xpassed", ""),
        ], filename="r2.json")
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        flaky = _write_list(tmp_path, "flaky.txt", [
            "compatibility/tests/f.py::t_flaky",
        ])
        res = reconcile_failing_list(r1, failing, flaky, extra_reports=[r2])
        assert res["flaky_passes"] == ["compatibility/tests/f.py::t_flaky"]


class TestMultiRunKeepsListedErrors:
    """An 'error' is not evidence that a listed test passed.

    _actually_failed reads a listed 'error' as "did not fail", because under
    strict xfail a listed test that passes is reported as failed/error. An error
    the xfail model does not account for would therefore delete a live
    known-failure entry. The single-report path keeps those for a human; the
    multi-run path must not be laxer.
    """

    def test_listed_error_in_every_run_is_kept_not_removed(self, tmp_path):
        r1 = _write_report(tmp_path, [
            ("compatibility/tests/e.py::t_err", "error", "fixture blew up"),
        ], filename="r1.json")
        r2 = _write_report(tmp_path, [
            ("compatibility/tests/e.py::t_err", "error", "fixture blew up"),
        ], filename="r2.json")
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/e.py::t_err",
        ])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["removed"] == []
        assert res["kept_errored"] == ["compatibility/tests/e.py::t_err"]
        assert any("t_err" in line for line in res["lines"])

    def test_listed_xpass_in_every_run_is_still_removed(self, tmp_path):
        # The genuine XPASS(strict) case must keep working.
        r1 = _write_report(tmp_path, [
            ("compatibility/tests/e.py::t_pass", "failed", "[XPASS(strict)]"),
        ], filename="r1.json")
        r2 = _write_report(tmp_path, [
            ("compatibility/tests/e.py::t_pass", "failed", "[XPASS(strict)]"),
        ], filename="r2.json")
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/e.py::t_pass",
        ])
        res = reconcile_failing_list(r1, failing, extra_reports=[r2])
        assert res["removed"] == ["compatibility/tests/e.py::t_pass"]
        assert res["kept_errored"] == []


class TestReportIdentityIsCanonical:
    """The duplicate guard is only as good as the id it compares.

    Hashing the counters plus the first and last node id lets two reports that
    fail DIFFERENT tests collide, so a genuinely new report is refused; and it
    makes the id depend on record order, so re-serialising the SAME report gets
    it applied twice. Both defeat the guard, in opposite directions.
    """

    def _report(self, tests):
        return {
            "summary": {"collected": len(tests), "total": len(tests),
                        "passed": sum(1 for t in tests if t[1] == "passed"),
                        "failed": sum(1 for t in tests if t[1] == "failed")},
            "tests": [{"nodeid": PREFIX + nid, "outcome": outcome} for nid, outcome in tests],
        }

    def test_same_totals_and_endpoints_different_failures_differ(self):
        from functional_gate import report_identity
        a = self._report([("a.py::first", "passed"), ("m1.py::mid", "failed"),
                          ("m2.py::mid", "passed"), ("z.py::last", "passed")])
        b = self._report([("a.py::first", "passed"), ("m1.py::mid", "passed"),
                          ("m2.py::mid", "failed"), ("z.py::last", "passed")])
        assert report_identity(a) != report_identity(b)

    def test_reordering_the_same_report_keeps_its_identity(self):
        from functional_gate import report_identity
        tests = [("a.py::first", "passed"), ("m.py::mid", "failed"),
                 ("z.py::last", "passed")]
        a = self._report(tests)
        b = self._report(list(reversed(tests)))
        assert report_identity(a) == report_identity(b)

    def test_prefixed_and_bare_node_ids_agree(self):
        from functional_gate import report_identity
        a = {"tests": [{"nodeid": PREFIX + "a.py::t", "outcome": "failed"}]}
        b = {"tests": [{"nodeid": "a.py::t", "outcome": "failed"}]}
        assert report_identity(a) == report_identity(b)