#!/usr/bin/env python3

import copy
import base64
import contextlib
import io
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "ci-operator/step-registry/enmaas/deploy/enmaas-deploy-commands.sh"
INFRA = "node-role.kubernetes.io/infra"
INFRA_TOLERATION = {"key": INFRA, "operator": "Equal", "value": "", "effect": "NoSchedule"}
REGISTRY = "image-registry.openshift-image-registry.svc:5000/enmaas/"
EXPORTER = REGISTRY + "usage-exporter@sha256:" + "a" * 64
API = REGISTRY + "maas-api@sha256:" + "b" * 64
PULL_SECRET = "default-dockercfg-synthetic"
DECODER = shutil.which("oc") or shutil.which("kubectl")


class EnmaasPlacementFixture(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        source = DEPLOY.read_text(encoding="utf-8")
        function = source.split("configure_placement() {", 1)[1].split("\n}\n", 1)[0]
        self.script = "configure_placement() {" + function + '\n}\nconfigure_placement "$1" "$2" "${3:-}" "${4:-}" "${5:-false}"\n'
        self.nodes = [
            {"metadata": {"labels": {"kubernetes.io/os": "linux", "node-role.kubernetes.io/worker": ""}}},
            {"metadata": {"labels": {"kubernetes.io/os": "linux", INFRA: ""}},
             "spec": {"taints": [{"key": INFRA, "value": "", "effect": "NoSchedule"}]}},
        ]

    def pod_spec(self):
        return {
            "nodeSelector": {"enmaas": "true"},
            "tolerations": [{"key": "dedicated", "value": "enmaas", "effect": "NoSchedule"}],
            "initContainers": [{"name": "init", "image": "example.invalid/init:unchanged"}],
            "containers": [{"name": "app", "image": "example.invalid/app:unchanged",
                            "resources": {"requests": {"cpu": "10m"}}}],
            "volumes": [{"name": "data", "emptyDir": {}}],
        }

    def workload(self, kind, spec):
        if kind == "PodTemplate":
            return {"apiVersion": "v1", "kind": kind, "template": {"spec": spec}}
        if kind == "Pod":
            body = spec
        elif kind == "CronJob":
            body = {"jobTemplate": {"spec": {"template": {"spec": spec}}}}
        else:
            body = {"template": {"spec": spec}}
        api_version = "v1"
        if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"):
            api_version = "apps/v1"
        elif kind in ("Job", "CronJob"):
            api_version = "batch/v1"
        elif kind == "DeploymentConfig":
            api_version = "apps.openshift.io/v1"
        return {"apiVersion": api_version, "kind": kind, "metadata": {"name": "synthetic"}, "spec": body}

    def run_placement(self, documents, project="enmaas-monitoring", images=()):
        manifest = self.directory / "manifest.yaml"
        manifest.write_text(documents if isinstance(documents, str) else yaml.safe_dump_all(documents),
                            encoding="utf-8")
        (self.directory / "nodes.json").write_text(json.dumps({"items": self.nodes}), encoding="utf-8")
        result = subprocess.run(
            ["bash", "-eu", "-o", "pipefail", "-c", self.script, "placement", str(manifest), project,
             *images],
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "WORK_DIR": str(self.directory)},
            capture_output=True, text=True, check=False,
        )
        try:
            rendered = list(yaml.safe_load_all(manifest.read_text(encoding="utf-8")))
        except yaml.YAMLError:
            rendered = None
        return result, rendered

    def find_specs(self, value):
        if isinstance(value, dict):
            if "containers" in value:
                yield value
            else:
                for item in value.values():
                    yield from self.find_specs(item)
        elif isinstance(value, list):
            for item in value:
                yield from self.find_specs(item)


class EnmaasPlacementTests(EnmaasPlacementFixture):
    def test_all_workload_shapes_and_projects(self):
        kinds = ["Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet",
                 "ReplicationController", "DeploymentConfig", "Job", "CronJob", "PodTemplate"]
        for project in ("enmaas", "enmaas-monitoring"):
            with self.subTest(project=project):
                documents = [self.workload(kind, self.pod_spec()) for kind in kinds]
                documents.append({"apiVersion": "v1", "kind": "List", "items": [
                    self.workload("Job", self.pod_spec())]})
                documents.append({"apiVersion": "v1", "kind": "ConfigMap", "data": {"unchanged": "value"}})
                original = copy.deepcopy(documents)
                result, rendered = self.run_placement(documents, project)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("11 pod specs", result.stdout)
                for actual, previous in zip(self.find_specs(rendered), self.find_specs(original)):
                    self.assertEqual(actual.pop("nodeSelector"), {
                        "kubernetes.io/os": "linux", **({INFRA: ""} if project.endswith("monitoring") else {})})
                    self.assertEqual(actual.pop("tolerations"),
                                     [INFRA_TOLERATION] if project.endswith("monitoring") else [])
                    previous.pop("nodeSelector")
                    previous.pop("tolerations")
                    self.assertEqual(actual, previous)
                self.assertEqual(rendered[-1], documents[-1])

    def test_fail_fast_without_matching_nodes(self):
        for project, nodes in (("enmaas-monitoring", self.nodes[:1]), ("enmaas", self.nodes[1:])):
            with self.subTest(project=project):
                self.nodes = nodes
                result, rendered = self.run_placement([self.workload("Job", self.pod_spec())], project)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No nodes match", result.stderr)
                self.assertEqual(rendered[0]["spec"]["template"]["spec"], self.pod_spec())

    def test_reject_unexpected_constraints(self):
        for constraint in (
            {"tolerations": [{"operator": "Exists"}]},
            {"tolerations": [{"key": INFRA, "operator": "Exists", "effect": "NoSchedule"}]},
            {"nodeSelector": {"unavailable": "true"}},
            {"nodeName": "unavailable"},
            {"affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {}}}},
        ):
            with self.subTest(constraint=constraint):
                spec = {**self.pod_spec(), **constraint}
                result, _ = self.run_placement([self.workload("Deployment", spec)])
                self.assertNotEqual(result.returncode, 0)

    def test_reject_additional_infra_taint(self):
        self.nodes[1]["spec"]["taints"].append({"key": "other", "effect": "NoSchedule"})
        result, _ = self.run_placement([self.workload("StatefulSet", self.pod_spec())])
        self.assertNotEqual(result.returncode, 0)

    def test_idempotent(self):
        result, rendered = self.run_placement([self.workload("Deployment", self.pod_spec())])
        self.assertEqual(result.returncode, 0, result.stderr)
        repeated, second = self.run_placement(rendered)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(second, rendered)


class EnmaasPlacementConstraintTests(EnmaasPlacementFixture):
    def test_only_actual_pod_specs_changed(self):
        unrelated = [
            {"apiVersion": "example.invalid/v1", "kind": "Deployment", "spec": self.pod_spec()},
            {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
             "spec": {"schema": {"containers": {"type": "array"}}}},
            {"apiVersion": "example.invalid/v1", "kind": "Settings",
             "spec": {"template": {"spec": self.pod_spec()}, "containers": ["not a pod"]}},
        ]
        result, rendered = self.run_placement([self.workload("Pod", self.pod_spec()), *unrelated])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[1:], unrelated)
        self.assertIn("1 pod specs", result.stdout)
        shared = self.pod_spec()
        custom = {"apiVersion": "example.invalid/v1", "kind": "Settings", "spec": shared}
        documents = [{"apiVersion": "v1", "kind": "List", "items": [
            self.workload("Pod", shared), custom]}]
        result, rendered = self.run_placement(documents)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[0]["items"][1], custom)

    def test_typed_and_nested_lists(self):
        documents = [{"apiVersion": "v1", "kind": "List", "items": [
            {"apiVersion": "apps/v1", "kind": "DeploymentList", "items": [
                self.workload("Deployment", self.pod_spec())]}]}]
        result, _ = self.run_placement(documents)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 pod specs", result.stdout)

    def test_preserve_unrelated_placement(self):
        spec = self.pod_spec()
        spec["nodeSelector"]["storage"] = "ssd"
        self.nodes[1]["metadata"]["labels"]["storage"] = "ssd"
        tolerations = [{"key": "maintenance", "operator": "Equal", "value": "planned", "effect": ""},
                       {"key": "node.kubernetes.io/not-ready", "operator": "Exists",
                        "effect": "NoExecute", "tolerationSeconds": 300}]
        spec["tolerations"] += tolerations
        self.nodes[1]["spec"]["taints"].append(
            {"key": "maintenance", "value": "planned", "effect": "NoSchedule"})
        result, rendered = self.run_placement([self.workload("Pod", spec)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[0]["spec"]["nodeSelector"]["storage"], "ssd")
        self.assertEqual(rendered[0]["spec"]["tolerations"], tolerations + [INFRA_TOLERATION])

    def test_affinity_operators(self):
        self.nodes[1]["metadata"].update(name="infra-node")
        self.nodes[1]["metadata"]["labels"].update(zone="east", generation="5")
        cases = [("zone", "In", ["east"], True), ("zone", "In", ["west"], False),
                 ("zone", "NotIn", ["west"], True), ("absent", "NotIn", ["west"], True),
                 ("zone", "Exists", [], True), ("absent", "Exists", [], False),
                 ("zone", "DoesNotExist", [], False), ("absent", "DoesNotExist", [], True),
                 ("generation", "Gt", ["4"], True), ("generation", "Lt", ["5"], False),
                 ("zone", "Gt", ["4"], False)]
        for key, operator, values, expected in cases:
            with self.subTest(operator=operator, key=key, values=values):
                spec = self.pod_spec()
                spec["affinity"] = {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {
                    "nodeSelectorTerms": [{"matchExpressions": [
                        {"key": key, "operator": operator, "values": values}]}]}}}
                result, rendered = self.run_placement([self.workload("Pod", spec)])
                self.assertEqual(result.returncode == 0, expected, result.stderr)
                self.assertEqual(rendered[0]["spec"]["affinity"], spec["affinity"])

    def test_affinity_boolean_semantics_and_preference(self):
        for terms, expected in (([], False), ([{}], False), ([{}, {"matchExpressions": [
                {"key": "kubernetes.io/os", "operator": "In", "values": ["linux"]}]}], True),
                ([{"matchExpressions": [{"key": "kubernetes.io/os", "operator": "In", "values": ["linux"]},
                                        {"key": "missing", "operator": "Exists"}]}], False)):
            with self.subTest(terms=terms):
                spec = self.pod_spec()
                spec["affinity"] = {"nodeAffinity": {
                    "requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": terms},
                    "preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 1, "preference": {
                        "matchExpressions": [{"key": "unavailable", "operator": "Exists"}]}}]}}
                original = copy.deepcopy(spec["affinity"])
                result, rendered = self.run_placement([self.workload("Pod", spec)])
                self.assertEqual(result.returncode == 0, expected, result.stderr)
                self.assertEqual(rendered[0]["spec"]["affinity"], original)

    def test_stale_affinity_normalized_for_both_projects(self):
        for project in ("enmaas", "enmaas-monitoring"):
            with self.subTest(project=project):
                spec = self.pod_spec()
                spec["affinity"] = {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {
                    "nodeSelectorTerms": [{"matchExpressions": [
                        {"key": "enmaas", "operator": "In", "values": ["true"]},
                        {"key": "kubernetes.io/os", "operator": "In", "values": ["linux"]}]}]}}}
                result, rendered = self.run_placement([self.workload("Pod", spec)], project)
                self.assertEqual(result.returncode, 0, result.stderr)
                expression = rendered[0]["spec"]["affinity"]["nodeAffinity"][
                    "requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"][0]["matchExpressions"][0]
                self.assertEqual(expression, {"key": INFRA if project.endswith("monitoring") else "kubernetes.io/os",
                                              "operator": "In", "values": [""] if project.endswith("monitoring")
                                              else ["linux"]})

    def test_node_name_and_field_affinity(self):
        self.nodes[1]["metadata"]["name"] = "infra-node"
        for name in ("infra-node", "missing"):
            for field in (False, True):
                with self.subTest(name=name, field=field):
                    spec = self.pod_spec()
                    if field:
                        spec["affinity"] = {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {
                            "nodeSelectorTerms": [{"matchFields": [
                                {"key": "metadata.name", "operator": "In", "values": [name]}]}]}}}
                    else:
                        spec["nodeName"] = name
                    result, _ = self.run_placement([self.workload("Pod", spec)])
                    self.assertEqual(result.returncode == 0, name == "infra-node", result.stderr)

    def test_cordoned_and_untolerated_noexecute_nodes_fail(self):
        for constraint in ({"unschedulable": True}, {"taints": [
                {"key": "unrelated", "value": "", "effect": "NoExecute"}]}):
            with self.subTest(constraint=constraint):
                self.nodes[1]["spec"].update(constraint)
                result, _ = self.run_placement([self.workload("Pod", self.pod_spec())])
                self.assertNotEqual(result.returncode, 0)

    def test_nonstale_selectors_not_overwritten(self):
        for selector in ({"enmaas": "false"}, {"kubernetes.io/os": "windows"}, {INFRA: "different"}):
            with self.subTest(selector=selector):
                spec = {**self.pod_spec(), "nodeSelector": selector}
                result, rendered = self.run_placement([self.workload("Pod", spec)])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(rendered[0]["spec"]["nodeSelector"], selector)

    def test_malformed_or_empty_render(self):
        for raw in ("", "---\n", "invalid: [", "text", "[]", "apiVersion: v1\nkind: List\nitems: null",
                    "apiVersion: v1\nkind: Pod\nspec: {}"):
            with self.subTest(raw=raw):
                result, _ = self.run_placement(raw)
                self.assertNotEqual(result.returncode, 0)

    def test_existing_equivalent_infra_toleration(self):
        spec = self.pod_spec()
        spec["tolerations"].append({"key": INFRA, "effect": "NoSchedule"})
        result, rendered = self.run_placement([self.workload("Pod", spec)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[0]["spec"]["tolerations"], [INFRA_TOLERATION])

    def test_application_rejects_infra_toleration(self):
        spec = self.pod_spec()
        spec["tolerations"].append(INFRA_TOLERATION)
        result, _ = self.run_placement([self.workload("Pod", spec)], "enmaas")
        self.assertNotEqual(result.returncode, 0)

    def test_empty_render_fails(self):
        result, _ = self.run_placement([{"apiVersion": "v1", "kind": "ConfigMap"}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No pod specs", result.stderr)

    def test_both_renders_checked_before_apply(self):
        source = DEPLOY.read_text(encoding="utf-8").split('echo "Rendering and checking', 1)[1]
        self.assertLess(source.index('configure_placement "/tmp/${project}.yaml"'),
                        source.index("oc apply -f /tmp/enmaas.yaml"))
        self.assertIn('for project in enmaas enmaas-monitoring;', source)
        self.assertIn('--server-side --field-manager=enmaas-opps --force-conflicts', source)

    @unittest.skipUnless(DECODER, "requires an actual oc or kubectl local decoder")
    def test_render_consumer_fail_fast(self):
        source = DEPLOY.read_text(encoding="utf-8")
        consumer = source[source.index('echo "Rendering and checking'):].split(
            'echo "Patching NetworkPolicy', 1)[0]
        consumer = consumer.replace("/tmp/", str(self.directory) + "/")
        manifest = self.directory / "input.yaml"
        spec = self.pod_spec()
        spec["containers"].extend([{"name": "api", "image": API}, {
            "name": "exporter", "image": "quay.io/modden/enmaas-usage-exporter:old"}])
        spec["containers"][-2]["envFrom"] = [{"secretRef": {"name": "enmaas-api-db-config"}}]
        spec["initContainers"].append({"name": "migrate", "image": API, "envFrom": [
            {"secretRef": {"name": "enmaas-api-db-config"}}]})
        spec["imagePullSecrets"] = [{"name": "enmaas-api-pull"}, {"name": "external"}]
        manifest.write_text(yaml.safe_dump(self.workload("Job", spec)), encoding="utf-8")
        registry = source[source.index("registry_pull_secret() {"):source.index("configure_placement() {")]
        executable = self.directory / "oc"
        executable.write_text('#!/bin/bash\noc "$@"\n', encoding="utf-8")
        executable.chmod(0o755)
        harness = '''
make() {
  if [[ "$*" == *"PROJECT=enmaas-monitoring"* ]]; then
    case "${RENDER_MODE:-valid}" in
      failed) cat "${WORK_DIR}/input.yaml"; return 7 ;;
      malformed) echo 'invalid: ['; return ;;
      empty) return ;;
      nulls) cat "${WORK_DIR}/input.yaml"; printf '\\n---\\nnull\\n---\\n'; return ;;
      decoder) echo 'apiVersion: v1
kind: ConfigMap
metadata: invalid
---'; cat "${WORK_DIR}/input.yaml"; return ;;
    esac
  fi
  cat "${WORK_DIR}/input.yaml"
}
oc() {
  if [[ "$1" == --kubeconfig=* ]]; then
    echo decode >> "${WORK_DIR}/decodes"
    "$REAL_DECODER" "$@"
  elif [[ "$1 $2" == "get serviceaccount" ]]; then
    [[ "${SECRET_STATUS:-0}" == 0 ]] || return "$SECRET_STATUS"
    echo '{"metadata":{"uid":"synthetic"},"imagePullSecrets":[{"name":"default-dockercfg-synthetic"}]}'
  elif [[ "$1 $2" == "get secret" ]]; then
    if [[ "${SECRET_MODE:-valid}" == malformed ]]; then echo invalid; return; fi
    python3 - <<'SYNTHETIC'
import base64
import json
data = base64.b64encode(json.dumps({"image-registry.openshift-image-registry.svc:5000": {
    "auth": "synthetic-placeholder-not-a-credential"}}).encode()).decode()
print(json.dumps({"metadata": {"annotations": {"kubernetes.io/service-account.name": "default",
    "kubernetes.io/service-account.uid": "synthetic"}}, "type": "kubernetes.io/dockercfg",
    "data": {".dockercfg": data}}))
SYNTHETIC
  elif [[ "$1" == get ]]; then
    cat "${WORK_DIR}/input-nodes.json"
    return "${GET_STATUS:-0}"
  else
    [[ $(wc -l < "${WORK_DIR}/decodes") == 2 ]] || return 19
    echo "$*" >> "${WORK_DIR}/applies"
    cp "${@: -1}" "${WORK_DIR}/applied-$(wc -l < "${WORK_DIR}/applies").yaml"
    return "${APPLY_STATUS:-0}"
  fi
}
export -f oc
'''
        cases = [(self.nodes[:1], {}, 1, 0), (self.nodes, {}, 0, 2),
                 (self.nodes, {"RENDER_MODE": "failed"}, 7, 0),
                 (self.nodes, {"RENDER_MODE": "malformed"}, 1, 0),
                 (self.nodes, {"RENDER_MODE": "empty"}, 1, 0),
                 (self.nodes, {"RENDER_MODE": "nulls"}, 0, 2),
                 (self.nodes, {"RENDER_MODE": "decoder"}, 1, 0),
                 (self.nodes, {"GET_STATUS": "9"}, 9, 0),
                 (self.nodes, {"SECRET_STATUS": "6"}, 1, 0),
                 (self.nodes, {"SECRET_MODE": "malformed"}, 1, 0),
                 (self.nodes, {"APPLY_STATUS": "8"}, 8, 1)]
        for nodes, environment, expected, apply_count in cases:
            with self.subTest(expected=expected, environment=environment):
                applies = self.directory / "applies"
                applies.unlink(missing_ok=True)
                (self.directory / "decodes").unlink(missing_ok=True)
                (self.directory / "input-nodes.json").write_text(
                    json.dumps({"items": nodes}), encoding="utf-8")
                result = subprocess.run(
                    ["bash", "-eu", "-o", "pipefail", "-c", harness + registry + self.script.split(
                        '\nconfigure_placement "$1" "$2"', 1)[0] + "\n" + consumer],
                    env={"PATH": str(self.directory) + ":/usr/local/bin:/usr/bin:/bin",
                         "WORK_DIR": str(self.directory),
                         "REAL_DECODER": DECODER,
                         "DB_URL": "synthetic-presence-indicator",
                         "ENMAAS_ENV": "synthetic", "INTERNAL_REGISTRY": REGISTRY.rstrip("/"),
                         "USAGE_EXPORTER_DIGEST": "sha256:" + "a" * 64, **environment},
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                if not apply_count:
                    self.assertFalse(applies.exists())
                else:
                    self.assertEqual(len(applies.read_text(encoding="utf-8").splitlines()), apply_count)
                    for index in range(1, apply_count + 1):
                        applied = yaml.safe_load((self.directory / f"applied-{index}.yaml").read_text(
                            encoding="utf-8"))["spec"]["template"]["spec"]
                        self.assertNotIn("enmaas", applied["nodeSelector"])
                        self.assertEqual(applied["tolerations"], [] if index == 1 else [INFRA_TOLERATION])
                        if index == 1:
                            self.assertEqual(applied["imagePullSecrets"], [
                                {"name": "external"}, {"name": PULL_SECRET}])
                            self.assertEqual(applied["containers"][-1]["image"], EXPORTER)
                            for container in (applied["containers"][-2], applied["initContainers"][-1]):
                                self.assertEqual(container["envFrom"], [{"secretRef": {"name": "maas-db-config"}}])


class EnmaasSerializationTests(EnmaasPlacementFixture):
    def decode(self, raw, decoder):
        return subprocess.run(
            [decoder, "--kubeconfig=/dev/null", "--server=http://127.0.0.1:1", "--request-timeout=1s",
             "label", "--local=true", "--overwrite=true", "--filename=-",
             "enmaas-ci-validation=local", "-o", "name"],
            input=raw, capture_output=True, text=True, check=False, timeout=15,
        )

    @unittest.skipUnless(DECODER, "requires an actual oc or kubectl local decoder")
    def test_null_serialization_actual_kubernetes_decoder(self):
        documents = [self.workload("Pod", self.pod_spec()),
                     {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "synthetic"},
                      "data": {"unchanged": "value"}}]
        valid = yaml.safe_dump_all(documents)
        broken = yaml.safe_dump_all([*documents, None])
        self.assertIn("--- null\n", broken)
        decoders = {path for path in (shutil.which("oc"), shutil.which("kubectl")) if path}
        for raw in (valid + "---\n", valid + "---\nnull\n", valid + "---\n~\n"):
            result, rendered = self.run_placement(raw)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(rendered), 2)
            normalized = (self.directory / "manifest.yaml").read_text(encoding="utf-8")
            self.assertNotIn("--- null", normalized)
            for decoder in decoders:
                with self.subTest(decoder=decoder, raw=raw[-10:]):
                    self.assertEqual(self.decode(valid + "---\n", decoder).returncode, 0)
                    failed = self.decode(broken, decoder)
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertIn("invalid Yaml document separator: null", failed.stderr)
                    passed = self.decode(normalized, decoder)
                    self.assertEqual(passed.returncode, 0, passed.stderr)

    def test_nested_typed_lists_filter_null_preserve_objects(self):
        config = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "synthetic"},
                  "data": {"unchanged": "value"}}
        typed = self.workload("Job", self.pod_spec())
        del typed["apiVersion"]
        del typed["kind"]
        documents = [None, {"apiVersion": "v1", "kind": "List", "items": [None, config,
                     {"apiVersion": "batch/v1", "kind": "JobList", "items": [None, typed]}]}, None]
        result, rendered = self.run_placement(documents)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rendered), 1)
        items = rendered[0]["items"]
        self.assertEqual(items[0], config)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[1]["kind"], "Job")
        if DECODER:
            decoded = self.decode((self.directory / "manifest.yaml").read_text(encoding="utf-8"), DECODER)
            self.assertEqual(decoded.returncode, 0, decoded.stderr)

    def test_unrelated_custom_null_fields_preserved(self):
        custom = {"apiVersion": "example.invalid/v1", "kind": "Settings", "metadata": {"name": "synthetic"},
                  "spec": {"items": [None, "unchanged"], "nullable": None}}
        result, rendered = self.run_placement([self.workload("Pod", self.pod_spec()), custom, None])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[-1], custom)

    def test_nonresource_documents_fail_actionably_without_writing(self):
        pod = self.workload("Pod", self.pod_spec())
        for bad in ("scalar", 7, True, [], {"kind": "Pod"}):
            for documents in ([pod, bad], [{"apiVersion": "v1", "kind": "List", "items": [pod, bad]}]):
                with self.subTest(bad=bad, nested=len(documents) == 1):
                    result, rendered = self.run_placement(documents)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Expected a Kubernetes resource object", result.stderr)
                    self.assertIn("document[", result.stderr)
                    self.assertEqual(rendered, documents)


class EnmaasDatabaseTests(EnmaasPlacementFixture):
    def database_spec(self):
        spec = self.pod_spec()
        api = {"name": "api", "image": API, "envFrom": [
            {"secretRef": {"name": "enmaas-api-db-config", "optional": False}},
            {"secretRef": {"name": "unrelated", "optional": True}}], "env": [
                {"name": "DB", "valueFrom": {"secretKeyRef": {
                    "name": "enmaas-api-db-config", "key": "DB_CONNECTION_URL", "optional": False}}}]}
        spec["containers"] = [api, {"name": "exporter", "image": EXPORTER}]
        spec["initContainers"] = [dict(copy.deepcopy(api), name="migrate"), {
            "name": "unrelated", "image": "example.invalid/other", "envFrom": copy.deepcopy(api["envFrom"])}]
        return spec

    def test_external_database_references_only_api_init_and_main(self):
        spec = self.database_spec()
        documents = [self.workload("Deployment", spec)]
        for external in ("true", "false"):
            result, rendered = self.run_placement(documents, "enmaas", (EXPORTER, PULL_SECRET, external))
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = rendered[0]["spec"]["template"]["spec"]
            for field in ("containers", "initContainers"):
                expected = copy.deepcopy(spec[field][0])
                if external == "true":
                    expected["envFrom"][0]["secretRef"]["name"] = "maas-db-config"
                    expected["env"][0]["valueFrom"]["secretKeyRef"]["name"] = "maas-db-config"
                self.assertEqual(actual[field][0], expected)
                self.assertEqual(actual[field][1], spec[field][1])

    def test_unexpected_database_key_fails_without_writing(self):
        spec = self.database_spec()
        spec["initContainers"][0]["env"][0]["valueFrom"]["secretKeyRef"]["key"] = "unverified"
        documents = [self.workload("Job", spec)]
        result, rendered = self.run_placement(documents, "enmaas", (EXPORTER, PULL_SECRET, "true"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected API database secret key", result.stderr)
        self.assertEqual(rendered, documents)


class EnmaasImageTests(EnmaasPlacementFixture):
    def test_all_pod_kinds_and_container_types(self):
        for kind in ("Pod", "PodTemplate", "ReplicationController", "Deployment", "StatefulSet",
                     "DaemonSet", "ReplicaSet", "DeploymentConfig", "Job", "CronJob"):
            with self.subTest(kind=kind):
                spec = self.pod_spec()
                spec["containers"].append({"name": "api", "image": API})
                spec["containers"].append({"name": "unrelated-exporter",
                                           "image": "quay.io/other/enmaas-usage-exporter:unchanged"})
                spec["initContainers"].extend([
                    {"name": "migrate", "image": API, "args": ["migrate"], "env": []},
                    {"name": "export", "image": "quay.io/modden/enmaas-usage-exporter@sha256:old"}])
                spec["imagePullSecrets"] = [{"name": "enmaas-api-pull"}, {"name": "external"}]
                original = copy.deepcopy(spec)
                workload = self.workload(kind, spec)
                documents = [{"apiVersion": "v1", "kind": "List", "items": [{
                    "apiVersion": workload["apiVersion"], "kind": kind + "List", "items": [workload]}]}]
                result, rendered = self.run_placement(documents, "enmaas", (EXPORTER, PULL_SECRET))
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = next(self.find_specs(rendered))
                self.assertEqual(actual["containers"], original["containers"])
                self.assertEqual(actual["initContainers"][:-1], original["initContainers"][:-1])
                self.assertEqual(actual["initContainers"][-1]["image"], EXPORTER)
                self.assertEqual(actual["imagePullSecrets"], [
                    {"name": "external"}, {"name": PULL_SECRET}])
                repeated, again = self.run_placement(rendered, "enmaas", (EXPORTER, PULL_SECRET))
                self.assertEqual(repeated.returncode, 0, repeated.stderr)
                self.assertEqual(again, rendered)

    def test_preserve_unrelated_fields_and_credentials(self):
        spec = self.pod_spec()
        spec.update(serviceAccountName="default", automountServiceAccountToken=False,
                    imagePullSecrets=[{"name": "external"}])
        spec["containers"] = [{"name": "api", "image": API}, {
            "name": "exporter", "image": "quay.io/modden/enmaas-usage-exporter:old"}]
        unrelated = {"apiVersion": "example.invalid/v1", "kind": "Deployment", "spec": {
            "template": {"spec": copy.deepcopy(spec)}}}
        account = {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "default"},
                   "automountServiceAccountToken": False, "imagePullSecrets": [{"name": "external"}]}
        result, rendered = self.run_placement([
            self.workload("Deployment", spec), unrelated, account], "enmaas", (EXPORTER, PULL_SECRET))
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = next(self.find_specs(rendered))
        self.assertFalse(actual["automountServiceAccountToken"])
        self.assertEqual(actual["serviceAccountName"], "default")
        self.assertEqual(actual["imagePullSecrets"], [{"name": "external"}, {"name": PULL_SECRET}])
        self.assertEqual(rendered[1], unrelated)
        self.assertEqual(rendered[2], account)

    def test_exporter_digest_discovery_consumer(self):
        source = DEPLOY.read_text(encoding="utf-8")
        consumer = source[source.index("image_digest() {"):source.index("registry_pull_secret() {")]
        params = self.directory / "params"
        params.write_text("\n".join(key + "=old" for key in (
            "ENMAAS_API_IMAGE_REPOSITORY", "ENMAAS_API_IMAGE_DIGEST", "METERING_IMAGE_REPOSITORY",
            "METERING_IMAGE_DIGEST", "PRAXIS_IMAGE_REPOSITORY", "VERTEX_IMAGE_DIGEST")), encoding="utf-8")
        harness = 'oc() { echo "$*" >> "$CALLS"; echo "sha256:$DIGEST"; return "$GET_STATUS"; }\n'
        for status in (0, 7):
            result = subprocess.run([
                "bash", "-eu", "-o", "pipefail", "-c", harness + consumer
                + '\nprintf "EXPORTER=%s" "$USAGE_EXPORTER_DIGEST"'],
                env={"PATH": "/usr/local/bin:/usr/bin:/bin", "PARAMS_FILE": str(params),
                     "INTERNAL_REGISTRY": REGISTRY.rstrip("/"), "DIGEST": "a" * 64,
                     "GET_STATUS": str(status), "CALLS": str(self.directory / "calls")},
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, status, result.stderr)
            if not status:
                self.assertIn("EXPORTER=sha256:" + "a" * 64, result.stdout)
                self.assertIn("get istag usage-exporter:latest -n enmaas", (
                    self.directory / "calls").read_text(encoding="utf-8"))

    def test_invalid_image_or_credentials_fail_without_writing(self):
        for images, extra in (((EXPORTER, ""), {}), (("bad", PULL_SECRET), {}),
                              ((EXPORTER, PULL_SECRET), {"serviceAccountName": "custom"})):
            with self.subTest(images=images, extra=extra):
                spec = {**self.pod_spec(), **extra}
                spec["containers"] = [{"name": "api", "image": API}]
                documents = [self.workload("Deployment", spec)]
                result, rendered = self.run_placement(documents, "enmaas", images)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(rendered, documents)

    def test_missing_exporter_fails_closed(self):
        result, _ = self.run_placement([self.workload("Pod", self.pod_spec())],
                                       "enmaas", (EXPORTER, PULL_SECRET))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No usage-exporter image", result.stderr)

    def test_registry_secret_discovery(self):
        source = DEPLOY.read_text(encoding="utf-8").split("registry_pull_secret() {", 1)[1]
        code = source.split("<<'PYTHON'\n", 1)[1].split("\nPYTHON", 1)[0]
        discovery = self.directory / "registry_discovery.py"
        discovery.write_text(code, encoding="utf-8")
        account = {"metadata": {"uid": "synthetic-uid"}, "imagePullSecrets": [{"name": PULL_SECRET}]}
        encoded = base64.b64encode(json.dumps({REGISTRY.split("/", 1)[0]: {
            "auth": "synthetic-placeholder-not-a-credential"}}).encode()).decode()
        for mode in ("legacy", "bound", "empty", "unmanaged", "wrong-uid", "forbidden", "missing",
                     "malformed", "wrong-registry", "retry", "timeout", "invalid-json-object"):
            with self.subTest(mode=mode):
                secret = {"metadata": {"annotations": {
                    "kubernetes.io/service-account.name": "default",
                    "kubernetes.io/service-account.uid": "synthetic-uid"}},
                    "type": "kubernetes.io/dockercfg", "data": {".dockercfg": encoded}}
                if mode == "bound":
                    secret["metadata"] = {"annotations": {
                        "openshift.io/internal-registry-auth-token.service-account": "default"},
                        "ownerReferences": [{"kind": "ServiceAccount", "name": "default",
                                             "uid": "synthetic-uid"}]}
                elif mode == "empty":
                    secret["data"] = {}
                elif mode == "unmanaged":
                    secret["metadata"] = {}
                elif mode == "wrong-uid":
                    secret["metadata"]["annotations"]["kubernetes.io/service-account.uid"] = "other"
                elif mode == "malformed":
                    secret["data"] = {".dockercfg": "not-base64"}
                elif mode == "wrong-registry":
                    secret["data"] = {".dockercfg": base64.b64encode(b'{}').decode()}
                elif mode == "missing":
                    secret = {}
                values = [account, secret] * 12
                if mode == "retry":
                    values.insert(0, {})
                responses = [subprocess.CompletedProcess(
                    ["oc"], 9 if mode == "forbidden" else 0, json.dumps(value), "not disclosed")
                    for value in values]
                if mode == "timeout":
                    responses = [subprocess.TimeoutExpired(["oc"], 15, output="synthetic-sensitive")]
                elif mode == "invalid-json-object":
                    responses[0].stdout = "[]"
                output = io.StringIO()
                with mock.patch("subprocess.run", side_effect=responses), mock.patch("time.sleep"), \
                        contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as stopped:
                    runpy.run_path(str(discovery), run_name="__main__")
                self.assertEqual(stopped.exception.code == 0, mode in ("legacy", "bound", "retry"))
                self.assertEqual(output.getvalue(), PULL_SECRET + "\n" if mode in (
                    "legacy", "bound", "retry") else "")


if __name__ == "__main__":
    unittest.main()
