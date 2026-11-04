#!/usr/bin/env python3
"""Offline selection checks: CONFIGRESOLVER_BINARY=/path/to/ci-operator-configresolver
python3 hack/test_rosa_e2e_selection.py.

Use the consumer from the image in Makefile's validate-step-registry target.
Only local configuration resolution and fixture-backed command scripts execute;
the suite binary is replaced with an argument recorder, never a cluster client.
"""

import contextlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "ci-operator/step-registry"
CONFIG = ROOT / ("ci-operator/config/openshift-online/rosa-e2e/"
                 "openshift-online-rosa-e2e-main__periodics.yaml")
PRIVATE_JOB = "rosa-hcp-e2e-privatelink-connectivity-mc-health-staging"
PUBLIC_JOB = "rosa-hcp-e2e-aws-vpc-cni-staging"
WORKFLOWS = {PRIVATE_JOB: "rosa-e2e-hcp-rosa-cli-private",
             PUBLIC_JOB: "rosa-e2e-hcp-aws-vpc-cni"}
CUSTOMER_FILTER = "Area:DataPlane || Area:CustomerFeatures"
PLATFORM_FILTER = "Area:ManagementPlane"
PRIVATE_FILTER = "Area:ManagementPlane && !Access:PublicAPI"


class RosaE2ESelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        binary = shutil.which(os.environ.get(
            "CONFIGRESOLVER_BINARY", "ci-operator-configresolver"))
        if binary is None:
            raise RuntimeError("Set CONFIGRESOLVER_BINARY to the configresolver consumer")
        resources = contextlib.ExitStack()
        cls.addClassCleanup(resources.close)
        directory = Path(resources.enter_context(tempfile.TemporaryDirectory()))
        config_directory = directory / "config/openshift-online/rosa-e2e"
        config_directory.mkdir(parents=True)
        shutil.copy(CONFIG, config_directory)
        kubeconfig = directory / "kubeconfig"
        kubeconfig.write_text(json.dumps({
            "apiVersion": "v1", "kind": "Config",
            "clusters": [{"name": "offline", "cluster": {"server": "http://127.0.0.1:1"}}],
            "contexts": [{"name": "offline", "context": {"cluster": "offline", "user": "offline"}}],
            "current-context": "offline", "users": [{"name": "offline", "user": {}}],
        }), encoding="utf-8")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        cls.url = f"http://127.0.0.1:{port}"
        log = resources.enter_context(
            (directory / "resolver.log").open("w+", encoding="utf-8"))
        cls.process = resources.enter_context(subprocess.Popen([
            binary, "--config", str(directory / "config"),
            "--registry", str(REGISTRY), "--port", str(port),
            "--ui-port", "0", "--gracePeriod", "1s",
        ], env={"PATH": os.environ["PATH"], "KUBECONFIG": str(kubeconfig)},
            stdout=log, stderr=subprocess.STDOUT))
        cls.addClassCleanup(cls.stop_resolver)
        for _ in range(120):
            if cls.process.poll() is not None:
                break
            try:
                with urllib.request.urlopen(cls.url + "/readyz", timeout=1):
                    return
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.5)
        log.seek(0)
        raise RuntimeError("Local configresolver failed to start:\n" + log.read())

    @classmethod
    def stop_resolver(cls):
        if cls.process.poll() is None:
            cls.process.terminate()
            try:
                cls.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait(timeout=10)

    def resolve(self, job_name=PRIVATE_JOB, environment=None):
        with urllib.request.urlopen(
                self.url + "/config?org=openshift-online&repo=rosa-e2e"
                "&branch=main&variant=periodics", timeout=30) as response:
            config = json.load(response)
        test = next(test for test in config["tests"] if test["as"] == job_name)
        if environment is None:
            return test["literal_steps"]["test"]
        config["tests"] = [test]
        del test["literal_steps"]
        test["steps"] = {"workflow": WORKFLOWS[job_name], "env": environment}
        request = urllib.request.Request(
            self.url + "/resolve", data=json.dumps(config).encode("utf-8"),
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                resolved = json.load(response)
        except urllib.error.HTTPError as error:
            self.fail(error.read().decode("utf-8"))
        return resolved["tests"][0]["literal_steps"]["test"]

    def run_step(self, step):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ("cluster-id", "mc-kubeconfig", "bp-kubeconfig", "ocm-token"):
                (directory / name).write_text("fixture", encoding="utf-8")
            environment = {"PATH": os.environ["PATH"],
                           "SHARED_DIR": temporary, "ARTIFACT_DIR": temporary,
                           "CLUSTER_PROFILE_DIR": temporary}
            environment.update({parameter["name"]: parameter["default"]
                                for parameter in step.get("env", [])})
            command = step["commands"].replace(
                "/usr/local/bin/e2e.test", "printf '%s\\n'")
            result = subprocess.run(["bash", "-c", command], env=environment,
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            return [argument.removeprefix("--ginkgo.label-filter=")
                    for argument in result.stdout.splitlines()
                    if argument.startswith("--ginkgo.label-filter=")]

    def assert_filters(self, steps, customer, platform):
        self.assertEqual([step["as"] for step in steps],
                         ["rosa-e2e-validate-customer", "rosa-e2e-validate-platform"])
        self.assertEqual(self.run_step(steps[0]), [customer] if customer else [])
        self.assertEqual(self.run_step(steps[1]), [platform] if platform else [])

    def test_private_workflow_preserves_both_plane_scopes(self):
        self.assert_filters(self.resolve(), CUSTOMER_FILTER, PRIVATE_FILTER)

    def test_public_workflow_keeps_public_api_coverage(self):
        self.assert_filters(self.resolve(PUBLIC_JOB),
                            CUSTOMER_FILTER, PLATFORM_FILTER)

    def test_legacy_filter_remains_supported(self):
        self.assert_filters(self.resolve(PUBLIC_JOB, {
            "LABEL_FILTER": "Importance:Critical"}),
            "Importance:Critical", "Importance:Critical")

    def test_platform_override_does_not_override_customer_filter(self):
        self.assert_filters(self.resolve(environment={"LABEL_FILTER": "Area:DataPlane"}),
                            "Area:DataPlane", PRIVATE_FILTER)

    def test_empty_platform_override_falls_back_to_legacy_filter(self):
        self.assert_filters(self.resolve(environment={"PLATFORM_LABEL_FILTER": ""}),
                            CUSTOMER_FILTER, PLATFORM_FILTER)

    def test_empty_filters_do_not_add_a_ginkgo_filter(self):
        self.assert_filters(self.resolve(environment={
            "PLATFORM_LABEL_FILTER": "", "LABEL_FILTER": ""}), "", "")


if __name__ == "__main__":
    unittest.main()
