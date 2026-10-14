#!/usr/bin/env python3

import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "ci-operator/step-registry/tls/scanner"


class TLSScannerTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        self.manifest = self.directory / "pod.yaml"
        self.marker = self.directory / "injected"
        self.arguments = self.directory / "arguments.json"
        self.environment = {
            **os.environ,
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "SHARED_DIR": str(self.directory),
            "ARTIFACT_DIR": str(self.directory / "artifacts"),
            "PULL_SPEC_TLS_SCANNER_TOOL": "scanner:test",
            "SCANNER_CPU": "4",
            "SCANNER_MEMORY": "4Gi",
            "SCANNER_NAMESPACE": "",
            "TLS_SCANNER_CLUSTER_LABEL": "",
            "SCAN_NAMESPACE": "openshift-ingress",
            "PQC_CHECK": "false",
            "EXPECTED_GROUPS": "",
            "SCAN_LIMIT_IPS": "",
            "TLS_PROFILE_TYPE": "",
            "TEST_MANIFEST": str(self.manifest),
            "TEST_ARGUMENTS": str(self.arguments),
        }
        self.write_executable("oc", '''#!/bin/bash
if [[ "$*" == "create -f -" ]]; then
    cat > "${TEST_MANIFEST}"
    exit 42
fi
''')
        self.write_executable("sleep", "#!/bin/bash\nexit 0\n")
        self.write_executable("scanner", '''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
Path(os.environ["TEST_ARGUMENTS"]).write_text(json.dumps(sys.argv[1:]))
''')

    def write_executable(self, name, contents):
        path = self.directory / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def run_step(self, value, step="run"):
        return subprocess.run(
            ["bash", str(SCANNER / step / f"tls-scanner-{step}-commands.sh")],
            env={**self.environment, "COMPONENT_FILTER": value},
            capture_output=True,
            text=True,
            check=False,
        )

    def scanner_arguments(self):
        pod = yaml.safe_load(self.manifest.read_text(encoding="utf-8"))
        command = pod["spec"]["containers"][0]["command"]
        self.assertEqual(command[:2], ["/bin/bash", "-c"])
        script = command[2].replace("/usr/local/bin/tls-scanner", str(self.directory / "scanner"))
        script = script.replace("/results", str(self.directory / "results"))
        result = subprocess.run(
            ["bash", "-c", "sleep() { :; }\n" + script],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.arguments.read_text(encoding="utf-8"))

    def test_safe_filters_are_single_literal_arguments(self):
        for step in ("run", "recheck"):
            for value in ("", "envoy", "envoy,gateway", " Envoy_1.v2, gateway-api ", "envoy,\tgateway"):
                with self.subTest(step=step, value=value):
                    result = self.run_step(value, step)
                    self.assertEqual(result.returncode, 42, result.stderr)
                    arguments = self.scanner_arguments()
                    component_arguments = [argument for argument in arguments if argument.startswith("--component-filter")]
                    self.assertEqual(component_arguments, [f"--component-filter={value}"] if value else [])
                    self.assertIn("--namespace-filter", arguments)
                    self.assertFalse(self.marker.exists())

    def test_malicious_and_invalid_filters_rejected_before_pod_creation(self):
        values = (
            f"$(touch {self.marker})",
            f"`touch {self.marker}`",
            f"envoy;touch {self.marker}",
            f"envoy'\";touch {self.marker};#",
            f"envoy\ntouch {self.marker}",
            "envoy|cat", "envoy&&true", "envoy>file", "envoy\\", "envoy*",
            ",envoy", "envoy,", "envoy,,gateway", " ", "--help", "envoy gateway",
        )
        for step in ("run", "recheck"):
            for value in values:
                with self.subTest(step=step, value=value):
                    result = self.run_step(value, step)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("Invalid COMPONENT_FILTER", result.stderr)
                    self.assertFalse(self.manifest.exists())
                    self.assertFalse(self.marker.exists())

    def test_ref_environment_parity_and_symlink(self):
        run = yaml.safe_load((SCANNER / "run/tls-scanner-run-ref.yaml").read_text())["ref"]
        recheck = yaml.safe_load((SCANNER / "recheck/tls-scanner-recheck-ref.yaml").read_text())["ref"]
        self.assertEqual(run["env"], recheck["env"])
        self.assertEqual(recheck["as"], "tls-scanner-recheck")
        commands = SCANNER / "recheck" / recheck["commands"]
        self.assertTrue(commands.is_symlink())
        self.assertEqual(commands.resolve(), SCANNER / "run" / run["commands"])

    def test_recheck_forwards_shared_parameters(self):
        self.environment.update({
            "SCANNER_NAMESPACE": "existing",
            "SCANNER_CPU_REQUEST": "500m",
            "SCANNER_CPU_LIMIT": "2",
            "SCANNER_MEM_REQUEST": "1Gi",
            "SCANNER_MEM_LIMIT": "3Gi",
            "EXPECTED_GROUPS": "X25519, x25519",
            "EXPECTED_GROUPS_MODE": "exact",
        })
        result = self.run_step("envoy", "recheck")
        self.assertEqual(result.returncode, 42, result.stderr)
        arguments = self.scanner_arguments()
        self.assertIn("--expected-groups=X25519,x25519", arguments)
        self.assertIn("--expected-groups-mode=exact", arguments)
        pod = yaml.safe_load(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(pod["metadata"]["namespace"], "existing")
        self.assertEqual(pod["spec"]["containers"][0]["resources"], {
            "requests": {"cpu": "500m", "memory": "1Gi"},
            "limits": {"cpu": "2", "memory": "3Gi"},
        })

    def test_gateway_jobs_remain_optional_and_ordered(self):
        for branch in ("main", "release-5.1"):
            with self.subTest(branch=branch):
                filename = f"openshift-cluster-ingress-operator-{branch}"
                config = yaml.safe_load((ROOT / "ci-operator/config/openshift/cluster-ingress-operator" / f"{filename}.yaml").read_text())
                test = next(test for test in config["tests"] if test["as"] == "tls-scanner-aws-gatewayapi")
                self.assertIs(test["optional"], True)
                self.assertIs(test["always_run"], False)
                self.assertEqual([step["ref"] for step in test["steps"]["test"] if "ref" in step], ["tls-scanner-run", "tls-13", "tls-scanner-recheck"])
                self.assertEqual(test["steps"]["env"]["TLS_13_TLS_ADHERENCE_POLICY"], "StrictAllComponents")
                jobs = yaml.safe_load((ROOT / "ci-operator/jobs/openshift/cluster-ingress-operator" / f"{filename}-presubmits.yaml").read_text())
                job = next(job for job in jobs["presubmits"]["openshift/cluster-ingress-operator"] if job["name"].endswith("-tls-scanner-aws-gatewayapi"))
                self.assertIs(job["optional"], True)
                self.assertIs(job["always_run"], False)
                escaped_branch = branch.replace(".", r"\.")
                self.assertEqual(job["branches"], [f"^{escaped_branch}$", f"^{escaped_branch}-"])
                self.assertEqual(job["annotations"]["pipeline_skip_if_only_changed"], test["pipeline_skip_if_only_changed"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
