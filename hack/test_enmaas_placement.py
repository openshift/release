#!/usr/bin/env python3

import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "ci-operator/step-registry/enmaas/deploy/enmaas-deploy-commands.sh"
INFRA = "node-role.kubernetes.io/infra"
INFRA_TOLERATION = {"key": INFRA, "operator": "Equal", "value": "", "effect": "NoSchedule"}
API = "example.invalid/api:manifest-default"
EXPORTER = "example.invalid/exporter:manifest-default"
DECODER = shutil.which("oc") or shutil.which("kubectl")


class EnmaasPlacementFixture(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(DECODER, "EnMaaS regressions require oc or kubectl on PATH; no decoder coverage may be skipped")
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        source = DEPLOY.read_text(encoding="utf-8")
        function = source.split("configure_placement() {", 1)[1].split("\n}\n", 1)[0]
        self.script = "configure_placement() {" + function + '\n}\nconfigure_placement "$1" "$2" "${3:-false}"\n'
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

    def run_placement(self, documents, project="enmaas-monitoring", external_database="false"):
        manifest = self.directory / "manifest.yaml"
        manifest.write_text(documents if isinstance(documents, str) else yaml.safe_dump_all(documents),
                            encoding="utf-8")
        (self.directory / "nodes.json").write_text(json.dumps({"items": self.nodes}), encoding="utf-8")
        result = subprocess.run(
            ["bash", "-eu", "-o", "pipefail", "-c", self.script, "placement", str(manifest), project,
             external_database],
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

    def test_render_consumer_fail_fast(self):
        source = DEPLOY.read_text(encoding="utf-8")
        consumer = source[source.index('echo "Rendering and checking'):].split(
            'echo "Patching NetworkPolicy', 1)[0]
        consumer = consumer.replace("/tmp/", str(self.directory) + "/")
        manifest = self.directory / "input.yaml"
        spec = self.pod_spec()
        spec["containers"].extend([{"name": "enmaas-api", "image": API}, {
            "name": "exporter", "image": EXPORTER}])
        spec["containers"][-2]["envFrom"] = [{"secretRef": {"name": "enmaas-api-db-config"}}]
        spec["initContainers"].append({"name": "migrate", "image": API, "envFrom": [
            {"secretRef": {"name": "enmaas-api-db-config"}}]})
        spec["imagePullSecrets"] = [{"name": "enmaas-api-pull"}, {"name": "external"}]
        workload = self.workload("Job", spec)
        workload["metadata"]["labels"] = {"app.kubernetes.io/name": "enmaas-api"}
        manifest.write_text(yaml.safe_dump(workload), encoding="utf-8")
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
  elif [[ "$1 $2" == "get nodes" ]]; then
    cat "${WORK_DIR}/input-nodes.json"
    return "${GET_STATUS:-0}"
  elif [[ "$1" == apply ]]; then
    [[ $(wc -l < "${WORK_DIR}/decodes") == 2 ]] || return 19
    echo "$*" >> "${WORK_DIR}/applies"
    cp "${@: -1}" "${WORK_DIR}/applied-$(wc -l < "${WORK_DIR}/applies").yaml"
    return "${APPLY_STATUS:-0}"
  else
    return 33
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
                 (self.nodes, {"APPLY_STATUS": "8"}, 8, 1)]
        for nodes, environment, expected, apply_count in cases:
            with self.subTest(expected=expected, environment=environment):
                applies = self.directory / "applies"
                applies.unlink(missing_ok=True)
                (self.directory / "decodes").unlink(missing_ok=True)
                (self.directory / "input-nodes.json").write_text(
                    json.dumps({"items": nodes}), encoding="utf-8")
                result = subprocess.run(
                    ["bash", "-eu", "-o", "pipefail", "-c", harness + self.script.split(
                        '\nconfigure_placement "$1" "$2"', 1)[0] + "\n" + consumer],
                    env={"PATH": str(self.directory) + ":/usr/local/bin:/usr/bin:/bin",
                         "WORK_DIR": str(self.directory),
                         "REAL_DECODER": DECODER,
                         "DB_URL": "synthetic-presence-indicator",
                         "ENMAAS_ENV": "synthetic", **environment},
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
                                {"name": "enmaas-api-pull"}, {"name": "external"}])
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
    def api_workload(self, kind, spec):
        workload = self.workload(kind, spec)
        workload["metadata"]["labels"] = {"app.kubernetes.io/name": "enmaas-api"}
        return workload

    def database_spec(self):
        spec = self.pod_spec()
        api = {"name": "enmaas-api", "image": API, "envFrom": [
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
        documents = [self.api_workload("Deployment", spec)]
        for external in ("true", "false"):
            result, rendered = self.run_placement(documents, "enmaas", external)
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
        documents = [self.api_workload("Job", spec)]
        result, rendered = self.run_placement(documents, "enmaas", "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected API database secret key", result.stderr)
        self.assertEqual(rendered, documents)

    def test_api_identity_by_name_or_public_label_not_image(self):
        for mode in ("name", "label"):
            with self.subTest(mode=mode):
                spec = self.database_spec()
                spec["containers"][0]["image"] = "example.invalid/different-default@sha256:" + "c" * 64
                workload = self.api_workload("Pod", spec)
                if mode == "name":
                    workload["metadata"] = {"name": "enmaas-api"}
                result, rendered = self.run_placement([workload], "enmaas", "true")
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = rendered[0]["spec"]
                self.assertEqual(actual["containers"][0]["image"], spec["containers"][0]["image"])
                self.assertEqual(actual["initContainers"][0]["envFrom"][0]["secretRef"]["name"], "maas-db-config")

    def test_unrelated_workload_database_references_unchanged(self):
        spec = self.database_spec()
        result, rendered = self.run_placement([self.workload("Job", spec)], "enmaas", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[0]["spec"]["template"]["spec"]["containers"], spec["containers"])
        self.assertEqual(rendered[0]["spec"]["template"]["spec"]["initContainers"], spec["initContainers"])

    def test_monitoring_database_references_unchanged(self):
        spec = self.database_spec()
        result, rendered = self.run_placement([self.api_workload("Pod", spec)], "enmaas-monitoring", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[0]["spec"]["containers"], spec["containers"])
        self.assertEqual(rendered[0]["spec"]["initContainers"], spec["initContainers"])

    def test_database_creation_and_shape_preservation(self):
        source = DEPLOY.read_text(encoding="utf-8")
        self.assertIn('create secret generic maas-db-config', source)
        self.assertIn('--from-literal=DB_CONNECTION_URL="${DB_URL}"', source)
        spec = self.database_spec()
        spec.update(serviceAccountName="custom", imagePullSecrets=[{"name": "manifest-default"}])
        spec["containers"][0]["envFrom"][0]["prefix"] = "UNCHANGED_"
        spec["initContainers"][0]["env"].append({"name": "LITERAL", "value": "unchanged"})
        result, rendered = self.run_placement([self.api_workload("Pod", spec)], "enmaas", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = rendered[0]["spec"]
        self.assertEqual(actual["containers"][0]["envFrom"][0]["prefix"], "UNCHANGED_")
        self.assertEqual(actual["initContainers"][0]["env"][-1], {"name": "LITERAL", "value": "unchanged"})
        self.assertEqual(actual["imagePullSecrets"], spec["imagePullSecrets"])
        self.assertEqual(actual["serviceAccountName"], "custom")


class EnmaasDefaultImageTests(EnmaasPlacementFixture):
    def test_all_workload_images_and_pull_references_preserved(self):
        for kind in ("Pod", "PodTemplate", "ReplicationController", "Deployment", "StatefulSet",
                     "DaemonSet", "ReplicaSet", "DeploymentConfig", "Job", "CronJob"):
            for project in ("enmaas", "enmaas-monitoring"):
                with self.subTest(kind=kind, project=project):
                    spec = self.pod_spec()
                    spec.update(serviceAccountName="custom", automountServiceAccountToken=False,
                                imagePullSecrets=[{"name": "manifest-default"}, {"name": "external"}])
                    spec["containers"].extend([{"name": "enmaas-api", "image": API},
                                               {"name": "exporter", "image": EXPORTER}])
                    spec["initContainers"].append({"name": "migrate", "image": API})
                    workload = self.workload(kind, spec)
                    documents = [{"apiVersion": "v1", "kind": "List", "items": [{
                        "apiVersion": workload["apiVersion"], "kind": kind + "List", "items": [workload]}]}]
                    result, rendered = self.run_placement(documents, project)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    actual = next(self.find_specs(rendered))
                    for field in ("containers", "initContainers", "imagePullSecrets", "serviceAccountName",
                                  "automountServiceAccountToken"):
                        self.assertEqual(actual[field], spec[field])
                    repeated, again = self.run_placement(rendered, project)
                    self.assertEqual(repeated.returncode, 0, repeated.stderr)
                    self.assertEqual(again, rendered)

    def test_no_pull_secret_or_service_account_added(self):
        result, rendered = self.run_placement([self.workload("Pod", self.pod_spec())], "enmaas")
        self.assertEqual(result.returncode, 0, result.stderr)
        for field in ("imagePullSecrets", "serviceAccountName", "serviceAccount"):
            self.assertNotIn(field, rendered[0]["spec"])

    def test_service_account_and_unrelated_resources_untouched(self):
        account = {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "default"},
                   "automountServiceAccountToken": False, "imagePullSecrets": [{"name": "manifest-default"}]}
        unrelated = {"apiVersion": "example.invalid/v1", "kind": "Settings", "spec": {
            "image": API, "imagePullSecrets": [{"name": "manifest-default"}]}}
        result, rendered = self.run_placement([self.workload("Pod", self.pod_spec()), account, unrelated])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered[1:], [account, unrelated])

    def test_deployment_has_no_workload_build_or_registry_wiring(self):
        source = DEPLOY.read_text(encoding="utf-8")
        for removed in ("start-build", "BuildConfig", "ImageStream", "imagestream", "get istag", "BUILDS_DIR",
                        "image_digest", "set_param", "INTERNAL_REGISTRY", "DIGEST", "registry_pull_secret",
                        "imagePullSecrets", "get secret", "get serviceaccount", "configure_images",
                        "ENMAAS_API_IMAGE", "METERING_IMAGE", "PRAXIS_IMAGE", "VERTEX_IMAGE"):
            self.assertNotIn(removed, source)
        self.assertEqual(source.count("git clone"), 2)
        self.assertIn('ENMAAS_CREDENTIALS="/secret/enmaas/token"', source)

    def test_helper_image_and_existing_github_credential_retained(self):
        config = ROOT / "ci-operator/config/openshift-eng/ocp-perfscale/openshift-eng-ocp-perfscale-main__rosa_hcp-5.0-nightly-x86.yaml"
        images = yaml.safe_load(config.read_text(encoding="utf-8"))["images"]["items"]
        self.assertIn("enmaas-deploy-image", [image["to"] for image in images])
        reference = yaml.safe_load(DEPLOY.with_name("enmaas-deploy-ref.yaml").read_text(encoding="utf-8"))["ref"]
        self.assertEqual(reference["from"], "enmaas-deploy-image")
        self.assertEqual(len(reference["credentials"]), 1)
        self.assertEqual(reference["credentials"][0]["mount_path"], "/secret/enmaas")

    def test_missing_exporter_or_api_is_not_an_error(self):
        result, _ = self.run_placement([self.workload("Job", self.pod_spec())], "enmaas", "true")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
