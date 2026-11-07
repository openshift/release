"""Focused checks for plan provenance, result correctness and failure handling."""

import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

import validation


def example_plan():
    return {
        "title": "Controller restart recovery",
        "ready": True,
        "gaps": [],
        "assumptions": ["The test resource supports a mutable replicas field."],
        "checks": [{
            "id": "restart-recovery",
            "source": "jira",
            "reference": "https://jira.example/browse/OCPBUGS-123 acceptance criteria",
            "issue": "OCPBUGS-123",
            "requirement": "Existing resources reconcile after restart",
            "prerequisites": ["A representative managed resource is ready"],
            "actions": ["Restart controller", "Change replicas", "Wait at most 120s for the new generation"],
            "expected": "observedGeneration equals generation and ready replicas equal the requested value",
            "evidence": "Resource generations, replica counts, controller identities",
        }],
        "sources": {
            "repository": "openshift/example",
            "pull": 123,
            "revision": "a" * 40,
            "base": "b" * 40,
            "url": "https://github.com/openshift/example/pull/123",
            "issues": [{"key": "OCPBUGS-123", "url": "https://jira.example/browse/OCPBUGS-123", "status": "retrieved"}],
        },
    }


class FakeSandbox:  # pylint: disable=too-few-public-methods
    def run(self, _text):
        return "observedGeneration=7 generation=7 replicas=3 readyReplicas=3", 0


class FakeModel:  # pylint: disable=too-few-public-methods
    def __init__(self, messages):
        self.messages = iter(messages)

    def complete(self, _messages, _tools=None):
        return next(self.messages)


def function_call(name, arguments):
    return {"role": "assistant", "tool_calls": [{"id": name, "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)}}]}


class PlanTests(unittest.TestCase):
    def test_extract_keys(self):
        cases = [
            ("OCPBUGS-123: fix restart", ["OCPBUGS-123"]),
            ("OCPBUGS-123 DPTP-45 OCPBUGS-123", ["OCPBUGS-123", "DPTP-45"]),
            ("NO-JIRA: fix restart", []),
            ("reliability improvements", []),
        ]
        for title, expected in cases:
            with self.subTest(title=title):
                self.assertEqual(validation.extract_keys(title), expected)

    def test_plan_sources(self):
        cases = [
            ("explicit procedure", "jira", "retrieved", True),
            ("acceptance criteria only", "jira", "retrieved", True),
            ("incomplete Jira and inferred expectations", "inference", "retrieved", True),
            ("unavailable Jira with PR fallback", "pr", "unavailable: retrieval failed", True),
            ("fabricated unavailable Jira criterion", "jira", "unavailable: retrieval failed", False),
        ]
        for name, source, status, valid in cases:
            with self.subTest(name=name):
                plan = example_plan()
                plan["checks"][0]["source"] = source
                plan["sources"]["issues"][0]["status"] = status
                if valid:
                    validation.validate_plan(plan)
                else:
                    with self.assertRaises(validation.ValidationError):
                        validation.validate_plan(plan)
        plan = example_plan()
        plan["sources"]["issues"] = []
        plan["checks"][0].update(source="inference", issue="")
        validation.validate_plan(plan)

    def test_reject_incomplete_plans(self):
        changes = [
            {"checks": []},
            {"ready": False},
            {"gaps": ["contradictory intent"]},
            {"title": ""},
            {"checks": [example_plan()["checks"][0]] * 2},
        ]
        for change in changes:
            with self.subTest(change=change):
                plan = example_plan()
                plan.update(change)
                with self.assertRaises(validation.ValidationError):
                    validation.validate_plan(plan)
        for field in ("actions", "expected", "reference", "requirement", "evidence"):
            with self.subTest(field=field):
                plan = example_plan()
                plan["checks"][0][field] = [] if field == "actions" else ""
                with self.assertRaises(validation.ValidationError):
                    validation.validate_plan(plan)

    def test_multiple_issue_scope(self):
        plan = example_plan()
        plan["sources"]["issues"].append({"key": "DPTP-45", "status": "retrieved"})
        with self.assertRaises(validation.ValidationError):
            validation.validate_plan(plan)
        other = copy.deepcopy(plan["checks"][0])
        other.update(id="other-issue", issue="DPTP-45")
        plan["checks"].append(other)
        validation.validate_plan(plan)

    def test_plan_integrity_and_job_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            shared = Path(temporary)
            plan = example_plan()
            plan["hash"] = validation.plan_hash(plan)
            validation.write_json(shared / "validation.json", plan)
            validation.atomic_write(shared / "validation.md", validation.plan_markdown(plan))
            spec = {"refs": {"org": "openshift", "repo": "example", "base_sha": "b" * 40,
                             "pulls": [{"number": 123, "sha": "a" * 40}]}}
            with mock.patch.dict(os.environ, {"JOB_SPEC": json.dumps(spec)}):
                self.assertEqual(validation.load_plan(shared), plan)
                validation.atomic_write(shared / "validation.md", "weakened expected result")
                with self.assertRaisesRegex(validation.ValidationError, "does not match"):
                    validation.load_plan(shared)
                validation.atomic_write(shared / "validation.md", validation.plan_markdown(plan))
                plan["checks"][0]["expected"] = "Pod is running"
                validation.write_json(shared / "validation.json", plan)
                with self.assertRaisesRegex(validation.ValidationError, "hash mismatch"):
                    validation.load_plan(shared)


class ResultTests(unittest.TestCase):
    def setUp(self):
        # unittest's addCleanup owns this resource for the lifetime of each case.
        self.temporary = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.temporary.cleanup)
        self.artifacts = Path(self.temporary.name)
        plan = example_plan()
        plan["hash"] = validation.plan_hash(plan)
        self.execution = validation.Execution(plan, self.artifacts, FakeSandbox(), [])

    def run_check(self):
        return self.execution.invoke("run_command", {"check_id": "restart-recovery", "command": "oc get example -o json"})["evidence"]

    def record(self, outcome="pass", evidence=None):
        if evidence is None:
            evidence = [self.run_check()]
        return self.execution.invoke("record_result", {
            "check_id": "restart-recovery", "outcome": outcome,
            "observed": "generation 7 was observed; 3 requested and ready replicas", "evidence": evidence})

    def test_pass_requires_evidence(self):
        for evidence in ([], ["../../kubeconfig"], ["missing.txt"]):
            with self.subTest(evidence=evidence):
                with self.assertRaises(validation.ValidationError):
                    self.record(evidence=evidence)
        path = self.run_check()
        (self.artifacts / path).unlink()
        with self.assertRaises(validation.ValidationError):
            self.record(evidence=[path])

    def test_results_cannot_be_replaced(self):
        self.record("fail")
        with self.assertRaises(validation.ValidationError):
            self.record("pass", evidence=[])
        checkpoint = json.loads((self.artifacts / "partial-results.json").read_text())
        self.assertEqual(checkpoint[0]["outcome"], "fail")

    def test_outcomes_and_junit(self):
        cases = [
            ("complete success", "pass", None, "pass", 0),
            ("product defect", "fail", None, "fail", 1),
            ("setup failure", "unable_to_verify", None, "unable_to_verify", 1),
            ("failure then timeout", "fail", "runner timed out", "fail", 1),
            ("success then runner failure", "pass", "runner error", "unable_to_verify", 1),
            ("missing output", None, "incomplete output", "unable_to_verify", 1),
        ]
        for name, outcome, error, overall, exit_status in cases:
            with self.subTest(name=name):
                results = {}
                if outcome:
                    results["restart-recovery"] = {"check_id": "restart-recovery", "outcome": outcome,
                                                  "observed": "observed values", "evidence": []}
                self.assertEqual(validation.finalize(example_plan(), results, self.artifacts, error, {}), exit_status)
                report = json.loads((self.artifacts / "results.json").read_text())
                self.assertEqual(report["overall"], overall)
                suite = ET.parse(self.artifacts / "junit_agent_validation.xml").getroot()
                self.assertEqual(int(suite.attrib["tests"]), 1 + bool(error))

    def test_no_plan_never_passes(self):
        self.assertEqual(validation.finalize({}, {}, self.artifacts, "missing plan", {}), 1)

    def test_model_tool_loop_records_observations(self):
        model = FakeModel([
            function_call("run_command", {"check_id": "restart-recovery", "command": "oc get example"}),
            function_call("record_result", {"check_id": "restart-recovery", "outcome": "pass",
                          "observed": "generation=7 observedGeneration=7 replicas=3 readyReplicas=3",
                          "evidence": ["evidence/0001-restart-recovery.txt"]}),
        ])
        self.execution.run(model)
        self.assertEqual(self.execution.results["restart-recovery"]["outcome"], "pass")

    def test_normal_model_exit_is_not_a_pass(self):
        model = FakeModel([{"role": "assistant", "content": "Everything passed!"}])
        with self.assertRaisesRegex(validation.ValidationError, "without results"):
            self.execution.run(model)

    def test_runner_error_and_partial_failure_are_retained(self):
        self.record("fail")
        with mock.patch.object(validation, "load_plan", return_value=example_plan()), \
             mock.patch.object(validation, "Model", side_effect=RuntimeError("private error content")):
            # All unexpected runner exceptions must still produce failed JUnit.
            for filename in ("validation.json", "validation.md", "sources.json"):
                validation.atomic_write(self.artifacts / filename, "{}")
            self.assertEqual(validation.execute(self.artifacts, self.artifacts), 1)
        self.assertIn("RuntimeError", (self.artifacts / "report.md").read_text())
        self.assertNotIn("private error content", (self.artifacts / "report.md").read_text())


class ProtocolTests(unittest.TestCase):
    def test_source_retrieval_and_fallback(self):
        spec = {"refs": {"org": "openshift", "repo": "example", "base_sha": "b" * 40,
                         "pulls": [{"number": 123, "sha": "a" * 40}]}}
        cases = [
            ("explicit validation", "OCPBUGS-123: restart", {"description": "Restart then update the resource"}, False),
            ("acceptance criteria", "OCPBUGS-123: restart", {"description": None, "customfield_42": "Generation advances"}, False),
            ("incomplete Jira", "OCPBUGS-123: restart", {"description": "Reliability"}, False),
            ("no Jira", "NO-JIRA: restart", None, False),
            ("unavailable Jira", "OCPBUGS-123: restart", None, True),
        ]
        for name, title, fields, unavailable in cases:
            with self.subTest(name=name):
                pull = {"head": {"sha": "a" * 40}, "title": title, "body": "Recover reconciliation"}
                responses = [pull]
                if fields is not None:
                    responses.append({"fields": fields})
                elif unavailable:
                    responses.append(validation.ValidationError("API returned HTTP 403"))
                env = {"JOB_SPEC": json.dumps(spec), "JIRA_USERNAME": "test@example.com", "JIRA_ACCEPTANCE_FIELD": "customfield_42"}
                with mock.patch.dict(os.environ, env), \
                     mock.patch.object(validation, "request_json", side_effect=responses), \
                     mock.patch.object(validation, "token_file", return_value="private-token"), \
                     mock.patch.object(validation, "tested_diff", return_value="tested diff"):
                    sources, context, _ = validation.capture_sources()
                self.assertEqual(sources["revision"], "a" * 40)
                self.assertEqual(context["diff"], "tested diff")
                if fields is not None:
                    self.assertEqual(sources["issues"][0]["status"], "retrieved")
                    self.assertEqual(sources["issues"][0]["fields"]["description"], fields.get("description"))
                elif unavailable:
                    self.assertIn("unavailable", sources["issues"][0]["status"])
                    self.assertNotIn("fields", sources["issues"][0])
                else:
                    self.assertEqual(sources["issues"], [])

    def test_preparation_does_not_publish_private_source_material(self):
        plan = example_plan()
        sources = plan.pop("sources")
        sources["issues"][0]["fields"] = {"description": "private issue body"}
        model = mock.Mock(token="model-secret", model="test-model", usage={})
        model.complete.return_value = {"content": json.dumps(plan)}
        with tempfile.TemporaryDirectory() as temporary:
            shared, artifacts = Path(temporary) / "shared", Path(temporary) / "artifacts"
            shared.mkdir()
            artifacts.mkdir()
            with mock.patch.object(validation, "capture_sources", return_value=(sources, {"diff": "private diff"}, [])), \
                 mock.patch.object(validation, "Model", return_value=model):
                validation.prepare(shared, artifacts)
            for path in list(shared.iterdir()) + list(artifacts.iterdir()):
                self.assertNotIn("private issue body", path.read_text())
                self.assertNotIn("private diff", path.read_text())
                self.assertNotIn("model-secret", path.read_text())

    def test_deployment_digest_must_match_tested_component(self):
        info = {"references": {"spec": {"tags": [{"name": "example", "from": {"name": "registry/component@sha256:abc"}}]}}}
        matching = {"metadata": {"namespace": "example", "name": "controller"},
                    "status": {"containerStatuses": [{"name": "operator", "ready": True,
                                "imageID": "registry/component@sha256:abc"}]}}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            env = {"RELEASE_IMAGE_LATEST": "registry/release@sha256:123", "VALIDATION_COMPONENT": "example"}
            for name, pods, passed in [("missing", [], False), ("deployed", [matching], True)]:
                with self.subTest(name=name), mock.patch.dict(os.environ, env), \
                     mock.patch.object(validation, "command", side_effect=[json.dumps(info), json.dumps({"items": pods})]):
                    if passed:
                        validation.verify_deployment(directory / "kubeconfig", directory, [])
                        self.assertTrue((directory / "deployment.json").exists())
                    else:
                        with self.assertRaisesRegex(validation.ValidationError, "no ready container"):
                            validation.verify_deployment(directory / "kubeconfig", directory, [])

    def test_redaction(self):
        text = 'Bearer abcdefghijkl\ntoken: cluster-token\n{"password": "cluster-password"}\nknown-secret\n'
        result = validation.redact(text, ["known-secret"])
        for secret in ("abcdefghijkl", "cluster-token", "cluster-password", "known-secret"):
            self.assertNotIn(secret, result)

    def test_non_https_endpoint_rejected(self):
        with self.assertRaises(validation.ValidationError):
            validation.request_json("http://models.example/chat")

    def test_runtime_reasons_are_distinct(self):
        with self.assertRaises(validation.DeadlineExceeded):
            validation.interrupted(signal.SIGALRM, None)
        with self.assertRaises(InterruptedError):
            validation.interrupted(signal.SIGTERM, None)
        self.assertEqual(validation.safe_error(subprocess.TimeoutExpired("podman", 90)), "command timed out")

    def test_budget_prevents_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            token = Path(temporary) / "token"
            token.write_text("model-secret")
            env = {"VALIDATION_MODEL_URL": "https://model.example/chat",
                   "VALIDATION_EXECUTE_MODEL": "model", "VALIDATION_MODEL_TOKEN_FILE": str(token),
                   "VALIDATION_TOKEN_BUDGET": "1"}
            with mock.patch.dict(os.environ, env), mock.patch.object(validation, "request_json") as request:
                model = validation.Model("execute")
                with self.assertRaisesRegex(validation.ValidationError, "budget exhausted"):
                    model.complete([{"role": "system", "content": "test"}])
                request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
