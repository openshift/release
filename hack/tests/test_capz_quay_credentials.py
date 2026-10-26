"""Exercise the CAPZ credential diagnostics with synthetic secrets and kubectl."""

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
STEPS = ROOT / "ci-operator/step-registry/capz/arohcp"
AUTH = base64.b64encode(b"robot:test-token-do-not-log").decode()
CONFIG = {"auths": {"quay.io": {"auth": AUTH}}}
DIGEST = hashlib.sha256(b"robot:test-token-do-not-log").hexdigest()


class QuayCredentialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def assert_private(self, result):
        for value in (AUTH, "test-token-do-not-log", DIGEST):
            self.assertNotIn(value, result.stdout + result.stderr)

    def source_check(self, config, expected=DIGEST):
        source = (STEPS / "write-env/capz-arohcp-write-env-commands.sh").read_text()
        start = source.index('# Validate and fingerprint the mounted Quay credential.')
        end = source.index('# Write resolved environment', start)
        credential = self.directory / "auth.json"
        credential.write_text(config if isinstance(config, str) else json.dumps(config))
        env = dict(os.environ, SHARED_DIR=str(self.directory),
                   QUAY_CREDS_FILE=str(credential), QUAY_AUTH_EXPECTED_SHA256=expected)
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", source[start:end]],
                                env=env, text=True, capture_output=True, check=False)
        self.assert_private(result)
        return result

    def test_mounted_credential_matches_known_good_value(self):
        self.assertEqual(self.source_check(CONFIG).returncode, 0)
        self.assertEqual((self.directory / "quay-auth.sha256").read_text().strip(), DIGEST)
        self.assertEqual((self.directory / "quay-auth.sha256").stat().st_mode & 0o777, 0o600)

    def test_empty_malformed_and_stale_mounted_credentials_fail_privately(self):
        for config in ({"auths": {}}, "not-json", {"auths": {"quay.io": {"auth": "!!!"}}},
                       {"auths": {"quay.io": {"auth": base64.b64encode(b"robot:").decode()}}}):
            with self.subTest(config=config):
                self.assertNotEqual(self.source_check(config).returncode, 0)
        self.assertNotEqual(self.source_check(CONFIG, "0" * 64).returncode, 0)

    def cluster_check(self, *, changed_secret=False, empty_environment=False,
                      wrong_reference=False, kubectl_failure=False, test_status=0, enabled=True):
        shared = self.directory
        binary = shared / "bin"
        binary.mkdir()
        (shared / "quay-auth.sha256").write_text(DIGEST + "\n")
        (shared / "capz-test-env.sh").write_text("set +x\n")
        fixtures = {}
        for namespace, secret, prefixes in [
                ("capi-system", "capi-manager-pull-credentials",
                 ["capi-controller-manager", "mce-capi-webhook-config"]),
                ("capz-system", "capz-manager-pull-credentials",
                 ["capz-controller-manager", "azureserviceoperator-controller-manager"])]:
            config = {"auths": {}} if changed_secret else CONFIG
            fixtures[f"{namespace}/secret"] = {
                "type": "kubernetes.io/dockerconfigjson",
                "data": {".dockerconfigjson": base64.b64encode(json.dumps(config).encode()).decode()}}
            fixtures[f"{namespace}/pods"] = {"items": [
                {"metadata": {"name": prefix + "-abc-123"},
                 "spec": {"imagePullSecrets": [{"name": "wrong" if wrong_reference else secret}]}}
                for prefix in prefixes]}
        (shared / "fixtures.json").write_text(json.dumps(fixtures))
        kubectl = binary / "kubectl"
        kubectl.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                           "if os.environ['KUBECTL_FAILURE'] == '1':\n"
                           " print('test-token-do-not-log', file=sys.stderr)\n sys.exit(1)\n"
                           "args=sys.argv[1:]\n"
                           "assert '--kubeconfig' in args and '-n' in args\n"
                           "ns=args[args.index('-n')+1]\n"
                           "kind=args[args.index('get')+1]\n"
                           "print(json.dumps(json.load(open(os.environ['FIXTURES']))[ns+'/'+kind]))\n")
        kubectl.chmod(0o755)
        runner = binary / "script"
        runner.write_text(f"#!/bin/bash\nexit {test_status}\n")
        runner.chmod(0o755)
        config = {"auths": {}} if empty_environment else CONFIG
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                   SHARED_DIR=str(shared), ARTIFACT_DIR=str(shared), ARO_REPO_DIR=str(shared),
                   IMAGE_PULL_SECRET_B64=base64.b64encode(json.dumps(config).encode()).decode(),
                   FIXTURES=str(shared / "fixtures.json"), KUBECTL_FAILURE=str(int(kubectl_failure)),
                   QUAY_AUTH_DIAGNOSTICS=str(enabled).lower())
        result = subprocess.run(
            ["bash", str(STEPS / "management-cluster/capz-arohcp-management-cluster-commands.sh")],
            env=env, text=True, capture_output=True, check=False)
        self.assert_private(result)
        return result

    def test_unconfigured_jobs_keep_existing_behavior(self):
        self.assertEqual(self.source_check({"auths": {}}, "").returncode, 0)
        self.assertFalse((self.directory / "quay-auth.sha256").exists())
        result = self.cluster_check(enabled=False, kubectl_failure=True)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("[quay-diag]", result.stdout)

    def test_matching_environment_secrets_and_pods_pass(self):
        result = self.cluster_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("environment → CAPI pull secret: MATCH", result.stdout)
        self.assertIn("environment → CAPZ pull secret: MATCH", result.stdout)

    def test_empty_environment_is_detected(self):
        self.assertNotEqual(self.cluster_check(empty_environment=True).returncode, 0)

    def test_empty_cluster_secret_is_detected(self):
        self.assertNotEqual(self.cluster_check(changed_secret=True).returncode, 0)

    def test_wrong_pod_reference_is_detected(self):
        self.assertNotEqual(self.cluster_check(wrong_reference=True).returncode, 0)

    def test_api_failure_is_reported_without_raw_stderr(self):
        self.assertNotEqual(self.cluster_check(kubectl_failure=True).returncode, 0)

    def test_diagnostics_run_after_failure_and_preserve_original_status(self):
        result = self.cluster_check(test_status=42, changed_secret=True)
        self.assertEqual(result.returncode, 42)
        self.assertIn("environment → CAPI pull secret: INVALID", result.stdout)


if __name__ == "__main__":
    unittest.main()
