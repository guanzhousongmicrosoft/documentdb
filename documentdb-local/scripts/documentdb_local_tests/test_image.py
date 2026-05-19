"""
Image-level integration test for documentdb-local.

Scope is intentionally narrow:

  - The image must build (covered by the CI build-image job that runs the
    Docker build before this test executes).
  - A freshly-started container must reach readiness within a sane timeout.
  - The gateway must be reachable from inside the container with mongosh
    using the configured admin credentials over SCRAM-SHA-256 + TLS.
  - Authentication must actually be enforced (wrong password is rejected).

This file is the documentdb-local equivalent of a "smoke test": it
exercises the surface that documentdb-local itself promises (container
boot, readiness log, mongosh-reachable gateway, auth enforcement) and
deliberately does NOT exercise wire-protocol or aggregation semantics -
those belong to the upstream functional-tests image referenced from
documentdb-local/functional-tests/config/image.yml.

The image reference is supplied via the DOCUMENTDB_LOCAL_IMAGE env var
so the same script works locally and in CI:

    DOCUMENTDB_LOCAL_IMAGE=documentdb-local:dev \\
        python3 -m unittest discover -v \\
            -s documentdb-local/scripts/documentdb_local_tests \\
            -p 'test_image.py'
"""

from __future__ import annotations

import os
import secrets
import string
import subprocess
import time
import unittest
import uuid


READY_LOG = "=== DocumentDB is ready ==="
DEFAULT_READY_TIMEOUT = int(os.environ.get("DOCUMENTDB_READY_TIMEOUT", "240"))
DEFAULT_PORT = 10260
DEFAULT_USERNAME = "docdb_admin"


def _random_password(length: int = 32) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _docker(*args: str, check: bool = True, capture: bool = True,
            timeout: int | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["docker", *args],
        check=check,
        text=True,
        capture_output=capture,
        timeout=timeout,
    )


@unittest.skipUnless(
    os.environ.get("DOCUMENTDB_LOCAL_IMAGE"),
    "Set DOCUMENTDB_LOCAL_IMAGE to the documentdb-local image reference to run.",
)
class DocumentDBLocalImageTests(unittest.TestCase):
    """End-to-end smoke tests for the documentdb-local image."""

    image: str
    container: str | None
    password: str

    @classmethod
    def setUpClass(cls):
        cls.image = os.environ["DOCUMENTDB_LOCAL_IMAGE"]
        cls.container = None
        cls.password = _random_password()

        # Sanity check the image is present locally before we try to run it.
        result = _docker("image", "inspect", cls.image, check=False)
        if result.returncode != 0:
            raise unittest.SkipTest(
                f"Image not available locally: {cls.image}\n"
                f"docker image inspect stderr:\n{result.stderr}"
            )

        cls.container = f"docdb-image-test-{uuid.uuid4().hex[:8]}"

        # Start the container with random credentials and explicit
        # --skip-init-data; built-in sample-data loading is covered by a
        # separate scenario and we want a minimal, deterministic start.
        _docker(
            "run", "-d",
            "--name", cls.container,
            cls.image,
            "--username", DEFAULT_USERNAME,
            "--password", cls.password,
            "--skip-init-data",
        )

        # Wait for readiness or surface logs on failure.
        deadline = time.monotonic() + DEFAULT_READY_TIMEOUT
        while time.monotonic() < deadline:
            inspect = _docker(
                "inspect", "-f", "{{.State.Running}}", cls.container,
                check=False,
            )
            if inspect.returncode != 0 or inspect.stdout.strip() != "true":
                cls._cleanup_with_logs(
                    f"Container exited before becoming ready "
                    f"(state inspect: {inspect.stdout.strip()!r})"
                )

            logs = _docker("logs", cls.container, check=False)
            if READY_LOG in logs.stdout or READY_LOG in logs.stderr:
                return

            time.sleep(2)

        cls._cleanup_with_logs(
            f"Container did not produce the readiness log "
            f"'{READY_LOG}' within {DEFAULT_READY_TIMEOUT}s"
        )

    @classmethod
    def tearDownClass(cls):
        if cls.container:
            _docker("rm", "-f", cls.container, check=False)
            cls.container = None

    @classmethod
    def _cleanup_with_logs(cls, message: str) -> None:
        """Print recent container logs and remove the container, then fail."""
        log_excerpt = ""
        if cls.container:
            logs = _docker("logs", cls.container, check=False)
            tail = "\n".join(
                (logs.stdout + logs.stderr).splitlines()[-60:]
            )
            log_excerpt = f"\n--- container logs (last 60 lines) ---\n{tail}"
            _docker("rm", "-f", cls.container, check=False)
            cls.container = None
        raise AssertionError(f"setUpClass failed: {message}{log_excerpt}")

    # ---------------------------------------------------------------------
    # Test cases
    # ---------------------------------------------------------------------

    def _mongosh(self, eval_code: str, *, username: str | None = None,
                 password: str | None = None) -> subprocess.CompletedProcess:
        """Run a mongosh --eval inside the container.

        Defaults to the configured admin credentials. Pass an explicit
        username/password for negative-path tests.
        """
        user = username if username is not None else DEFAULT_USERNAME
        pw = password if password is not None else self.password
        return _docker(
            "exec", "-i", self.container,
            "mongosh",
            f"localhost:{DEFAULT_PORT}",
            "-u", user, "-p", pw,
            "--authenticationMechanism", "SCRAM-SHA-256",
            "--tls", "--tlsAllowInvalidCertificates",
            "--quiet",
            "--eval", eval_code,
            check=False,
            timeout=30,
        )

    def test_container_is_running(self):
        """The container should still be in the running state."""
        result = _docker("inspect", "-f", "{{.State.Running}}", self.container)
        self.assertEqual(
            result.stdout.strip(), "true",
            f"container not running: {result.stdout!r}",
        )

    def test_readiness_log_is_present(self):
        """The entrypoint should have written its readiness marker to stdout."""
        logs = _docker("logs", self.container)
        combined = logs.stdout + logs.stderr
        self.assertIn(
            READY_LOG, combined,
            f"readiness log not found in container logs (last 40 lines):\n"
            + "\n".join(combined.splitlines()[-40:]),
        )

    def test_mongosh_ping_succeeds_with_correct_credentials(self):
        """mongosh ping with the configured creds should return ok=1."""
        result = self._mongosh("db.runCommand({ping: 1}).ok")
        self.assertEqual(
            result.returncode, 0,
            f"mongosh exited {result.returncode}\nstdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}",
        )
        last_line = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        self.assertEqual(
            last_line, "1",
            f"expected ping ok=1 as the last stdout line, got {last_line!r}\n"
            f"full stdout:\n{result.stdout}",
        )

    def test_mongosh_ping_rejected_with_wrong_password(self):
        """Authentication must be enforced - a wrong password must fail."""
        result = self._mongosh(
            "db.runCommand({ping: 1})",
            password=self.password + "-wrong",
        )
        self.assertNotEqual(
            result.returncode, 0,
            "mongosh unexpectedly succeeded with a wrong password "
            "(this means auth is not being enforced)\nstdout:\n"
            f"{result.stdout}\nstderr:\n{result.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
