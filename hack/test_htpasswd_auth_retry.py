"""Offline regression tests for the multi-user htpasswd step's login retries."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


STEP = (Path(__file__).resolve().parents[1] / "ci-operator/step-registry/osd-ccs"
        / "conf/idp/htpasswd/multi-users/osd-ccs-conf-idp-htpasswd-multi-users-commands.sh")
SECRETS = ("mock-client-secret-value", "mock-offline-token-value", "mock-server-token-value")
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["MOCK_ROOT"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
calls_file = root / "calls.json"
if name == "head":
    if args == ["/dev/urandom"]:
        print("deterministicpassword")
        sys.exit(0)
    os.execv("/usr/bin/head", ["head"] + args)
if name == "jq":
    value = json.load(sys.stdin)
    print(value["items"][0]["id"] if args == ["-r", ".items[].id"] else json.dumps(value))
    sys.exit(0)
calls = json.loads(calls_file.read_text())
calls.append([name, args[0] if name == "ocm" else args])
calls_file.write_text(json.dumps(calls))
if name == "sleep":
    sys.exit(0)
if args == ["version"]:
    print("mock-version")
elif args[0] == "login":
    expected = ["--url", "staging"]
    if os.environ["AUTH_MODE"] == "sso":
        expected += ["--client-id", "mock-client-id", "--client-secret", "mock-client-secret-value"]
    else:
        expected += ["--token", "mock-offline-token-value"]
    if args[1:] != expected:
        sys.exit(99)
    index = sum(call == ["ocm", "login"] for call in calls) - 1
    message, status = json.loads(os.environ["LOGIN_RESULTS"])[index]
    print("mock-client-secret-value mock-offline-token-value mock-server-token-value")
    print(message + " mock-server-token-value", file=sys.stderr)
    sys.exit(status)
elif args[0] == "get":
    print('{"items":[{"id":"mock-idp"}]}')
elif args[0] == "post":
    json.load(sys.stdin)
    sys.exit(int(os.environ["POST_STATUS"]))
else:
    sys.exit(98)
'''


class HtpasswdAuthRetryTests(unittest.TestCase):
    def run_step(self, mode, results, attempts, delays, status=0):
        authenticated = attempts > 0 and results[attempts - 1][1] == 0
        post_status = status if authenticated else 0
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            profile = root / "profile"
            shared = root / "shared"
            temporary = root / "tmp"
            for path in (binaries, profile, shared, temporary):
                path.mkdir()
            for name in ("ocm", "sleep", "head", "jq"):
                executable = binaries / name
                executable.write_text(MOCK)
                executable.chmod(0o755)
            if mode != "none":
                (profile / "ocm-token").write_text(SECRETS[1])
            if mode == "partial":
                (profile / "sso-client-id").write_text("mock-client-id")
            if mode == "sso":
                (profile / "sso-client-id").write_text("mock-client-id")
                (profile / "sso-client-secret").write_text(SECRETS[0])
            (shared / "cluster-id").write_text("mock-cluster")
            (root / "calls.json").write_text("[]")
            environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                               CLUSTER_PROFILE_DIR=str(profile), SHARED_DIR=str(shared),
                               TMPDIR=str(temporary), OCM_LOGIN_ENV="staging", USER_COUNT="2",
                               MOCK_ROOT=str(root), AUTH_MODE=mode,
                               LOGIN_RESULTS=json.dumps(results), POST_STATUS=str(post_status))
            process = subprocess.run(["bash", "-x", str(STEP)], env=environment,
                                     capture_output=True, text=True, timeout=15, check=False)
            self.assertEqual(process.returncode, status, process.stdout + process.stderr)
            logs = process.stdout + process.stderr
            for secret in (*SECRETS, "mock-client-id"):
                self.assertNotIn(secret, logs)
            for message, _status in results:
                self.assertNotIn(message, logs)
            calls = json.loads((root / "calls.json").read_text())
            self.assertEqual(calls.count(["ocm", "login"]), attempts)
            self.assertEqual([call[1] for call in calls if call[0] == "sleep"], delays)
            self.assertEqual(calls.count(["ocm", "get"]), 2 if authenticated else 0)
            self.assertEqual(calls.count(["ocm", "post"]),
                             (1 if post_status else 2) if authenticated else 0)
            self.assertEqual((shared / "runtime_env").exists(), status == 0)
            self.assertEqual(list(temporary.iterdir()), [])
            for attempt in range(1, attempts + 1):
                self.assertIn(f"OCM login attempt {attempt}/3", logs)
            return logs

    def test_login_outcomes_in_both_modes(self):
        cases = (
            ([("success", 0)], 1, [], 0),
            ([("connection reset by peer", 7), ("success", 0)], 2, [["2"]], 0),
            ([("net/http: TLS handshake timeout", 7), ("success", 0)], 2, [["2"]], 0),
            ([("connection reset by peer", 7), ("connection reset by peer", 8),
              ("success", 0)], 3, [["2"], ["4"]], 0),
            ([("connection reset by peer", 7), ("connection reset by peer", 8),
              ("connection reset by peer", 42)], 3, [["2"], ["4"]], 42),
            ([("invalid credentials", 23)], 1, [], 23),
            ([("invalid_grant: connection reset by peer", 24)], 1, [], 24),
            ([("unexpected failure", 25)], 1, [], 25),
            ([("connection reset by peer", 7), ("unauthorized", 26)], 2, [["2"]], 26),
        )
        for mode in ("sso", "token"):
            for results, attempts, delays, status in cases:
                with self.subTest(mode=mode, results=results):
                    self.run_step(mode, results, attempts, delays, status)

    def test_credential_selection_edges(self):
        self.run_step("partial", [("success", 0)], 1, [])
        self.run_step("none", [], 0, [], status=1)

    def test_user_creation_failure_is_not_retried(self):
        for mode in ("sso", "token"):
            with self.subTest(mode=mode):
                self.run_step(mode, [("success", 0)], 1, [], status=37)


if __name__ == "__main__":
    unittest.main(verbosity=2)
