#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "ci-operator/step-registry"
HELPER = "rosa-hypershift-operator-gather-minimal"
SCRIPTS = {
    HELPER: "rosa/hypershift-operator/gather-minimal/" + HELPER,
    "rosa-e2e-test": "rosa/e2e/test/rosa-e2e-test",
    "rosa-hypershift-operator-deploy": "rosa/hypershift-operator/deploy/rosa-hypershift-operator-deploy",
    "rosa-hypershift-operator-verify-hcp-health": "rosa/hypershift-operator/verify-hcp-health/rosa-hypershift-operator-verify-hcp-health",
}

MOCK = r'''#!/usr/bin/python3
import json, os, pathlib, sys, time
from urllib.parse import urlparse, parse_qs
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get("MODE", "normal")
if command == "timeout":
    with open(os.environ["TIMEOUTS"], "a") as stream:
        stream.write(" ".join(args[:3]) + "\n")
    if mode == "timeout" and "60s" in args:
        sys.exit(124)
    os.execv("/usr/bin/timeout", ["timeout"] + args)
if command == "sleep":
    sys.exit(0)
if command == "curl":
    print(json.dumps({"tags":[{"name":"latest-fixture", "manifest_digest":"sha256:fixture"}]}))
    sys.exit(0)
if command == "mv" and mode == "write_error":
    sys.exit(1)
if command == "mv":
    os.execv("/usr/bin/mv", ["mv"] + args)
if command == "ocm":
    if "login" in args:
        print("{}")
    elif any("/osd_fleet_mgmt/" in arg for arg in args):
        print(json.dumps({"items":[{"cluster_management_reference":{"cluster_id":"fixture-mc"}}]}))
    elif any(arg.endswith("/credentials") for arg in args):
        print(json.dumps({"kubeconfig":"fixture-kubeconfig"}))
    elif any(arg.endswith("/hypershift") for arg in args):
        print("{}")
    else:
        print(json.dumps({"name":"fixture-mc", "items":[{"id":"fixture-mc"}]}))
    sys.exit(0)
if "--raw" not in args:
    if "rollout" in args:
        if mode in ("locked", "match"):
            sys.exit(99)
        sys.exit(int(os.environ.get("ORIGINAL_EXIT", "0")))
    if "configmap" in args:
        if mode == "locked":
            print("fixture-lock")
        sys.exit(0)
    if any("readyReplicas" in arg for arg in args):
        print("1")
    elif any("image" in arg for arg in args):
        print("quay.io/acm-d/rhtap-hypershift-operator@sha256:fixture" if mode == "match" else "fixture-image")
    elif "--no-headers" in args:
        print("fixture-row")
    else:
        print(json.dumps({"items":[]}))
    sys.exit(0)
path = args[args.index("--raw") + 1]
with open(os.environ["REQUESTS"], "a") as stream:
    stream.write(path + "\n")
if mode == "permission":
    print("do-not-retain permission body", file=sys.stderr)
    sys.exit(1)
if mode == "blocked_request":
    time.sleep(30)
if mode == "malformed":
    print("do-not-retain invalid json")
    sys.exit(0)
if mode == "oversized":
    print(" " * 1048577)
    sys.exit(0)
namespace = "ocm-int-fixture-id-fixture-cluster"
hc_namespace = "ocm-int-fixture-id"
parsed = urlparse(path)
parts = parsed.path.split("/")
resource = parts[-1]
query = parse_qs(parsed.query)
foreign = "do-not-retain"
def metadata(name, ns=namespace, uid="fixture-uid"):
    return {"name":name,"namespace":ns,"uid":uid,"generation":7,"annotations":{"unsafe":foreign},"labels":{"unsafe":foreign}}
condition = {"type":"Available","status":"False","message":foreign,"reason":foreign,"observedGeneration":6,"lastTransitionTime":"2026-01-01T00:00:00Z"}
if mode == "unknown_enums":
    condition["status"] = foreign
def listing(items):
    return {"metadata":{"continue":"next" if mode == "truncated" or (mode == "workload_truncated" and resource != "hostedcontrolplanes") else ""},"items":items}
if resource == "hostedcontrolplanes":
    hcp = {"metadata":metadata("fixture-cluster"),"spec":{"clusterID":"fixture-uuid"},"status":{"conditions":[condition]}}
    hcp["metadata"]["annotations"]["hypershift.openshift.io/cluster"] = hc_namespace + "/fixture-cluster"
    if mode == "bad_target":
        hcp["metadata"]["annotations"]["hypershift.openshift.io/cluster"] = "other/other"
    result = listing([hcp])
elif "hostedclusters" in parts:
    result = {"metadata":metadata("fixture-cluster",hc_namespace),"spec":{"clusterID":"fixture-uuid"},"status":{"conditions":[condition]}}
elif resource == "nodepools":
    result = listing([{"metadata":metadata("fixture-pool",hc_namespace),"spec":{"clusterName":"fixture-cluster"},"status":{"conditions":[condition]}}, {"metadata":metadata(foreign,hc_namespace),"spec":{"clusterName":"other"},"status":{"conditions":[{"type":foreign,"status":"True"}]}}])
elif "deployments" in parts:
    role = "catalog" if resource == "redhat-operators-catalog" else "operator"
    ns = namespace if role == "catalog" else "hypershift"
    result = {"metadata":metadata(resource,ns,role + "-uid"),"spec":{"replicas":1,"selector":{"matchLabels":{"app":resource}},"template":{"spec":{"unsafe":foreign}}},"status":{"observedGeneration":6,"replicas":1,"updatedReplicas":1,"readyReplicas":0,"availableReplicas":0,"unavailableReplicas":1}}
    if mode == "absent":
        del result["status"]["readyReplicas"]
    if mode == "bad_selector":
        result["spec"]["selector"]["matchLabels"]["unsafe"] = "not,a,selector"
elif resource in ("replicasets","pods","events"):
    ns = parts[parts.index("namespaces") + 1]
    role = "catalog" if ns == namespace else "operator"
    if resource == "replicasets":
        owned = {"metadata":metadata("fixture-rs",ns,role + "-rs"),"spec":{"replicas":1},"status":{"replicas":1,"readyReplicas":0}}
        owned["metadata"]["ownerReferences"] = [{"uid":role + "-uid","kind":"Deployment","controller":True}]
        other = {"metadata":metadata(foreign,ns,"other-rs"),"spec":{"replicas":99},"status":{}}
        result = listing([owned,other])
    elif resource == "pods":
        owned = {"metadata":metadata("fixture-pod",ns,role + "-pod"),"spec":{"nodeName":foreign},"status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","message":foreign}],"containerStatuses":[{"name":foreign,"ready":False,"restartCount":3,"state":{"waiting":{"reason":"CrashLoopBackOff","message":foreign}},"lastState":{"terminated":{"exitCode":137,"signal":9,"reason":"OOMKilled","message":foreign,"finishedAt":"2026-01-01T00:00:00Z"}}}]}}
        owned["metadata"]["ownerReferences"] = [{"uid":role + "-rs","kind":"ReplicaSet","controller":True}]
        if mode == "unknown_enums":
            owned["status"]["phase"] = foreign
            owned["status"]["containerStatuses"][0]["state"]["waiting"]["reason"] = foreign
        other = {"metadata":metadata(foreign,ns),"status":{"phase":"Running"}}
        result = listing([] if mode == "no_pods" else [owned,other])
    else:
        result = listing([{"metadata":metadata("fixture-event",ns),"involvedObject":{"uid":role + "-pod","name":foreign},"type":"Warning","reason":"FailedScheduling","message":foreign,"count":2}, {"metadata":metadata(foreign,ns),"involvedObject":{"uid":"other"},"type":"Warning","reason":foreign,"count":99}])
else:
    raise SystemExit("unexpected fixture request")
print(json.dumps(result))
'''


class MinimalDiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.commands = self.directory / "commands"
        self.bin = self.directory / "bin"
        self.shared = self.directory / "shared"
        self.artifacts = self.directory / "artifacts"
        self.profile = self.directory / "profile"
        for directory in (self.commands, self.bin, self.shared, self.artifacts, self.profile):
            directory.mkdir()
        for key, path in SCRIPTS.items():
            shutil.copyfile(REGISTRY / (path + "-commands.sh"), self.commands / key)
        for name in ("oc", "ocm", "curl", "sleep", "timeout", "mv"):
            executable = self.bin / name
            executable.write_text(MOCK)
            executable.chmod(0o755)
        for name, value in (("cluster-id", "fixture-id"), ("cluster-name", "fixture-cluster"), ("hs-mc.kubeconfig", "fixture-kubeconfig")):
            (self.shared / name).write_text(value)
        (self.profile / "ocm-token").write_text("fixture-placeholder")
        self.environment = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"], SHARED_DIR=str(self.shared), ARTIFACT_DIR=str(self.artifacts), CLUSTER_PROFILE_DIR=str(self.profile), HO_MINIMAL_DIAGNOSTICS="true", OCM_LOGIN_ENV="integration", REGION="us-west-2", CLUSTER_SECTOR="fixture-sector", REQUESTS=str(self.directory / "requests"), TIMEOUTS=str(self.directory / "timeouts"))

    def run_script(self, key=HELPER, status=0, mode="normal", enabled=True, tracing=False):
        environment = dict(self.environment, MODE=mode, ORIGINAL_EXIT=str(status), HO_MINIMAL_DIAGNOSTICS=str(enabled).lower())
        launcher = 'function /usr/local/bin/e2e.test() { return "$ORIGINAL_EXIT"; }; source "$1"'
        args = ["bash", "-c", launcher, "fixture"]
        if tracing:
            args.insert(1, "-x")
        args.append(str(self.commands / key))
        if key == HELPER:
            args = ["bash"] + (["-x"] if tracing else []) + [str(self.commands / key)]
        return subprocess.run(args, env=environment, capture_output=True, text=True, timeout=20, check=False)

    def bundle(self):
        text = (self.artifacts / "ho-minimal-diagnostics.json").read_text()
        self.assertNotIn("do-not-retain", text)
        self.assertNotIn("fixture-", text)
        self.assertLess(len(text), 262144)
        self.assertFalse(list(self.artifacts.glob(".ho-minimal.*")))
        return json.loads(text)

    def assert_schema(self, value):
        allowed_keys = {
            "schemaVersion", "phase", "outcome", "failure", "truncated", "omissions", "logs", "ocm", "categories", "items",
            "target", "hostedCluster", "hostedControlPlane", "nodePools", "catalogDeployment", "catalogReplicaSets", "catalogPods", "catalogEvents", "operatorDeployment", "operatorReplicaSets", "operatorPods", "operatorEvents",
            "generation", "observedGeneration", "desired", "current", "updated", "ready", "available", "unavailable", "conditions", "type", "status", "lastTransitionTime", "phase", "assignedNode", "scheduled", "containers", "restartCount", "previous", "state", "exitCode", "signal", "reason", "startedAt", "finishedAt", "count", "firstTimestamp", "lastTimestamp",
        }
        allowed_values = {
            "test", "before_deploy", "deploy", "verify", "post", "complete", "partial", "failed", "unavailable", "request_failed", "invalid_response", "oversized", "invalid_target", "missing_tool", "missing_kubeconfig", "helper_unavailable", "collector_failed", "invalid_output",
            "omitted_by_policy", "not_queried", "Available", "Progressing", "Degraded", "Ready", "Upgradeable", "ValidConfiguration", "SupportedHostedCluster", "True", "False", "Unknown", "Other", "Pending", "Running", "Succeeded", "Failed", "waiting", "running", "terminated", "unknown", "Completed", "Error", "OOMKilled", "ContainerCannotRun", "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "PodInitializing", "ContainerCreating", "Unschedulable", "SchedulingGated", "Scheduled", "FailedScheduling", "FailedMount", "FailedAttachVolume", "BackOff", "Pulled", "Pulling", "Created", "Started", "Killing", "Unhealthy", "Normal", "Warning", "2026-01-01T00:00:00Z",
        }
        if isinstance(value, dict):
            self.assertFalse(value.keys() - allowed_keys)
            for item in value.values():
                self.assert_schema(item)
        elif isinstance(value, list):
            for item in value:
                self.assert_schema(item)
        elif isinstance(value, str):
            self.assertIn(value, allowed_values)
        else:
            self.assertIsInstance(value, (int, bool, type(None)))

    def test_scoped_before_and_after_deploy(self):
        for status in (0, 23):
            with self.subTest(status=status):
                result = self.run_script("rosa-hypershift-operator-deploy", status=status)
                self.assertEqual(result.returncode, status, result.stderr)
                baseline_path = self.artifacts / "ho-before-deploy/ho-minimal-diagnostics.json"
                baseline_text = baseline_path.read_text()
                baseline = json.loads(baseline_text)
                after = self.bundle()
                self.assert_schema(baseline)
                self.assertNotIn("fixture-", baseline_text)
                self.assertNotIn("do-not-retain", baseline_text)
                self.assertEqual(baseline["phase"], "before_deploy")
                self.assertEqual(after["phase"], "deploy")
                for snapshot in (baseline, after):
                    self.assertTrue(snapshot["categories"]["catalogDeployment"]["items"])
                    self.assertEqual(snapshot["categories"]["target"]["outcome"], "complete")
                self.assertFalse(list(baseline_path.parent.glob(".ho-minimal.*")))

    def test_skipped_deploy_retains_safe_baseline_and_exit_snapshot(self):
        for mode in ("locked", "match"):
            with self.subTest(mode=mode):
                self.assertEqual(self.run_script("rosa-hypershift-operator-deploy", mode=mode).returncode, 0)
                baseline_text = (self.artifacts / "ho-before-deploy/ho-minimal-diagnostics.json").read_text()
                baseline = json.loads(baseline_text)
                self.assert_schema(baseline)
                self.assertNotIn("fixture-", baseline_text)
                self.assertNotIn("do-not-retain", baseline_text)
                self.assertEqual(baseline["phase"], "before_deploy")
                self.assertTrue(baseline["categories"]["catalogDeployment"]["items"])
                self.assertEqual(self.bundle()["phase"], "deploy")

    def test_old_raw_collector_is_removed(self):
        for key in ("rosa-hypershift-operator-deploy", "rosa-hypershift-operator-verify-hcp-health"):
            script = (self.commands / key).read_text()
            self.assertNotIn("capture_health", script)
            self.assertNotIn('"${phase}-${resource}.json"', script)
            self.assertNotIn("--request-timeout=15s", script)
        self.assertFalse((ROOT / "hack/validate-rosa-ho-health-diagnostics.sh").exists())
        self.assertFalse((ROOT / "hack/rosa-ho-minimal-diagnostics.md").exists())

    def test_management_catalog_and_distinct_namespaces(self):
        result = self.run_script(tracing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        bundle = self.bundle()
        self.assert_schema(bundle)
        self.assertEqual(bundle["outcome"], "complete")
        categories = bundle["categories"]
        deployment = categories["catalogDeployment"]["items"][0]
        self.assertEqual(deployment, dict(generation=7, observedGeneration=6, desired=1, current=1, updated=1, ready=0, available=0, unavailable=1))
        self.assertEqual(len(categories["catalogReplicaSets"]["items"]), 1)
        pod = categories["catalogPods"]["items"][0]
        self.assertEqual(pod["scheduled"], "False")
        self.assertEqual(pod["containers"][0]["previous"]["exitCode"], 137)
        self.assertEqual(categories["catalogEvents"]["items"][0]["count"], 2)
        requests = Path(self.environment["REQUESTS"]).read_text().splitlines()
        self.assertLessEqual(len(requests), 18)
        self.assertTrue(any("ocm-int-fixture-id-fixture-cluster/deployments/redhat-operators-catalog" in path for path in requests))
        self.assertTrue(any("ocm-int-fixture-id/hostedclusters/fixture-cluster" in path for path in requests))
        self.assertFalse(any("/namespaces/" not in path for path in requests))
        self.assertNotIn("do-not-retain", result.stdout + result.stderr)

    def test_early_e2e_preserves_all_exit_codes_without_post(self):
        for status in (0, 1, 23):
            with self.subTest(status=status):
                result = self.run_script("rosa-e2e-test", status=status)
                self.assertEqual(result.returncode, status, result.stderr)
                bundle = self.bundle()
                self.assertEqual(bundle["phase"], "test")
                self.assertTrue(bundle["categories"]["catalogPods"]["items"])

    def test_deploy_and_verification_failures_stay_failed(self):
        for key in ("rosa-hypershift-operator-deploy", "rosa-hypershift-operator-verify-hcp-health"):
            with self.subTest(key=key):
                result = self.run_script(key, status=1)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertTrue(self.bundle()["categories"]["catalogDeployment"]["items"])

    def test_default_disabled_has_no_added_queries_or_artifacts(self):
        for key in SCRIPTS:
            with self.subTest(key=key):
                self.run_script(key, enabled=False)
                self.assertFalse((self.artifacts / "ho-minimal-diagnostics.json").exists())
                self.assertFalse(Path(self.environment["REQUESTS"]).exists())

    def test_collection_errors_preserve_test_failure(self):
        for mode in ("permission", "malformed", "oversized", "timeout", "bad_target"):
            with self.subTest(mode=mode):
                result = self.run_script("rosa-e2e-test", status=23, mode=mode)
                self.assertEqual(result.returncode, 23)
                bundle = self.bundle()
                self.assertNotEqual(bundle["outcome"], "complete")
                self.assert_schema(bundle)

    def test_missing_helper(self):
        (self.commands / HELPER).unlink()
        result = self.run_script("rosa-e2e-test", status=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.bundle()["failure"], "helper_unavailable")

    def test_missing_tool(self):
        (self.bin / "oc").unlink()
        for tool in ("bash", "head", "jq", "mkdir", "mktemp", "rm"):
            (self.bin / tool).symlink_to(shutil.which(tool))
        self.environment["PATH"] = str(self.bin)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.bundle()["failure"], "missing_tool")

    def test_missing_kubeconfig(self):
        (self.shared / "hs-mc.kubeconfig").unlink()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.bundle()["failure"], "missing_kubeconfig")

    def test_write_failure_does_not_change_exit_or_leave_temporary(self):
        result = self.run_script("rosa-e2e-test", status=23, mode="write_error")
        self.assertEqual(result.returncode, 23)
        self.assertFalse(list(self.artifacts.iterdir()))
        result = self.run_script(mode="write_error")
        self.assertEqual(result.returncode, 0)
        self.assertIn("artifact write failed", result.stderr)

    def test_absent_counts_are_not_zero_and_empty_pods_are_not_complete(self):
        self.run_script(mode="absent")
        self.assertIsNone(self.bundle()["categories"]["catalogDeployment"]["items"][0]["ready"])
        self.run_script(mode="no_pods")
        self.assertEqual(self.bundle()["outcome"], "partial")
        self.assertEqual(self.bundle()["categories"]["catalogPods"]["outcome"], "unavailable")

    def test_pagination_is_bounded_and_reported(self):
        self.run_script(mode="truncated")
        self.assertEqual(self.bundle()["categories"]["target"]["outcome"], "invalid_target")
        self.assertTrue(self.bundle()["truncated"])
        self.assertEqual(self.bundle()["outcome"], "partial")

    def test_workload_truncation_is_not_complete(self):
        self.run_script(mode="workload_truncated")
        bundle = self.bundle()
        self.assertTrue(bundle["categories"]["catalogPods"]["truncated"])
        self.assertEqual(bundle["outcome"], "partial")

    def test_selector_is_rejected_as_a_whole(self):
        self.run_script(mode="bad_selector")
        self.assertEqual(self.bundle()["categories"]["catalogDeployment"]["outcome"], "invalid_target")
        requests = Path(self.environment["REQUESTS"]).read_text()
        self.assertNotIn("replicasets", requests)

    def test_unknown_enums_are_not_retained(self):
        result = self.run_script(tracing=True, mode="unknown_enums")
        bundle = self.bundle()
        self.assert_schema(bundle)
        self.assertEqual(bundle["categories"]["hostedCluster"]["items"][0]["conditions"][0]["status"], "Other")
        self.assertEqual(bundle["categories"]["catalogPods"]["items"][0]["phase"], "Other")
        self.assertNotIn("do-not-retain", result.stdout + result.stderr)

    def test_real_request_timeout_bounds_blocked_oc(self):
        start = time.monotonic()
        result = self.run_script("rosa-e2e-test", status=23, mode="blocked_request")
        self.assertEqual(result.returncode, 23)
        self.assertLess(time.monotonic() - start, 15)
        self.assertEqual(self.bundle()["outcome"], "partial")

    def test_missing_helper_writer_does_not_log_unsafe_path(self):
        (self.commands / HELPER).unlink()
        (self.profile / "ocm-token").unlink()
        blocked = self.directory / "do-not-retain"
        blocked.write_text("fixture")
        self.environment["ARTIFACT_DIR"] = str(blocked / "child")
        result = self.run_script("rosa-e2e-test")
        self.assertEqual(result.returncode, 1)
        self.assertIn("artifact write failed", result.stderr)
        self.assertNotIn("do-not-retain", result.stdout + result.stderr)

    def test_invalid_target_never_queries_catalog_or_nodepools(self):
        self.run_script(mode="bad_target")
        bundle = self.bundle()
        self.assertEqual(bundle["categories"]["target"]["outcome"], "invalid_target")
        requests = Path(self.environment["REQUESTS"]).read_text()
        self.assertNotIn("redhat-operators-catalog", requests)
        self.assertNotIn("nodepools", requests)

    def test_unwritable_artifact_destination_preserves_failure(self):
        blocked = self.directory / "not-a-directory"
        blocked.write_text("fixture")
        self.environment["ARTIFACT_DIR"] = str(blocked / "child")
        result = self.run_script("rosa-e2e-test", status=23)
        self.assertEqual(result.returncode, 23)
        self.assertFalse(list(self.artifacts.iterdir()))

    def test_term_cleanup_matches_disabled_script(self):
        statuses = []
        for enabled in (False, True):
            marker = self.directory / "child-pid"
            marker.unlink(missing_ok=True)
            launcher = 'function /usr/local/bin/e2e.test() { /bin/sleep 30 & printf "%s" "$!" > "$CHILD_PID"; wait; }; source "$1"'
            environment = dict(self.environment, HO_MINIMAL_DIAGNOSTICS=str(enabled).lower(), CHILD_PID=str(marker))
            process = subprocess.Popen(["bash", "-c", launcher, "fixture", str(self.commands / "rosa-e2e-test")], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(marker.exists())
                process.send_signal(signal.SIGTERM)
                statuses.append(process.wait(timeout=10))
                child = int(marker.read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
            finally:
                if process.poll() is None:
                    if marker.exists():
                        try:
                            os.kill(int(marker.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    process.kill()
                    process.wait(timeout=2)
        self.assertEqual(statuses[0], statuses[1])
        self.assertTrue(self.bundle()["categories"]["catalogDeployment"]["items"])

    def test_global_deadline_failure_is_bounded(self):
        start = time.monotonic()
        self.run_script(mode="timeout")
        self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(self.bundle()["failure"], "collector_failed")
        self.assertIn("-k 2s 60s", Path(self.environment["TIMEOUTS"]).read_text())

    def test_configmap_mount_keys_and_workflow_contract(self):
        for key, path in SCRIPTS.items():
            ref = (REGISTRY / (path + "-ref.yaml")).read_text()
            self.assertIn("run_as_script: true", ref)
            self.assertIn("as: " + key, ref)
            self.assertIn("default: \"false\"", ref)
        workflow = (REGISTRY / "rosa/e2e/hcp/ho-upgrade/rosa-e2e-hcp-ho-upgrade-workflow.yaml").read_text()
        self.assertIn('HO_MINIMAL_DIAGNOSTICS: "true"', workflow)
        self.assertLess(workflow.index("- ref: " + HELPER), workflow.index("- chain: rosa-cluster-deprovision"))
        self.assertIn("- ref: rosa-hypershift-operator-restore", workflow)
        self.assertNotIn("allow_best_effort_post_steps", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
