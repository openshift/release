#!/usr/bin/env python3

"""Hermetic full-step tests: python3 hack/rosa_gather_rhobs_logs_test.py."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STEP = ROOT / "ci-operator/step-registry/rosa/gather/rhobs-logs"
SCRIPT = STEP / "rosa-gather-rhobs-logs-commands.sh"
MARKER = "synthetic-response-marker"
SUCCESS = {"status": "success", "data": {"resultType": "streams", "result": [
    {"stream": {"app": "fixture"}, "values": [["123", "first\nsecond"], ["456", "third"]]}
]}}
EMPTY = {"status": "success", "data": {"resultType": "streams", "result": []}}
FAKE_CURL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

arguments = sys.argv[1:]
if "-X" in arguments:
    print('{"access_token":"synthetic-token"}')
    sys.exit(0)
assert "--max-time" in arguments and arguments[arguments.index("--max-time") + 1] == "120"
assert "-w" in arguments and "\n%{http_code}" in arguments
query = next(argument[6:] for argument in arguments if argument.startswith("query="))
config = json.loads(Path(os.environ["FIXTURE_CONFIG"]).read_text())
mode = config["mode"]
if mode == "mixed":
    names = ("ovnkube-controller", "cloud-network-config-controller", "egressip")
    name = next((name for name in names if name in query), None)
    if name:
        barrier = Path(os.environ["FIXTURE_BARRIER"])
        (barrier / name).touch()
        deadline = time.monotonic() + 5
        while len(list(barrier.iterdir())) != 3:
            if time.monotonic() > deadline:
                sys.exit(99)
            time.sleep(0.01)
    mode = {"ovnkube-controller": "success", "cloud-network-config-controller": "timeout",
            "egressip": "malformed"}.get(name, "http" if "ocm-staging-" in query else "success")
exit_code, http_code = {"http": (22, "503"), "transport": (7, "000"),
                        "timeout": (28, "200"), "redirect": (0, "302")}.get(mode, (0, "200"))
body = config["success"] if mode in ("success", "timeout", "transport", "http", "redirect") else config["body"]
sys.stdout.write(body + "\n" + http_code)
sys.stderr.write("synthetic-token synthetic-response-marker")
sys.exit(exit_code)
'''


class RhobsLogsTest(unittest.TestCase):
    """Execute the ref's entire Bash consumer with only the credential mount relocated."""

    def run_step(self, mode, body=None, output_errors=False, fallback=False):
        """Supply synthetic curl responses; no credentials, kubeconfig or network are used."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("bin", "shared", "artifacts", "credentials", "barrier"):
                (root / name).mkdir()
            for name in ("client_id", "client_secret", "oidc_issuer_url"):
                (root / "credentials" / name).write_text("synthetic-fixture")
            if not fallback:
                (root / "shared/cluster-id").write_text("synthetic-cluster")
            config = {"mode": mode, "success": json.dumps(SUCCESS),
                      "body": body if isinstance(body, str) else json.dumps(body)}
            (root / "config.json").write_text(json.dumps(config))
            curl = root / "bin/curl"
            curl.write_text(FAKE_CURL)
            curl.chmod(0o755)
            script = root / "step.sh"
            source = SCRIPT.read_text()
            self.assertIn("commands: " + SCRIPT.name,
                          (STEP / "rosa-gather-rhobs-logs-ref.yaml").read_text())
            script.write_text(source.replace("/usr/local/rhobs-oidc", str(root / "credentials")))
            logs = root / "artifacts/rhobs-logs"
            logs.mkdir()
            if output_errors:
                (logs / "mco.txt").mkdir()
                (logs / "cert-manager.txt.status.json").mkdir()
            else:
                (logs / "mco.txt").write_text("stale-output")
            environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                               SHARED_DIR=str(root / "shared"), ARTIFACT_DIR=str(root / "artifacts"),
                               OCM_LOGIN_ENV="staging", FIXTURE_CONFIG=str(root / "config.json"),
                               FIXTURE_BARRIER=str(root / "barrier"))
            result = subprocess.run(["bash", str(script)], env=environment, capture_output=True,
                                    text=True, timeout=30, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            for forbidden in (MARKER, "synthetic-token", "first", "stale-output"):
                self.assertNotIn(forbidden, result.stdout)
            artifacts = {str(path.relative_to(logs)): path.read_text()
                         for path in logs.rglob("*") if path.is_file()}
            self.assertFalse(any(".rhobs-" in name for name in artifacts))
            statuses = {name.removesuffix(".status.json"): json.loads(content)
                        for name, content in artifacts.items() if name.endswith(".status.json")}
            for status in statuses.values():
                self.assertEqual(set(status), {"outcome", "entries", "curl_exit", "http_status",
                                               "output_cleanup_failed"})
                self.assertLess(len(json.dumps(status)), 200)
                self.assertNotIn(MARKER, json.dumps(status))
            return artifacts, statuses, result.stdout

    def test_success_preserves_messages(self):
        artifacts, statuses, stdout = self.run_step("success")
        self.assertEqual(len(statuses), 13)
        for name, status in statuses.items():
            self.assertEqual(status, {"outcome": "success_nonempty", "entries": 2,
                                      "curl_exit": 0, "http_status": 200,
                                      "output_cleanup_failed": False})
            self.assertEqual(artifacts[name], "first\nsecond\nthird\n")
        self.assertEqual(stdout.count("Loki outcome:"), 13)

    def test_empty_is_success(self):
        artifacts, statuses, _ = self.run_step("empty", EMPTY)
        self.assertEqual(len(statuses), 13)
        for name, status in statuses.items():
            self.assertEqual(status["outcome"], "success_empty")
            self.assertEqual(status["entries"], 0)
            self.assertEqual(artifacts[name], "")

    def test_failures_never_publish_partial_or_stale_logs(self):
        cases = [
            ("http", None, "http_error", 22, 503),
            ("redirect", None, "http_error", 0, 302),
            ("transport", None, "transport_error", 7, 0),
            ("timeout", None, "timeout", 28, 200),
            ("malformed", MARKER, "malformed_json", 0, 200),
            ("malformed", "[" * 10000 + "]" * 10000, "malformed_json", 0, 200),
            ("api", {"status": "error", "error": MARKER}, "api_error", 0, 200),
            ("schema", {}, "schema_error", 0, 200),
            ("schema", [], "schema_error", 0, 200),
            ("schema", {"status": "success", "data": {"result": []}}, "schema_error", 0, 200),
            ("schema", {"status": "success", "data": {"resultType": "matrix", "result": []}},
             "schema_error", 0, 200),
            ("schema", {"status": "success", "data": {"resultType": "streams", "result": [
                {"values": [["123", MARKER], ["456", 7]]}]}}, "schema_error", 0, 200),
        ]
        for mode, body, outcome, curl_exit, http_status in cases:
            with self.subTest(mode=mode, body=body):
                artifacts, statuses, stdout = self.run_step(mode, body)
                self.assertEqual(len(statuses), 13)
                self.assertFalse(any(name.endswith(".txt") for name in artifacts))
                for status in statuses.values():
                    self.assertEqual(status, {"outcome": outcome, "entries": 0,
                                              "curl_exit": curl_exit, "http_status": http_status,
                                              "output_cleanup_failed": False})
                self.assertIn("cs-telemetry.txt outcome=" + outcome, stdout)

    def test_parallel_queries_and_later_gathers_continue(self):
        artifacts, statuses, _ = self.run_step("mixed", MARKER)
        self.assertEqual(len(statuses), 13)
        self.assertEqual(statuses["hcp-guest-cluster.txt"]["outcome"], "http_error")
        self.assertEqual(statuses["ovnkube-controller.txt"]["outcome"], "success_nonempty")
        self.assertEqual(statuses["cloud-network-config-controller.txt"]["outcome"], "timeout")
        self.assertEqual(statuses["egressip-filtered.txt"]["outcome"], "malformed_json")
        self.assertEqual(artifacts["cs-telemetry.txt"], "first\nsecond\nthird\n")

    def test_output_and_sidecar_failures_are_reported(self):
        artifacts, statuses, stdout = self.run_step("success", output_errors=True)
        self.assertEqual(statuses["mco.txt"]["outcome"], "output_error")
        self.assertEqual(statuses["mco.txt"]["entries"], 0)
        self.assertTrue(statuses["mco.txt"]["output_cleanup_failed"])
        self.assertNotIn("mco.txt", artifacts)
        self.assertIn("cert-manager.txt outcome=success_nonempty entries=2 "
                      "curl_exit=0 http_status=200 sidecar=write_error", stdout)
        self.assertIn("cs-telemetry.txt", artifacts)

    def test_encoding_failure_removes_stale_output(self):
        response = {"status": "success", "data": {"resultType": "streams", "result": [
            {"values": [["123", "\ud800"]]}]}}
        artifacts, statuses, _ = self.run_step("schema", response)
        self.assertEqual(statuses["mco.txt"]["outcome"], "output_error")
        self.assertFalse(statuses["mco.txt"]["output_cleanup_failed"])
        self.assertNotIn("mco.txt", artifacts)

    def test_fallback_consumer(self):
        _, statuses, _ = self.run_step("empty", EMPTY, fallback=True)
        self.assertEqual(statuses["all-cs/cs-telemetry.txt"]["outcome"], "success_empty")


if __name__ == "__main__":
    unittest.main()
