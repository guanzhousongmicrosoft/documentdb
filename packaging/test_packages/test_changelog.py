# SPDX-License-Identifier: MIT

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "packaging/update_spec_changelog.sh"
RC_NOTE = "Release executable memory allocated for PCRE2 JIT-compiled regular expressions"


class ChangelogTests(unittest.TestCase):
    def generate(self, version, source=None):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "packaging/rpm/spec").mkdir(parents=True)
            (root / "packaging/deb").mkdir(parents=True)
            (root / "debian").mkdir()
            changelog = root / "CHANGELOG.md"
            if source is None:
                shutil.copyfile(ROOT / "CHANGELOG.md", changelog)
            else:
                changelog.write_text(source)
            shutil.copyfile(
                ROOT / "packaging/rpm/spec/documentdb.spec",
                root / "packaging/rpm/spec/documentdb.spec",
            )
            original = changelog.read_bytes()

            result = subprocess.run(
                ["bash", str(SCRIPT), version],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("WARNING:", result.stderr)
            self.assertEqual(changelog.read_bytes(), original)
            self.assertFalse((root / "CHANGELOG.md.backup").exists())

            spec = (root / "packaging/rpm/spec/documentdb.spec").read_text()
            deb = (root / "packaging/deb/changelog").read_text()
            self.assertEqual((root / "debian/changelog").read_text(), deb)
            return spec.split("%changelog\n", 1)[1], deb

    def test_rc_notes_use_real_version_in_both_package_formats(self):
        source = (ROOT / "CHANGELOG.md").read_text()
        source = source[source.index("### documentdb v1.0-0"):]
        expected_versions = re.findall(r"(?m)^### documentdb v([^ ]+)", source)
        expected_notes = [
            line[2:]
            for line in source.split("\n### ", 1)[0].splitlines()
            if line.startswith("* ")
        ]
        for version in ("1.0-0", "1.0.0"):
            with self.subTest(version=version):
                rpm, deb = self.generate(version)
                rpm_versions = re.findall(r"(?m)^\* .* - (\d+\.\d+-\d+)$", rpm)
                deb_versions = re.findall(r"(?m)^documentdb \(([^)]+)\)", deb)

                self.assertEqual(rpm_versions, expected_versions)
                self.assertEqual(deb_versions, expected_versions)
                self.assertEqual(rpm_versions.count("1.0-0"), 1)
                self.assertEqual(deb_versions.count("1.0-0"), 1)
                rpm_notes = re.findall(r"(?m)^- (.*)$", rpm.split("\n* ", 1)[0])
                deb_notes = re.findall(
                    r"(?m)^  \* (.*)$", deb.split("\ndocumentdb ", 1)[0]
                )
                self.assertEqual(
                    rpm_notes, [note.replace("%", "%%") for note in expected_notes]
                )
                self.assertEqual(deb_notes, expected_notes)
                for changelog in (rpm, deb):
                    self.assertEqual(changelog.count(RC_NOTE), 1)
                    self.assertNotIn("No details provided.", changelog)
                    self.assertNotIn("0.0-0", changelog)

    def test_older_release_starts_at_its_own_notes(self):
        rpm, deb = self.generate("0.117-0")
        self.assertRegex(rpm, r"(?m)^\* .* - 0\.117-0$")
        self.assertTrue(deb.startswith("documentdb (0.117-0)"))
        for changelog in (rpm, deb):
            self.assertIn("Reject embedded null characters", changelog)
            self.assertNotIn(RC_NOTE, changelog)

    def test_pre_1_0_changelog_control(self):
        source = (ROOT / "CHANGELOG.md").read_text()
        source = source[source.index("### documentdb v0.117-0"):]
        rpm, deb = self.generate("0.117-0", source)
        self.assertEqual(
            re.findall(r"(?m)^\* .* - (\d+\.\d+-\d+)$", rpm)[:3],
            ["0.117-0", "0.116-0", "0.115-0"],
        )
        self.assertEqual(
            re.findall(r"(?m)^documentdb \(([^)]+)\)", deb)[:3],
            ["0.117-0", "0.116-0", "0.115-0"],
        )
        for changelog in (rpm, deb):
            self.assertIn("Reject embedded null characters", changelog)
            self.assertNotIn(RC_NOTE, changelog)


if __name__ == "__main__":
    unittest.main()
