# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

OSS_ROOT = Path(__file__).resolve().parents[3]
HELPER = OSS_ROOT / "packaging" / "postgres-min-version.sh"
SETUP_VERSIONS = OSS_ROOT / "scripts" / "setup_versions.sh"

FIXTURE = """set -u
set -e
function GetPostgresSourceRef()
{
  case "$1" in
    19) echo REL_19_STABLE ;;
    18) echo REL_18_7 ;;
    17) echo REL_17_12 ;;
    *) echo "Invalid PG Version specified $1"; exit 1 ;;
  esac
}
"""


def run(function, *args, setup_versions=SETUP_VERSIONS):
    return subprocess.run(
        ["bash", "-c", '. "$1"; shift; "$@"', "_", str(HELPER), function, *args, str(setup_versions)],
        capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)


class PostgresMinVersionTests(unittest.TestCase):
    """packaging/postgres-min-version.sh, which keeps builds off PostgreSQL minors the tests never ran."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.fixture = Path(tmp.name, "setup_versions.sh")
        self.fixture.write_text(FIXTURE, encoding="utf-8")

    def check(self, major, found):
        return run("documentdb_check_postgres_version", major, found, setup_versions=self.fixture)

    def test_every_released_pin_yields_a_minimum(self):
        text = SETUP_VERSIONS.read_text(encoding="utf-8")
        pins = re.findall(r'^POSTGRES_(\d+)_REF="REL_\1_(\d+)"$', text, re.MULTILINE)
        self.assertTrue(pins, "no released POSTGRES_<major>_REF found in setup_versions.sh")
        for major, minor in pins:
            r = run("documentdb_postgres_min_version", major)
            self.assertEqual((r.returncode, r.stdout), (0, f"{major}.{minor}\n"), r.stderr)

    def test_branch_pin_yields_no_minimum_and_skips_the_check(self):
        r = run("documentdb_postgres_min_version", "19", setup_versions=self.fixture)
        self.assertEqual((r.returncode, r.stdout), (0, ""), r.stderr)
        r = self.check("19", "19~rc2-1.pgdg24.04+1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not checking", r.stdout)

    def test_accepts_the_tested_minor_and_newer(self):
        for major, found in [("17", "17.12-1.pgdg24.04+1"), ("17", "17.12-1PGDG.rhel9.8"),
                             ("17", "17.13"), ("17", "17.100-1"), ("17", "1:17.12-1"), ("18", "18.7-1.pgdg13+2")]:
            with self.subTest(found=found):
                r = self.check(major, found)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_rejects_an_older_minor(self):
        # 17.9 sorts after 17.12 as text; the comparison must be numeric.
        for major, found in [("17", "17.11-1.pgdg24.04+1"), ("17", "17.9"), ("17", "17.0-1"), ("18", "18.6-1PGDG.rhel9.8")]:
            with self.subTest(found=found):
                r = self.check(major, found)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn("older than", r.stderr)

    def test_rejects_versions_it_cannot_read(self):
        for major, found in [("17", ""), ("17", "17"), ("17", "17."), ("17", "17x12"), ("17", "18.12"),
                             ("17", "117.12"), ("17", "170012")]:
            with self.subTest(found=found):
                r = self.check(major, found)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn("cannot read", r.stderr)

    def test_rejects_an_unpinned_or_malformed_major(self):
        for major in ["16", "", "17.12", "x"]:
            with self.subTest(major=major):
                r = self.check(major, "17.12")
                self.assertEqual(r.returncode, 1, r.stdout)

    def test_builds_run_the_check_on_the_postgres_they_install(self):
        for path, package in [
            ("packaging/deb/packaging-entrypoint.sh", "postgresql-server-dev-${POSTGRES_VERSION}"),
            ("packaging/rpm/packaging-entrypoint-rpm.sh", "postgresql${POSTGRES_VERSION}-devel"),
            ("packaging/gateway/docker/Dockerfile_documentdb_local", "postgresql-${POSTGRES_VERSION})"),
        ]:
            with self.subTest(path=path):
                text = (OSS_ROOT / path).read_text(encoding="utf-8")
                self.assertIn("documentdb_check_postgres_version", text)
                self.assertIn(package, text)


if __name__ == "__main__":
    unittest.main()
