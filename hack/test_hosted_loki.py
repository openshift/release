"""Offline regression coverage for the hosted Loki install manifests.

Run with python3 hack/test_hosted_loki.py (requires PyYAML).
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


SCRIPT = (Path(__file__).resolve().parents[1] / "ci-operator/step-registry/ipi/install/"
          "hosted-loki/ipi-install-hosted-loki-commands.sh")
ARBITER_LABEL = "node-role.kubernetes.io/arbiter"


class HostedLokiTests(unittest.TestCase):
    """Render the real step without cluster access or production credentials."""

    def render(self, directory, proxy=False, trusted_ca=False, **overrides):
        """Run the step with fixture credentials and return parsed manifests."""
        shared = directory / "shared"
        shared.mkdir()
        binaries = directory / "bin"
        binaries.mkdir()
        cat = binaries / "cat"
        cat.write_text('''#!/bin/bash
case "${1:-}" in
  /var/run/loki-secret/*) printf fixture ;;
  *) exec /usr/bin/cat "$@" ;;
esac
''')
        cat.chmod(0o755)
        if proxy:
            config = "proxy:\n  httpsProxy: http://proxy.example.test:3128\n"
            if trusted_ca:
                config += "additionalTrustBundle: |\n  fixture-ca\n"
            (shared / "install-config.yaml").write_text(config)
        environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                           SHARED_DIR=str(shared), LOKI_ENABLED="true",
                           LOKI_USE_SERVICEMONITOR="true", JOB_NAME="hosted-loki-test",
                           BUILD_ID="1")
        environment.update(overrides)
        subprocess.run(["bash", str(SCRIPT)], env=environment, check=True,
                       capture_output=True, text=True)
        return [manifest for path in sorted(shared.glob("manifest_*.yml"))
                for manifest in yaml.safe_load_all(path.read_text())]

    def assert_placement(self, workload):
        """Check the required selector's shape and its label-presence semantics."""
        pod = workload["spec"]["template"]["spec"]
        terms = pod["affinity"]["nodeAffinity"][
            "requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"]
        self.assertEqual(terms, [{"matchExpressions": [
            {"key": ARBITER_LABEL, "operator": "DoesNotExist"}]}])
        for role in ("worker", "master"):
            labels = {"kubernetes.io/os": "linux", f"node-role.kubernetes.io/{role}": ""}
            for arbiter_value in (None, "", "true"):
                candidate = dict(labels)
                if arbiter_value is not None:
                    candidate[ARBITER_LABEL] = arbiter_value
                matches = all(candidate.get(key) == value
                              for key, value in pod.get("nodeSelector", {}).items())
                matches = matches and any(
                    all(expression["key"] not in candidate
                        for expression in term["matchExpressions"])
                    for term in terms)
                self.assertEqual(matches, arbiter_value is None, candidate)
        if workload["kind"] == "DaemonSet":
            self.assertEqual(pod["nodeSelector"], {"kubernetes.io/os": "linux"})
        else:
            self.assertNotIn("nodeSelector", pod)
        self.assertEqual(pod["tolerations"], [{"operator": "Exists"}])

    def test_rendered_workloads(self):
        """All pod templates exclude arbiters with or without proxy/CA/monitoring."""
        for proxy, trusted_ca in ((False, False), (True, False), (True, True)):
            for monitoring in ("true", ""):
                with self.subTest(proxy=proxy, trusted_ca=trusted_ca, monitoring=monitoring):
                    with tempfile.TemporaryDirectory() as temporary:
                        manifests = self.render(Path(temporary), proxy, trusted_ca,
                                                LOKI_USE_SERVICEMONITOR=monitoring)
                    workloads = [manifest for manifest in manifests
                                 if "template" in manifest.get("spec", {})]
                    self.assertEqual({(item["kind"], item["metadata"]["name"])
                                      for item in workloads},
                                     {("DaemonSet", "loki-promtail"),
                                      ("Deployment", "event-exporter")})
                    self.assertFalse(any(item["kind"] in ("Pod", "Job", "CronJob")
                                         for item in manifests))
                    for workload in workloads:
                        self.assert_placement(workload)
                    promtail = next(item for item in workloads if item["kind"] == "DaemonSet")
                    pod = promtail["spec"]["template"]["spec"]
                    collector = next(item for item in pod["containers"]
                                     if item["name"] == "prod-bearer-token")
                    environment = {item["name"]: item.get("value") for item in collector["env"]}
                    self.assertEqual(environment.get("HTTPS_PROXY"),
                                     "http://proxy.example.test:3128" if proxy else None)
                    self.assertEqual(environment.get("SSL_CERT_FILE"),
                                     "/etc/proxy-ca/ca-bundle.crt" if trusted_ca else None)
                    config = next(item for item in manifests if item["kind"] == "ConfigMap"
                                  and item["metadata"]["name"] == "loki-promtail")
                    client = yaml.safe_load(config["data"]["promtail.yaml"])["clients"][0]
                    self.assertEqual(client.get("proxy_url"),
                                     "http://proxy.example.test:3128" if proxy else None)
                    self.assertEqual(any(item["name"] == "proxy-trusted-ca"
                                         for item in pod["volumes"]), trusted_ca)
                    self.assertEqual(any(item["kind"] == "ServiceMonitor" for item in manifests),
                                     monitoring == "true")

    def test_disabled_and_ipv6(self):
        """Existing early exits still produce no manifests."""
        for overrides in ({"LOKI_ENABLED": "false"}, {"JOB_NAME": "e2e-ipv6"}):
            with self.subTest(overrides=overrides):
                with tempfile.TemporaryDirectory() as temporary:
                    self.assertEqual(self.render(Path(temporary), **overrides), [])


if __name__ == "__main__":
    unittest.main()
