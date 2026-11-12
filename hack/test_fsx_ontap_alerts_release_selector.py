#!/usr/bin/env python3
"""Tests for the hand-maintained FSx for NetApp ONTAP alerts release-5.1 periodic.

The job wraps ci-operator to select the newest 5.1 nightly payload in the Ready,
Accepted or Rejected phase before ci-operator starts. These tests execute the
wrapper command straight from the Prow job YAML with stub curl and ci-operator
executables, so they exercise the same script that Prow runs.

Run with `make test-fsx-ontap-alerts-release-selector`.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
JOBS_DIR = ROOT / "ci-operator/jobs"
JOB_FILE = (JOBS_DIR / "openshift/cluster-storage-operator"
            / "openshift-cluster-storage-operator-release-5.1-fsx-ontap-alerts-periodics.yaml")
GENERATED_JOB_FILE = JOB_FILE.with_name("openshift-cluster-storage-operator-release-5.1-periodics.yaml")
SOURCE_CONFIG = (ROOT / "ci-operator/config/openshift/cluster-storage-operator"
                 / "openshift-cluster-storage-operator-release-5.1__periodics.yaml")
JOB_NAME = ("periodic-ci-openshift-cluster-storage-operator-release-5.1-periodics-"
            "periodic-e2e-aws-csi-fsx-ontap-alerts")
TARGET = "periodic-e2e-aws-csi-fsx-ontap-alerts"
STREAM = "5.1.0-0.nightly"
REGISTRY = "registry.ci.openshift.org/ocp/release-5"
TAGS_URL = ("https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/"
            f"{STREAM}/tags?phase=Ready&phase=Accepted&phase=Rejected")


def load_job():
    with JOB_FILE.open(encoding="utf-8") as job_file:
        periodics = yaml.safe_load(job_file)["periodics"]
    jobs = [job for job in periodics if job["name"] == JOB_NAME]
    if len(jobs) != 1:
        raise AssertionError(f"expected one {JOB_NAME} in {JOB_FILE}, found {len(jobs)}")
    return jobs[0]


def inline_config(job):
    env = {item["name"]: item.get("value") for item in job["spec"]["containers"][0]["env"]}
    return yaml.safe_load(env["UNRESOLVED_CONFIG"])


def shared_spec(job):
    """Return the parts of a job that prowgen generates identically for every test."""
    container = job["spec"]["containers"][0]
    return {
        "agent": job["agent"],
        "decorate": job.get("decorate"),
        "decoration_config": job.get("decoration_config"),
        "extra_refs": job["extra_refs"],
        "args": [arg for arg in container["args"] if not arg.startswith("--target=")],
        "env": [item for item in container.get("env", []) if item["name"] != "UNRESOLVED_CONFIG"],
        "image": container["image"],
        "imagePullPolicy": container.get("imagePullPolicy"),
        "ports": container.get("ports"),
        "resources": container.get("resources"),
        "volumeMounts": container.get("volumeMounts"),
        "serviceAccountName": job["spec"].get("serviceAccountName"),
        "volumes": job["spec"].get("volumes"),
    }


def tag(timestamp, phase, pull_spec=None, stream=STREAM):
    name = f"{stream}-{timestamp}"
    entry = {"name": name, "phase": phase}
    entry["pullSpec"] = f"{REGISTRY}:{name}" if pull_spec is None else pull_spec
    return entry


def release(*tags, stream=STREAM):
    return json.dumps({"name": stream, "tags": list(tags)})


class JobDefinitionTests(unittest.TestCase):
    def setUp(self):
        self.job = load_job()
        self.container = self.job["spec"]["containers"][0]

    def test_job_is_defined_once_and_not_generated(self):
        definitions = []
        for path in sorted(JOBS_DIR.rglob("*.yaml")):
            if JOB_NAME not in path.read_text(encoding="utf-8"):
                continue
            with path.open(encoding="utf-8") as job_file:
                config = yaml.safe_load(job_file) or {}
            definitions.extend(path for job in config.get("periodics") or [] if job["name"] == JOB_NAME)
        self.assertEqual(definitions, [JOB_FILE])
        self.assertNotIn("ci.openshift.io/generator", self.job["labels"])
        self.assertIn("make test-fsx-ontap-alerts-release-selector",
                      self.job["annotations"]["ci.openshift.io/description"])

    def test_matches_generated_jobs(self):
        # prowgen only updates generated jobs; catch drift in credentials, volumes or args.
        # Compare with jobs generated from the same config variant: jobs generated
        # from other variants of this branch would pass a different --variant.
        variant = self.job["labels"]["ci-operator.openshift.io/variant"]
        with GENERATED_JOB_FILE.open(encoding="utf-8") as job_file:
            generated = [job for job in yaml.safe_load(job_file)["periodics"]
                         if job["labels"].get("ci.openshift.io/generator") == "prowgen"
                         and job["labels"].get("ci-operator.openshift.io/variant") == variant]
        self.assertTrue(generated, f"no generated jobs in {GENERATED_JOB_FILE}")
        for job in generated:
            with self.subTest(job=job["name"]):
                self.assertEqual(shared_spec(self.job), shared_spec(job))

    def test_inline_config_matches_source_config(self):
        with SOURCE_CONFIG.open(encoding="utf-8") as config_file:
            source = yaml.safe_load(config_file)
        config = inline_config(self.job)
        for section in ("base_images", "build_root", "releases", "resources", "zz_generated_metadata"):
            with self.subTest(section=section):
                self.assertEqual(config[section], source[section])
        self.assertNotIn(TARGET, [test["as"] for test in source["tests"]])

    def test_inline_config_defines_the_target(self):
        config = inline_config(self.job)
        self.assertEqual([test["as"] for test in config["tests"]], [TARGET])
        self.assertIn(f"--target={TARGET}", self.container["args"])
        self.assertEqual(config["zz_generated_metadata"]["variant"], "periodics")
        self.assertIn("--variant=periodics", self.container["args"])

    def test_no_kubernetes_variable_expansion(self):
        # Kubernetes expands $(NAME) and $$ in container commands and env values.
        values = self.container["command"] + [item.get("value") or "" for item in self.container["env"]]
        for value in values:
            self.assertIsNone(re.search(r"\$\([A-Za-z_][A-Za-z0-9_]*\)|\$\$", value))


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        self.container = load_job()["spec"]["containers"][0]
        self.response = self.directory / "response.json"
        self.curl_args = self.directory / "curl-args"
        self.ci_operator = self.directory / "ci-operator.json"
        self.environment = {
            key: value for key, value in os.environ.items() if key != "RELEASE_IMAGE_LATEST"
        }
        self.environment.update({
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "TEST_RESPONSE": str(self.response),
            "TEST_CURL_ARGS": str(self.curl_args),
            "TEST_CURL_EXIT": "0",
            "TEST_CI_OPERATOR": str(self.ci_operator),
        })
        self.write_executable("curl", '''#!/bin/bash
printf '%s\\n' "$@" > "${TEST_CURL_ARGS}"
if [[ "${TEST_CURL_EXIT}" == 0 ]]; then
    cat "${TEST_RESPONSE}"
fi
exit "${TEST_CURL_EXIT}"
''')
        self.write_executable("ci-operator", '''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
Path(os.environ["TEST_CI_OPERATOR"]).write_text(json.dumps(
    {"release": os.environ.get("RELEASE_IMAGE_LATEST"), "args": sys.argv[1:]}))
''')

    def write_executable(self, name, contents):
        path = self.directory / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def run_wrapper(self, body, curl_exit=0):
        self.response.write_text(body, encoding="utf-8")
        self.environment["TEST_CURL_EXIT"] = str(curl_exit)
        if self.ci_operator.exists():
            self.ci_operator.unlink()
        return subprocess.run(
            self.container["command"] + self.container["args"],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_selected(self, result, name):
        self.assertEqual(result.returncode, 0, result.stderr)
        invocation = json.loads(self.ci_operator.read_text(encoding="utf-8"))
        self.assertEqual(invocation["release"], f"{REGISTRY}:{name}")
        self.assertEqual(invocation["args"], self.container["args"])

    def assert_rejected(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.ci_operator.exists(), "ci-operator must not start")

    def test_selects_newest_tag_from_unordered_response(self):
        result = self.run_wrapper(release(
            tag("2026-11-09-070837", "Accepted"),
            tag("2026-11-11-091902", "Ready"),
            tag("2026-11-10-234040", "Rejected"),
            tag("2026-11-08-010203", "Accepted"),
        ))
        self.assert_selected(result, f"{STREAM}-2026-11-11-091902")
        self.assertIn(f"Selected {STREAM}-2026-11-11-091902 (Ready)", result.stderr)

    def test_selects_each_eligible_phase(self):
        for phase in ("Ready", "Accepted", "Rejected"):
            with self.subTest(phase=phase):
                result = self.run_wrapper(release(
                    tag("2026-11-01-000000", "Accepted"),
                    tag("2026-11-02-000000", phase),
                ))
                self.assert_selected(result, f"{STREAM}-2026-11-02-000000")

    def test_excludes_pending_and_failed_tags(self):
        result = self.run_wrapper(release(
            tag("2026-11-12-000000", "Pending"),
            tag("2026-11-11-000000", "Failed"),
            tag("2026-11-10-000000", "Rejected"),
            tag("2026-11-09-000000", "Accepted"),
        ))
        self.assert_selected(result, f"{STREAM}-2026-11-10-000000")

    def test_rejects_response_without_eligible_tag(self):
        for body in (release(), release(tag("2026-11-12-000000", "Pending"), tag("2026-11-11-000000", "Failed"))):
            with self.subTest(body=body):
                self.assert_rejected(self.run_wrapper(body), "is Ready, Accepted or Rejected")

    def test_rejects_malformed_responses(self):
        cases = {
            "empty": ("", "empty response"),
            "whitespace": ("\n", "empty response"),
            "not json": ("<html>unavailable</html>", "malformed release controller response"),
            "not an object": ("[]", "not a JSON object"),
            "wrong stream": (release(tag("2026-11-11-000000", "Ready"), stream="5.1.0-0.ci"),
                             "expected '5.1.0-0.nightly'"),
            "missing tags": (json.dumps({"name": STREAM}), "no tags list"),
            "tags not a list": (json.dumps({"name": STREAM, "tags": {}}), "no tags list"),
            "tag not an object": (json.dumps({"name": STREAM, "tags": ["x"]}), "malformed tag entry"),
            "tag from another stream": (release(tag("2026-11-11-000000", "Ready", stream="5.1.0-0.ci")),
                                        "is not a timestamped"),
            "untimestamped tag": (json.dumps({"name": STREAM, "tags": [{"name": STREAM, "phase": "Ready"}]}),
                                  "is not a timestamped"),
            "impossible timestamp": (release(tag("2026-13-40-250000", "Ready")), "invalid creation timestamp"),
            "unknown phase": (release(tag("2026-11-11-000000", "Succeeded")), "unknown phase"),
            "missing phase": (json.dumps({"name": STREAM, "tags": [{"name": f"{STREAM}-2026-11-11-000000"}]}),
                              "unknown phase"),
        }
        for case, (body, message) in cases.items():
            with self.subTest(case=case):
                self.assert_rejected(self.run_wrapper(body), message)

    def test_rejects_invalid_pull_spec_without_fallback(self):
        name = f"{STREAM}-2026-11-11-000000"
        for pull_spec in ("", f"{REGISTRY}:{STREAM}-2026-11-01-000000", f"{REGISTRY}@sha256:abc", 42):
            with self.subTest(pull_spec=pull_spec):
                result = self.run_wrapper(release(
                    tag("2026-11-01-000000", "Accepted"),
                    tag("2026-11-11-000000", "Ready", pull_spec=pull_spec),
                ))
                self.assert_rejected(result, f"newest eligible tag {name} has an invalid pullSpec")
        body = json.loads(release(tag("2026-11-01-000000", "Accepted"), tag("2026-11-11-000000", "Ready")))
        del body["tags"][1]["pullSpec"]
        self.assert_rejected(self.run_wrapper(json.dumps(body)), "has an invalid pullSpec None")

    def test_rejects_http_failures(self):
        for exit_code in (6, 22, 28):
            with self.subTest(exit_code=exit_code):
                self.assert_rejected(self.run_wrapper("", curl_exit=exit_code), "failed to list")

    def test_requests_filtered_tags_with_bounded_retries(self):
        self.run_wrapper(release(tag("2026-11-11-000000", "Ready")))
        arguments = self.curl_args.read_text(encoding="utf-8").splitlines()
        self.assertEqual(arguments[-1], TAGS_URL)
        self.assertIn("--fail", arguments)
        for flag, value in (("--retry", "5"), ("--retry-delay", "10"), ("--max-time", "60"),
                            ("--connect-timeout", "20")):
            self.assertEqual(arguments[arguments.index(flag) + 1], value)


if __name__ == "__main__":
    unittest.main()
