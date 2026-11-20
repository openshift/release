#!/usr/bin/env python3
"""Test guest feature argument and manifest plumbing without cloud access.

Requires PyYAML, as do the repository's other Python validation tools.
Run: python3 hack/test-hypershift-agentic-features.py
"""

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

# These stubs replace only external programs. Tests run the full registry
# creation commands and manifest transformations.
STUB = r"""
import json, os, pathlib, sys
import yaml
root = pathlib.Path(os.environ["TEST_ROOT"])
tool, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / "calls.jsonl").open("a") as calls:
    calls.write(json.dumps([tool, args]) + "\n")
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
        self.feature_spec = {
            "featureSet": "CustomNoUpgrade",
            "customNoUpgrade": {"enabled": ["Example"], "disabled": ["Other"]},
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
                args = [args for tool, args in self.calls() if tool == "hypershift"][-1]
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
            self.feature_spec,
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
            cluster["spec"]["configuration"]["featureGate"], self.feature_spec
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


if __name__ == "__main__":
    unittest.main()
