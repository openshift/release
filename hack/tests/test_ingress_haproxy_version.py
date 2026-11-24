import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / (
    "ci-operator/step-registry/ingress/verify/haproxy-version/"
    "ingress-verify-haproxy-version-commands.sh"
)

MOCK_OC = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
scenario = json.loads(os.environ["MOCK_SCENARIO"])
with open(os.environ["MOCK_CALLS"], "a") as stream:
    stream.write(json.dumps(args) + "\n")

def output(value):
    print(json.dumps(value))
    sys.exit(0)

initial = scenario.get("installed_initial", False)
digest = "1" * 64 if initial else "2" * 64
image = "quay.io/ci/haproxy@sha256:" + digest
if scenario.get("mirror"):
    image = "mirror.invalid/haproxy@sha256:" + digest
if scenario.get("wrong_image"):
    image = "quay.io/ci/other@sha256:" + "9" * 64

if args[:3] == ["adm", "release", "info"]:
    payload = args[3]
    if any(arg.startswith("--image-for=") for arg in args):
        if scenario.get("missing_" + payload):
            sys.exit(1)
        print("quay.io/ci/haproxy@sha256:" + ("1" if payload == "initial" else "2") * 64)
        sys.exit(0)
    output({"metadata": {"version": "5.2.0" if scenario.get("wrong_release") else "5.1.0-ci"},
            "digest": "sha256:" + ("a" if payload == "initial" else "b") * 64})
if args[:2] == ["image", "info"]:
    output({"digest": "sha256:" + ("3" if scenario.get("platform_digest") else digest[0]) * 64})
if "wait" in args:
    sys.exit(1 if scenario.get("wait_failure") else 0)
if "rollout" in args:
    sys.exit(1 if scenario.get("rollout_failure") else 0)
if "exec" in args:
    print("HAProxy version 3.2.1" if scenario.get("second_bad") and "second-pod" in args else
          scenario.get("binary", "HAProxy version 3.4.1 2026/01/01"))
    sys.exit(1 if scenario.get("exec_failure") else 0)
if args[:3] == ["get", "clusterversion", "version"]:
    output({"status": {"desired": {"image": "initial" if initial else "latest"}}})
if args[:2] == ["get", "node"]:
    output({"status": {"nodeInfo": {"architecture": "amd64"}}})
if "ingresscontroller" in args:
    output({"status": {} if scenario.get("missing_status") else {
        "effectiveHAProxyVersion": "3.2" if scenario.get("wrong_status") else "3.4"}})
if "deployment" in args:
    replicas = 2 if scenario.get("second_bad") else 1
    output({"metadata": {"uid": "deployment", "generation": 7,
             "annotations": {"deployment.kubernetes.io/revision": "5"}},
            "spec": {"replicas": replicas, "selector": {"matchLabels": {"app": "router"}},
             "template": {"spec": {"containers": [{"name": "router"}],
               "initContainers": [] if scenario.get("missing_container") else [
                   {"name": "haproxy", "image": image}]}}},
            "status": {"replicas": replicas, "updatedReplicas": replicas, "availableReplicas": replicas,
                       "observedGeneration": 6 if scenario.get("stale_generation") else 7}})
if "replicasets" in args:
    output({"items": [{"metadata": {"uid": "current-rs",
        "ownerReferences": [{"uid": "deployment", "controller": True}],
        "annotations": {"deployment.kubernetes.io/revision": "5"}}}]})
if "pods" in args:
    pod = {"metadata": {"name": "current-pod", "uid": "current-pod-uid",
           "ownerReferences": [{"uid": "old-rs" if scenario.get("wrong_owner") else "current-rs",
                                 "controller": True}]},
           "spec": {"nodeName": "node", "containers": [{"name": "router"}],
                    "initContainers": [{"name": "haproxy", "image": image}]},
           "status": {"conditions": [{"type": "Ready", "status": "True"}],
            "initContainerStatuses": [{"name": "haproxy", "ready": not scenario.get("not_running"),
                "state": {"running": {}}, "imageID": "docker-pullable://registry/haproxy@sha256:" +
                ("9" if scenario.get("wrong_digest") else "3" if scenario.get("platform_digest") else digest[0]) * 64}]}}
    if scenario.get("terminating"):
        pod["metadata"]["deletionTimestamp"] = "2026-01-01T00:00:00Z"
    pods = [pod]
    if scenario.get("second_bad"):
        second = json.loads(json.dumps(pod))
        second["metadata"]["name"] = "second-pod"
        second["metadata"]["uid"] = "second-pod-uid"
        pods.append(second)
    if scenario.get("stale_pod"):
        old = json.loads(json.dumps(pod))
        old["metadata"]["name"] = "old-pod"
        old["metadata"]["ownerReferences"][0]["uid"] = "old-rs"
        pods.append(old)
    output({"items": pods})
raise SystemExit("Unexpected oc invocation: " + repr(args))
'''


class HAProxyVersionVerificationTests(unittest.TestCase):
    def run_verifier(self, scenario=None, stage="before", upgrade=False, version="3.4"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock = root / "oc"
            mock.write_text(MOCK_OC)
            mock.chmod(0o755)
            (root / "kubeconfig").touch()
            calls = root / "calls.jsonl"
            environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                               SHARED_DIR=str(root), ARTIFACT_DIR=str(root / "artifacts"),
                               RELEASE_IMAGE_INITIAL="initial", RELEASE_IMAGE_LATEST="latest",
                               HAPROXY_VERSION=version, HAPROXY_VERIFY_STAGE=stage,
                               HAPROXY_VERIFY_UPGRADE=str(upgrade).lower(),
                               MOCK_SCENARIO=json.dumps(scenario or {}), MOCK_CALLS=str(calls))
            result = subprocess.run(["bash", str(SCRIPT)], env=environment,
                                    capture_output=True, text=True, check=False)
            invoked = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            proof = root / "artifacts/haproxy-version.jsonl"
            records = [json.loads(line) for line in proof.read_text().splitlines()] if proof.exists() else []
            return result, invoked, records

    def test_valid_latest_and_upgrade_phases(self):
        for stage, upgrade, initial in [("before", False, False), ("after", False, False),
                                        ("before", True, True), ("after", True, False)]:
            with self.subTest(stage=stage, upgrade=upgrade):
                result, _, records = self.run_verifier({"installed_initial": initial}, stage, upgrade)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(records[0]["payload"], "initial" if initial else "latest")
                self.assertEqual(records[0]["effectiveVersion"], "3.4")
                self.assertEqual(records[0]["payloadVersion"], "5.1.0-ci")
                self.assertEqual(records[0]["image"].split(":")[-1], ("1" if initial else "2") * 64)

    def test_preflight_never_queries_or_executes_cluster_workloads(self):
        result, calls, records = self.run_verifier(stage="preflight", upgrade=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call[:3] == ["adm", "release", "info"] for call in calls))
        self.assertFalse(records)

    def test_mirrors_platform_digest_and_stale_pods(self):
        result, calls, records = self.run_verifier({"mirror": True, "platform_digest": True,
                                                   "stale_pod": True})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["imageID"], "sha256:" + "3" * 64)
        executions = [call for call in calls if "exec" in call]
        self.assertEqual(len(executions), 1)
        self.assertIn("current-pod", executions[0])

    def test_negative_verification_cases(self):
        scenarios = [{name: True} for name in ["missing_latest", "missing_status", "wrong_status",
                     "wrong_release", "missing_container", "wrong_image", "wrong_digest",
                     "rollout_failure", "wait_failure", "exec_failure", "wrong_owner",
                     "not_running", "stale_generation", "terminating"]]
        scenarios += [{"binary": version} for version in ["HAProxy version 3.2.1",
                      "HAProxy version 3x4.1", "HAProxy version 3.4-dev1",
                      "HAProxy version 3.4", "HAProxy version 3.4.invalid"]]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                result, _, _ = self.run_verifier(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_every_current_pod_is_checked(self):
        result, calls, _ = self.run_verifier({"second_bad": True})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len([call for call in calls if "exec" in call]), 2)

    def test_missing_initial_and_wrong_upgrade_phase_fail(self):
        for scenario, stage in [({"missing_initial": True}, "preflight"),
                                ({"installed_initial": False}, "before"),
                                ({"installed_initial": True}, "after")]:
            result, _, _ = self.run_verifier(scenario, stage, True)
            self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_missing_and_invalid_version(self):
        for version in ["", "3x4", "3.4;false"]:
            result, _, _ = self.run_verifier(version=version)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
