#!/usr/bin/env python3
"""Offline login regressions: python3 hack/test-rosa-sts-account-roles-login.py."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import venv


ROOT = Path(__file__).resolve().parents[1]
STEP = ROOT / "ci-operator/step-registry/rosa/sts/account-roles/create"
SCRIPT = STEP / "rosa-sts-account-roles-create-commands.sh"
HTML = "expected response content type 'application/json' but received 'text/html'"
SENTINEL = "SYNTHETIC_RESPONSE_BODY_DO_NOT_LOG"
CLIENT_ID = "synthetic-client-id"
CLIENT_SECRET = "synthetic-client-secret"
TOKEN = "synthetic-offline-token"
MOCK_ROSA = r'''import json
import os
from pathlib import Path
import sys

root = Path(os.environ["MOCK_ROOT"])
assert sys.executable == os.environ["MOCK_PYTHON"]
arguments = sys.argv[1:]
if arguments[0] != "login":
    with (root / "downstream").open("a") as stream:
        stream.write(arguments[0] + "\n")
    sys.exit(89)
events = [json.loads(line) for line in
          (root / "artifacts/rosa-sts-account-roles-login.jsonl").read_text().splitlines()]
assert events[-1]["event"] == "start"
with (root / "calls").open("a") as stream:
    stream.write(json.dumps(arguments) + "\n")
attempt = len((root / "calls").read_text().splitlines())
plan = json.loads((root / "plan").read_text())
status, stdout, stderr = plan[attempt - 1]
print(stdout)
print(stderr, file=sys.stderr)
sys.exit(status)
'''


class LoginTests(unittest.TestCase):
    """Exercise the complete inline step with synthetic credentials and safe mocks."""

    def run_case(self, plan, credentials="both", environment="staging", traced=False):
        """Check login behavior and output safety, returning captured mock evidence."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("bin", "profile", "shared", "artifacts"):
                (root / name).mkdir()
            (root / "profile/.awscred").write_text("synthetic-unused-aws-credential")
            (root / "shared/cluster-prefix").write_text("synthetic-prefix")
            files = {
                "client": {"sso-client-id": CLIENT_ID, "sso-client-secret": CLIENT_SECRET},
                "token": {"ocm-token": TOKEN},
                "partial": {"sso-client-id": CLIENT_ID},
                "secret_only": {"sso-client-secret": CLIENT_SECRET},
                "empty": {"sso-client-id": "", "sso-client-secret": "", "ocm-token": ""},
                "missing": {},
            }
            files["both"] = {**files["client"], **files["token"]}
            files["partial_token"] = {**files["partial"], **files["token"]}
            files["secret_token"] = {**files["secret_only"], **files["token"]}
            for name, value in files[credentials].items():
                (root / "profile" / name).write_text(value)
            (root / "plan").write_text(json.dumps(plan))
            mocks = {
                "rosa": f"#!{sys.executable}\n{MOCK_ROSA}",
                "sleep": '#!/bin/bash\nprintf "%s\\n" "$*" >> "$MOCK_ROOT/sleeps"\n',
                "aws": '#!/bin/bash\necho forbidden > "$MOCK_ROOT/cloud"; exit 98\n',
            }
            for name, contents in mocks.items():
                path = root / "bin" / name
                path.write_text(contents)
                path.chmod(0o755)
            environment_values = {
                "PATH": f"{root / 'bin'}:/usr/bin:/bin",
                "HOME": str(root),
                "MOCK_ROOT": str(root),
                "MOCK_PYTHON": sys.executable,
                "ARTIFACT_DIR": str(root / "artifacts"),
                "CLUSTER_PROFILE_DIR": str(root / "profile"),
                "SHARED_DIR": str(root / "shared"),
                "LEASED_RESOURCE": "synthetic-region",
                "OCM_LOGIN_ENV": environment,
                "CHANNEL_GROUP": "stable",
            }
            command = "#!/bin/bash\nset -eu\n" + SCRIPT.read_text()
            arguments = ["/bin/bash"] + (["-x"] if traced else []) + ["-c", command]
            result = subprocess.run(
                arguments, env=environment_values, capture_output=True, text=True,
                check=False, timeout=10,
            )
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()] \
                if (root / "calls").exists() else []
            sleeps = (root / "sleeps").read_text().splitlines() \
                if (root / "sleeps").exists() else []
            artifact = root / "artifacts/rosa-sts-account-roles-login.jsonl"
            events = [json.loads(line) for line in artifact.read_text().splitlines()]
            downstream = (root / "downstream").read_text().splitlines() \
                if (root / "downstream").exists() else []
            public_output = result.stdout + result.stderr
            public_output += "".join(path.read_text() for path in (root / "artifacts").rglob("*")
                                     if path.is_file())
            for sensitive in (CLIENT_ID, CLIENT_SECRET, TOKEN, SENTINEL, "<html>"):
                self.assertNotIn(sensitive, public_output)
            self.assertFalse((root / "cloud").exists())
            self.assertEqual(downstream, ["whoami"] if plan and plan[len(calls) - 1][0] == 0
                             and calls else [])
            self.assertEqual(len(events), 2 * max(len(calls), 1))
            for index, event in enumerate(events):
                self.assertEqual(event["event"], "start" if index % 2 == 0 else "result")
                self.assertRegex(event["timestamp_utc"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
                self.assertEqual(event["max_attempts"], 3)
                self.assertEqual(event["attempt"], index // 2 + 1 if calls else 0)
                self.assertEqual(event["endpoint"], "unknown")
                self.assertEqual(event["http_status"], "unknown")
                self.assertEqual(event["environment"], environment
                                 if environment in ("production", "staging", "integration")
                                 else "unknown")
                self.assertEqual(event["cli_exit_code"], None if index % 2 == 0 or not calls
                                 else plan[index // 2][0])
            for call in calls:
                expected = ["login", "--env", environment]
                expected += ["--client-id", CLIENT_ID, "--client-secret", CLIENT_SECRET] \
                    if credentials in ("both", "client") else ["--token", TOKEN]
                self.assertEqual(call, expected)
            return result.returncode, calls, sleeps, events

    def test_mock_uses_runner_interpreter(self):
        """Run login cases under a distinct virtualenv interpreter without pip/network."""
        with tempfile.TemporaryDirectory() as directory:
            venv.EnvBuilder(with_pip=False).create(directory)
            interpreter = Path(directory) / "bin/python"
            self.assertNotEqual(str(interpreter), sys.executable)
            result = subprocess.run(
                [str(interpreter), str(Path(__file__).resolve()),
                 "LoginTests.test_credentials_and_success_output_safety"],
                capture_output=True, text=True, check=False, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_credentials_and_success_output_safety(self):
        for credentials in ("client", "token", "both", "partial_token", "secret_token"):
            for traced in (False, True):
                with self.subTest(credentials=credentials, traced=traced):
                    status, calls, sleeps, events = self.run_case(
                        [(0, SENTINEL + CLIENT_SECRET, TOKEN)], credentials, traced=traced)
                    self.assertEqual(status, 89)
                    self.assertEqual(len(calls), 1)
                    self.assertEqual(sleeps, [])
                    self.assertEqual(events[-1]["class"], "success")

    def test_missing_and_partial_credentials(self):
        for credentials in ("missing", "partial", "secret_only", "empty"):
            with self.subTest(credentials=credentials):
                status, calls, sleeps, events = self.run_case([], credentials, traced=True)
                self.assertEqual((status, calls, sleeps), (1, [], []))
                self.assertEqual(events[-1]["class"], "missing_credentials")

    def test_html_recovery(self):
        for attempt in (2, 3):
            for stream in ("stdout", "stderr"):
                with self.subTest(attempt=attempt, stream=stream):
                    failure = (47, HTML + SENTINEL if stream == "stdout" else "",
                               HTML + SENTINEL if stream == "stderr" else "")
                    status, calls, sleeps, events = self.run_case(
                        [failure] * (attempt - 1) + [(0, SENTINEL, "")], traced=True)
                    self.assertEqual(status, 89)
                    self.assertEqual(len(calls), attempt)
                    self.assertEqual(sleeps, ["10", "20"][:attempt - 1])
                    self.assertEqual(events[1]["class"], "json_html_mismatch")

    def test_exhaustion_preserves_final_exit(self):
        status, calls, sleeps, events = self.run_case(
            [(41, HTML, ""), (42, "", HTML), (73, HTML + SENTINEL, CLIENT_SECRET)], traced=True)
        self.assertEqual((status, len(calls), sleeps), (73, 3, ["10", "20"]))
        self.assertEqual(events[-1]["cli_exit_code"], 73)

    def test_transport_candidates(self):
        for signature in ("TLS handshake timeout", "i/o timeout", "connection reset by peer"):
            with self.subTest(signature=signature):
                status, calls, sleeps, events = self.run_case(
                    [(35, signature, SENTINEL), (0, SENTINEL, "")])
                self.assertEqual((status, len(calls), sleeps), (89, 2, ["10"]))
                self.assertEqual(events[1]["class"], "transport_candidate")

    def test_transport_exhaustion(self):
        status, calls, sleeps, events = self.run_case(
            [(31, "i/o timeout", SENTINEL), (32, "connection reset by peer", SENTINEL),
             (33, "TLS handshake timeout", SENTINEL)], traced=True)
        self.assertEqual((status, len(calls), sleeps), (33, 3, ["10", "20"]))
        self.assertEqual(events[-1]["class"], "transport_candidate")

    def test_success_ignores_error_like_output(self):
        status, calls, sleeps, events = self.run_case(
            [(0, HTML + " invalid_client " + SENTINEL, "<html>" + TOKEN)], traced=True)
        self.assertEqual((status, len(calls), sleeps), (89, 1, []))
        self.assertEqual(events[-1]["class"], "success")

    def test_unknown_after_retry_stops(self):
        status, calls, sleeps, events = self.run_case(
            [(45, HTML, SENTINEL), (61, "unknown failure", SENTINEL)], traced=True)
        self.assertEqual((status, len(calls), sleeps), (61, 2, ["10"]))
        self.assertEqual(events[-1]["class"], "unknown")

    def test_permanent_precedes_candidates(self):
        for rejection in ("invalid_client", "invalid_grant", "401 Unauthorized", "403 Forbidden",
                          "invalid token", "token expired", "expired token"):
            with self.subTest(rejection=rejection):
                status, calls, sleeps, events = self.run_case(
                    [(64, HTML + " i/o timeout " + rejection, SENTINEL)], traced=True)
                self.assertEqual((status, len(calls), sleeps), (64, 1, []))
                self.assertEqual(events[-1]["class"], "auth_rejected")

    def test_unknown_errors_fail_immediately(self):
        for message in ("unclassified error", "expected response content type 'application/json' "
                        "but received 'text/plain'", "invalid character '<' looking for beginning "
                        "of value", "context deadline exceeded", "connection refused"):
            with self.subTest(message=message):
                status, calls, sleeps, events = self.run_case([(57, message, SENTINEL)])
                self.assertEqual((status, len(calls), sleeps), (57, 1, []))
                self.assertEqual(events[-1]["class"], "unknown")

    def test_rejection_after_retry_stops(self):
        status, calls, sleeps, events = self.run_case(
            [(45, HTML, SENTINEL), (62, "invalid_client", SENTINEL)])
        self.assertEqual((status, len(calls), sleeps), (62, 2, ["10"]))
        self.assertEqual(events[-1]["class"], "auth_rejected")

    def test_environment_allowlist(self):
        for environment in ("production", "integration", 'synthetic-untrusted-"\nvalue'):
            with self.subTest(environment=environment):
                self.run_case([(19, "unknown", "")], environment=environment, traced=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
