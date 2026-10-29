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

    def source_check(self, config, expected=DIGEST, metadata=None, registry=None):
        source = (STEPS / "write-env/capz-arohcp-write-env-commands.sh").read_text()
        start = source.index('# Validate and fingerprint the mounted Quay credential.')
        end = source.index('# Write resolved environment', start)
        credential = self.directory / "auth.json"
        credential.write_text(config if isinstance(config, str) else json.dumps(config))
        env = dict(os.environ, SHARED_DIR=str(self.directory),
                   QUAY_CREDS_FILE=str(credential), QUAY_AUTH_EXPECTED_SHA256=expected,
                   QUAY_USERNAME_EXPECTED_SHA256=hashlib.sha256(b"robot").hexdigest(),
                   QUAY_TOKEN_EXPECTED_SHA256=hashlib.sha256(b"test-token-do-not-log").hexdigest(),
                   NAMESPACE="", QUAY_DIAGNOSTIC_IMAGES="")
        if metadata is not None or registry is not None:
            binary = self.directory / "bin"
            binary.mkdir(exist_ok=True)
            fixture = self.directory / "metadata.json"
            fixture.write_text(json.dumps(metadata or {}))
            registry_fixture = self.directory / "registry.json"
            registry_fixture.write_text(json.dumps(registry or {}))
            oc = binary / "oc"
            oc.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                          "args=sys.argv[1:]\n"
                          "if args[:2] == ['image','info']:\n"
                          " assert args[args.index('--registry-config')+1] == os.environ['QUAY_CREDS_FILE']\n"
                          " assert '--filter-by-os=linux/amd64' in args\n"
                          " data=json.load(open(os.environ['REGISTRY_FIXTURE']))\n"
                          " print(data.get('stdout','test-token-do-not-log'))\n"
                          " print(data.get('stderr',''),file=sys.stderr)\n"
                          " sys.exit(data.get('status',0))\n"
                          "assert 'KUBECONFIG' not in os.environ\n"
                          "kind=args[args.index('get')+1]\n"
                          "data=json.load(open(os.environ['METADATA_FIXTURE']))\n"
                          "if kind not in data:\n"
                          " print('test-token-do-not-log',file=sys.stderr)\n sys.exit(1)\n"
                          "print(json.dumps(data[kind]))\n")
            oc.chmod(0o755)
            env.update(PATH=str(binary) + os.pathsep + env["PATH"],
                       METADATA_FIXTURE=str(fixture), NAMESPACE="ci-test",
                       REGISTRY_FIXTURE=str(registry_fixture),
                       HOSTNAME="write-env", KUBECONFIG="/must-not-use-aks-config")
        if registry is not None:
            env['QUAY_DIAGNOSTIC_IMAGES'] = (
                'quay.io/acm-d/ose-cluster-api-rhel9:v5.0 '
                'quay.io/acm-d/mce-capi-webhook-config-rhel9:5.0-dev '
                'quay.io/acm-d/cluster-api-provider-azure-rhel9:5.0-dev '
                'quay.io/acm-d/azure-service-operator-rhel9:5.0-dev')
        command = source[start:end] + '\nif [[ "$QUAY_AUTH_DIAGNOSTICS" == true ]]; then probe_quay_images; fi\n'
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", command],
                                env=env, text=True, capture_output=True, check=False)
        self.assert_private(result)
        return result

    def test_mounted_credential_matches_known_good_value(self):
        self.assertEqual(self.source_check(CONFIG).returncode, 0)
        self.assertEqual((self.directory / "quay-auth.sha256").read_text().strip(), DIGEST)
        self.assertEqual((self.directory / "quay-auth.sha256").stat().st_mode & 0o777, 0o600)

    def test_empty_and_malformed_mounted_credentials_fail_privately(self):
        for config in ({"auths": {}}, "not-json", {"auths": {"quay.io": {"auth": "!!!"}}},
                       {"auths": {"quay.io": {"auth": base64.b64encode(b"robot:").decode()}}}):
            with self.subTest(config=config):
                self.assertNotEqual(self.source_check(config).returncode, 0)
        self.assertEqual(self.source_check(CONFIG, "0" * 64).returncode, 0)

    def test_csi_source_and_resolved_version_are_reported_without_payloads(self):
        resource = "projects/openshift-ci-secrets/secrets/collection__group__field/versions/latest"
        metadata = {
            "pod": {"spec": {
                "containers": [{"name": "test", "volumeMounts": [
                    {"name": "quay", "mountPath": "/etc/quay-pull-credentials"}]}],
                "volumes": [{"name": "quay", "csi": {
                    "driver": "secrets-store.csi.k8s.io",
                    "volumeAttributes": {"secretProviderClass": "quay-spc"}}}]}},
            "secretproviderclass": {"spec": {"provider": "gcp", "parameters": {
                "secrets": "- resourceName: " + resource + "\n  fileName: .dockerconfigjson\n",
                "unexpected-secret": "test-token-do-not-log"}}},
            "secretproviderclasspodstatuses": {"items": [{"status": {
                "podName": "write-env", "secretProviderClassName": "quay-spc",
                "objects": [{"id": resource, "version": "17"}]}}]}}
        result = self.source_check(CONFIG, "0" * 64, metadata)
        self.assertEqual(result.returncode, 0)
        self.assertIn("CSI provider: gcp", result.stdout)
        self.assertIn(resource, result.stdout)
        self.assertIn("Resolved GSM version: 17", result.stdout)
        self.assertNotIn("unexpected-secret", result.stdout)
        metadata["secretproviderclasspodstatuses"]["items"][0]["status"]["objects"][0]["version"] = (
            resource.rsplit("/", 1)[0] + "/17")
        result = self.source_check(CONFIG, "0" * 64, metadata)
        self.assertIn("Resolved GSM version: 17", result.stdout)

    def test_metadata_access_failure_does_not_hide_credential_mismatch(self):
        result = self.source_check(CONFIG, "0" * 64, {})
        self.assertEqual(result.returncode, 0)
        self.assertIn("Source metadata: UNAVAILABLE", result.stdout)
        self.assertIn("username vs known-good: MATCH", result.stdout)

    def test_sibling_fields_can_match_when_docker_config_is_stale(self):
        (self.directory / "auth").write_text(AUTH)
        (self.directory / "acm_d_mce_quay_username").write_text("robot")
        (self.directory / "acm_d_mce_quay_pullsecret").write_text("test-token-do-not-log")
        stale = {"auths": {"quay.io": {"auth": base64.b64encode(b"old:old-token").decode()}}}
        result = self.source_check(stale)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Sibling auth decoded pair vs known-good: MATCH", result.stdout)
        self.assertIn("Sibling username vs known-good: MATCH", result.stdout)
        self.assertIn("Sibling token vs known-good: MATCH", result.stdout)

    def test_username_and_token_changes_are_distinguished_without_values(self):
        for credential, username, token in [
                (b"other-robot:test-token-do-not-log", "MISMATCH", "MATCH"),
                (b"robot:other-token-do-not-log", "MATCH", "MISMATCH")]:
            with self.subTest(username=username, token=token):
                config = {"auths": {"quay.io": {
                    "auth": base64.b64encode(credential).decode()}}}
                result = self.source_check(config)
                self.assertEqual(result.returncode, 0)
                self.assertIn("username vs known-good: " + username, result.stdout)
                self.assertIn("token vs known-good: " + token, result.stdout)
                self.assertNotIn(credential.decode(), result.stdout + result.stderr)
                self.assertNotIn("other-token-do-not-log", result.stdout + result.stderr)

    def test_whitespace_only_difference_is_identified_without_trimming_credentials(self):
        for credential, component in [
                (b" robot :test-token-do-not-log", "username"),
                (b"robot: test-token-do-not-log\r\n", "token")]:
            with self.subTest(component=component):
                config = {"auths": {"quay.io": {
                    "auth": base64.b64encode(credential).decode()}}}
                result = self.source_check(config)
                self.assertEqual(result.returncode, 0)
                self.assertIn(component + " leading/trailing whitespace: YES", result.stdout)
                self.assertIn(component + " after trimming whitespace vs known-good: MATCH", result.stdout)
                self.assertEqual((self.directory / "quay-auth.sha256").read_text().strip(),
                                 hashlib.sha256(credential).hexdigest())

    def test_different_reference_does_not_block_successful_manifest_access(self):
        result = self.source_check(CONFIG, "0" * 64, registry={"status": 0})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Prow mount: MISMATCH", result.stdout)
        self.assertEqual(result.stdout.count("manifest access: SUCCESS"), 4)
        self.assertFalse(list(self.directory.glob("quay-image-probe.*")))

    def test_manifest_errors_are_classified_without_raw_output(self):
        for message, status, category in [
                ("unauthorized test-token-do-not-log", 1, "AUTHENTICATION REJECTED"),
                ("403 Forbidden test-token-do-not-log", 1, "ACCESS DENIED"),
                ("429 Too Many Requests test-token-do-not-log", 1, "RATE LIMITED"),
                ("no such host test-token-do-not-log", 1, "DNS FAILURE"),
                ("x509: certificate test-token-do-not-log", 1, "TLS FAILURE"),
                ("test-token-do-not-log", 124, "TIMEOUT"),
                ("manifest unknown test-token-do-not-log", 1, "IMAGE OR TAG NOT FOUND"),
                ("unknown test-token-do-not-log", 1, "UNCLASSIFIED ERROR")]:
            with self.subTest(category=category):
                result = self.source_check(CONFIG, registry={"status": status, "stderr": message})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout.count("manifest access: " + category), 4)
                self.assertFalse(list(self.directory.glob("quay-image-probe.*")))

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
