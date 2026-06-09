import re
import subprocess
import tempfile
import unittest
from pathlib import Path

OSS_ROOT = Path(__file__).resolve().parents[3]
SETUP_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-setup.sh"
TUNE_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-tune.sh"
GATEWAY_SETUP_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-register-gateway.sh"
GATEWAY_ADMIN_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
GATEWAY_POSTINST = OSS_ROOT / "documentdb-local" / "maintainer-scripts" / "gateway" / "postinst"
STANDALONE_BUILD_SCRIPT = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
PACKAGING_README = OSS_ROOT / "packaging" / "README.md"


class DocumentDBSetupTests(unittest.TestCase):
    def test_peer_auth_map_allows_supported_documentdb_user_roles(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"local -a map_lines=\(\n(?P<body>.*?)\n\s*\)",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)

        map_lines = {
            line.strip().strip('"')
            for line in match.group("body").splitlines()
            if line.strip().startswith('"documentdb-map')
        }

        self.assertTrue(
            {
                "documentdb-map   documentdb   documentdb",
                "documentdb-map   documentdb   +documentdb_readonly_role",
                "documentdb-map   documentdb   +documentdb_readwrite_role",
                "documentdb-map   documentdb   +documentdb_admin_role",
            }.issubset(map_lines)
        )
        self.assertNotIn("documentdb-map   documentdb   all", map_lines)


class DocumentDBTuneTests(unittest.TestCase):
    """Tests for the documentdb-tune standalone script."""

    def test_print_output_contains_required_settings(self):
        """--print should output all required GUC settings."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = result.stdout
        self.assertIn("shared_preload_libraries", output)
        self.assertIn("pg_cron", output)
        self.assertIn("pg_documentdb_core", output)
        self.assertIn("pg_documentdb", output)
        self.assertIn("documentdb.enableBackgroundWorker = true", output)
        self.assertIn("cron.database_name = 'postgres'", output)

    def test_print_output_has_managed_block_markers(self):
        """--print should wrap output in managed block markers."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("# >>> documentdb-setup managed configuration >>>", result.stdout)
        self.assertIn("# <<< documentdb-setup managed configuration <<<", result.stdout)

    def test_backup_file_uses_unique_tempfile(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"backup_file\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "mktemp",
            body,
            "documentdb-tune backups must not collide under concurrent runs",
        )
        self.assertIn(
            ".documentdb-backup.${timestamp}.XXXXXX",
            body,
            "documentdb-tune backups must retain timestamped names with a unique suffix",
        )
        self.assertNotIn(
            'local backup="${file}.documentdb-backup.${timestamp}"',
            body,
            "documentdb-tune must not use timestamp-only backup filenames",
        )

    def test_debian_include_edit_is_backed_up(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_debian_include_line\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        backup_idx = body.find('backup_file "${DEBIAN_LIVE_PG_CONF}"')
        append_idx = body.find('} >> "${DEBIAN_LIVE_PG_CONF}"')
        self.assertGreaterEqual(
            backup_idx,
            0,
            "documentdb-tune must back up the live config before appending the include",
        )
        self.assertGreater(
            append_idx,
            backup_idx,
            "documentdb-tune must back up the live config before appending the include",
        )

    def test_apply_restore_round_trip(self):
        """Apply then restore should leave the file unchanged (modulo trailing whitespace)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            conf = Path(tmpdir) / "postgresql.conf"
            original_content = "# existing config\nlisten_addresses = '*'\n"
            conf.write_text(original_content)

            # Apply
            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            applied = conf.read_text()
            self.assertIn("shared_preload_libraries", applied)
            self.assertIn("# >>> documentdb-setup managed configuration >>>", applied)

            # Restore
            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--restore"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            restored = conf.read_text().rstrip("\n") + "\n"
            self.assertEqual(restored.strip(), original_content.strip())

    def test_idempotent_apply(self):
        """Applying twice should detect no changes on the second run."""
        with tempfile.TemporaryDirectory() as tmpdir:
            conf = Path(tmpdir) / "postgresql.conf"
            conf.write_text("# test\n")

            subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            first_content = conf.read_text()

            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("already up to date", result.stdout)
            self.assertEqual(conf.read_text(), first_content)

    def test_dry_run_does_not_modify(self):
        """--dry-run should not write to the config file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            conf = Path(tmpdir) / "postgresql.conf"
            conf.write_text("# original\n")

            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--dry-run"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(conf.read_text(), "# original\n")

    def test_missing_pg_version_fails(self):
        """Missing --pg-version (without --pgdata) should fail."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--yes"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--pg-version is required", result.stderr)

    def test_help_flag(self):
        """--help should succeed and show usage."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("documentdb-tune", result.stdout)


class DocumentDBGatewaySetupTests(unittest.TestCase):
    """Tests for the gateway setup script's ident map configuration."""

    def test_ident_map_uses_gateway_user(self):
        """The gateway setup script should use documentdb-gateway OS user in ident map."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('GW_OS_USER="documentdb-gateway"', script)
        self.assertIn('GW_PG_ROLE="documentdb-gateway"', script)
        self.assertIn("documentdb-gateway-map", script)

    def test_ident_map_contains_required_roles(self):
        """The ident map should map to all required role groups."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("+documentdb_admin_role", script)
        self.assertIn("+documentdb_readwrite_role", script)
        self.assertIn("+documentdb_readonly_role", script)

    def test_no_all_mapping(self):
        """The ident map should NOT contain a wildcard 'all' mapping."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Look for patterns like "documentdb-gateway-map ... all" that would be unsafe
        all_pattern = re.compile(
            r"documentdb-gateway-map\s+\S+\s+all\b"
        )
        self.assertIsNone(all_pattern.search(script))

    def test_setup_complete_message_is_after_side_effects(self):
        """The 'Setup complete' message must print AFTER role creation,
        connection-file/env writing, optional admin user creation, and
        state recording. Previously this message was emitted before any of
        those side effects, which could mislead operators on failure."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        setup_complete_idx = script.find('Setup complete. Remaining steps')
        self.assertGreater(setup_complete_idx, -1,
                           "Expected 'Setup complete' message in register-gateway script")
        for required_call in ("create_gateway_role",
                              "write_connection_secret",
                              "create_admin_user",
                              "record_state"):
            # Match the call as a token followed by a statement separator
            # (newline, semicolon, or `;` from `if foo; then`). Reviewer-flagged
            # (multi-model should-fix M): create_admin_user is now invoked via
            # `if create_admin_user; then` so the older "...\n" pattern no
            # longer matched even though the call site is correct.
            call_match = re.search(
                rf"(?m)^[\s\t]*(?:if\s+)?{re.escape(required_call)}\b(?:\s*;|\s*$)",
                script,
            )
            self.assertIsNotNone(
                call_match,
                f"Expected {required_call} call in register-gateway",
            )
            self.assertLess(
                call_match.start(), setup_complete_idx,
                f"{required_call} must be invoked before the 'Setup complete' message; "
                f"currently it is at position {call_match.start()} but message is at {setup_complete_idx}."
            )


class DocumentDBSetupWizardFlagsTests(unittest.TestCase):
    """Phase 10 contract: documentdb-setup must implement the design's
    flag surface, branch flow on --target-postgres-instance, and honor
    --dry-run as a no-side-effect preview path."""

    def _help_output(self):
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def _dry_run(self, *extra_args):
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT),
             "--admin-user", "admin",
             "--password-file", "/dev/null",
             "--dry-run", *extra_args],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0,
                         f"dry-run with args {extra_args!r} failed: {result.stderr}")
        return result.stdout

    def test_help_lists_canonical_flag_names(self):
        """Per design §4.4, the canonical flags are
        --use-new-postgres-instance and --target-postgres-instance."""
        h = self._help_output()
        self.assertIn("--use-new-postgres-instance", h)
        self.assertIn("--target-postgres-instance", h)

    def test_help_lists_deprecated_aliases(self):
        """Deprecated aliases must remain documented so existing
        automation does not silently break."""
        h = self._help_output()
        self.assertIn("--use-private-cluster", h)
        self.assertIn("--target-cluster", h)

    def test_dry_run_greenfield_announces_per_major_units(self):
        """Greenfield dry-run must reference the per-major templated
        systemd units (documentdb-postgresql@N.service,
        documentdb-gateway-local@N.service) per design §4.4."""
        out = self._dry_run("--pg-version", "18")
        self.assertIn("documentdb-postgresql@18.service", out)
        self.assertIn("documentdb-gateway-local@18.service", out)
        self.assertIn("GREENFIELD", out)
        # Greenfield must mention initdb with --username=documentdb-local
        # (OS user matches the templated service's User= directive).
        self.assertIn("--username=documentdb-local", out)

    def test_dry_run_brownfield_branches_correctly(self):
        """--target-postgres-instance N/C must switch the wizard into
        BROWNFIELD mode (no initdb, print reload command for operator)."""
        out = self._dry_run("--target-postgres-instance", "18/main")
        self.assertIn("BROWNFIELD", out)
        self.assertIn("18/main", out)
        # Brownfield must NOT initdb.
        self.assertNotIn("initdb --pgdata", out)
        # Brownfield must print the per-major reload command for the
        # operator to run against the system PG service.
        self.assertIn("systemctl reload postgresql@18-main", out)
        # Brownfield must still use the per-major templated gateway unit.
        self.assertIn("documentdb-gateway-local@18.service", out)

    def test_dry_run_delegates_to_subtools(self):
        """Both dry-run flows must mention delegation to documentdb-tune
        (postgresql.conf) and documentdb-register-gateway (hba/ident/role/url)."""
        out = self._dry_run("--pg-version", "18")
        self.assertIn("documentdb-tune --yes", out)
        self.assertIn("documentdb-register-gateway --yes", out)

    def test_dry_run_performs_no_side_effects(self):
        """--dry-run must not create any state files, data dirs, or
        run any service commands. We verify by ensuring the dry-run
        path exits before preflight_validation (which calls require_root)
        and without touching the filesystem."""
        with tempfile.TemporaryDirectory() as tmpdir:
            sentinel_etc = Path(tmpdir) / "etc-marker"
            sentinel_etc.write_text("untouched\n")
            result = subprocess.run(
                ["bash", str(SETUP_SCRIPT),
                 "--admin-user", "admin",
                 "--password-file", "/dev/null",
                 "--dry-run", "--pg-version", "18"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            # require_root would have failed the run if dry-run hadn't
            # exited early; success exit + sentinel intact confirms the
            # no-side-effect property.
            self.assertEqual(sentinel_etc.read_text(), "untouched\n")
            self.assertIn("no side effects performed", result.stdout)

    def test_target_postgres_instance_is_actually_wired(self):
        """Regression for reviewer finding #1: TARGET_CLUSTER must be
        read in main() (not only in parse_arguments) to drive flow.
        Verified by source-grep — main() must reference prepare_brownfield_instance
        when TARGET_CLUSTER is non-empty."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("prepare_brownfield_instance", script,
                      "Expected prepare_brownfield_instance function in setup.sh")
        # The main() flow must check TARGET_CLUSTER and call brownfield prep.
        # We look for the canonical guard:
        self.assertRegex(
            script,
            r'if \[\[ -n "\$\{TARGET_CLUSTER\}" \]\]; then\s*\n\s*prepare_brownfield_instance',
            "main() must branch on TARGET_CLUSTER and call prepare_brownfield_instance",
        )

    def test_per_major_systemd_unit_is_default_target(self):
        """start_or_restart_postgres must enable the per-major templated
        unit (documentdb-postgresql@N.service), not the non-templated one."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The new code path uses documentdb-postgresql@${PG_VERSION}.service
        self.assertRegex(
            script,
            r'pg_unit="documentdb-postgresql@\$\{PG_VERSION\}\.service"',
            "start_or_restart_postgres must use the per-major templated PG unit",
        )

    def test_greenfield_uses_documentdb_local_os_user(self):
        """Greenfield initdb must use --username=documentdb-local so
        that the templated PG unit (User=documentdb-local) and peer auth
        line up 1:1 (no ident map entry needed for the superuser)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--username=documentdb-local", script)
        # And the wizard must not initdb as the old "documentdb" OS user.
        self.assertNotIn("--username=documentdb \\", script)

    def test_every_invasive_step_routes_through_confirm_or_apply(self):
        """Reviewer #4 follow-up: ensure the wizard's consent gate
        actually wraps every invasive step the design lists in §4.4,
        not just initdb and systemctl. The script source must show
        confirm_or_apply guarding postgresql.conf write, hba/ident
        write (via register-gateway delegation), CREATE EXTENSION,
        and admin-user bootstrap."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Each label is a substring of the confirm_or_apply description
        # for one invasive operation. If a step regresses past the gate,
        # this test will fail.
        for label in (
            "Initialize PostgreSQL ${PG_VERSION} cluster",
            "Write postgresql.conf managed block via documentdb-tune",
            "Run documentdb-register-gateway --yes",
            "Run CREATE EXTENSION documentdb CASCADE",
            "Bootstrap first admin user",
        ):
            self.assertRegex(
                script,
                r'confirm_or_apply "[^"]*' + re.escape(label),
                f"Invasive step '{label}' must be wrapped in confirm_or_apply",
            )

    def test_dry_run_advertises_all_invasive_steps(self):
        """The dry-run preview must enumerate every invasive step that
        would run in apply mode, not just initdb + systemctl."""
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT),
             "--admin-user", "admin",
             "--password-file", "/dev/null",
             "--dry-run", "--pg-version", "18"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        for step in (
            "documentdb-tune --yes",
            "documentdb-register-gateway --yes",
            "CREATE EXTENSION documentdb CASCADE",
            "bootstrap admin user",
            "documentdb-postgresql@18.service",
            "documentdb-gateway-local@18.service",
        ):
            self.assertIn(step, out,
                          f"Dry-run preview must mention '{step}'")

    def test_brownfield_persists_per_major_state(self):
        """Reviewer #5 follow-up: brownfield must NOT write the
        per-major setup.conf (which would make the templated PG service
        activate). It writes a separate brownfield.conf for --restore
        tracking that no templated-unit ConditionPathExists checks."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'brownfield_conf="\$\{per_major_dir\}/brownfield\.conf"',
            "persist_brownfield_state must write /etc/documentdb/local/N/brownfield.conf",
        )
        # The brownfield branch in main() must call persist_brownfield_state,
        # NOT persist_self_managed_postgres_state.
        self.assertRegex(
            script,
            r'(?s)if \[\[ -n "\$\{TARGET_CLUSTER\}" \]\]; then\s*\n\s*prepare_brownfield_instance.*?persist_brownfield_state',
            "Brownfield flow must call persist_brownfield_state for --restore tracking",
        )


class Phase11WizardCorrectnessTests(unittest.TestCase):
    """Phase 11 (second-round reviewer feedback): regressions for the
    wizard-correctness issues that prevented end-to-end greenfield install."""

    def test_register_gateway_runs_after_pg_started(self):
        """Issue 1: register-gateway must NOT be called from
        prepare_self_managed_cluster (where PG is still down). It runs
        from register_gateway_after_pg_running, invoked from main()
        AFTER start_or_restart_postgres."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The pre-Phase-11 bug: ensure_pg_ident_map called inside
        # prepare_self_managed_cluster before PG was started. The wrapper
        # helper register_gateway_after_pg_running must exist and be
        # invoked from main() after the PG-start step.
        self.assertIn("register_gateway_after_pg_running", script)
        self.assertRegex(
            script,
            r'(?s)start_or_restart_postgres.*?register_gateway_after_pg_running',
            "register_gateway_after_pg_running must be called after start_or_restart_postgres",
        )

    def test_register_gateway_accepts_pg_owner(self):
        """Issue 1 follow-up: the wizard passes --pg-owner so
        register-gateway connects as the right OS user
        (documentdb-local for greenfield, postgres for brownfield)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'--pg-owner\s+"\$\{PG_OWNER\}"',
            "wizard must pass --pg-owner to documentdb-register-gateway",
        )
        rg = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--pg-owner)", rg)

    def test_hba_rule_is_scoped_to_documentdb_roles(self):
        """Issue 2: build_hba_block must NOT produce 'all all' which would
        catch every local peer connection and lock out postgres /
        documentdb-local. It must be scoped to the documentdb_*_role
        groups plus the gateway PG role."""
        rg = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Extract the heredoc body inside build_hba_block — that's the
        # actual rule emitted into pg_hba.conf, not the surrounding
        # comments. The cat <<EOF ... EOF block is what gets executed.
        m = re.search(
            r'build_hba_block\(\)\s*\{.*?cat\s*<<[A-Z]+\n(?P<body>.+?)\nEOF',
            rg, flags=re.DOTALL,
        )
        self.assertIsNotNone(m, "build_hba_block function or heredoc not found")
        body = m.group("body")
        self.assertNotRegex(
            body, r'^\s*local\s+all\s+all\s+peer',
            f"HBA rule must NOT match 'local all all peer'; got body:\n{body}",
        )
        # Scoped form: includes the role groups so peer auth still
        # applies for the gateway-relevant DB roles only.
        self.assertIn("+documentdb_admin_role", body)
        self.assertIn("+documentdb_readwrite_role", body)
        self.assertIn("+documentdb_readonly_role", body)

    def test_per_major_pg_systemd_unit_has_no_user_directive(self):
        """Issue 3: documentdb-postgresql@.service must NOT set
        User=documentdb-local because the helper script needs root for
        runuser; systemd starts the helper as root and the script
        downgrades itself."""
        unit_path = OSS_ROOT / "packaging" / "appliance" / "systemd" / "documentdb-postgresql@.service"
        unit = unit_path.read_text(encoding="utf-8")
        self.assertNotRegex(
            unit, r'^User=',
            "documentdb-postgresql@.service must not set User= (script needs root for runuser)",
        )
        self.assertNotRegex(unit, r'^Group=', "must not set Group= either")

    def test_lazy_defaults_in_resolve_runtime_paths(self):
        """Issue 4: per-major PG_PORT and DATA_DIR must be computed in
        resolve_runtime_paths (after detect_postgres_installation),
        not parse_arguments. Source-grep: resolve_runtime_paths must
        contain the per-major override logic."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The override predicate that only fires if not explicit AND
        # value equals the legacy default.
        self.assertRegex(
            script,
            r'(?s)resolve_runtime_paths\(\) \{.*?PG_PORT_EXPLICIT.*?9700 \+ PG_VERSION',
            "resolve_runtime_paths must set PG_PORT=9700+PG_VERSION when not explicit",
        )
        self.assertRegex(
            script,
            r'(?s)resolve_runtime_paths\(\) \{.*?DATA_DIR_EXPLICIT.*?/var/lib/documentdb-local/\$\{PG_VERSION\}/data',
            "resolve_runtime_paths must set DATA_DIR=/var/lib/documentdb-local/N/data when not explicit",
        )

    def test_url_password_detection_handles_empty_userinfo(self):
        """Suggestion 3: postgresql://:secret@host/db must be detected as
        password-bearing. Verified by source-grep that has_password no
        longer depends on user being non-empty."""
        # Read the Rust setup.rs to confirm the fix is present.
        rust_path = (
            OSS_ROOT / "pg_documentdb_gw" / "documentdb_gateway_core"
            / "src" / "configuration" / "setup.rs"
        )
        rust = rust_path.read_text(encoding="utf-8")
        self.assertNotRegex(
            rust,
            r'has_password\s*=\s*!user\.is_empty\(\)',
            "URL password detection must not gate on user being non-empty (empty-user-only edge case)",
        )

    def test_strict_version_check_env_var_removed(self):
        """Suggestion 2: DOCUMENTDB_STRICT_VERSION_CHECK was parsed but
        never enforced. It must be removed from the public env-var
        surface in setup.rs."""
        rust_path = (
            OSS_ROOT / "pg_documentdb_gw" / "documentdb_gateway_core"
            / "src" / "configuration" / "setup.rs"
        )
        rust = rust_path.read_text(encoding="utf-8")
        self.assertNotIn('"DOCUMENTDB_STRICT_VERSION_CHECK"', rust)
        # The struct field is also gone (the only mentions left are the
        # historical-note comments).
        self.assertNotRegex(
            rust,
            r'pub strict_version_check:\s*Option<bool>',
            "strict_version_check struct field must be removed",
        )

    def test_tune_writes_debian_documentdb_conf(self):
        """Issue 7: documentdb-tune must write the per-instance fragment
        as documentdb.conf (matching the createcluster.d hook and the
        design's .sample naming), NOT postgresql.conf."""
        tune_path = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-tune.sh"
        tune = tune_path.read_text(encoding="utf-8")
        self.assertIn(
            'CONFIG_TARGET="${cluster_dir}/documentdb.conf"',
            tune,
            "tune must write to /etc/postgresql-common/documentdb/N/C/documentdb.conf",
        )
        # The createcluster.d hook must point at the same filename.
        hook_path = OSS_ROOT / "documentdb-local" / "conf" / "99-documentdb.conf"
        self.assertIn("/documentdb.conf'", hook_path.read_text(encoding="utf-8"))

    def test_tune_adds_include_line_for_existing_debian_clusters(self):
        """Issue 7 follow-up: tune must add the include_if_exists line
        to the live cluster's postgresql.conf for clusters that pre-date
        the createcluster.d hook; otherwise the fragment is silently
        unused."""
        tune_path = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-tune.sh"
        tune = tune_path.read_text(encoding="utf-8")
        self.assertIn("ensure_debian_include_line", tune)
        self.assertRegex(
            tune,
            r'include_marker_start="# >>> documentdb-tune managed include >>>"',
            "include line must be wrapped in its own managed-block markers",
        )

    def test_gateway_postrm_does_not_strip_pg_state(self):
        """Issue 8: the gateway runtime package's postrm must NOT
        mutate PostgreSQL-side managed blocks — that violates the
        runtime-only boundary per design §4.3."""
        postrm_path = (
            OSS_ROOT / "documentdb-local" / "maintainer-scripts"
            / "gateway" / "postrm"
        )
        postrm = postrm_path.read_text(encoding="utf-8")
        # The pre-Phase-11 postrm called documentdb_strip_managed_block
        # against pg_hba.conf / pg_ident.conf / postgresql.conf — that's
        # what we're removing.
        self.assertNotIn(
            "documentdb-setup managed hba",
            postrm,
            "gateway postrm must not touch pg_hba.conf",
        )
        self.assertNotIn(
            "documentdb-setup managed pg_ident",
            postrm,
            "gateway postrm must not touch pg_ident.conf",
        )
        self.assertNotIn(
            "documentdb-setup managed configuration",
            postrm,
            "gateway postrm must not touch postgresql.conf",
        )


class Phase12DesignParityAndOpsTests(unittest.TestCase):
    """Phase 12: implement the missing operational flags the design
    promised (--print-config, --status) and pin the design doc's flag
    list to what the wizard actually ships."""

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(SETUP_SCRIPT), *args],
            capture_output=True, text=True, timeout=10,
        )

    def test_print_config_emits_expected_keys(self):
        """--print-config must report mode, PG version/port, paths,
        templated systemd unit names, and delegated tools — read-only,
        no preflight."""
        r = self._run("--print-config", "--pg-version", "18")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        for needed in (
            "mode:",
            "GREENFIELD",
            "PG version:",
            "PG port:                       9718",
            "PG socket dir:                 /run/documentdb-local/18/postgresql",
            "PG data dir (greenfield):      /var/lib/documentdb-local/18/data",
            "documentdb-postgresql@18.service",
            "documentdb-gateway-local@18.service",
            "documentdb-local@18.target",
            "documentdb-local.target -> documentdb-local@18.target",
            "/etc/documentdb/local/18/setup.conf",
            "/etc/documentdb/local/18/brownfield.conf",
            "/var/lib/documentdb-local/18/gateway/pg-url",
            "documentdb-tune",
            "documentdb-register-gateway",
        ):
            self.assertIn(needed, out, f"--print-config missing '{needed}'")

    def test_print_config_brownfield_mode(self):
        """--print-config with --target-postgres-instance must report
        BROWNFIELD mode and include the targeted instance identifier."""
        r = self._run("--print-config", "--target-postgres-instance", "18/main")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("BROWNFIELD (18/main)", r.stdout)

    def test_print_config_performs_no_side_effects(self):
        """--print-config must not require root and must not touch the
        filesystem. The test runs as a non-root user; if any side-effect
        path runs, require_root inside preflight_validation would fire
        and fail the run."""
        r = self._run("--print-config", "--pg-version", "18")
        self.assertEqual(r.returncode, 0, r.stderr)
        # require_root prints "must be run as root"; its absence proves
        # the dispatch short-circuited before preflight.
        self.assertNotIn("must be run as root", r.stdout + r.stderr)

    def test_print_config_uses_per_major_target_for_non_default_major(self):
        """The public alias stays fixed to the paved-road major. For a
        non-default install, --print-config must point operators at the
        explicit per-major target instead of pretending the alias moves."""
        r = self._run("--print-config", "--pg-version", "17")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preferred day-2 target:      documentdb-local@17.target", r.stdout)
        self.assertIn("documentdb-local.target -> documentdb-local@18.target", r.stdout)
        self.assertNotIn("documentdb-local.target -> documentdb-local@17.target", r.stdout)

    def test_status_reports_unconfigured_when_no_state_file(self):
        """--status with no installation should report '<not configured>'
        and exit non-zero so scripts can gate."""
        r = self._run("--status", "--pg-version", "18")
        # Exit code 1 (or 0 with state); in this dev env there is no
        # /etc/documentdb/local/18/setup.conf so we expect non-zero.
        self.assertIn("documentdb-setup status", r.stdout)
        # Either reports unconfigured or finds nothing — both are
        # non-fatal for the test; we just confirm the status path runs.
        self.assertNotIn("must be run as root", r.stdout + r.stderr)

    def test_help_lists_print_config_and_status(self):
        """--help must advertise the operational flags we just added so
        operators can discover them."""
        r = self._run("--help")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--print-config", r.stdout)
        self.assertIn("--status", r.stdout)

    def test_design_doc_flag_list_matches_implementation(self):
        """Phase 12 parity check (reviewer issue 1): every flag the
        design doc's §4.4 "Key flags" section claims as a wizard CLI
        flag must actually appear in --help output. The previous design
        listed --pgdata / --tls-cert-file / --tls-key-file / --quiet /
        --update which were never implemented; this test pins the doc
        to reality going forward."""
        design_path = OSS_ROOT / "packaging" / "gateway" / "packaging-design.md"
        design = design_path.read_text(encoding="utf-8")
        # Find the "Key flags" section in §4.4 and pull out every
        # `--flag-name` token mentioned (excluding things that are
        # clearly env vars or commented as alias).
        m = re.search(
            r'Key flags[^\n]*:\n(?P<body>(?:.+?\n){0,40}?)\n(?:The bootstrap flags|Terminology in)',
            design, flags=re.DOTALL,
        )
        self.assertIsNotNone(m, "Key flags section not found in packaging-design.md")
        body = m.group("body")
        claimed = set(re.findall(r'`(--[a-z][a-z0-9-]*)`', body))
        # Strip flags that the design intentionally lists as deprecated
        # aliases — they still must be honored by the wizard, but their
        # canonical form is what the design teaches.
        deprecated_alias_marker = re.compile(
            r'`(--[a-z][a-z0-9-]*)`\s+\(.*?deprecated', re.IGNORECASE,
        )
        deprecated = set(deprecated_alias_marker.findall(body))
        claimed_non_deprecated = claimed - deprecated

        r = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        help_text = r.stdout

        missing = [f for f in sorted(claimed_non_deprecated) if f not in help_text]
        self.assertFalse(
            missing,
            "Design doc claims these wizard flags but they are missing "
            f"from --help: {missing}\n\nHelp output:\n{help_text}",
        )

    def test_design_doc_tool_inventory_includes_gateway_admin(self):
        """Phase 12 (reviewer issue 2): documentdb-gateway-admin is
        installed by documentdb-postgresql-tools but was missing from
        the §8 tool inventory."""
        design_path = OSS_ROOT / "packaging" / "gateway" / "packaging-design.md"
        design = design_path.read_text(encoding="utf-8")
        # Look for the row in the §8 table.
        self.assertRegex(
            design,
            r'\|\s*`documentdb-gateway-admin`\s*\|\s*`documentdb-postgresql-tools`',
            "Tool inventory must include documentdb-gateway-admin in documentdb-postgresql-tools",
        )


class BrownfieldGatewayDropInTests(unittest.TestCase):
    """packaging-design.md §4.4: brownfield's stand-alone target must order the
    gateway on the adopted PostgreSQL service, not the (skipped) per-major
    greenfield documentdb-postgresql@N.service. The wizard writes a per-instance
    systemd drop-in to make this true at the unit level (not just at wizard
    runtime). Reviewer-flagged gap from the second-pass packaging audit."""

    def test_wizard_defines_brownfield_dropin_writer(self):
        """The wizard must expose write_brownfield_gateway_dropin and
        remove_brownfield_gateway_dropin (so both apply and --restore wire
        through one code path)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("write_brownfield_gateway_dropin()", script,
                      "write_brownfield_gateway_dropin must be defined")
        self.assertIn("remove_brownfield_gateway_dropin()", script,
                      "remove_brownfield_gateway_dropin must be defined")

    def test_persist_brownfield_state_invokes_dropin_writer(self):
        """persist_brownfield_state must call write_brownfield_gateway_dropin
        so a brownfield apply actually installs the drop-in, not just the
        per-major state file."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"persist_brownfield_state\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "persist_brownfield_state body not found")
        self.assertIn(
            "write_brownfield_gateway_dropin",
            match.group("body"),
            "persist_brownfield_state must invoke the drop-in writer",
        )

    def test_dropin_path_matches_design(self):
        """The drop-in must live under
        /etc/systemd/system/documentdb-gateway-local@<N>.service.d/brownfield.conf
        — admin-owned tree so package upgrades never overwrite it."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/systemd/system/documentdb-gateway-local@${PG_VERSION}.service.d',
            script,
            "Drop-in directory path must match design",
        )
        self.assertIn(
            'brownfield.conf',
            script,
            "Drop-in file must be named brownfield.conf",
        )

    def test_dropin_resets_and_repoints_dependency_lists(self):
        """The drop-in must (a) reset Requires=/After= to drop the greenfield
        documentdb-postgresql@%i.service dep, and (b) re-point at the adopted
        PG service unit. Without the empty-string reset, systemd would append
        rather than replace."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r"Requires=\s*\n\s*After=\s*\n\s*Requires=\$\{adopted_pg_unit\}",
            "Drop-in must reset Requires= then set the adopted PG unit",
        )

    def test_debian_pg_service_unit_name_resolved_for_debian_layout(self):
        """On Debian-like layouts (/etc/postgresql/<V> present) the adopted PG
        service unit must be postgresql@<V>-<C>.service."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"resolve_brownfield_pg_service_unit\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "resolve_brownfield_pg_service_unit not found")
        body = match.group("body")
        self.assertIn('postgresql@%s-%s.service', body,
                      "Debian-style unit name (postgresql@V-C.service) must be used")
        self.assertIn('postgresql-%s.service', body,
                      "RHEL-style unit name (postgresql-V.service) must be the fallback")

    def test_restore_path_removes_brownfield_dropin(self):
        """--restore must iterate brownfield.conf state files and invoke
        remove_brownfield_gateway_dropin so a re-adopt of a different PG
        instance starts from a clean unit-file view."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("/etc/documentdb/local/*/brownfield.conf", script,
                      "--restore must look for brownfield.conf state files")
        self.assertRegex(
            script,
            r"remove_brownfield_gateway_dropin\s+\"\$\{bf_major\}\"",
            "--restore must invoke remove_brownfield_gateway_dropin for each brownfield state",
        )

    def test_deb_postrm_strips_brownfield_dropin_directory(self):
        """The DEB postrm in build-standalone-deb.sh must remove the drop-in
        directory on full purge so the unit-file view is clean after uninstall.
        Reviewer-flagged (GPT-5 iter 3): the cleanup is scoped to the
        package's own PG major via the ${PKG_PG_VERSION} substitution so a
        co-installed documentdb-N for another major is not disturbed."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # The postrm heredoc references the substituted shell variable.
        self.assertIn(
            '/etc/systemd/system/documentdb-gateway-local@${PKG_PG_VERSION}.service.d',
            text,
            "DEB postrm must sweep the per-major brownfield drop-in dir scoped to PKG_PG_VERSION",
        )
        self.assertIn(
            'rm -f "${brownfield_file}"',
            text,
            "DEB postrm sweep must remove the brownfield.conf drop-in",
        )
        # Guard against regression to the wildcard form that touched other majors.
        self.assertNotIn(
            'for dropin_dir in /etc/systemd/system/documentdb-gateway-local@*.service.d',
            text,
            "DEB postrm must NOT iterate all majors — that would tear down co-installed documentdb-N for other PG versions",
        )

    def test_rpm_postun_strips_brownfield_dropin_directory(self):
        """The RPM %postun in documentdb-local.spec must remove the drop-in
        directory on full uninstall for the same reason."""
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/systemd/system/documentdb-gateway-local@%{pg_version}.service.d',
            text,
            "RPM %postun must clean up the per-major brownfield drop-in directory",
        )

    def test_target_cluster_strict_slash_validation(self):
        """Reviewer-flagged bug: --target-postgres-instance without a slash
        (e.g. just '18') would silently pass the old validator because both
        ${TARGET_CLUSTER%%/*} and ${TARGET_CLUSTER#*/} return the whole
        string when there is no slash, producing a broken
        postgresql@18-18.service Requires= in the drop-in. The wizard must
        now reject this up front and the resolver must double-check."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Strict slash check at the top of prepare_brownfield_instance.
        self.assertRegex(
            script,
            r'if \[\[ "\$\{TARGET_CLUSTER\}" != \*/\* \]\]; then\s+die',
            "prepare_brownfield_instance must reject --target-postgres-instance without a slash",
        )
        # And again in the resolver as defense in depth.
        self.assertRegex(
            script,
            r'resolve_brownfield_pg_service_unit\(\)[\s\S]+?\[\[ "\$\{TARGET_CLUSTER\}" == \*/\* \]\]',
            "resolve_brownfield_pg_service_unit must defensively re-validate the slash form",
        )

    def test_target_cluster_strict_cluster_name_validation(self):
        """The cluster name (the part after the slash) becomes part of the
        systemd unit name (postgresql@V-C.service) and is interpolated into
        shell strings via runuser, so it must be restricted to a PostgreSQL
        identifier form. Without this, --target-postgres-instance '18/$(rm /)'
        would interpolate unchecked into the drop-in. The shape must match
        what Debian's pg_createcluster permits (alphanumeric first char) so
        the wizard never rejects an existing valid cluster like '1replica'."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'target_cluster_name.*=~.*\^\[A-Za-z0-9\]\[A-Za-z0-9_-\]\*\$',
            "Cluster name must be a safe identifier matching pg_createcluster's rules",
        )


class StandalonePackageMaintainerScriptTests(unittest.TestCase):
    """packaging-design.md §6 row "Restart active gateway service on upgrade:
    documentdb-N install: Yes (gateway side only)" + §7 "Maintainer scripts
    restart PostgreSQL: Never". The DEB postinst and RPM %posttrans must
    restart only the gateway-local templated instance on upgrade, never the
    per-major target (which would bounce the underlying PG too)."""

    def test_deb_standalone_postinst_restarts_only_gateway_on_upgrade(self):
        """Standalone DEB postinst on upgrade ($2 is the previously-installed
        version) must restart documentdb-gateway-local@N.service only — not
        the per-major target."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # Upgrade-gated restart present. After Gap #22 fix, the systemd
        # detection now uses { [ -d /run/systemd/system ] && command -v
        # systemctl ...; } compound. Both forms are accepted.
        self.assertRegex(
            text,
            r'if \[ -n "\\?\${2:-}" \] && (?:command -v systemctl|\{ \[ -d /run/systemd/system \] && command -v systemctl)',
            "DEB postinst must gate restart on upgrade (\\$2 is set) AND a working systemd",
        )
        # Restart targets the gateway-local unit, not the target.
        self.assertRegex(
            text,
            r'systemctl restart "\\?\$\{gw_unit\}"',
            "DEB postinst must restart the gateway-local unit on upgrade",
        )
        # Belt and braces: ensure the postinst does NOT restart the target.
        self.assertNotRegex(
            text,
            r'systemctl restart "documentdb-local@.*\.target"',
            "DEB postinst must NOT restart the per-major target (would bounce PG)",
        )

    def test_rpm_standalone_posttrans_restarts_only_gateway(self):
        """Same contract on the RPM side: %posttrans restarts the gateway-
        local instance, never the per-major target."""
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        # Match a single %posttrans block.
        match = re.search(r"%posttrans\s*\n(?P<body>.*?)(?=^%|\Z)", text,
                          flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(match, "documentdb-local.spec must define %posttrans")
        body = match.group("body")
        self.assertIn(
            'systemctl restart "documentdb-gateway-local@%{pg_version}.service"',
            body,
            "%posttrans must restart the gateway-local unit on upgrade",
        )
        self.assertNotRegex(
            body,
            r'systemctl restart "documentdb-local@.*\.target"',
            "%posttrans must NOT restart the per-major target (would bounce PG, violates §7)",
        )


class RegisterGatewayAutoDetectTests(unittest.TestCase):
    """packaging-design.md §5 Workflow B step (3): documentdb-register-gateway
    must auto-detect when there is exactly one PostgreSQL instance on the
    host (the typical case), and fail loudly when there are zero or many."""

    def test_help_text_advertises_autodetect(self):
        """Operators discover the auto-detect via --help. The help must say
        so explicitly so the design promise isn't a hidden behavior."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "exactly one PostgreSQL instance on the host",
            text,
            "Help text must advertise the auto-detect behavior",
        )

    def test_autodetect_function_present(self):
        """The autodetect helper exists and is invoked from parse_arguments
        when neither --target-postgres-instance nor --pgdata is given."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "autodetect_single_pg_instance()",
            text,
            "autodetect_single_pg_instance() helper must be defined",
        )
        # The wiring point: autodetect must run from the no-explicit-target
        # fall-through path inside parse_arguments. Match across whitespace
        # without depending on the exact comment formatting.
        match = re.search(
            r"parse_arguments\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "parse_arguments body not found")
        self.assertIn(
            "autodetect_single_pg_instance",
            match.group("body"),
            "parse_arguments must invoke autodetect_single_pg_instance when no target is given",
        )

    def test_autodetect_refuses_when_multiple_pg_instances(self):
        """When pg_lsclusters / /etc/postgresql/<V>/<C>/ enumerate more than
        one instance, the script must NOT silently pick one — it must fail
        with a message that lists the candidates so the operator picks."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Check the multi-instance branch returns failure rather than picking [0].
        match = re.search(
            r"autodetect_single_pg_instance\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "autodetect_single_pg_instance body not found")
        body = match.group("body")
        self.assertRegex(
            body,
            r'\(\(\s*\$\{#candidates\[@\]\}\s*>\s*1\s*\)\)',
            "Auto-detect must explicitly handle the >1-candidate case",
        )
        self.assertRegex(
            body,
            r'multiple PostgreSQL instances found',
            "Auto-detect's multi-instance error message must enumerate candidates",
        )

    def test_autodetect_validates_cluster_name_safely(self):
        """Candidate cluster names (from pg_lsclusters output or directory
        enumeration) must be filtered through a safe identifier regex so a
        maliciously-named directory cannot inject a unit name fragment
        downstream. Shape must match pg_createcluster (alphanumeric first
        char) so existing legal clusters like '1replica' are not filtered
        out of the auto-detect candidate list."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"autodetect_single_pg_instance\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertRegex(
            body,
            r'cluster.*=~.*\^\[A-Za-z0-9\]\[A-Za-z0-9_-\]\*\$',
            "Auto-detect must use pg_createcluster's identifier shape",
        )

    def test_autodetect_handles_rhel_layout(self):
        """The RHEL/Fedora PGDG layout uses /var/lib/pgsql/<V>/data/ rather
        than /etc/postgresql/<V>/<C>/. Auto-detect must walk that path on
        RHEL or it would never resolve a candidate on the RPM-family OSes."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"autodetect_single_pg_instance\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "/var/lib/pgsql",
            body,
            "Auto-detect must enumerate RHEL-style /var/lib/pgsql/<V>/data",
        )


class BrownfieldClusterIdentityValidationTests(unittest.TestCase):
    """Reviewer-flagged bug (GPT-5 second pass): --target-postgres-instance
    V/NAME on Debian must refuse if /etc/postgresql/V/NAME doesn't exist,
    and after live-discovery must cross-check that the connected instance's
    config_file actually lives under that cluster's config dir. Otherwise a
    typo causes the wizard to mutate one cluster's config while wiring the
    systemd drop-in to a different cluster."""

    def test_debian_cluster_dir_existence_check(self):
        """Up-front check that the named Debian cluster's /etc/postgresql/V/N
        directory exists before any psql/SHOW round-trip."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'if [[ ! -d "/etc/postgresql/${PG_VERSION}/${target_cluster_name}" ]]; then',
            script,
            "Must check the named Debian cluster directory before proceeding",
        )
        self.assertIn(
            "Brownfield: PostgreSQL ${PG_VERSION} cluster '${target_cluster_name}' not found",
            script,
            "Error message must name the missing cluster so the operator sees the typo",
        )

    def test_rhel_data_dir_existence_check(self):
        """RHEL/Fedora analog: refuse if /var/lib/pgsql/V/data is missing
        (PGDG packages create this on initdb)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'\[\[ ! -d "/var/lib/pgsql/\$\{PG_VERSION\}/data" \]\]',
            "Must check RHEL PGDG data directory existence",
        )

    def test_live_config_file_cluster_membership_verified(self):
        """After SHOW config_file, the live instance's config_file path must
        live under /etc/postgresql/<V>/<target_cluster_name>/ — otherwise we
        are connected to a different cluster than the operator named."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'Refusing to adopt the wrong cluster',
            script,
            "Must die with a clear message when live config_file is outside the named cluster",
        )


class StandalonePurgeOrphanSweepTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 second pass): the package's postrm / %postun
    orphan sweep must cover gateway.env and /run/.../pg-url, not just the
    brownfield drop-in. Otherwise --restore followed by purge leaves
    operator-visible files behind."""

    def test_deb_postrm_sweeps_orphaned_gateway_env(self):
        """DEB postrm per-major env strip must clean gateway.env left behind
        by --restore. Reviewer-flagged (GPT-5 iter 3): scoped to the
        package's own PG major (per_major_env = .../<PKG_PG_VERSION>/gateway.env)
        so co-installed majors keep their env."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn(
            'per_major_env="/etc/documentdb/local/${PKG_PG_VERSION}/gateway.env"',
            text,
            "DEB postrm must scope gateway.env cleanup to PKG_PG_VERSION",
        )
        # Guard against regression to the wildcard form.
        self.assertNotIn(
            'for per_major_env in /etc/documentdb/local/*/gateway.env',
            text,
            "DEB postrm must NOT iterate all majors when cleaning gateway.env",
        )

    def test_rpm_postun_sweeps_orphaned_gateway_env(self):
        """Mirror check for RPM %postun."""
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            'per_major_env="/etc/documentdb/local/%{pg_version}/gateway.env"',
            text,
            "RPM %postun must unconditionally sweep the per-major gateway.env",
        )

    def test_restore_strips_brownfield_gateway_env_and_pgurl(self):
        """--restore must clean gateway.env + pg-url for each brownfield
        state, not just the brownfield drop-in. The postrm sweep is a
        backstop; --restore should be the primary path."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'bf_env_file="${bf_dir}/gateway.env"',
            script,
            "--restore must process the per-major gateway.env fragment",
        )
        # After iter-11 pg-url lives at /var/lib/.../pg-url (persistent),
        # but --restore must clean BOTH the new path AND the legacy /run/
        # path for upgrade-safe behavior.
        self.assertIn(
            '/run/documentdb-local/${bf_major}/gateway/pg-url',
            script,
            "--restore must clean the legacy /run/ pg-url path (for pre-iter11 hosts)",
        )
        self.assertIn(
            '/var/lib/documentdb-local/${bf_major}/gateway/pg-url',
            script,
            "--restore must clean the current /var/lib pg-url path",
        )

    def test_remove_brownfield_dropin_is_symmetric_with_writer(self):
        """Reviewer-flagged (Sonnet second pass): write_brownfield_gateway_dropin
        does systemctl daemon-reload after installing the drop-in.
        remove_brownfield_gateway_dropin must do the same after removing it, so
        any future caller (not just --restore which does its own reload) gets a
        consistent unit-file view."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"remove_brownfield_gateway_dropin\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "remove_brownfield_gateway_dropin body not found")
        body = match.group("body")
        self.assertIn(
            "systemctl daemon-reload",
            body,
            "Remover must call daemon-reload symmetrically with the writer",
        )
        # Only reload if we actually removed something — avoid spurious
        # reloads when --restore iterates per-major dirs that have no drop-in.
        self.assertIn(
            'existed=true',
            body,
            "Remover should track whether the drop-in actually existed before reloading",
        )

    def test_brownfield_adoption_warning_present(self):
        """packaging-design.md §4.4 Safety Properties: "Warn loudly when
        adopting a postgres-owned PostgreSQL instance...require confirmation.
        Don't refuse." The brownfield path must emit an explicit warning and
        prompt before mutating an existing PG owned by a non-root OS user."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The warning lives inside prepare_brownfield_instance (after the
        # cluster-membership cross-check).
        match = re.search(
            r"prepare_brownfield_instance\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "prepare_brownfield_instance body not found")
        body = match.group("body")
        self.assertIn(
            'Adopting an existing PostgreSQL instance owned by OS user',
            body,
            "Brownfield must warn loudly when adopting another OS user's PG",
        )
        # Interactive prompt with --yes bypass.
        self.assertIn(
            'Adopt this PostgreSQL instance and continue? [y/N]',
            body,
            "Brownfield must prompt for adoption confirmation in interactive mode",
        )
        # --yes branch is non-interactive but still logs the warning loudly.
        self.assertIn(
            'Proceeding non-interactively because --yes was given.',
            body,
            "Brownfield must explicitly log that --yes bypassed the prompt",
        )

    def test_brownfield_register_gateway_call_uses_target_postgres_instance(self):
        """Reviewer-flagged (GPT-5 iter 2): on Debian brownfield, the HBA/
        ident files live at /etc/postgresql/<V>/<C>/, NOT under the data
        dir. Passing --pgdata "${LIVE_DATA_DIR}" makes register-gateway
        look for /var/lib/postgresql/<V>/<C>/pg_hba.conf which doesn't
        exist on Debian. ensure_pg_ident_map must branch on TARGET_CLUSTER:
        brownfield → --target-postgres-instance; greenfield → --pgdata."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "ensure_pg_ident_map body not found")
        body = match.group("body")
        # Branch on brownfield/greenfield.
        self.assertIn(
            'if [[ -n "${TARGET_CLUSTER}" ]]; then',
            body,
            "Must branch on TARGET_CLUSTER to choose the right register-gateway flags",
        )
        self.assertIn(
            '--target-postgres-instance "${TARGET_CLUSTER}"',
            body,
            "Brownfield path must pass --target-postgres-instance",
        )
        # Greenfield still uses --pgdata (its data dir IS where hba/ident live).
        self.assertIn(
            '--pgdata "${LIVE_DATA_DIR}"',
            body,
            "Greenfield path must still pass --pgdata (initdb places hba/ident there)",
        )




class RegisterGatewayPortResolutionTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 2): when --target-postgres-instance or
    auto-detect names a specific cluster, register-gateway must discover the
    cluster's actual TCP port before defaulting to 5432. Otherwise HBA/ident
    edits go to one cluster while psql ops hit whatever's on 5432."""

    def test_resolver_present(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'resolve_target_cluster_port()',
            text,
            "resolve_target_cluster_port helper must be defined",
        )

    def test_resolver_invoked_before_5432_fallback(self):
        """The resolver call must precede the [[ -z PG_PORT ]] && PG_PORT=5432
        line in main(), or the 5432 default would still win."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r'^main\(\) \{(?P<body>.*?)^\}',
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "main() body not found")
        body = match.group("body")
        resolver_idx = body.find('resolve_target_cluster_port')
        fallback_idx = body.find('PG_PORT="5432"')
        self.assertGreater(resolver_idx, 0, "Resolver must be invoked from main()")
        self.assertGreater(fallback_idx, resolver_idx,
                           "Resolver must run BEFORE the 5432 fallback")

    def test_resolver_reads_debian_postgresql_conf(self):
        """The resolver must parse /etc/postgresql/<V>/<C>/postgresql.conf
        on Debian — that's the canonical source for per-cluster port."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}/postgresql.conf',
            text,
            "Resolver must read the named Debian cluster's postgresql.conf",
        )


class RegisterGatewayRecoveryMarkerTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 2): persist a recovery marker BEFORE the
    first HBA/ident write. Without this, a mid-flow SIGTERM leaves managed
    blocks in PG config files with no state-file pointer for the package's
    postrm sweep to find."""

    def test_recovery_marker_helper_defined(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'write_recovery_marker()',
            text,
            "write_recovery_marker helper must be defined",
        )

    def test_recovery_marker_called_before_hba_write(self):
        """The marker write must precede the first prepend_with_managed_block
        call so a SIGTERM between them still leaves a state-file pointer."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_setup\(\) \{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "do_setup body not found")
        body = match.group("body")
        marker_idx = body.find('write_recovery_marker')
        hba_idx = body.find('prepend_with_managed_block')
        self.assertGreater(marker_idx, 0, "write_recovery_marker must be invoked")
        self.assertGreater(hba_idx, marker_idx,
                           "Recovery marker must be written BEFORE the HBA edit")


class GreenfieldRestoreSymmetryTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 2): greenfield --restore must strip the
    per-major gateway.env fragment, drop-in, and pg-url tmpfs file, same as
    brownfield --restore does."""

    def test_greenfield_restore_strips_gateway_env(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The greenfield restore loop processes setup.conf (vs. brownfield's
        # brownfield.conf). Look for the per-major env-strip inside that loop.
        match = re.search(
            r"for per_major_conf in /etc/documentdb/local/\*/setup\.conf;.*?(?=for per_major_brownfield)",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, "Greenfield restore loop not found")
        body = match.group(0)
        self.assertIn(
            'pm_env_file="${pm_dir}/gateway.env"',
            body,
            "Greenfield --restore must clean per-major gateway.env",
        )
        # After iter-11 pg-url is at /var/lib (persistent); legacy /run/
        # path also cleaned for upgrade safety.
        self.assertIn(
            '/run/documentdb-local/${pm_major}/gateway/pg-url',
            body,
            "Greenfield --restore must clean the legacy /run/ pg-url (for pre-iter11 hosts)",
        )
        self.assertIn(
            '/var/lib/documentdb-local/${pm_major}/gateway/pg-url',
            body,
            "Greenfield --restore must clean the current /var/lib pg-url",
        )
        self.assertIn(
            'remove_brownfield_gateway_dropin "${pm_major}"',
            body,
            "Greenfield --restore must invoke the drop-in remover too (defensive)",
        )


class GatewayCiPavedRoadTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 2): the gateway build/test/upload CI
    steps were pinned to pg_version=='17'. The paved road per
    packaging-design.md §9.1 is PG 18, so on main pushes the paved-road
    combination was never being exercised. Both workflows must gate on '18'."""

    def test_deb_workflow_gates_gateway_on_pg18(self):
        wf = OSS_ROOT / ".github" / "workflows" / "build_deb_packages.yml"
        text = wf.read_text(encoding="utf-8")
        self.assertNotIn(
            "matrix.pg_version == '17'",
            text,
            "Gateway build must not gate on pg17 — the paved road is pg18 (§9.1)",
        )
        self.assertIn(
            "matrix.pg_version == '18'",
            text,
            "Gateway build must gate on pg18 per packaging-design.md §9.1",
        )

    def test_rpm_workflow_gates_gateway_on_pg18(self):
        wf = OSS_ROOT / ".github" / "workflows" / "build_rpm_packages.yml"
        text = wf.read_text(encoding="utf-8")
        self.assertNotIn(
            "matrix.pg_version == '17'",
            text,
            "Gateway build must not gate on pg17 — the paved road is pg18 (§9.1)",
        )
        self.assertIn(
            "matrix.pg_version == '18'",
            text,
            "Gateway build must gate on pg18 per packaging-design.md §9.1",
        )


class GatewayRpmPosttransRestartsLocalInstancesTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 2): documentdb-gateway DEB postinst
    restarts active documentdb-gateway-local@N instances after upgrade, but
    the RPM %posttrans only restarted the plain documentdb-gateway.service.
    Stand-alone per-major instances on RPM hosts would run the old binary
    until manually restarted."""

    def test_rpm_gateway_posttrans_iterates_local_instances(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec"
        text = spec.read_text(encoding="utf-8")
        match = re.search(r"%posttrans\s*\n(?P<body>.*?)(?=^%|\Z)", text,
                          flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "documentdb-gateway-local@*.service",
            body,
            "RPM %posttrans must enumerate active per-major gateway-local instances",
        )
        self.assertIn(
            "systemctl restart",
            body,
            "RPM %posttrans must restart enumerated instances",
        )


class DebianMaintainerBootstrapPathTests(unittest.TestCase):
    """The DEB maintainer scripts rely on shipped sysusers/tmpfiles.d
    files. They must point the systemd helpers at the installed paths and
    still fall back locally if those helpers are unavailable or fail."""

    def test_gateway_postinst_uses_installed_sysusers_and_tmpfiles_paths(self):
        text = GATEWAY_POSTINST.read_text(encoding="utf-8")
        self.assertIn(
            "/usr/lib/sysusers.d/documentdb-gateway.conf",
            text,
            "Gateway postinst must pass the installed sysusers.d path",
        )
        self.assertIn(
            "/usr/lib/tmpfiles.d/documentdb-gateway.conf",
            text,
            "Gateway postinst must pass the installed tmpfiles.d path",
        )
        self.assertIn(
            "ensure_gateway_user()",
            text,
            "Gateway postinst must keep a manual user fallback if sysusers fails",
        )
        self.assertIn(
            "ensure_gateway_tmpfiles()",
            text,
            "Gateway postinst must keep a manual tmpfiles fallback if tmpfiles fails",
        )

    def test_standalone_builder_uses_installed_sysusers_and_tmpfiles_paths(self):
        text = STANDALONE_BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "/usr/lib/sysusers.d/documentdb-local.conf",
            text,
            "Standalone DEB postinst must pass the installed sysusers.d path",
        )
        self.assertIn(
            "/usr/lib/tmpfiles.d/documentdb-local.conf",
            text,
            "Standalone DEB postinst must pass the installed tmpfiles.d path",
        )
        self.assertIn(
            "groupadd --system documentdb-local",
            text,
            "Standalone DEB postinst must retain a manual user fallback",
        )


class GatewayDockerImageCiConsistencyTests(unittest.TestCase):
    """Reviewer-flagged (Haiku iter 3): build_gateway.yml had `--pg 17`
    hard-coded for the gateway build step even though the workflow iterates
    matrix.pg_version 15-18 to produce a documentdb-local Docker image per
    major. The mismatch let the gateway artifact and extension artifact
    diverge in their PG build context. Must use the matrix value."""

    def test_build_gateway_yml_uses_matrix_pg_version(self):
        wf = OSS_ROOT / ".github" / "workflows" / "build_gateway.yml"
        text = wf.read_text(encoding="utf-8")
        self.assertNotIn(
            "--pg 17 --output-dir",
            text,
            "Gateway image build must not hard-code --pg 17; use ${{ matrix.pg_version }}",
        )
        self.assertIn(
            "--pg ${{ matrix.pg_version }} --output-dir",
            text,
            "Gateway image build must match the matrix PG major",
        )


class StateModeBrownfieldTriggerTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 3): in brownfield mode register-gateway
    must write brownfield.conf, NOT setup.conf. The greenfield templated PG
    service has ConditionPathExists=/etc/documentdb/local/%i/setup.conf, so
    if brownfield setup wrote setup.conf the greenfield PG service would
    become activatable and could trample the adopted PG service's lifecycle."""

    def test_register_gateway_supports_state_mode_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--state-mode', text,
                      "register-gateway must accept --state-mode")
        self.assertIn('STATE_MODE="greenfield"', text,
                      "Default state mode must remain greenfield for back-compat")
        self.assertRegex(text, r'greenfield\|brownfield', "Must validate mode value")

    def test_register_gateway_writes_brownfield_conf_when_mode_brownfield(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'STATE_FILE="/etc/documentdb/local/${PG_VERSION}/brownfield.conf"',
            text,
            "Brownfield state mode must produce brownfield.conf (avoids ConditionPathExists trigger)",
        )
        self.assertIn(
            'STATE_FILE="/etc/documentdb/local/${PG_VERSION}/setup.conf"',
            text,
            "Default/greenfield state mode must still produce setup.conf",
        )

    def test_setup_passes_brownfield_state_mode_in_brownfield(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '--target-postgres-instance "${TARGET_CLUSTER}" --state-mode brownfield',
            body,
            "Brownfield invocation must pass --state-mode brownfield",
        )
        # After iter-11 the greenfield call also threads --pg-version.
        self.assertIn(
            '--pgdata "${LIVE_DATA_DIR}" --pg-version "${PG_VERSION}" --state-mode greenfield',
            body,
            "Greenfield invocation must pass --pg-version and --state-mode greenfield",
        )


class RecoveryMarkerFailureHandlingTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 3): write_recovery_marker must die on
    mktemp / write / mv failure rather than silently return. Otherwise the
    caller proceeds to HBA/ident edits without a recoverable state-file
    pointer."""

    def test_recovery_marker_dies_on_mktemp_failure(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_recovery_marker\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # The only legitimate `|| return 0` is the empty-STATE_FILE guard
        # at the top. The mktemp/write/mv operations must all `|| die` so
        # the caller doesn't proceed without a recoverable state-file
        # pointer.
        self.assertIn('die "Cannot create recovery marker at', body,
                      "mktemp failure must die with a clear error")
        self.assertIn('die "Cannot write recovery marker contents to', body,
                      "stdout write failure must die")
        self.assertIn('die "Cannot rename recovery marker into place', body,
                      "mv failure must die")


class ClusterIdentityVerificationTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 3): register-gateway must verify
    SHOW config_file matches the named cluster after psql connection.
    Catches stale --pg-port, mid-flow port changes, and overlapping
    bind addresses."""

    def test_verifier_helper_defined(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('verify_psql_connects_to_named_cluster()', text,
                      "Cluster identity verifier helper must be defined")

    def test_verifier_called_before_hba_write(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_setup\(\) \{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        verifier_idx = body.find('verify_psql_connects_to_named_cluster')
        hba_idx = body.find('prepend_with_managed_block')
        self.assertGreater(verifier_idx, 0, "Verifier must be invoked from do_setup")
        self.assertGreater(hba_idx, verifier_idx,
                           "Verifier must run BEFORE the HBA write")

    def test_verifier_dies_on_mismatch(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"verify_psql_connects_to_named_cluster\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('Cluster identity check failed', body,
                      "Mismatch must produce a clear error message")
        self.assertIn('Refusing to edit HBA/ident', body,
                      "Mismatch error must explain the refusal")


class BrownfieldDropinMarkerCheckTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 3): the orphan sweep must only delete
    a brownfield.conf file that carries our generated-by marker, so an
    operator-authored override under the same filename survives purge."""

    def test_deb_postrm_checks_marker_before_delete(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # The sweep must grep for the marker before rm -f.
        self.assertIn(
            'grep -Fq "# Generated by documentdb-setup --target-postgres-instance"',
            text,
            "DEB postrm orphan sweep must check generated-by marker before delete",
        )


class StandaloneDebPostrmPerMajorScopingTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 3): purging one DEB documentdb-N must
    not tear down state for co-installed documentdb-M packages. The postrm
    is generated with a substituted ${PKG_PG_VERSION} placeholder so it
    only touches its own major's state."""

    def test_postrm_template_uses_placeholder(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn("PKG_PG_VERSION='__PG_VERSION__'", text,
                      "Postrm template must declare the PKG_PG_VERSION placeholder")
        self.assertIn(
            'sed -i "s|__PG_VERSION__|${PG_VERSION}|g" "${PKG_DIR}/DEBIAN/postrm"',
            text,
            "Placeholder must be substituted at build time",
        )

    def test_postrm_no_wildcard_per_major_paths(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # Extract just the postrm heredoc so the test isn't tricked by
        # the surrounding shell script using these wildcards safely (e.g.,
        # the "other_majors_remain" probe legitimately enumerates all
        # majors as a read-only check, not as a cleanup loop).
        postrm_match = re.search(
            r"cat > \"\$\{PKG_DIR\}/DEBIAN/postrm\" <<'POSTRM'\n(?P<body>.*?)\nPOSTRM\n",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(postrm_match, "DEB postrm heredoc not found")
        body = postrm_match.group("body")
        # Cleanup loops must scope to PKG_PG_VERSION — wildcard cleanup
        # patterns iterate other majors and break co-installs.
        self.assertNotRegex(
            body,
            r'for [a-zA-Z_]+ in /etc/documentdb/local/\*/setup\.conf;',
            "Postrm must not iterate setup.conf cleanup across all majors",
        )
        self.assertNotRegex(
            body,
            r'for [a-zA-Z_]+ in /etc/documentdb/local/\*/brownfield\.conf;',
            "Postrm must not iterate brownfield.conf cleanup across all majors",
        )
        self.assertNotIn(
            'rm -f /run/documentdb-local/*/gateway/pg-url',
            body,
            "Postrm must not remove pg-url across all majors",
        )
        # The read-only "other_majors_remain" probe IS allowed to enumerate
        # all majors — it just checks whether any other documentdb-N is
        # still installed before removing the shared
        # /etc/documentdb/documentdb-postgresql.env file.
        self.assertIn(
            'other_majors_remain',
            body,
            "Postrm must probe for other co-installed majors before removing shared state",
        )


class AwkPortParserBugfixTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 3): the awk port-extraction script's
    gsub regex `[[:space:]#].*` ate the entire value because of the leading
    whitespace after `=`. Fixed by stripping leading whitespace separately
    before stripping trailing whitespace/comment. This test guards against
    regression in both register-gateway and setup."""

    def test_register_gateway_awk_strips_leading_whitespace(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The fixed form does TWO gsubs: leading whitespace first, then
        # trailing whitespace/comment. The old form did only the second.
        self.assertIn(
            'gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2)',
            text,
            "Port awk parser must strip leading whitespace before trailing comment",
        )

    def test_setup_awk_strips_leading_whitespace(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2)',
            script,
            "Setup's port awk parser must also use the two-step strip pattern",
        )


class BrownfieldLegacySetupConfCleanupTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 4): pre-iter3 brownfield runs wrote
    setup.conf (which has the wrong ConditionPathExists semantics for
    brownfield). On upgraded hosts, that stale file still triggers the
    greenfield PG service. persist_brownfield_state must delete it."""

    def test_persist_brownfield_state_removes_legacy_setup_conf(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"persist_brownfield_state\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('legacy_setup_conf="${per_major_dir}/setup.conf"', body,
                      "Must declare the legacy setup.conf path")
        self.assertIn('rm -f "${legacy_setup_conf}"', body,
                      "Must remove the legacy setup.conf so greenfield PG service stays silent")


class RegisterGatewayStateModeAutoSelectTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 4): operators running
    documentdb-register-gateway directly with --target-postgres-instance
    (a brownfield invocation) should not have to remember --state-mode.
    The tool auto-defaults to brownfield when --target-postgres-instance
    is set unless --state-mode was passed explicitly."""

    def test_state_mode_tracks_explicit_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('STATE_MODE_EXPLICIT=false', text,
                      "STATE_MODE_EXPLICIT tracking var must be declared")
        self.assertIn('STATE_MODE_EXPLICIT=true', text,
                      "Parser must set STATE_MODE_EXPLICIT=true when --state-mode is used")

    def test_auto_default_to_brownfield_when_target_set(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The auto-default block runs after parse_arguments fall-through.
        self.assertIn(
            'if [[ "${STATE_MODE_EXPLICIT}" != "true" ]]; then',
            text,
            "Auto-default must only kick in when --state-mode was not explicit",
        )
        self.assertRegex(
            text,
            r'if \[\[ -n "\$\{TARGET_CLUSTER\}" \]\]; then\s+STATE_MODE="brownfield"',
            "Auto-default must select brownfield when --target-postgres-instance is set",
        )

    def test_help_documents_state_mode(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--state-mode MODE', text,
                      "--help must document --state-mode")
        self.assertIn('Default: greenfield, unless', text,
                      "--help must explain the auto-default behavior")


class LegacyPostgresEnvFileCleanupTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 4): the legacy
    /etc/documentdb/documentdb-postgresql.env was never cleaned up by
    purge or %postun, so a stale file could persist after uninstall and
    confuse a future install. Only remove it when no other per-major
    install remains."""

    def test_deb_postrm_cleans_legacy_postgres_env_when_last_install(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/documentdb/documentdb-postgresql.env',
            text,
            "DEB postrm must reference the legacy postgres env file",
        )
        self.assertIn(
            'other_majors_remain',
            text,
            "DEB postrm must guard the removal with an other-majors probe",
        )

    def test_rpm_postun_cleans_legacy_postgres_env_when_last_install(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/documentdb/documentdb-postgresql.env',
            text,
            "RPM %postun must reference the legacy postgres env file",
        )
        self.assertIn(
            'other_majors_remain',
            text,
            "RPM %postun must guard the removal with an other-majors probe",
        )


class GatewayAdminBrownfieldStateAutoDetectTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 4): documentdb-gateway-admin's
    auto_detect_connection() only iterated setup.conf, so day-2 admin
    commands defaulted to port 5432 on hosts where the wizard ran in
    brownfield mode (state was in brownfield.conf, not setup.conf)."""

    def test_admin_autodetect_iterates_brownfield_conf(self):
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/documentdb/local/*/brownfield.conf',
            text,
            "documentdb-gateway-admin auto-detect must also iterate brownfield.conf",
        )

    def test_admin_autodetect_uses_distro_socket_for_brownfield(self):
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        # Brownfield mode means adopted system PG, so the connection
        # socket dir is the distro's /var/run/postgresql (not the
        # appliance's /run/documentdb-local/N/postgresql).
        self.assertIn('DOCUMENTDB_MODE=', text,
                      "Auto-detect must read the mode marker")
        self.assertIn('"brownfield"', text,
                      "Auto-detect must branch on the brownfield marker")
        self.assertIn('/var/run/postgresql', text,
                      "Brownfield branch must use the distro socket dir")

    def test_admin_create_user_reads_password_from_file_in_jq(self):
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"cmd_create_user\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '--rawfile pwd "${RESOLVED_PASSWORD_FILE}"',
            body,
            "create-user must pass the password to jq via --rawfile from a file path "
            "(resolve_password_to_file materializes either --password-file or "
            "--password-stdin into RESOLVED_PASSWORD_FILE before this call); "
            "the literal secret must never appear in argv",
        )
        self.assertNotIn(
            "--arg pwd",
            body,
            "create-user must not pass the password value through jq argv",
        )

    def test_register_gateway_state_file_includes_port_and_owner(self):
        """For the admin tool's auto-detect to work, register-gateway's
        state file must persist PG_PORT and PG_OWNER. Previously only
        the wizard's brownfield.conf did, so a direct Workflow B
        invocation left admin commands stuck at port 5432."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn("printf 'PG_PORT=%s\\n'", body,
                      "record_state must persist PG_PORT for the admin auto-detect")
        self.assertIn("printf 'PG_OWNER=%s\\n'", body,
                      "record_state must persist PG_OWNER for the admin auto-detect")
        self.assertIn("printf 'DOCUMENTDB_MODE=%s\\n'", body,
                      "record_state must persist the state mode for the admin auto-detect")


class GatewayAdminUsageSurfaceTests(unittest.TestCase):
    """The packaged admin helper is a standalone CLI; the help output
    should teach that name and advertise the target-db override."""

    def test_gateway_admin_help_uses_packaged_cli_name(self):
        result = subprocess.run(
            ["bash", str(GATEWAY_ADMIN_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: documentdb-gateway-admin <command> [OPTIONS]", result.stdout)

    def test_gateway_admin_help_mentions_target_db(self):
        result = subprocess.run(
            ["bash", str(GATEWAY_ADMIN_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--target-db NAME", result.stdout)


class RpmMetaPackageSystemdAliasTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 5): the design's public day-2 surface
    is documentdb-local.target. The DEB meta package installs it via
    postinst; the RPM meta previously shipped no files and no scriptlets,
    so the alias did not exist on RPM hosts. Now %post installs and
    %postun removes the alias unit."""

    def test_rpm_meta_post_installs_alias(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec"
        text = spec.read_text(encoding="utf-8")
        match = re.search(r"%post\s*\n(?P<body>.*?)(?=^%[a-z]|\Z)", text,
                          flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(match, "RPM meta must define a %post scriptlet")
        body = match.group("body")
        self.assertIn(
            '/etc/systemd/system/documentdb-local.target',
            body,
            "RPM meta %post must create the documentdb-local.target alias",
        )
        self.assertIn(
            'Requires=documentdb-local@%{default_pg_major}.target',
            body,
            "RPM meta %post must reference the per-major target",
        )

    def test_rpm_meta_postun_removes_alias(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec"
        text = spec.read_text(encoding="utf-8")
        match = re.search(r"%postun\s*\n(?P<body>.*?)(?=^%[a-z]|\Z)", text,
                          flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(match, "RPM meta must define a %postun scriptlet")
        body = match.group("body")
        # Removal only on full uninstall ($1 == 0).
        self.assertIn(
            'if [ "$1" -eq 0 ]; then',
            body,
            "RPM meta %postun must guard removal on $1 == 0",
        )
        self.assertIn(
            'rm -f /etc/systemd/system/documentdb-local.target',
            body,
            "RPM meta %postun must remove the alias on full uninstall",
        )


class GatewayAdminMultiMajorDisambiguationTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 5): documentdb-gateway-admin's
    auto_detect_connection() previously returned on first state-file
    match. With multiple majors installed (a supported topology per
    design §4.4), that nondeterministically picked one. Now it must
    refuse and tell the operator to be explicit."""

    def test_admin_autodetect_refuses_on_multiple_majors(self):
        admin_script = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin_script.read_text(encoding="utf-8")
        match = re.search(
            r"auto_detect_connection\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "auto_detect_connection body not found")
        body = match.group("body")
        # After iter-9 the dedup is at (major, cluster) granularity,
        # not just major. The variable is `distinct_instances` and the
        # error message says "instances", not "majors".
        self.assertIn('distinct_instances', body,
                      "auto-detect must track distinct (major, cluster) instances")
        # Must fail with a clear message on ambiguity.
        self.assertIn('multiple PostgreSQL instances are registered', body,
                      "auto-detect must surface a clear ambiguity error")
        self.assertIn('Re-run with --pg-port and --socket-dir', body,
                      "Error must tell the operator how to disambiguate")

    def test_admin_autodetect_collapses_legacy_env_with_same_major(self):
        """The legacy /etc/documentdb/documentdb-postgresql.env carries the
        same PG_VERSION as its matching per-major state file. Without
        deduplication, an upgraded host would show up as ambiguous when
        in fact there's only one logical instance."""
        admin_script = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin_script.read_text(encoding="utf-8")
        match = re.search(
            r"auto_detect_connection\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # The dedup logic compares PG_VERSION across state files.
        self.assertIn('PG_VERSION=', body,
                      "auto-detect must read PG_VERSION for dedup")
        self.assertRegex(body, r'seen=false', "Must use a seen-flag for dedup")


class ToolsPackageJqDependencyTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 5): documentdb-gateway-admin invokes
    jq unconditionally for create-user / drop-user / reset-password BSON
    construction. The DEB postgresql-tools package and the RPM tools spec
    must declare jq as a hard dependency, otherwise Workflow B installs
    (just the tools package without the meta) die at runtime with
    'jq: command not found'."""

    def test_deb_tools_depends_on_jq(self):
        builder = OSS_ROOT / "packaging" / "postgresql-tools" / "build-postgresql-tools-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'Depends:.*\bjq\b',
            "DEB postgresql-tools must declare jq in Depends",
        )

    def test_rpm_tools_requires_jq(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-tools.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'(?m)^Requires:\s+jq\s*$',
            "RPM documentdb-tools.spec must Require jq",
        )


class TemplatedPostgresDropInTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 6): the custom --data-dir drop-in must
    target the templated documentdb-postgresql@N.service.d/, NOT the
    legacy non-templated documentdb-postgresql.service.d/. The new
    package only ships the templated unit, so the drop-in had no effect."""

    def test_dropin_targets_templated_unit(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_postgres_systemd_drop_in\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '/etc/systemd/system/documentdb-postgresql@${PG_VERSION}.service.d',
            body,
            "Drop-in must target the per-major templated unit",
        )

    def test_dropin_cleans_legacy_non_templated_path(self):
        """Hosts upgraded from pre-iter6 may have a stale drop-in under the
        non-templated path. ensure_postgres_systemd_drop_in must clean it."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_postgres_systemd_drop_in\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('legacy_drop_in_dir', body,
                      "Must reference the legacy non-templated path for cleanup")

    def test_restore_cleans_both_templated_and_legacy_dropins(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'documentdb-postgresql@*.service.d',
            script,
            "--restore must iterate templated per-major drop-in dirs",
        )


class StatusReadsPersistedGatewayPortTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 6): --status was probing
    ${GATEWAY_PORT} from CLI/default (10260) instead of the persisted
    GATEWAY_PORT from the per-major state file. Installs created with
    --listen-port were reported "not listening" even when healthy."""

    def test_status_reads_persisted_port_from_state_file(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('effective_gateway_port', body,
                      "status must compute an effective gateway port")
        self.assertIn("GATEWAY_PORT=", body,
                      "status must read GATEWAY_PORT from the persisted state file")
        # The probe must use the effective port, not the CLI default.
        self.assertIn('"sport = :${effective_gateway_port}"', body,
                      "ss probe must use the effective (persisted-or-default) port")


class GatewayCleanInstallTestPackageContractTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 6): the DEB/RPM clean-install tests
    for the gateway package were still asserting documentdb-setup,
    documentdb-postgresql.service, sample-data, etc., even though those
    moved to documentdb-N under the split-package design. The
    gateway-only test container doesn't install documentdb-N, so the
    assertions would fail or (worse) the test wasn't being run at all."""

    def test_deb_gateway_test_asserts_only_gateway_surface(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint.sh"
        text = path.read_text(encoding="utf-8")
        # Must verify gateway-specific files.
        self.assertIn('assert_executable /usr/bin/documentdb-gateway', text)
        self.assertIn('assert_file /lib/systemd/system/documentdb-gateway.service', text)
        # Must explicitly reject documentdb-setup presence in the gateway
        # package's MANIFEST (documentdb-N owns documentdb-setup, and
        # documentdb-N is now co-installed in the test container, so
        # disk-presence checks aren't useful — manifest checks via
        # `dpkg -L documentdb-gateway` are what gates the boundary).
        self.assertIn(
            'documentdb-gateway manifest must NOT contain documentdb-setup',
            text,
            "DEB gateway test must guard the package-boundary invariant via dpkg -L",
        )

    def test_rpm_gateway_test_asserts_only_gateway_surface(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint-rpm.sh"
        text = path.read_text(encoding="utf-8")
        self.assertIn('assert_executable /usr/bin/documentdb-gateway', text)
        self.assertIn('assert_file /lib/systemd/system/documentdb-gateway.service', text)
        self.assertIn(
            'documentdb-setup must not be installed by the gateway RPM',
            text,
            "RPM gateway test must guard against accidental documentdb-N pull-in",
        )


class JqDependencyBoundaryTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 7): jq belongs ONLY to
    documentdb-postgresql-tools (because documentdb-gateway-admin uses it).
    The gateway binary itself doesn't use jq — per packaging-design.md
    §4.3 the gateway package has no product-specific runtime deps. Both
    DEB and RPM gateway specs must NOT declare jq."""

    def test_gateway_deb_does_not_depend_on_jq(self):
        builder = OSS_ROOT / "packaging" / "gateway" / "build-gateway-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # The DEPENDS variable construction must not include jq.
        match = re.search(
            r'DEPENDS="[^"]*jq[^"]*"',
            text,
        )
        self.assertIsNone(match,
                          "Gateway build-gateway-deb.sh must not include jq in DEPENDS")

    def test_gateway_rpm_does_not_require_jq(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertNotRegex(
            text,
            r'(?m)^Requires:\s+jq\s*$',
            "documentdb-gateway.spec must not Require jq (it belongs to documentdb-postgresql-tools)",
        )


class TargetAliasStopPropagationTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 7): the documentdb-local.target wrapper
    unit uses Requires=, which only propagates start (pull-in) — NOT stop
    or restart. `systemctl stop documentdb-local.target` would leave the
    appliance running. The fix is to install a PartOf=documentdb-local.target
    drop-in on the per-major target so stop/restart propagates correctly."""

    def test_deb_meta_installs_partof_dropin(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-meta-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # In the source heredoc, ${DEFAULT_PG_MAJOR} is escaped to
        # \${DEFAULT_PG_MAJOR} so it stays a runtime variable in the
        # installed postinst. Look for either form to be robust.
        self.assertRegex(
            text,
            r'documentdb-local@\\?\$\{DEFAULT_PG_MAJOR\}\.target\.d/wrapper-partof\.conf',
            "DEB meta postinst must install the stop-propagation drop-in",
        )
        self.assertIn(
            'PartOf=documentdb-local.target',
            text,
            "Drop-in must declare PartOf=documentdb-local.target so stop propagates",
        )

    def test_rpm_meta_installs_partof_dropin(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            'documentdb-local@%{default_pg_major}.target.d/wrapper-partof.conf',
            text,
            "RPM meta %post must install the stop-propagation drop-in",
        )
        self.assertIn(
            'PartOf=documentdb-local.target',
            text,
            "Drop-in must declare PartOf=documentdb-local.target so stop propagates",
        )

    def test_deb_meta_postrm_removes_partof_dropin(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-meta-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'rm -f /etc/systemd/system/documentdb-local@\\?\$\{DEFAULT_PG_MAJOR\}\.target\.d/wrapper-partof\.conf',
            "DEB meta postrm must remove the PartOf drop-in on purge",
        )

    def test_rpm_meta_postun_removes_partof_dropin(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            'rm -f /etc/systemd/system/documentdb-local@%{default_pg_major}.target.d/wrapper-partof.conf',
            text,
            "RPM meta %postun must remove the PartOf drop-in on full uninstall",
        )


class GatewayMaintainerScriptDoesNotTouchPostgresTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 7): the gateway package is runtime-only
    per packaging-design.md §4.3 / §7 ("Maintainer scripts restart
    PostgreSQL: Never"). Gateway maintainer scripts must touch ONLY gateway
    services, never the PG service. Both DEB and RPM clean-install tests
    must assert this."""

    def test_deb_gateway_postinst_assertions_do_not_touch_postgres(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint.sh"
        text = path.read_text(encoding="utf-8")
        # The gateway postinst assertion should NOT positively assert
        # `restart documentdb-postgresql` anywhere. It SHOULD negatively
        # assert it.
        self.assertIn(
            'Upgrade postinst must NOT restart PostgreSQL',
            text,
            "DEB gateway test must assert postinst does NOT restart PostgreSQL",
        )
        # The old positive assertion that gateway prerm stops PG must be gone.
        self.assertIn(
            'Removal prerm must NOT touch PostgreSQL',
            text,
            "DEB gateway test must explicitly forbid prerm stopping PostgreSQL",
        )

    def test_rpm_gateway_posttrans_assertions_do_not_touch_postgres(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint-rpm.sh"
        text = path.read_text(encoding="utf-8")
        self.assertIn(
            'Posttrans must NOT restart PostgreSQL',
            text,
            "RPM gateway test must assert posttrans does NOT restart PostgreSQL",
        )
        self.assertIn(
            'Removal %preun must NOT stop PostgreSQL',
            text,
            "RPM gateway test must explicitly forbid %preun stopping PostgreSQL",
        )


class RegisterGatewayAdminBootstrapContractTests(unittest.TestCase):
    """The first-admin bootstrap is optional, but once requested it must
    either run with a password file or fail clearly."""

    def test_register_gateway_help_marks_admin_bootstrap_optional(self):
        result = subprocess.run(
            ["bash", str(GATEWAY_SETUP_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Bootstrap the first admin user (optional;", result.stdout)
        self.assertIn("Password file for --admin-user", result.stdout)

    def test_register_gateway_validates_admin_user_and_password_file_together(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "--admin-user is required when --admin-password-file is set.",
            text,
            "register-gateway must reject a password file without --admin-user",
        )
        self.assertIn(
            "--admin-password-file is required when --admin-user is set.",
            text,
            "register-gateway must reject --admin-user without a password file",
        )
        self.assertIn(
            "without bootstrapping a first admin user",
            text,
            "register-gateway should describe the optional bootstrap accurately",
        )


class TargetDbThreadingTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 8): the original implementation
    hardcoded /postgres in the gateway connection URL and -d postgres in
    the admin tool, locking Workflow B installs to the postgres database.
    Operators who created the documentdb extension in a different DB
    silently broke. --target-db now threads the actual database name
    through register-gateway → connection URL + admin bootstrap, and
    through documentdb-gateway-admin's psql calls."""

    def test_register_gateway_accepts_target_db_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--target-db)', text,
                      "register-gateway must accept --target-db")
        self.assertIn('TARGET_DB="postgres"', text,
                      "register-gateway must default TARGET_DB to 'postgres'")

    def test_register_gateway_uses_target_db_in_connection_url(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_connection_secret\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('${TARGET_DB}', body,
                      "Connection URL must interpolate ${TARGET_DB}")
        # Belt-and-braces: must NOT hardcode /postgres anymore.
        self.assertNotRegex(
            body,
            r'postgresql://[^/"\']*@/postgres\?',
            "Connection URL must not hardcode /postgres",
        )

    def test_register_gateway_threads_target_db_to_admin_bootstrap(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"create_admin_user\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('--target-db "${TARGET_DB}"', body,
                      "create_admin_user must pass --target-db to documentdb-gateway-admin")

    def test_register_gateway_target_db_rejects_unsafe_value(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The arg parser must reject anything that doesn't look like a
        # PostgreSQL identifier so it can't escape into the URL or shell.
        self.assertRegex(
            text,
            r'--target-db must be a PostgreSQL identifier',
            "--target-db must validate the value",
        )

    def test_gateway_admin_accepts_target_db_flag(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        self.assertIn('--target-db)', text,
                      "documentdb-gateway-admin must accept --target-db")
        self.assertIn('TARGET_DB="postgres"', text,
                      "documentdb-gateway-admin must default TARGET_DB to 'postgres'")

    def test_gateway_admin_uses_target_db_in_all_psql_calls(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        # No more hardcoded `-d postgres` (only the comment should still
        # mention it, prefixed by `# `).
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            self.assertNotRegex(
                line,
                r'-d postgres\b',
                f"Admin script must not hardcode -d postgres in: {stripped[:80]}",
            )


class ToolsDebSuggestsHardcodedExtensionTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5 iter 8): the DEB tools package's
    `Suggests: postgresql-18-documentdb` was misleading on PG 15/16/17
    hosts. The package is PG-agnostic per design §4.2 — Suggests should
    not pin one major. Matches the RPM tools spec which omits the
    suggestion entirely.

    Reviewer-flagged (Sonnet iter 9): same pattern existed in the
    gateway DEB/RPM. Now neither should pin a specific PG-major
    extension package."""

    def test_deb_tools_does_not_suggest_pinned_extension(self):
        builder = OSS_ROOT / "packaging" / "postgresql-tools" / "build-postgresql-tools-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # Walk non-comment lines only — the explanatory comment
        # mentions postgresql-18-documentdb historically.
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            self.assertNotIn(
                'postgresql-18-documentdb',
                line,
                f"DEB tools must not hardcode postgresql-18-documentdb (line {lineno}: {stripped[:80]})",
            )
        # Should still suggest the gateway runtime per §4.2.
        self.assertIn(
            'Suggests: documentdb-gateway',
            text,
            "DEB tools must still Suggest the gateway runtime",
        )

    def test_deb_gateway_does_not_suggest_pinned_extension(self):
        builder = OSS_ROOT / "packaging" / "gateway" / "build-gateway-deb.sh"
        text = builder.read_text(encoding="utf-8")
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            self.assertNotIn(
                'postgresql-18-documentdb',
                line,
                f"DEB gateway must not hardcode postgresql-18-documentdb (line {lineno}: {stripped[:80]})",
            )

    def test_rpm_gateway_does_not_suggest_pinned_extension(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec"
        text = spec.read_text(encoding="utf-8")
        # Walk non-comment lines only. The %post echo message intentionally
        # tells the operator "sudo dnf install postgresql18-documentdb"
        # as a hint, which is fine as user-visible text (the operator
        # adjusts for their major); only the Suggests directive matters.
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith('#') or stripped.startswith('echo'):
                continue
            self.assertNotRegex(
                line,
                r'^Suggests:\s+postgresql18-documentdb\b',
                f"RPM gateway must not Suggest a pinned PG-major extension (line {lineno})",
            )


class GatewayLoadsPackagedConfigTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 + GPT-5.5 iter 9): the packaged gateway
    runtime didn't load /etc/documentdb/gateway/SetupConfiguration.json by
    default — only an explicit --config or the build-tree dev path. So
    documentdb-setup wizard updates to that file were ignored when the
    systemd unit started the gateway with bare `documentdb-gateway run`."""

    def test_gateway_main_reads_packaged_config_path(self):
        main_rs = OSS_ROOT / "pg_documentdb_gw" / "documentdb_gateway" / "src" / "main.rs"
        text = main_rs.read_text(encoding="utf-8")
        self.assertIn(
            '"/etc/documentdb/gateway/SetupConfiguration.json"',
            text,
            "Gateway runtime must check the packaged config path",
        )
        # The packaged path must take precedence over the dev path in the
        # .or_else() chain. Look at the actual chain (not the comment).
        # The structural pattern is: `config.or_else(packaged).or_else(dev)`.
        match = re.search(
            r"fn load_configuration[^{]*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Strip comments so positional comparisons reflect real code order.
        code_only = re.sub(r'^\s*//.*$', '', body, flags=re.MULTILINE)
        packaged_idx = code_only.find('packaged_path.exists()')
        dev_idx = code_only.find('dev_path.exists()')
        self.assertGreater(packaged_idx, 0,
                           "packaged_path.exists() must appear in real code, not just comments")
        self.assertGreater(dev_idx, 0,
                           "dev_path.exists() must still be checked as a fallback")
        self.assertLess(packaged_idx, dev_idx,
                        "packaged_path must be checked BEFORE dev_path in the .or_else() chain")


class GatewayEnvFragmentCarriesListenAddrTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 9): the per-major
    documentdb-gateway-local@N.service only loads its EnvironmentFile (the
    per-major gateway.env), not SetupConfiguration.json. The env fragment
    must therefore carry DOCUMENTDB_LISTEN_ADDR (and TLS auto-gen) so the
    operator's --listen-port reaches the runtime."""

    def test_register_gateway_supports_listen_addr_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--listen-addr)', text,
                      "register-gateway must accept --listen-addr")
        self.assertIn('GATEWAY_LISTEN_ADDR', text,
                      "register-gateway must store the listen addr")

    def test_env_fragment_emits_listen_addr(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_gateway_env_fragment\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('DOCUMENTDB_LISTEN_ADDR', body,
                      "Env fragment must emit DOCUMENTDB_LISTEN_ADDR when set")
        self.assertIn('DOCUMENTDB_TLS_AUTO_GENERATE', body,
                      "Env fragment must emit DOCUMENTDB_TLS_AUTO_GENERATE when set")

    def test_setup_passes_listen_addr_to_register_gateway(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('--listen-addr ":${GATEWAY_PORT}"', body,
                      "setup must thread --listen-port through register-gateway --listen-addr")
        self.assertIn('--tls-auto-generate true', body,
                      "setup must enable TLS auto-gen on standalone (design §4.3 default)")


class BrownfieldUsesDistroSocketTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 9): brownfield setup discovered
    PG_SOCKET_DIR_BROWNFIELD from the running PG but the downstream
    register-gateway / psql calls all consulted PG_SOCKET_DIR, which was
    still the appliance per-major socket dir (which doesn't exist for
    brownfield). PG_SOCKET_DIR must be overridden in brownfield to the
    distro socket."""

    def test_brownfield_overrides_socket_dir(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"prepare_brownfield_instance\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('PG_SOCKET_DIR="${distro_socket}"', body,
                      "Brownfield must override PG_SOCKET_DIR to the distro socket")


class GatewayLocalSocketAccessTests(unittest.TestCase):
    """The per-major gateway service must be able to traverse the private socket path."""

    def test_setup_creates_socket_dirs_with_gateway_group(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_socket_dir_writable\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'install -d -o documentdb-local -g documentdb-gateway -m 0750 "${socket_parent}"',
            body,
            "The runtime parent must grant traversal to the gateway group",
        )
        self.assertIn(
            'install -d -o documentdb-local -g documentdb-gateway -m 0750 "${PG_SOCKET_DIR}"',
            body,
            "The socket directory must grant traversal to the gateway group",
        )

    def test_service_helper_recreates_socket_dirs_with_gateway_group(self):
        service_helper = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb_postgresql_service.sh"
        text = service_helper.read_text(encoding="utf-8")
        self.assertIn('socket_group="documentdb-gateway"', text)
        self.assertIn('socket_group="${PG_OWNER}"', text)
        self.assertIn('-g "${socket_group}" -m 0750', text)

    def test_gateway_local_unit_allows_private_socket_dir(self):
        unit = OSS_ROOT / "packaging" / "appliance" / "systemd" / "documentdb-gateway-local@.service"
        text = unit.read_text(encoding="utf-8")
        self.assertIn(
            "/run/documentdb-local/%i/postgresql",
            text,
            "The gateway-local unit must be allowed to access the private socket directory",
        )


class BrownfieldTuneDelegationTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 9): on Debian brownfield, calling
    documentdb-tune --pgdata writes to the data-dir postgresql.conf which
    Debian clusters don't read. Use --pg-version/--cluster instead so the
    per-cluster fragment lands in /etc/postgresql-common/documentdb/V/C/."""

    def test_setup_uses_cluster_form_for_debian_brownfield(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"apply_managed_postgres_settings\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # The tune delegation must branch on TARGET_CLUSTER + Debian
        # config-dir presence to use --pg-version/--cluster instead of --pgdata.
        self.assertIn(
            'if [[ -n "${TARGET_CLUSTER}" && -d "/etc/postgresql/${PG_VERSION}/${TARGET_CLUSTER#*/}" ]]',
            body,
            "Tune delegation must branch on TARGET_CLUSTER for Debian brownfield",
        )
        self.assertIn(
            '--pg-version "${PG_VERSION}" --cluster "${TARGET_CLUSTER#*/}"',
            body,
            "Debian brownfield must call documentdb-tune --pg-version/--cluster",
        )


class AdminAutoDetectInstanceLevelDedupTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 iter 9): admin auto-detect dedupes
    state files by PG_VERSION only. Two clusters on the same major
    (18/main + 18/analytics) silently collapsed to one — auto-detect
    picked state_files[0]. Dedup must be by (PG_VERSION, CLUSTER_NAME)."""

    def test_admin_autodetect_dedups_by_instance(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        self.assertIn('distinct_instances', text,
                      "auto-detect must track distinct instances, not distinct majors")
        self.assertIn('CLUSTER_NAME=', text,
                      "auto-detect must read CLUSTER_NAME to form an instance key")
        self.assertIn('multiple PostgreSQL instances are registered', text,
                      "Ambiguity error must say 'instances', not 'majors'")


class RegisterGatewayQueriesLiveHbaIdentTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 iter 9): operators can override hba_file
    / ident_file in postgresql.conf. register-gateway must SHOW those
    values from the live cluster before mutating, otherwise it edits the
    distro-default paths and the running PG never sees the changes."""

    def test_verifier_queries_live_hba_and_ident(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"verify_psql_connects_to_named_cluster\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('SHOW hba_file', body,
                      "Verifier must SHOW hba_file from the live cluster")
        self.assertIn('SHOW ident_file', body,
                      "Verifier must SHOW ident_file from the live cluster")
        # On override, the resolved HBA_FILE/IDENT_FILE must be replaced
        # with the live values so subsequent writes go to the right files.
        self.assertIn('HBA_FILE="${live_hba_file}"', body,
                      "Verifier must override HBA_FILE with the live value")
        self.assertIn('IDENT_FILE="${live_ident_file}"', body,
                      "Verifier must override IDENT_FILE with the live value")


class BrownfieldRestartGuardTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 10): in brownfield mode, when
    documentdb-tune wrote shared_preload_libraries, the wizard logged
    "please restart PG" and then immediately ran CREATE EXTENSION.
    pg_documentdb is a preload library — CREATE EXTENSION fails until
    the postmaster restarts. Wizard must stop and let the operator
    restart + re-run."""

    def test_brownfield_stops_when_config_changed(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'documentdb-setup is exiting BEFORE running CREATE EXTENSION',
            body,
            "Brownfield must exit when PG_CONFIG_CHANGED — CREATE EXTENSION would fail before postmaster restart",
        )
        self.assertIn(
            'exit 0',
            body,
            "Brownfield restart-required path must exit cleanly (not error) so the operator can rerun",
        )

    def test_brownfield_provides_rerun_instructions(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'sudo documentdb-setup --target-postgres-instance',
            body,
            "Brownfield restart-required path must give a concrete rerun command",
        )


class RegisterGatewayWorkflowBEnvFileTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 iter 10): the per-major gateway.env path
    only works when documentdb-N (the standalone package) is installed.
    For Workflow B (just documentdb-gateway), the plain
    documentdb-gateway.service unit reads /etc/documentdb/gateway/gateway.env,
    not the per-major path. register-gateway must pick the right one
    based on which systemd template unit is shipped on the host."""

    def test_workflow_b_uses_plain_gateway_env_path(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Must detect whether the per-major templated unit is shipped.
        self.assertIn(
            '/lib/systemd/system/documentdb-gateway-local@.service',
            text,
            "register-gateway must detect documentdb-N installation via the templated unit",
        )
        # Workflow B fallback path uses /etc/documentdb/gateway/gateway.env.
        self.assertRegex(
            text,
            r'GATEWAY_ENV_FILE="/etc/documentdb/gateway/gateway\.env"',
            "register-gateway must fall back to /etc/documentdb/gateway/gateway.env when documentdb-N is absent",
        )


class RegisterGatewayRecoveryMarkerOrderTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 iter 10): recovery marker was written
    BEFORE verify_psql_connects_to_named_cluster, but the verifier also
    overrides HBA_FILE/IDENT_FILE with the live SHOW values. The marker
    must reflect the actual paths we're about to mutate, so verifier
    must run first."""

    def test_verifier_runs_before_recovery_marker_in_do_setup(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_setup\(\) \{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Strip comments so we compare real code order.
        code_only = re.sub(r'^\s*#.*$', '', body, flags=re.MULTILINE)
        verifier_idx = code_only.find('verify_psql_connects_to_named_cluster')
        marker_idx = code_only.find('write_recovery_marker')
        hba_write_idx = code_only.find('prepend_with_managed_block')
        self.assertGreater(verifier_idx, 0)
        self.assertGreater(marker_idx, 0)
        self.assertGreater(hba_write_idx, 0)
        self.assertLess(verifier_idx, marker_idx,
                        "verifier must run BEFORE write_recovery_marker so the marker records live paths")
        self.assertLess(marker_idx, hba_write_idx,
                        "recovery marker must still be written BEFORE the HBA edit")


class RegisterGatewayAdminBootstrapPgOwnerTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 10): create_admin_user delegated to
    documentdb-gateway-admin without --pg-owner, so a register-gateway
    invocation with --pg-owner documentdb-local (private greenfield PG)
    silently failed the admin bootstrap because the admin tool defaulted
    to postgres."""

    def test_create_admin_user_passes_pg_owner(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"create_admin_user\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('--pg-owner "${PG_OWNER}"', body,
                      "create_admin_user must pass --pg-owner to documentdb-gateway-admin")


class AdminAutoDetectSkipsWhenExplicitTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 iter 10): auto_detect_connection ran
    unconditionally, so on a multi-instance host the ambiguity check
    fired even when the operator already supplied --pg-port + --socket-dir.
    Operator got told to re-run with the flags they already passed."""

    def test_autodetect_returns_early_when_both_explicit(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        match = re.search(
            r"auto_detect_connection\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertRegex(
            body,
            r'if \[\[ -n "\$\{PG_PORT\}" && -n "\$\{SOCKET_DIR\}" \]\]; then\s+return 0',
            "auto-detect must short-circuit when both --pg-port and --socket-dir are explicit",
        )


class BrownfieldRestartLoopFixTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 11): on Debian, documentdb-tune
    writes shared_preload_libraries to the per-cluster include fragment,
    NOT to the live postgresql.conf. So setup's file-only SPL check kept
    triggering PG_CONFIG_CHANGED=true even after the operator restarted
    PG — causing an infinite restart-and-rerun loop.

    Fix: query SHOW shared_preload_libraries from the live server (the
    only authoritative answer), and only force exit if our required
    libraries are not actually loaded."""

    def test_brownfield_queries_live_shared_preload_libraries(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'SHOW shared_preload_libraries',
            "Brownfield must SHOW shared_preload_libraries from the live PG",
        )

    def test_brownfield_skips_restart_when_libs_already_loaded(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Look for the "all required libraries present in live PG" branch
        # that suppresses PG_CONFIG_CHANGED.
        self.assertIn('all_present=true', script,
                      "Brownfield must check each required lib against live SPL")
        self.assertIn('need_restart=false', script,
                      "Brownfield must skip the restart-required exit when live SPL has all libs")


class PgUrlPersistentPathTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 11): pg-url was at
    /run/documentdb-local/N/gateway/pg-url (tmpfs, cleared on reboot).
    The env file references it via DOCUMENTDB_PG_URL_FILE, which
    persists, so on reboot the gateway started with a dangling pointer
    and failed. Moved to /var/lib/documentdb-local/N/gateway/pg-url
    (persistent, same security boundary)."""

    def test_register_gateway_uses_persistent_path(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'SECRET_DIR="/var/lib/documentdb-local/${PG_VERSION}/gateway"',
            text,
            "register-gateway must write pg-url to the persistent /var/lib path",
        )

    def test_design_doc_specifies_persistent_path(self):
        design_path = OSS_ROOT / "packaging" / "gateway" / "packaging-design.md"
        text = design_path.read_text(encoding="utf-8")
        self.assertIn(
            '/var/lib/documentdb-local/N/gateway/pg-url',
            text,
            "Design doc must specify the persistent pg-url path",
        )
        self.assertIn(
            'reboot',
            text,
            "Design doc must explain WHY pg-url moved off tmpfs",
        )

    def test_postrm_cleans_both_old_and_new_paths(self):
        """Upgrade safety: hosts that installed pre-iter11 have pg-url at
        /run/. The postrm must clean both the new and legacy paths."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn(
            '/run/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url',
            text,
            "DEB postrm must clean the legacy /run/ pg-url for pre-iter11 upgrades",
        )
        self.assertIn(
            '/var/lib/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url',
            text,
            "DEB postrm must clean the current /var/lib pg-url",
        )

    def test_rpm_postun_cleans_both_paths(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            '/run/documentdb-local/%{pg_version}/gateway/pg-url',
            text,
            "RPM %postun must clean legacy /run/ pg-url",
        )
        self.assertIn(
            '/var/lib/documentdb-local/%{pg_version}/gateway/pg-url',
            text,
            "RPM %postun must clean current /var/lib pg-url",
        )


class RegisterGatewayPgVersionDerivationTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 iter 11): greenfield setup via wizard
    called documentdb-register-gateway with --pgdata only, no --pg-version.
    register-gateway then silently skipped all per-major work (psql
    resolver, SECRET_DIR, STATE_FILE, GATEWAY_ENV_FILE). Result:
    greenfield wizard installs had no working gateway connection state."""

    def test_register_gateway_accepts_pg_version_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--pg-version)', text,
                      "register-gateway must accept --pg-version")
        self.assertIn('PG_VERSION="$2"', text,
                      "--pg-version must set PG_VERSION")

    def test_register_gateway_derives_pg_version_from_pgdata(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Defensive fallback: even if the caller forgets --pg-version,
        # derive from PGDATA/PG_VERSION (standard initdb marker).
        self.assertIn(
            '"${PGDATA}/PG_VERSION"',
            text,
            "register-gateway must auto-derive PG_VERSION from PGDATA/PG_VERSION",
        )

    def test_setup_passes_pg_version_in_greenfield(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '--pg-version "${PG_VERSION}"',
            body,
            "Greenfield invocation must pass --pg-version explicitly",
        )


class GatewayEnvSampleConsistencyTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 12): the gateway.env.sample shipped
    under /usr/share/doc/documentdb-gateway/examples/ still advertised
    /run/documentdb-local/N/gateway/pg-url even after iter-11 moved the
    actual path to /var/lib. The postinst tells operators to copy this
    sample into /etc/documentdb/gateway/gateway.env, so a Workflow B
    operator who uncomments the line would reintroduce the reboot bug."""

    def test_sample_uses_persistent_pg_url_path(self):
        sample = OSS_ROOT / "packaging" / "gateway" / "config" / "gateway.env"
        text = sample.read_text(encoding="utf-8")
        self.assertNotIn(
            'DOCUMENTDB_PG_URL_FILE=/run/documentdb-local',
            text,
            "Sample must not advertise the legacy tmpfs path (reboot-unsafe)",
        )
        self.assertIn(
            'DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/N/gateway/pg-url',
            text,
            "Sample must show the persistent /var/lib path",
        )


class PackagingReadmeWorkflowCTests(unittest.TestCase):
    """The recommended stand-alone workflow should mirror the wizard's
    required inputs and interactive password prompt."""

    def test_workflow_c_example_passes_admin_user(self):
        text = PACKAGING_README.read_text(encoding="utf-8")
        self.assertIn(
            "sudo documentdb-setup --admin-user admin",
            text,
            "Workflow C example must include the required --admin-user flag",
        )


class RegisterGatewayPersistsEnvFilePathTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 13): GATEWAY_ENV_FILE is chosen at
    apply-time based on whether documentdb-N is installed. On --restore,
    runtime detection can pick the wrong path if the host changed
    between setup and restore (e.g., operator uninstalled documentdb-N).
    Persist the chosen path in the state file so --restore always
    operates on the file we actually wrote."""

    def test_record_state_persists_gateway_env_file(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "printf 'GATEWAY_ENV_FILE=%s\\n'",
            body,
            "record_state must persist GATEWAY_ENV_FILE",
        )

    def test_do_restore_reads_persisted_gateway_env_file(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "GATEWAY_ENV_FILE=",
            body,
            "do_restore must read GATEWAY_ENV_FILE from state file",
        )
        self.assertIn(
            'persisted_env_file',
            body,
            "do_restore must use a local variable to capture the persisted value",
        )


class RegisterGatewayAtomicStateWriteTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 14): record_state() previously
    used `> "${STATE_FILE}"` which truncates on open. A SIGTERM mid-write
    leaves a partial/empty state file that defeats --restore/postrm.
    Must write atomically via tempfile + rename, matching the
    write_recovery_marker() pattern."""

    def test_record_state_uses_atomic_temp_rename(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'mktemp "${STATE_FILE}',
            body,
            "record_state must allocate a tempfile via mktemp",
        )
        self.assertIn(
            'mv "${tmp}" "${STATE_FILE}"',
            body,
            "record_state must atomically rename tempfile into place",
        )
        self.assertNotRegex(
            body,
            r'\}\s*>\s*"\$\{STATE_FILE\}"',
            "record_state must not write directly to STATE_FILE (non-atomic)",
        )

    def test_record_state_dies_on_mktemp_failure(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertIn(
            "|| die",
            body,
            "record_state must die on mktemp/mv failure rather than leave inconsistent state",
        )


class RegisterGatewayRestoreFallbackTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 14): when state file lacks the
    GATEWAY_ENV_FILE field (pre-iter13 install), do_restore previously
    fell back to runtime detection — which is exactly what was broken
    originally and motivated persisting the path. Must instead scan
    BOTH known candidate paths (per-major + shared) so the managed
    block is reliably stripped from whichever one was actually written."""

    def test_do_restore_scans_multiple_env_candidates_on_legacy_state(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "env_candidates",
            body,
            "do_restore must maintain a list of candidate env paths",
        )
        self.assertIn(
            "for env_target in",
            body,
            "do_restore must iterate over candidate env paths",
        )
        self.assertIn(
            "/etc/documentdb/gateway/gateway.env",
            body,
            "do_restore must consider the shared gateway env path",
        )
        self.assertIn(
            "/etc/documentdb/local/${PG_VERSION}/gateway.env",
            body,
            "do_restore must consider the per-major env path",
        )

    def test_do_restore_prefers_persisted_path_when_present(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r"if\s*\[\[\s*-n\s*\"\$\{persisted_env_file\}\"\s*\]\];?\s*then",
            "do_restore must short-circuit to persisted path when present",
        )

    def test_do_restore_strips_hba_without_reordering_remaining_rules(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        hba_call = re.search(
            r"if \[\[ -f \"\$\{HBA_FILE\}\" \]\]; then(?P<body>.*?)fi",
            body,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(hba_call)
        self.assertIn(
            'rewrite_with_managed_block "${HBA_FILE}"',
            hba_call.group("body"),
            "HBA restore must strip the managed block without prepending an empty block path",
        )
        self.assertNotIn(
            'prepend_with_managed_block "${HBA_FILE}"',
            hba_call.group("body"),
            "HBA restore must not use the prepend helper for removal",
        )


class RegisterGatewayBackupSafetyTests(unittest.TestCase):
    """Config backups must be timestamped but unique under concurrent setup runs."""

    def test_backup_file_uses_unique_tempfile(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"backup_file\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "mktemp",
            body,
            "register-gateway backups must not collide under concurrent runs",
        )
        self.assertIn(
            ".documentdb-backup.${timestamp}.XXXXXX",
            body,
            "register-gateway backups must retain timestamped names with a unique suffix",
        )
        self.assertNotIn(
            ".documentdb-backup.${timestamp}\"",
            body,
            "register-gateway must not use timestamp-only backup filenames",
        )


class StatusOnlyHealthExitCodeTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.4 iter 14): the design doc (§5 line 284)
    says `--status ... exit 0 if a healthy install is found`, and the
    function docstring promises the same. The prior implementation
    exited 0 whenever the state file existed, regardless of whether
    the gateway service was running or anything was listening. CI
    scripts gating on documentdb-setup --status would treat broken
    installs as healthy. Real contract: state file + gw_active +
    listener (+ pg_active in greenfield)."""

    def test_status_only_requires_gateway_active(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{gw_active\}"\s*!=\s*"active"',
            "status_only must return non-zero when gateway service is not active",
        )

    def test_status_only_requires_listener(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{listening_port\}"\s*!=\s*"\$\{effective_gateway_port\}"',
            "status_only must return non-zero when no listener is found on the gateway port",
        )

    def test_status_only_requires_pg_active_in_greenfield(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{mode\}"\s*==\s*"greenfield"\s*&&\s*"\$\{pg_active\}"\s*!=\s*"active"',
            "status_only must require PG service active in greenfield mode (brownfield exempt)",
        )

    def test_status_only_does_not_short_circuit_on_state_file_alone(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        body = match.group("body")
        # The pre-iter14 short-circuit:
        #   [[ "${mode}" != "<not configured>" ]] && return 0 || return 1
        # must be gone.
        self.assertNotRegex(
            body,
            r'\[\[\s*"\$\{mode\}"\s*!=\s*"<not configured>"\s*\]\]\s*&&\s*return\s*0',
            "status_only must not exit 0 based on state file presence alone",
        )


class WriteRecoveryMarkerPersistsEnvFileTests(unittest.TestCase):
    """Reviewer-flagged (Sonnet iter 14 S-1): the write_recovery_marker
    runs before HBA/ident mutations; if SIGTERM lands between
    write_recovery_marker and record_state, do_restore would fall back
    to the candidate-sweep path (safe but coarser). Persist
    GATEWAY_ENV_FILE in the recovery marker too so the precise file is
    always recoverable even from the narrow crash window."""

    def test_write_recovery_marker_persists_gateway_env_file(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_recovery_marker\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "printf 'GATEWAY_ENV_FILE=%s\\n'",
            body,
            "write_recovery_marker must persist GATEWAY_ENV_FILE for SIGTERM resilience",
        )


class RegisterGatewayPreservesForeignStateKeysTests(unittest.TestCase):
    """Reviewer-flagged (GPT-5.5 iter 15): in greenfield mode the wizard
    (documentdb-setup) writes /etc/documentdb/local/N/setup.conf with
    additional keys (GATEWAY_PORT, DATA_DIR, CONFIG_FILE,
    DOCUMENTDB_MANAGED_POSTGRES) BEFORE calling register-gateway, which
    then writes to the SAME path. Without preservation, register-gateway
    silently drops those keys — breaking documentdb-setup --status (it
    reads GATEWAY_PORT to know which port to probe). Both record_state
    and write_recovery_marker (which both rewrite STATE_FILE) must
    preserve foreign keys."""

    def test_record_state_preserves_foreign_keys(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "managed_keys_re=",
            body,
            "record_state must define a managed-keys regex",
        )
        self.assertIn(
            'grep -Ev "${managed_keys_re}"',
            body,
            "record_state must extract non-managed lines via grep -Ev",
        )
        self.assertIn(
            'preserved',
            body,
            "record_state must use a preserved variable",
        )
        # Ensure GATEWAY_PORT is NOT in the managed-keys set (so it survives)
        managed_match = re.search(
            r"managed_keys_re='\^\((?P<keys>[^)]+)\)='",
            body,
        )
        self.assertIsNotNone(managed_match)
        keys = managed_match.group("keys").split("|")
        self.assertNotIn(
            "GATEWAY_PORT",
            keys,
            "GATEWAY_PORT must NOT be in record_state's managed keys (would be dropped)",
        )

    def test_write_recovery_marker_preserves_foreign_keys(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_recovery_marker\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "managed_keys_re=",
            body,
            "write_recovery_marker must define a managed-keys regex",
        )
        self.assertIn(
            'preserved',
            body,
            "write_recovery_marker must use a preserved variable",
        )
        managed_match = re.search(
            r"managed_keys_re='\^\((?P<keys>[^)]+)\)='",
            body,
        )
        self.assertIsNotNone(managed_match)
        keys = managed_match.group("keys").split("|")
        self.assertNotIn(
            "GATEWAY_PORT",
            keys,
            "GATEWAY_PORT must NOT be in write_recovery_marker's managed keys",
        )

    def test_record_state_preserves_only_valid_keyvalue_lines(self):
        # Guard: the preserve filter must reject comments and stray lines
        # that don't look like KEY=VALUE.
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertIn(
            "grep -E '^[A-Za-z_][A-Za-z0-9_]*='",
            body,
            "record_state must filter preserved lines to valid KEY=VALUE syntax",
        )


class RegisterGatewayPreserveLogicFunctionalTests(unittest.TestCase):
    """Functional verification of the GPT-5.5 iter-15 preserve logic:
    actually run the grep -Ev filter against a synthesized state file
    that mimics what documentdb-setup writes in greenfield (setup.conf
    with GATEWAY_PORT, DATA_DIR, CONFIG_FILE, DOCUMENTDB_MANAGED_POSTGRES)
    and verify the foreign keys survive while the managed keys are
    overridden."""

    def test_preserve_filter_keeps_gateway_port(self):
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            # Mimic what documentdb-setup writes in greenfield.
            f.write(
                "DOCUMENTDB_MANAGED_POSTGRES=true\n"
                "DOCUMENTDB_MODE=greenfield\n"
                "PG_VERSION=18\n"
                "PG_PORT=10260\n"
                "PG_OWNER=documentdb-local\n"
                "DATA_DIR=/var/lib/documentdb-local/18/data\n"
                "CONFIG_FILE=/var/lib/documentdb-local/18/data/postgresql.conf\n"
                "HBA_FILE=/var/lib/documentdb-local/18/data/pg_hba.conf\n"
                "IDENT_FILE=/var/lib/documentdb-local/18/data/pg_ident.conf\n"
                "GATEWAY_PORT=10261\n"
            )
            path = f.name
        try:
            managed_re = '^(HBA_FILE|IDENT_FILE|SECRET_FILE|PG_VERSION|CLUSTER_NAME|PG_PORT|PG_OWNER|DOCUMENTDB_MODE|GATEWAY_ENV_FILE)='
            result = subprocess.run(
                ["bash", "-c",
                 f"grep -Ev '{managed_re}' '{path}' | grep -E '^[A-Za-z_][A-Za-z0-9_]*='"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0)
            preserved_lines = result.stdout.strip().split("\n")
            self.assertIn("GATEWAY_PORT=10261", preserved_lines,
                          "GATEWAY_PORT must survive the preserve filter")
            self.assertIn("DATA_DIR=/var/lib/documentdb-local/18/data", preserved_lines,
                          "DATA_DIR must survive the preserve filter")
            self.assertIn("CONFIG_FILE=/var/lib/documentdb-local/18/data/postgresql.conf",
                          preserved_lines,
                          "CONFIG_FILE must survive the preserve filter")
            self.assertIn("DOCUMENTDB_MANAGED_POSTGRES=true", preserved_lines,
                          "DOCUMENTDB_MANAGED_POSTGRES must survive the preserve filter")
            for line in preserved_lines:
                key = line.split("=", 1)[0]
                self.assertNotIn(key, ("HBA_FILE", "IDENT_FILE", "PG_PORT", "PG_OWNER",
                                       "DOCUMENTDB_MODE", "PG_VERSION", "GATEWAY_ENV_FILE"),
                                 f"Managed key {key} should NOT survive (will be overwritten)")
        finally:
            import os
            os.unlink(path)

    def test_preserve_filter_handles_empty_file(self):
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            path = f.name
        try:
            managed_re = '^(HBA_FILE|IDENT_FILE|SECRET_FILE|PG_VERSION|CLUSTER_NAME|PG_PORT|PG_OWNER|DOCUMENTDB_MODE|GATEWAY_ENV_FILE)='
            result = subprocess.run(
                ["bash", "-c",
                 f"grep -Ev '{managed_re}' '{path}' 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.stdout, "", "Empty input should produce empty output")
        finally:
            import os
            os.unlink(path)

    def test_preserve_filter_strips_comments_and_garbage(self):
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write(
                "# This is a comment\n"
                "GATEWAY_PORT=10261\n"
                "not-a-keyvalue-line\n"
                "\n"
                "ANOTHER_KEY=value\n"
            )
            path = f.name
        try:
            managed_re = '^(HBA_FILE|IDENT_FILE|SECRET_FILE|PG_VERSION|CLUSTER_NAME|PG_PORT|PG_OWNER|DOCUMENTDB_MODE|GATEWAY_ENV_FILE)='
            result = subprocess.run(
                ["bash", "-c",
                 f"grep -Ev '{managed_re}' '{path}' | grep -E '^[A-Za-z_][A-Za-z0-9_]*='"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0)
            preserved = result.stdout.strip().split("\n")
            self.assertEqual(sorted(preserved), sorted(["GATEWAY_PORT=10261", "ANOTHER_KEY=value"]))
            for line in preserved:
                self.assertFalse(line.startswith("#"))
                self.assertIn("=", line)
        finally:
            import os
            os.unlink(path)


class WizardEnablesTargetForBootPersistenceTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 17): the wizard previously
    enabled individual templated services (documentdb-postgresql@N,
    documentdb-gateway-local@N) but never enabled
    documentdb-local@N.target itself. Since the services are only
    WantedBy=target, the target had to be enabled for reboot
    persistence — but no one did it. The wizard must call ensure_target_enabled_at_boot before printing the completion message
    so the stack actually persists across reboots."""

    def test_ensure_target_enabled_at_boot_helper_exists(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "ensure_target_enabled_at_boot()",
            text,
            "Wizard must define ensure_target_enabled_at_boot helper",
        )

    def test_helper_uses_per_major_target(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_target_enabled_at_boot\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'documentdb-local@${PG_VERSION}.target',
            body,
            "helper must reference per-major target",
        )
        self.assertIn(
            "systemctl enable",
            body,
            "helper must call systemctl enable on the target",
        )
        self.assertIn(
            "PUBLIC_ALIAS_PG_MAJOR",
            body,
            "helper must prefer the public wrapper alias for the paved-road major",
        )

    def test_helper_respects_no_enable(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_target_enabled_at_boot\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{NO_ENABLE\}"\s*==\s*"true"\s*\]\]\s*&&\s*return',
            "helper must early-return when --no-enable is set",
        )

    def test_main_calls_helper_before_completion(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The main flow must call ensure_target_enabled_at_boot before
        # print_completion_message so the operator's "ready" message
        # reflects the actually-enabled state.
        idx_helper = text.find("ensure_target_enabled_at_boot\n")
        idx_complete = text.find("print_completion_message\n")
        self.assertGreater(idx_helper, 0)
        self.assertGreater(idx_complete, 0)
        self.assertLess(
            idx_helper, idx_complete,
            "ensure_target_enabled_at_boot must run before print_completion_message",
        )

    def test_dry_run_preview_advertises_target_enable(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "systemctl enable documentdb-local@${preview_pg_version}.target",
            text,
            "dry-run preview must list target-enable step (reviewer iter 17)",
        )


class WaitForGatewayReadyAcceptsUnitNameTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 17): wait_for_gateway_ready
    previously hardcoded `journalctl -u documentdb-gateway` in its
    failure-hint, but start_gateway often selects
    documentdb-gateway-local@N.service. The function must accept the
    unit name as a parameter and reflect it in the hint."""

    def test_wait_for_gateway_ready_takes_unit_arg(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"wait_for_gateway_ready\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'running_unit="${1:-}"',
            body,
            "wait_for_gateway_ready must accept unit name as $1",
        )
        self.assertIn(
            'journalctl -u ${running_unit}',
            body,
            "failure hint must use the passed unit name",
        )

    def test_all_callers_pass_unit_name(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Find all calls to wait_for_gateway_ready (excluding the
        # definition itself). All of them must pass an argument.
        calls = re.findall(r'wait_for_gateway_ready(?:\s+[^"\n]*)?(\s+"[^"]*")?', text)
        # We expect at least 3 callers in start_gateway: per-major
        # systemd path, non-templated systemd path, and nohup fallback.
        # The function definition itself has no arg after the name.
        # Confirm via line-level check that the only naked invocation
        # is the definition line.
        for line in text.splitlines():
            stripped = line.strip()
            if stripped == "wait_for_gateway_ready" or stripped.startswith("wait_for_gateway_ready "):
                # Definition line is "wait_for_gateway_ready() {" — handled separately.
                if stripped.startswith("wait_for_gateway_ready()"):
                    continue
                self.assertTrue(
                    '"' in line,
                    f"Naked wait_for_gateway_ready call missing unit argument: {line!r}",
                )


class RegisterGatewayCompletionBranchesOnAdminTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 17): when no --admin-user
    is supplied, the completion message previously printed a misleading
    `mongosh ...admin@.../` connect URI, contradicting the earlier log
    that says no admin user was bootstrapped. Must branch: either show
    connect URI (admin exists) or instruct operator to bootstrap one."""

    def test_completion_branches_on_admin_user(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The misleading default `${ADMIN_USER:-admin}` substitution
        # must NOT appear in the connect URI any more.
        self.assertNotIn(
            'connect_user="${ADMIN_USER:-admin}"',
            text,
            "register-gateway must not hardcode admin user fallback in connect URI",
        )

    def test_completion_has_admin_branch(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'if [[ -n "${ADMIN_USER}" ]]; then',
            text,
            "completion must have explicit ADMIN_USER branch",
        )

    def test_completion_has_no_admin_branch(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "Bootstrap first admin user",
            text,
            "completion must instruct bootstrap when ADMIN_USER is empty",
        )
        self.assertIn(
            "documentdb-gateway-admin create-user",
            text,
            "completion's bootstrap instruction must reference the create-user tool",
        )


class GatewayPostinstWorkflowCNotDuplicatedTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 17): gateway postinst
    previously printed both Workflow B Next Steps and a Workflow C
    suggestion. When `apt install documentdb` pulls the gateway in
    transitively, the standalone postinst already prints Workflow C
    steps, so the gateway version is redundant and confusing."""

    def test_gateway_postinst_does_not_repeat_workflow_c(self):
        postinst = Path(__file__).resolve().parents[2] / "maintainer-scripts" / "gateway" / "postinst"
        text = postinst.read_text(encoding="utf-8")
        # The pre-iter-17 wording included "Or install the full
        # stand-alone package instead" — this is what the standalone
        # postinst already prints, so it must not appear here.
        self.assertNotIn(
            "Or install the full stand-alone package instead",
            text,
            "gateway postinst must not redundantly suggest the meta package",
        )


class BrownfieldReloadRequiredAutoReloadTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): brownfield reload-
    required path used to only log a hint, then continue into
    create_required_extensions_and_users + start_gateway. Without the
    reload, the new pg_hba/pg_ident rules are not active, so the
    gateway cannot authenticate as the documentdb-gateway PG role and
    silently fails to start. Must either auto-reload (preferred, since
    reload is non-disruptive) or exit-and-rerun like the restart path."""

    def test_reload_required_path_invokes_systemctl_reload(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Must reach a confirm_or_apply systemctl reload of the
        # adopted PG unit when PG_RELOAD_CHANGED=true in brownfield.
        self.assertIn(
            'confirm_or_apply "Reload',
            body,
            "brownfield reload path must confirm+apply the reload",
        )
        self.assertIn(
            'systemctl reload "${pg_unit_name}"',
            body,
            "brownfield must reload the actual adopted PG unit, not just log a hint",
        )

    def test_reload_required_falls_back_to_exit_when_no_systemd(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        # When systemd is unavailable, must exit-and-rerun (symmetry
        # with the restart-required branch).
        self.assertRegex(
            body,
            r'"\$\{HAS_WORKING_SYSTEMD\}"\s*==\s*"true"',
            "must check systemd availability before invoking systemctl reload",
        )


class GatewayBinaryBasenameBothFormsTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): listener_looks_like_gateway used to match only basename 'documentdb_gateway' (Cargo
    dev binary name). Packaged DEB/RPM install /usr/bin/documentdb-gateway (hyphen). Both must be accepted or the wizard falsely treats
    a running packaged gateway as a non-gateway port conflict."""

    def test_listener_check_accepts_both_basenames(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"listener_looks_like_gateway\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '"documentdb_gateway"',
            body,
            "must accept Cargo-built dev binary basename",
        )
        self.assertIn(
            '"documentdb-gateway"',
            body,
            "must accept packaged binary basename",
        )


class CaptureGatewayActiveStatePerMajorTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): the per-major
    templated documentdb-gateway-local@N.service is preferred by
    start_gateway. capture_gateway_active_state must check it too,
    not just the non-templated documentdb-gateway.service, so
    --no-enable correctly restores after PG-restart propagation."""

    def test_captures_per_major_unit_when_pg_version_known(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"capture_gateway_active_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'documentdb-gateway-local@${PG_VERSION}.service',
            body,
            "must inspect per-major templated unit when PG_VERSION is known",
        )
        self.assertIn(
            "documentdb-gateway.service",
            body,
            "must also inspect non-templated Workflow B unit",
        )


class RegisterGatewayPgdataSocketDefaultTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): resolve_cluster_paths
    early-returned for --pgdata without setting SOCKET_DIR. Result:
    pg-url had `host=&port=...` (empty host), role/extension checks
    silently skipped. Must default SOCKET_DIR in the --pgdata branch."""

    def test_pgdata_branch_defaults_socket_dir(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"resolve_cluster_paths\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Find the --pgdata branch (the if [[ -n "${PGDATA}" ]]) and
        # verify it sets SOCKET_DIR before its return.
        pgdata_branch = re.search(
            r'if \[\[ -n "\${PGDATA}" \]\];\s*then(.*?)return 0',
            body,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(pgdata_branch)
        self.assertIn(
            "SOCKET_DIR",
            pgdata_branch.group(1),
            "pgdata branch must set SOCKET_DIR before returning",
        )
        self.assertIn(
            "/var/run/postgresql",
            pgdata_branch.group(1),
            "default socket should match the distro convention",
        )


class StandaloneDebPrermStopsTargetTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): RPM has %preun to
    stop+disable documentdb-local@N.target on remove, but DEB had no
    prerm. apt remove/purge would unlink unit files while services
    still running. Must mirror RPM behavior in DEB prerm."""

    def test_deb_prerm_exists_in_build_script(self):
        build_script = (Path(__file__).resolve().parents[3] / "packaging" /
                        "standalone" / "build-standalone-deb.sh")
        text = build_script.read_text(encoding="utf-8")
        self.assertIn(
            'cat > "${PKG_DIR}/DEBIAN/prerm"',
            text,
            "build-standalone-deb.sh must generate a DEBIAN/prerm script",
        )

    def test_deb_prerm_stops_and_disables_target_on_remove(self):
        build_script = (Path(__file__).resolve().parents[3] / "packaging" /
                        "standalone" / "build-standalone-deb.sh")
        text = build_script.read_text(encoding="utf-8")
        prerm_match = re.search(
            r'cat > "\$\{PKG_DIR\}/DEBIAN/prerm" <<PRERM\n(.*?)\nPRERM',
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(prerm_match)
        prerm = prerm_match.group(1)
        self.assertIn(
            "remove)",
            prerm,
            "prerm must branch on Debian's 'remove' case",
        )
        self.assertIn(
            'systemctl stop "documentdb-local@${PG_VERSION}.target"',
            prerm,
            "prerm must stop the per-major target on remove",
        )
        self.assertIn(
            'systemctl disable "documentdb-local@${PG_VERSION}.target"',
            prerm,
            "prerm must disable the per-major target on remove",
        )


class RegisterGatewayPersistsTargetDbTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): TARGET_DB defaults
    to 'postgres' but operators commonly use --target-db <other>.
    Without persisting in state file, day-2 documentdb-gateway-admin
    auto-detect uses the wrong DB."""

    def test_record_state_persists_target_db(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertIn(
            "printf 'TARGET_DB=%s\\n'",
            body,
            "record_state must persist TARGET_DB for gateway-admin auto-detect",
        )

    def test_managed_keys_re_includes_target_db(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        # Find the managed_keys_re definition; TARGET_DB must be in it
        # so the preserve filter doesn't double-emit it.
        managed_match = re.search(
            r"managed_keys_re='\^\((?P<keys>[^)]+)\)='",
            body,
        )
        self.assertIsNotNone(managed_match)
        keys = managed_match.group("keys").split("|")
        self.assertIn(
            "TARGET_DB",
            keys,
            "TARGET_DB must be in the managed-keys set (preserve filter would otherwise duplicate it)",
        )


class GatewayAdminReadsTargetDbFromStateTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): gateway-admin's
    auto_detect_connection must read TARGET_DB from the state file
    when the operator didn't pass --target-db explicitly."""

    def test_explicit_flag_tracked(self):
        admin = (Path(__file__).resolve().parents[1] /
                 "documentdb-gateway-admin.sh")
        text = admin.read_text(encoding="utf-8")
        self.assertIn(
            "TARGET_DB_EXPLICIT=false",
            text,
            "gateway-admin must initialize TARGET_DB_EXPLICIT flag",
        )
        self.assertIn(
            "TARGET_DB_EXPLICIT=true",
            text,
            "--target-db arg parser must set TARGET_DB_EXPLICIT=true",
        )

    def test_auto_detect_reads_target_db_from_state(self):
        admin = (Path(__file__).resolve().parents[1] /
                 "documentdb-gateway-admin.sh")
        text = admin.read_text(encoding="utf-8")
        self.assertIn(
            'grep -E \'^TARGET_DB=\' "${state_file}"',
            text,
            "auto_detect_connection must grep TARGET_DB from state file",
        )
        self.assertIn(
            'TARGET_DB_EXPLICIT',
            text,
            "auto-detect must skip override when operator set --target-db explicitly",
        )


class GatewayDebJsonStripStaleFieldsTests(unittest.TestCase):
    """Reviewer-flagged (external review iter 18): shipped
    /etc/documentdb/gateway/SetupConfiguration.json carried
    PostgresPort:9712 which contradicts the per-major port design.
    Build script must strip connection-pinning fields and the
    legacy password field when packaging."""

    def test_deb_build_script_strips_stale_fields(self):
        build = (Path(__file__).resolve().parents[3] / "packaging" /
                 "gateway" / "build-gateway-deb.sh")
        text = build.read_text(encoding="utf-8")
        # Must reference all four sensitive fields in the strip
        for field in ("PostgresPort", "GatewayListenPort",
                      "PostgresDataUserPassword", "PostgresHostName"):
            self.assertIn(
                field, text,
                f"DEB build script must strip {field} from packaged JSON",
            )

    def test_rpm_spec_strips_stale_fields(self):
        spec = (Path(__file__).resolve().parents[3] / "packaging" /
                "rpm" / "spec" / "documentdb-gateway.spec")
        text = spec.read_text(encoding="utf-8")
        for field in ("PostgresPort", "GatewayListenPort",
                      "PostgresDataUserPassword"):
            self.assertIn(
                field, text,
                f"RPM spec must strip {field} from packaged JSON",
            )
