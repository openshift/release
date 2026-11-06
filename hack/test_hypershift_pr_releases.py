#!/usr/bin/env python3
"""Offline tests for the actual resolver and existing guest/test shell consumers."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


REPO = Path(__file__).resolve().parents[1]
REGISTRY = REPO / "ci-operator/step-registry"
RESOLVER = REGISTRY / "hypershift/resolve-pr-releases/hypershift-resolve-pr-releases-commands.sh"
CHAIN = REGISTRY / "hypershift/run-e2e-matrix-from-pr/hypershift-run-e2e-matrix-from-pr-chain.yaml"
WORKFLOW = REGISTRY / "hypershift/run-e2e-matrix/hypershift-run-e2e-matrix-workflow.yaml"
BODY = "## Release Test Matrix\n### AWS\n- [ ] release-4.21\n- [X] release-4.20\n- [ ] release-4.19\n"
SHA = "a" * 40
CI_NAME = "4.20.0-0.ci-2026-11-03-221630"
CI_REPOSITORY = "quay-proxy.ci.openshift.org/openshift/ci"
STABLE_REPOSITORY = "quay.io/openshift-release-dev/ocp-release"
CI_IMAGE = CI_REPOSITORY + "@sha256:" + "1" * 64
STABLE_IMAGE = STABLE_REPOSITORY + "@sha256:" + "2" * 64

STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["FIXTURE_DIR"])
fixture = json.loads((root / "fixture.json").read_text())
arguments = sys.argv[1:]
tool = Path(sys.argv[0]).name
with (root / "calls.jsonl").open("a") as output:
    output.write(json.dumps([tool, arguments]) + "\n")
if tool == "curl":
    url = arguments[-1]
    endpoint = "pr" if url.startswith("https://api.github.com/repos/") else "stable" if url.endswith("/tags") else "ci"
    status = fixture.get("http", {}).get(endpoint, "200")
    counter = root / (endpoint + "-count")
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    if isinstance(status, list):
        status = status[min(count, len(status) - 1)]
    body = fixture[endpoint]
    Path(arguments[arguments.index("--output") + 1]).write_text(body if isinstance(body, str) else json.dumps(body))
    print(status, end="")
    sys.exit(7 if status == "000" else 0)
if tool == "oc":
    if fixture.get("oc_error"):
        sys.exit(1)
    if arguments[:2] == ["image", "info"]:
        stable = "ocp-release:" in arguments[-1]
        print(json.dumps({"config": {"architecture": fixture.get("arch", "amd64"), "os": fixture.get("os", "linux")},
                          "digest": fixture.get("digest", "sha256:" + ("2" if stable else "1") * 64)}))
    elif arguments[:3] == ["adm", "release", "info"]:
        stable = "ocp-release@" in arguments[-1]
        print(json.dumps({"metadata": {"version": fixture.get("version", "4.20.10" if stable else fixture["ci"]["name"])}}))
    else:
        sys.exit(2)
'''


def tag(name, phase="Accepted"):
    return {"name": name, "phase": phase, "pullSpec": f"{STABLE_REPOSITORY}:{name}-x86_64"}


def remove_matrix_job(configuration, key):
    if key == "tests":
        jobs = configuration[key]
        selected = [job for job in jobs if job.get("as") == "e2e-from-pr-aws"]
        configuration[key] = [job for job in jobs if job not in selected]
    else:
        jobs = configuration[key]["openshift/hypershift"]
        selected = [job for job in jobs if job["name"] == "pull-ci-openshift-hypershift-main-e2e-from-pr-aws"]
        configuration[key]["openshift/hypershift"] = [job for job in jobs if job not in selected]
    return selected


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        for directory in ("bin", "shared", "artifacts"):
            (self.root / directory).mkdir()
        for name in ("curl", "oc"):
            executable = self.root / "bin" / name
            executable.write_text(STUB)
            executable.chmod(0o755)
        sleep = self.root / "bin/sleep"
        sleep.write_text("#!/bin/bash\nexit 0\n")
        sleep.chmod(0o755)
        self.fixture = {
            "pr": {"number": 123, "head": {"sha": SHA}, "base": {"ref": "main", "repo": {"owner": {"login": "openshift"}, "name": "hypershift"}}, "body": BODY},
            "ci": {"name": CI_NAME, "phase": "Accepted", "pullSpec": CI_REPOSITORY + ":rc_payload__" + CI_NAME},
            "stable": {"name": "4-stable", "tags": [tag("4.20.9"), tag("4.20.10"), tag("4.20.99-rc.1"), tag("4.21.100"), tag("4.20.100", "Rejected")]},
        }
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        FIXTURE_DIR=str(self.root), SHARED_DIR=str(self.root / "shared"), ARTIFACT_DIR=str(self.root / "artifacts"),
                        HYPERSHIFT_PLATFORM="aws", AWS_MULTI_ARCH="false", REPO_OWNER="openshift", REPO_NAME="hypershift",
                        PULL_NUMBER="123", PULL_PULL_SHA=SHA,
                        JOB_SPEC=json.dumps({"type": "presubmit", "refs": {"org": "openshift", "repo": "hypershift", "base_ref": "main", "pulls": [{"number": 123, "sha": SHA, "title": "untrusted title release-4.19"}]}}))

    def run_resolver(self, success=True):
        (self.root / "fixture.json").write_text(json.dumps(self.fixture))
        result = subprocess.run(["bash", str(RESOLVER)], env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return self.root / "shared/nodepool_release_images"

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_first_selection_numeric_ga_and_snapshot(self):
        self.fixture["pr"]["body"] += "- [x] release-4.19\nPRIVATE_PR_SENTINEL\n"
        result = self.run_resolver()
        self.assertIn("Ignoring additional checked AWS release-4.19", result.stderr)
        self.assertEqual(self.snapshot().read_text(), f"export RELEASE_IMAGE_LATEST='{CI_IMAGE}'\nexport OCP_IMAGE_N1='{STABLE_IMAGE}'\nexport E2E_PREVIOUS_RELEASE_IMAGE='{STABLE_IMAGE}'\n")
        metadata = json.loads((self.root / "artifacts/pr-release-matrix.json").read_text())
        self.assertEqual(metadata["stable"]["name"], "4.20.10")
        self.assertEqual(metadata["minor"], "4.20")
        self.assertNotIn("body", metadata)
        self.assertNotIn("PRIVATE_PR_SENTINEL", result.stdout + result.stderr + json.dumps(metadata))
        calls = self.calls()
        self.assertEqual(len([call for call in calls if call[0] == "curl"]), 3)
        self.assertEqual(len([call for call in calls if call[0] == "curl" and "api.github.com" in call[1][-1]]), 1)
        for tool, arguments in calls:
            if tool == "curl":
                self.assertNotIn("-L", arguments)
                self.assertIn("--max-time", arguments)
                self.assertNotIn("--header", arguments)
        self.assertEqual(list((self.root / "shared").glob(".pr-release-matrix.*")), [])

    def test_markers_platforms_boundaries_crlf_and_fences(self):
        bodies = [BODY.replace("[X]", "[x]"), BODY.replace("\n", "\r\n"),
                  "```markdown\n" + BODY.replace("4.20", "4.19") + "```\n" + BODY,
                  "~~~\n" + BODY + "~~~\n" + BODY,
                  "## Release Test Matrix\n### Azure\n- [x] release-4.19\n### AWS\n- [x] release-4.20\n### GCP\n- [x] release-4.19\n## Other\n- [x] release-4.19\n",
                  BODY + "### Azure\n- [x] anything unsafe\n",
                  "## Release Test Matrix\n### AWS\n```\n- [x] release-4.19\n```\n- [x] release-4.20\n"]
        for body in bodies:
            with self.subTest(body=body):
                self.fixture["pr"]["body"] = body
                self.run_resolver()
                self.assertIn(CI_IMAGE, self.snapshot().read_text())

    def test_missing_ambiguous_malformed_and_hostile(self):
        bodies = ["", "### AWS\n- [x] release-4.20", BODY.replace("### AWS", "### Azure"),
                  BODY.replace("[X]", "[ ]"), BODY + BODY, BODY + "### AWS\n- [x] release-4.20\n",
                  BODY.replace("Release Test Matrix", "Release Test Matrix extra"), BODY.replace("### AWS", "### aws"),
                  BODY.replace("release-4.20", "release-4.20.1"), BODY.replace("release-4.20", "release-4.20; touch /tmp/unsafe"),
                  BODY.replace("release-4.20", "$(touch /tmp/unsafe)"), BODY.replace("release-4.20", "release-04.20"),
                  BODY + "- [x ] release-4.19\n", BODY + "- [ x] release-4.19\n", BODY + "- [x release-4.19\n",
                  "## Release Test Matrix\n### AWS\n```\n- [x] release-4.20\n",
                  "## Release Test Matrix\n### AWS\n## Elsewhere\n- [x] release-4.20\n"]
        for body in bodies:
            with self.subTest(body=body):
                self.fixture["pr"]["body"] = body
                result = self.run_resolver(False)
                self.assertIn("ERROR:", result.stderr)
                self.assertFalse(self.snapshot().exists())

    def test_identity_and_sha_guard(self):
        cases = [("number", 999), ("head", {"sha": "b" * 40}),
                 ("base", {"ref": "release-4.20", "repo": {"owner": {"login": "openshift"}, "name": "hypershift"}}),
                 ("base", {"ref": "main", "repo": {"owner": {"login": "other"}, "name": "hypershift"}}), ("body", None)]
        original = dict(self.fixture["pr"])
        for field, value in cases:
            with self.subTest(field=field, value=value):
                self.fixture["pr"] = dict(original, **{field: value})
                self.run_resolver(False)
        self.fixture["pr"] = original
        self.env["PULL_PULL_SHA"] = "b" * 40
        self.run_resolver(False)
        self.env["PULL_PULL_SHA"] = SHA
        self.env["REPO_NAME"] = "hypershift/../../other"
        self.run_resolver(False)

    def test_job_metadata_and_platform_constraints(self):
        for key, value in (("AWS_MULTI_ARCH", "true"), ("HYPERSHIFT_PLATFORM", "azure"), ("PULL_NUMBER", "not-a-number"), ("JOB_SPEC", "not-json")):
            with self.subTest(key=key):
                original = self.env[key]
                self.env[key] = value
                self.run_resolver(False)
                self.env[key] = original
        for field, value in (("base_ref", "release-4.20"), ("org", "other"), ("pulls", [])):
            with self.subTest(field=field):
                job = json.loads(self.env["JOB_SPEC"])
                job["refs"][field] = value
                original = self.env["JOB_SPEC"]
                self.env["JOB_SPEC"] = json.dumps(job)
                self.run_resolver(False)
                self.env["JOB_SPEC"] = original

    def test_http_errors_invalid_json_and_retries(self):
        for endpoint in ("pr", "ci", "stable"):
            for status in ("403", "404", "302", "429", "500", "000"):
                with self.subTest(endpoint=endpoint, status=status):
                    self.fixture["http"] = {endpoint: status}
                    count_file = self.root / (endpoint + "-count")
                    before = int(count_file.read_text()) if count_file.exists() else 0
                    self.run_resolver(False)
                    self.assertEqual(int(count_file.read_text()) - before, 3 if status in ("429", "500", "000") else 1)
        self.fixture["http"] = {"pr": ["500", "200"]}
        (self.root / "pr-count").unlink()
        self.run_resolver()
        self.snapshot().unlink()
        self.fixture.pop("http")
        for endpoint in ("pr", "ci", "stable"):
            original = self.fixture[endpoint]
            self.fixture[endpoint] = "not json"
            self.run_resolver(False)
            self.fixture[endpoint] = original

    def test_invalid_or_unavailable_releases(self):
        cases = [("ci", {"name": CI_NAME, "phase": "Rejected", "pullSpec": CI_REPOSITORY + ":tag"}),
                 ("ci", {"name": CI_NAME.replace("4.20", "4.21"), "phase": "Accepted", "pullSpec": CI_REPOSITORY + ":tag"}),
                 ("ci", {"name": CI_NAME.replace("ci-", "nightly-"), "phase": "Accepted", "pullSpec": CI_REPOSITORY + ":tag"}),
                 ("ci", {"name": CI_NAME, "phase": "Accepted", "pullSpec": "evil.example/release:tag"}),
                 ("stable", {"name": "4-stable", "tags": []}),
                 ("stable", {"name": "4-stable", "tags": [tag("4.20.99-rc.1"), tag("4.21.2")]}),
                 ("stable", {"name": "4-stable", "tags": [dict(tag("4.20.10"), pullSpec=STABLE_REPOSITORY + ":4.20.10-aarch64")]}),
                 ("stable", {"name": "wrong", "tags": [tag("4.20.10")]})]
        for endpoint, value in cases:
            with self.subTest(endpoint=endpoint, value=value):
                original = self.fixture[endpoint]
                self.fixture[endpoint] = value
                self.run_resolver(False)
                self.fixture[endpoint] = original
        for field, value in (("arch", "arm64"), ("os", "windows"), ("digest", "sha256:bad"), ("version", "4.19.1"), ("oc_error", True)):
            with self.subTest(field=field):
                self.fixture[field] = value
                self.run_resolver(False)
                self.fixture.pop(field)

    def test_atomic_failure_does_not_replace_snapshot(self):
        self.snapshot().write_text("previous snapshot\n")
        self.fixture["arch"] = "arm64"
        self.run_resolver(False)
        self.assertEqual(self.snapshot().read_text(), "previous snapshot\n")
        self.assertEqual(list((self.root / "shared").glob(".pr-release-matrix.*")), [])

    def test_late_artifact_failure_cleans_staged_snapshot(self):
        self.snapshot().write_text("previous snapshot\n")
        blocked = self.root / "artifact-destination"
        blocked.write_text("not a directory")
        self.env["ARTIFACT_DIR"] = str(blocked)
        self.run_resolver(False)
        self.assertEqual(self.snapshot().read_text(), "previous snapshot\n")
        self.assertEqual(list((self.root / "shared").glob(".pr-release-matrix.*")), [])

    def consumer(self, kind, status=0):
        binary = self.root / "consumer"
        capture = self.root / "consumer.json"
        binary.write_text("#!/usr/bin/env python3\nimport json,os\nfrom pathlib import Path\n" +
                          f"Path({str(capture)!r}).write_text(json.dumps({{key:os.getenv(key) for key in ('RELEASE_IMAGE_LATEST','OCP_IMAGE_N1','E2E_PREVIOUS_RELEASE_IMAGE','KUBECONFIG','TEST_PLAN')}}))\nraise SystemExit({status})\n")
        binary.chmod(0o755)
        if kind == "test":
            commands = yaml.safe_load(CHAIN.read_text())["chain"]["steps"][0]["commands"].replace("/hypershift/bin/run-tests", str(binary))
        else:
            commands = (REGISTRY / "hypershift/aws/create-guests/hypershift-aws-create-guests-commands.sh").read_text().replace("/hypershift/bin/create-guests", str(binary))
        env = dict(self.env, RELEASE_IMAGE_LATEST="default-management", OCP_IMAGE_N1="default-skew", E2E_PREVIOUS_RELEASE_IMAGE="default-initial")
        result = subprocess.run(["bash", "-c", commands], env=env, text=True, capture_output=True, check=False)
        return result, json.loads(capture.read_text()) if capture.exists() else None

    def test_create_and_test_consume_same_snapshot_and_status(self):
        self.run_resolver()
        (self.root / "shared/test-plan.yaml").write_text("test plan")
        for consumer in ("create", "test"):
            for status in (0, 23):
                with self.subTest(consumer=consumer, status=status):
                    result, capture = self.consumer(consumer, status)
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(capture["RELEASE_IMAGE_LATEST"], CI_IMAGE)
                    self.assertEqual(capture["OCP_IMAGE_N1"], STABLE_IMAGE)
                    self.assertEqual(capture["E2E_PREVIOUS_RELEASE_IMAGE"], STABLE_IMAGE)
                    self.assertEqual(capture["TEST_PLAN"], str(self.root / "shared/test-plan.yaml"))

    def test_test_consumer_rejects_missing_incomplete_and_hostile_snapshot(self):
        result, capture = self.consumer("test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(capture)
        for content in ("", "export RELEASE_IMAGE_LATEST='default'\n", "$(touch /tmp/unsafe)\n", f"export RELEASE_IMAGE_LATEST='{CI_IMAGE}'\nexport OCP_IMAGE_N1='{STABLE_IMAGE}'\nexport E2E_PREVIOUS_RELEASE_IMAGE='{STABLE_IMAGE}'\necho unsafe\n"):
            with self.subTest(content=content):
                self.snapshot().write_text(content)
                result, capture = self.consumer("test")
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(capture)


class ConfigurationTests(unittest.TestCase):
    def test_workflow_order_and_preserved_cleanup(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())["workflow"]["steps"]
        original = yaml.safe_load((REGISTRY / "hypershift/aws/e2e-v2/hypershift-aws-e2e-v2-workflow.yaml").read_text())["workflow"]["steps"]
        self.assertEqual(workflow["post"], original["post"])
        self.assertNotIn({"ref": "hypershift-resolve-nodepool-releases"}, workflow["pre"])
        self.assertLess(workflow["pre"].index({"ref": "hypershift-resolve-pr-releases"}), workflow["pre"].index({"chain": "hypershift-aws-create-guests"}))
        self.assertEqual([step for step in workflow["pre"] if step != {"ref": "hypershift-resolve-pr-releases"}], [step for step in original["pre"] if step != {"ref": "hypershift-resolve-nodepool-releases"}])

    def test_only_new_source_and_generated_job(self):
        base = subprocess.check_output(["git", "merge-base", "HEAD", "origin/main"], cwd=REPO, text=True).strip()
        for path, key in (("ci-operator/config/openshift/hypershift/openshift-hypershift-main.yaml", "tests"),
                          ("ci-operator/jobs/openshift/hypershift/openshift-hypershift-main-presubmits.yaml", "presubmits")):
            current = yaml.safe_load((REPO / path).read_text())
            original = yaml.safe_load(subprocess.check_output(["git", "show", f"{base}:{path}"], cwd=REPO, text=True))
            merged_baseline = copy.deepcopy(current)
            selected = remove_matrix_job(current, key)
            self.assertEqual(len(selected), 1, path)
            self.assertFalse(selected[0]["always_run"])
            self.assertTrue(selected[0]["optional"])
            for baseline in (original, merged_baseline):
                remove_matrix_job(baseline, key)
                self.assertEqual(current, baseline, path)


if __name__ == "__main__":
    unittest.main()
