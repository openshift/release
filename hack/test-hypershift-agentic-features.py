#!/usr/bin/env python3
"""Exercise the actual creation commands and feature pre-step without cloud access.

Requires PyYAML, as do the repository's other Python validation tools.
Run: python3 hack/test-hypershift-agentic-features.py
"""

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "ci-operator/step-registry/hypershift"
CREATE = yaml.safe_load(
    (REGISTRY / "aws/create/hypershift-aws-create-chain.yaml").read_text()
)["chain"]["steps"][0]
VERIFY = (
    REGISTRY
    / "agentic-qe/verify-features/hypershift-agentic-qe-verify-features-commands.sh"
)
VERIFY_REF = yaml.safe_load(
    VERIFY.with_name("hypershift-agentic-qe-verify-features-ref.yaml").read_text()
)["ref"]

# These stubs replace only external programs. Tests run the full registry
# commands, including their manifest transformations and verification predicates.
STUB = r"""
import json, os, pathlib, sys
import yaml
root = pathlib.Path(os.environ["TEST_ROOT"])
tool, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
kubeconfig = os.environ.get("KUBECONFIG")
if "--kubeconfig" in args:
    kubeconfig = args[args.index("--kubeconfig") + 1]
with (root / "calls.jsonl").open("a") as calls:
    calls.write(json.dumps([tool, args, kubeconfig]) + "\n")
if tool == "hypershift":
    if "kubeconfig" in args:
        print("fake-kubeconfig")
    else:
        release_image = args[args.index("--release-image") + 1]
        objects = [
            {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "credentials"},
             "stringData": {"token": "RENDERED_SECRET_SENTINEL"}},
            {"apiVersion": "hypershift.openshift.io/v1beta1", "kind": "HostedCluster",
             "metadata": {"name": "test", "namespace": "clusters"},
             "spec": {"release": {"image": release_image}}},
            {"apiVersion": "hypershift.openshift.io/v1beta1", "kind": "NodePool",
             "metadata": {"name": "test", "namespace": "clusters"},
             "spec": {"release": {"image": release_image}}},
        ]
        if "--render-sensitive" not in args:
            objects = [o for o in objects if o["kind"] != "Secret"]
        print(yaml.safe_dump_all(objects))
elif tool == "oc":
    if "--dry-run=client" in args:
        filename = args[args.index("-f") + 1]
        if filename == "-":
            print(json.dumps(yaml.safe_load(sys.stdin.read())))
            sys.exit(0)
        source = pathlib.Path(filename)
        items = list(yaml.safe_load_all(source.read_text()))
        if os.environ.get("OC_JSON_STREAM"):
            print("\n".join(json.dumps(item) for item in items))
        else:
            print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
    elif "apply" in args:
        if os.environ.get("FAIL_APPLY"):
            sys.exit(1)
        source = pathlib.Path(args[args.index("-f") + 1])
        (root / "applied.json").write_text(source.read_text())
    elif "featuregates.config.openshift.io/cluster" in args:
        print((root / "feature.json").read_text())
    elif "clusterversion.config.openshift.io/version" in args:
        print((root / "version.json").read_text())
    elif "configmap/feature-gate" in args:
        if os.environ.get("MISSING_FEATURE_CONFIGMAP"):
            sys.exit(1)
        print((root / "configmap.json").read_text())
    elif "get" in args:
        print("Completed")
elif tool == "date":
    print("2026-11-19T12:00:00+00:00")
elif tool == "sha256sum":
    sys.stdin.read()
    print("a" * 64)
elif tool == "timeout":
    os.execvp(args[1], args[1:])
"""


class GuestFeaturesTest(unittest.TestCase):
    def setUp(self):
        resources = ExitStack()
        self.addCleanup(resources.close)
        self.root = Path(resources.enter_context(tempfile.TemporaryDirectory()))
        for name in ("bin", "shared", "artifacts"):
            (self.root / name).mkdir()
        for tool in ("oc", "hypershift", "sleep", "date", "sha256sum", "timeout"):
            path = self.root / "bin" / tool
            path.write_text(f"#!{sys.executable}\n" + STUB)
            path.chmod(0o755)
        self.env = {
            **os.environ,
            **{item["name"]: item["default"] for item in CREATE["env"]},
            "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
            "TEST_ROOT": str(self.root),
            "SHARED_DIR": str(self.root / "shared"),
            "ARTIFACT_DIR": str(self.root / "artifacts"),
            "CLUSTER_PROFILE_DIR": str(self.root),
            "PROW_JOB_ID": "test-job",
            "LEASED_RESOURCE": "us-east-1",
            "RELEASE_IMAGE_LATEST": "payload",
            "NODEPOOL_RELEASE_IMAGE_LATEST": "payload",
            "HYPERSHIFT_CREATE_CLUSTER_RENDER": "true",
        }
        self.features = {
            "apiVersion": "config.openshift.io/v1",
            "kind": "FeatureGate",
            "metadata": {"name": "cluster", "generation": 1},
            "spec": {
                "featureSet": "CustomNoUpgrade",
                "customNoUpgrade": {"enabled": ["Example"], "disabled": ["Other"]},
            },
            "status": {
                "featureGates": [
                    {
                        "version": "test-version",
                        "enabled": [{"name": "Example"}],
                        "disabled": [{"name": "Other"}],
                    }
                ]
            },
        }
        self.version = {
            "status": {
                "desired": {"version": "test-version"},
                "history": [{"version": "test-version", "state": "Completed"}],
            }
        }

    def run_commands(self, script, **env):
        return subprocess.run(
            ["bash", "-c", script],
            cwd=self.root,
            env={**self.env, **env},
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )

    def create(self, **env):
        return self.run_commands(
            CREATE["commands"].replace("/usr/bin/hypershift", "hypershift"), **env
        )

    def verify(self, features=None, version=None, rendered=None, configmap=None, **env):
        (self.root / "feature.json").write_text(
            json.dumps(features if features is not None else self.features)
        )
        (self.root / "version.json").write_text(
            json.dumps(version if version is not None else self.version)
        )
        expected = self.features if rendered is None else rendered
        if configmap is None:
            configmap = {
                "metadata": {
                    "annotations": {
                        "hypershift.openshift.io/payload-version": "test-version"
                    }
                },
                "data": {"feature-gate.yaml": yaml.safe_dump(expected)},
            }
        (self.root / "configmap.json").write_text(json.dumps(configmap))
        (self.root / "shared/cluster-name").write_text("test\n")
        return self.run_commands(VERIFY.read_text(), **env)

    def calls(self):
        path = self.root / "calls.jsonl"
        return (
            [json.loads(line) for line in path.read_text().splitlines()]
            if path.exists()
            else []
        )

    def test_default_and_predefined_sets_reach_cli(self):
        for feature_set in ("", "TechPreviewNoUpgrade", "DevPreviewNoUpgrade"):
            with self.subTest(feature_set=feature_set):
                result = self.create(
                    MULTISTAGE_PARAM_OVERRIDE_GUEST_FEATURE_SET=feature_set
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                args = [args for tool, args, _ in self.calls() if tool == "hypershift"][
                    -1
                ]
                flags = [arg for arg in args if arg.startswith("--feature-set=")]
                self.assertEqual(
                    flags, [f"--feature-set={feature_set}"] if feature_set else []
                )

    def test_custom_gates_set_before_apply_and_preserve_other_objects(self):
        result = self.create(
            MULTISTAGE_PARAM_OVERRIDE_GUEST_FEATURE_SET="CustomNoUpgrade",
            MULTISTAGE_PARAM_OVERRIDE_GUEST_FEATURE_GATES="Other=false,Example=true",
            HYPERSHIFT_CREATE_CLUSTER_RENDER="false",
            NODEPOOL_RELEASE_IMAGE_LATEST="nodepool-payload",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        objects = {
            item["kind"]: item
            for item in json.loads((self.root / "applied.json").read_text())["items"]
        }
        self.assertEqual(
            objects["HostedCluster"]["spec"]["configuration"]["featureGate"],
            self.features["spec"],
        )
        self.assertEqual(
            objects["NodePool"]["spec"]["release"]["image"], "nodepool-payload"
        )
        self.assertEqual(
            objects["Secret"]["stringData"]["token"], "RENDERED_SECRET_SENTINEL"
        )
        self.assertNotIn("RENDERED_SECRET_SENTINEL", result.stdout + result.stderr)
        self.assertFalse(list((self.root / "shared").glob("guest-*")))

    def test_custom_render_only_removes_secrets_and_does_not_apply(self):
        result = self.create(
            GUEST_FEATURE_SET="CustomNoUpgrade", GUEST_FEATURE_GATES="Example=true"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = (
            self.root / "shared/hypershift_create_cluster_render.yaml"
        ).read_text()
        self.assertNotIn("RENDERED_SECRET_SENTINEL", rendered)
        self.assertIn('"featureSet": "CustomNoUpgrade"', rendered)
        self.assertFalse((self.root / "applied.json").exists())
        self.assertFalse(list((self.root / "shared").glob("guest-*")))

    def test_custom_release_override_preserves_the_existing_skew_contract(self):
        for latest, nodepool, expected_nodepool in (
            ("payload", "payload", "override-payload"),
            ("payload", "nodepool-payload", "nodepool-payload"),
            ("", "nodepool-payload", "override-payload"),
            ("payload", "", "override-payload"),
        ):
            with self.subTest(latest=latest, nodepool=nodepool):
                result = self.create(
                    GUEST_FEATURE_SET="CustomNoUpgrade",
                    HYPERSHIFT_CREATE_CLUSTER_RENDER="false",
                    HYPERSHIFT_HC_RELEASE_IMAGE="override-payload",
                    RELEASE_IMAGE_LATEST=latest,
                    NODEPOOL_RELEASE_IMAGE_LATEST=nodepool,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                objects = {
                    obj["kind"]: obj
                    for obj in json.loads((self.root / "applied.json").read_text())[
                        "items"
                    ]
                }
                self.assertEqual(
                    objects["HostedCluster"]["spec"]["release"]["image"],
                    "override-payload",
                )
                self.assertEqual(
                    objects["NodePool"]["spec"]["release"]["image"], expected_nodepool
                )

    def test_custom_configuration_accepts_oc_consecutive_json_output(self):
        result = self.create(
            GUEST_FEATURE_SET="CustomNoUpgrade",
            GUEST_FEATURE_GATES="Example=true,Other=false",
            HYPERSHIFT_CREATE_CLUSTER_RENDER="false",
            OC_JSON_STREAM="true",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        objects = json.loads((self.root / "applied.json").read_text())["items"]
        cluster = next(obj for obj in objects if obj["kind"] == "HostedCluster")
        self.assertEqual(
            cluster["spec"]["configuration"]["featureGate"], self.features["spec"]
        )

    def test_apply_failure_cleans_up_sensitive_manifests(self):
        result = self.create(
            GUEST_FEATURE_SET="CustomNoUpgrade",
            FAIL_APPLY="true",
            HYPERSHIFT_CREATE_CLUSTER_RENDER="false",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list((self.root / "shared").glob("guest-*")))
        self.assertNotIn("RENDERED_SECRET_SENTINEL", result.stdout + result.stderr)

    def test_invalid_input_fails_before_external_calls(self):
        for feature_set, gates in (
            ("Invalid", ""),
            ("TechPreviewNoUpgrade", "Example=true"),
            ("", "Example=true"),
            ("CustomNoUpgrade", "Example=True"),
            ("CustomNoUpgrade", "Example=true,"),
            ("CustomNoUpgrade", "Example=true,Example=false"),
            ("CustomNoUpgrade", "$(echo bad)=true"),
            ("CustomNoUpgrade", ",".join(f"Gate{i}=true" for i in range(65))),
            ("CustomNoUpgrade", "X" * 129 + "=true"),
            ("CustomNoUpgrade", "X" * 8193),
        ):
            with self.subTest(feature_set=feature_set, gates=gates[:80]):
                result = self.create(
                    GUEST_FEATURE_SET=feature_set, GUEST_FEATURE_GATES=gates
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_verification_of_custom_gates_uses_hosted_cluster_and_keeps_evidence(self):
        result = self.verify(
            MULTISTAGE_PARAM_OVERRIDE_GUEST_FEATURE_SET="CustomNoUpgrade",
            MULTISTAGE_PARAM_OVERRIDE_GUEST_FEATURE_GATES="Example=true,Other=false",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads((self.root / "artifacts/guest-feature-state.json").read_text()),
            self.features,
        )
        for tool, args, kubeconfig in self.calls():
            if tool == "oc":
                filename = (
                    "kubeconfig"
                    if "configmap/feature-gate" in args
                    else "nested_kubeconfig"
                )
                self.assertEqual(kubeconfig, str(self.root / "shared" / filename))
                if "configmap/feature-gate" in args:
                    self.assertIn("clusters-test", args)

    def test_verification_accepts_preview_sets_and_optional_healthy_condition(self):
        for feature_set in ("TechPreviewNoUpgrade", "DevPreviewNoUpgrade"):
            for conditions in (
                [],
                [
                    {
                        "type": "DeterminationDegraded",
                        "status": "False",
                        "observedGeneration": 1,
                    }
                ],
            ):
                with self.subTest(feature_set=feature_set, conditions=conditions):
                    features = copy.deepcopy(self.features)
                    features["spec"] = {"featureSet": feature_set}
                    features["status"]["conditions"] = conditions
                    result = self.verify(
                        features=features,
                        rendered=features,
                        GUEST_FEATURE_SET=feature_set,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_stale_status_without_individual_overrides_or_a_condition_fails(self):
        for feature_set in (
            "TechPreviewNoUpgrade",
            "DevPreviewNoUpgrade",
            "CustomNoUpgrade",
        ):
            with self.subTest(feature_set=feature_set):
                features = copy.deepcopy(self.features)
                features["spec"] = {"featureSet": feature_set}
                rendered = copy.deepcopy(features)
                rendered["status"]["featureGates"][0]["enabled"].append(
                    {"name": "Preview"}
                )
                result = self.verify(
                    features=features, rendered=rendered, GUEST_FEATURE_SET=feature_set
                )
                self.assertNotEqual(result.returncode, 0)

    def test_stale_or_missing_rendered_expectations_fail(self):
        for case in ("spec", "version", "payload", "empty", "missing"):
            with self.subTest(case=case):
                rendered = copy.deepcopy(self.features)
                payload_version = "test-version"
                if case == "spec":
                    rendered["spec"]["customNoUpgrade"]["enabled"] = ["Different"]
                elif case == "version":
                    rendered["status"]["featureGates"][0]["version"] = "old-version"
                elif case == "payload":
                    payload_version = "old-version"
                configmap = {
                    "metadata": {
                        "annotations": {
                            "hypershift.openshift.io/payload-version": payload_version
                        }
                    },
                    "data": {
                        "feature-gate.yaml": ""
                        if case == "empty"
                        else yaml.safe_dump(rendered)
                    },
                }
                result = self.verify(
                    configmap=configmap,
                    GUEST_FEATURE_SET="CustomNoUpgrade",
                    GUEST_FEATURE_GATES="Example=true,Other=false",
                    MISSING_FEATURE_CONFIGMAP="true" if case == "missing" else "",
                )
                self.assertNotEqual(result.returncode, 0)

    def test_mismatched_or_unobserved_features_fail_before_hold(self):
        cases = []
        for path, value in (
            (("spec", "featureSet"), "TechPreviewNoUpgrade"),
            (("spec", "customNoUpgrade", "enabled"), ["Unrequested"]),
            (("status", "featureGates", 0, "version"), "old-version"),
            (("status", "featureGates", 0, "enabled"), []),
            (
                ("status", "featureGates", 0, "enabled"),
                [{"name": "Example"}, {"name": "Unrequested"}],
            ),
            (
                ("status", "featureGates", 0, "disabled"),
                [{"name": "Other"}, {"name": "Example"}],
            ),
            (
                ("status", "conditions"),
                [{"type": "DeterminationDegraded", "status": "True"}],
            ),
            (
                ("status", "conditions"),
                [
                    {
                        "type": "DeterminationDegraded",
                        "status": "False",
                        "observedGeneration": 0,
                    }
                ],
            ),
        ):
            features = copy.deepcopy(self.features)
            target = features
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            cases.append((str(path), features, self.version))
        cases.append(
            (
                "incomplete rollout",
                self.features,
                {
                    "status": {
                        "desired": {"version": "test-version"},
                        "history": [{"version": "test-version", "state": "Partial"}],
                    }
                },
            )
        )
        cases.append(("missing status", {"spec": self.features["spec"]}, self.version))
        for label, features, version in cases:
            with self.subTest(case=label):
                result = self.verify(
                    features=features,
                    version=version,
                    GUEST_FEATURE_SET="CustomNoUpgrade",
                    GUEST_FEATURE_GATES="Example=true,Other=false",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("did not match the request", result.stderr)

    def test_default_configuration_skips_additional_api_reads(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_verification_is_a_pre_step_before_hold(self):
        workflow = yaml.safe_load(
            (
                REGISTRY / "agentic-qe/aws/hypershift-agentic-qe-aws-workflow.yaml"
            ).read_text()
        )["workflow"]
        self.assertEqual(workflow["steps"]["pre"][-1], {"ref": VERIFY_REF["as"]})
        self.assertEqual(
            workflow["steps"]["test"][0], {"ref": "hypershift-agentic-qe-process"}
        )


if __name__ == "__main__":
    unittest.main()
