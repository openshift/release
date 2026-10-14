#!/usr/bin/env python3
"""Offline contract tests for the ART publisher; never contact a cluster."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci-operator/step-registry/openshift/os/publish/art/openshift-os-publish-art-commands.sh"
TAGS = ["stream-coreos", "stream-coreos-extensions"]
DIGESTS = ["sha256:" + "a" * 64, "sha256:" + "b" * 64]
SECRET = "credential-marker-do-not-log"


def mirror_image(state, args):
    assert "--keep-manifest-list=true" in args
    assert "--registry-config=/etc/push-secret/.dockerconfigjson" in args
    assert "@sha256:" in args[-1].split("=")[0]
    digest = DIGESTS[state["mirrors"]]
    tag = TAGS[state["mirrors"]]
    assert args[-1] == f"registry.build13.ci.openshift.org/job/pipeline@{digest}=quay.io/openshift/ci:origin_scos-5.1-art_{tag}_{digest.removeprefix('sha256:')}"
    state["mirrors"] += 1
    print(f"https://user:{SECRET}@registry.example/image", file=sys.stderr)
    print(f"https://user:{SECRET}@registry.example/image")
    return int(state["mode"] == "mirror-failure")


def mock_oc():
    state_path = Path(os.environ["MOCK_STATE"])
    state = json.loads(state_path.read_text(encoding="utf-8"))
    args = sys.argv[2:]
    state["commands"].append(args)
    stream = state["stream"]
    exit_code = 0
    if "mirror" in args:
        exit_code = mirror_image(state, args)
    elif "replace" in args:
        update = json.loads(Path(args[args.index("-f") + 1]).read_text(encoding="utf-8"))
        assert update["metadata"]["resourceVersion"] == stream["metadata"]["resourceVersion"]
        assert update["spec"]["tags"][-1]["name"] == TAGS[-1]
        assert update["spec"]["tags"][0] == stream["spec"]["tags"][0]
        state["replaces"] += 1
        if state["mode"] == "conflict-exhausted" or (
                state["mode"] in ("conflict", "conflict-superseded") and state["replaces"] == 1):
            stream["metadata"]["resourceVersion"] = "2"
            if state["mode"] == "conflict-superseded":
                stream["spec"]["tags"][1]["generation"] += 1
            exit_code = 1
            print(f'Error from server (Conflict): error when replacing "{args[args.index("-f") + 1]}": '
                  'Operation cannot be fulfilled on imagestreams.image.openshift.io "scos-5.1-art": '
                  'the object has been modified; please apply your changes to the latest version and try again', file=sys.stderr)
        elif state["mode"] in ("forbidden", "invalid", "timeout-unapplied", "conflict-word", "other-conflict"):
            messages = {
                "forbidden": f"Error from server (Forbidden): {SECRET} conflict",
                "invalid": f'The ImageStream "scos-5.1-art" is invalid: {SECRET}',
                "timeout-unapplied": f"error: context deadline exceeded {SECRET}",
                "conflict-word": f"error: proxy conflict {SECRET}",
                "other-conflict": f"Error from server (Conflict): admission conflict {SECRET}",
            }
            print(messages[state["mode"]], file=sys.stderr)
            exit_code = 7
        else:
            for tag in update["spec"]["tags"][1:]:
                assert tag["reference"] is False
                assert tag["generation"] == 0
                assert tag["importPolicy"] == {"importMode": "PreserveOriginal"}
                assert tag["referencePolicy"] == {"type": "Source"}
                assert tag["from"]["name"].endswith(DIGESTS[TAGS.index(tag["name"])])
                assert state["mirrors"] == 2
                tag["generation"] = 11
            update["metadata"]["resourceVersion"] = "3"
            if state["mode"] == "response-source":
                update["spec"]["tags"][1]["from"]["name"] = "quay.io/other@sha256:" + "c" * 64
            elif state["mode"] == "response-reference":
                update["spec"]["tags"][1]["reference"] = True
            state["stream"] = update
            stream = update
            state["updated"] = True
            if state["mode"] == "timeout-applied":
                print(f"error: context deadline exceeded {SECRET}", file=sys.stderr)
                exit_code = 7
    elif "get" in args:
        if state["updated"]:
            observe_import(state)
        if state["mode"] == "get-failure":
            print(f"error: {SECRET}", file=sys.stderr)
            exit_code = 1
    else:
        raise AssertionError(args)
    state_path.write_text(json.dumps(state), encoding="utf-8")
    if exit_code == 0 and ("replace" in args or "get" in args):
        print(json.dumps(stream))
    return exit_code


def observe_import(state):
    state["polls"] += 1
    stream = state["stream"]
    mode = state["mode"]
    if mode == "superseded":
        stream["spec"]["tags"][1]["generation"] += 1
    elif mode == "superseded-source":
        stream["spec"]["tags"][1]["from"]["name"] = "quay.io/other@sha256:" + "c" * 64
    elif mode == "recreated":
        stream["metadata"]["uid"] = "different-stream"
    stream["status"]["tags"] = []
    for index, tag in enumerate(stream["spec"]["tags"][1:]):
        tag_mode = mode
        if mode.startswith("mixed-"):
            _, tag_mode, failed_index = mode.split(":")
            if index != int(failed_index):
                tag_mode = "success"
        generation = tag["generation"]
        digest = tag["from"]["name"].split("@")[1]
        if tag_mode == "missing":
            continue
        pending = tag_mode == "timeout" or (tag_mode == "pending" and state["polls"] < 3)
        items = [] if pending else [{"image": digest, "generation": generation}]
        if tag_mode == "empty-image":
            items[0]["image"] = ""
        if tag_mode == "wrong-digest":
            items[0]["image"] = "sha256:" + "d" * 64
        if tag_mode == "stale-generation":
            items[0]["generation"] -= 1
        conditions = []
        if tag_mode in ("failure", "old-failure", "sensitive-failure"):
            conditions = [{"type": "ImportSuccess", "status": "False", "reason": "RegistryUnavailable", "message": SECRET,
                           "generation": generation - (tag_mode == "old-failure")}]
        if tag_mode == "sensitive-failure":
            tag["from"]["name"] = f"https://user:{SECRET}@registry.example/image@{digest}"
            tag["annotations"] = {"sensitive": SECRET}
            items[0]["dockerImageReference"] = f"https://user:{SECRET}@registry.example/image"
        stream["status"]["tags"].append({"tag": tag["name"], "items": items, "conditions": conditions})


class PublishArtTest(unittest.TestCase):
    def run_publisher(self, mode="success", source=None, job_type="postsubmit"):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            stream = {
                "apiVersion": "image.openshift.io/v1", "kind": "ImageStream",
                "metadata": {"name": "scos-5.1-art", "namespace": "origin", "resourceVersion": "1", "uid": "stream-id"},
                "spec": {"tags": [{"name": "unrelated", "reference": True}] + [
                    {"name": tag, "generation": 10, "reference": True, "from": {"kind": "DockerImage", "name": "quay.io/old:tag"}} for tag in TAGS]},
                "status": {"tags": []},
            }
            state_path = temp / "state.json"
            state_path.write_text(json.dumps({"mode": mode, "stream": stream, "updated": False, "commands": [], "mirrors": 0, "replaces": 0, "polls": 0}))
            mock = temp / "oc"
            mock.write_text(f'#!/bin/sh\nexec {sys.executable} {Path(__file__).resolve()} --mock-oc "$@"\n')
            mock.chmod(0o755)
            sleep = temp / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o755)
            env = dict(os.environ, PATH=f"{temp}:{os.environ['PATH']}", MOCK_STATE=str(state_path), JOB_TYPE=job_type,
                       STREAM_COREOS_IMAGE=source or "registry.build13.ci.openshift.org/job/pipeline@" + DIGESTS[0],
                       STREAM_COREOS_EXTENSIONS_IMAGE="registry.build13.ci.openshift.org/job/pipeline@" + DIGESTS[1])
            result = subprocess.run(["bash", str(SCRIPT)], env=env, text=True, capture_output=True, timeout=120, check=False)
            return result, json.loads(state_path.read_text())

    def test_success_and_tag_semantics(self):
        result, state = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["mirrors"], 2)
        self.assertEqual(state["replaces"], 1)
        self.assertIn("Both ART CoreOS imports", result.stdout)
        for args in state["commands"]:
            self.assertNotIn("patch", args)
            self.assertNotIn("import-image", args)
            self.assertNotIn("--reference", args)

    def test_pending(self):
        result, state = self.run_publisher("pending")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["polls"], 3)

    def test_both_tags_must_import(self):
        for index in (0, 1):
            for mode in ("pending", "missing", "wrong-digest", "stale-generation", "failure"):
                with self.subTest(index=index, mode=mode):
                    result, state = self.run_publisher(f"mixed-:{mode}:{index}")
                    if mode == "pending":
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(state["polls"], 3)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("import failed" if mode == "failure" else "Timed out", result.stderr)

    def test_import_failure_diagnostics(self):
        result, _ = self.run_publisher("failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ART image import failed", result.stderr)
        self.assertIn("RegistryUnavailable", result.stderr)

    def test_old_failure_does_not_fail_current_import(self):
        result, _ = self.run_publisher("old-failure")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bounded_wait(self):
        for mode in ("timeout", "empty-image", "wrong-digest", "stale-generation"):
            with self.subTest(mode=mode):
                result, state = self.run_publisher(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Timed out", result.stderr)
                self.assertEqual(state["polls"], 60)

    def test_superseding_update(self):
        for mode in ("superseded", "superseded-source", "recreated"):
            with self.subTest(mode=mode):
                result, state = self.run_publisher(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("superseded", result.stderr)
                self.assertEqual(state["replaces"], 1)

    def test_unexpected_update_response_rejected(self):
        for mode in ("response-source", "response-reference"):
            with self.subTest(mode=mode):
                result, state = self.run_publisher(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not match this build", result.stderr)
                self.assertEqual(state["polls"], 0)

    def test_safe_conflict_retry(self):
        result, state = self.run_publisher("conflict")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["replaces"], 2)

    def test_conflict_superseded_not_overwritten(self):
        result, state = self.run_publisher("conflict-superseded")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("superseded before update", result.stderr)
        self.assertEqual(state["replaces"], 1)

    def test_only_optimistic_conflicts_retried(self):
        for mode in ("forbidden", "invalid", "timeout-unapplied", "timeout-applied", "conflict-word", "other-conflict"):
            with self.subTest(mode=mode):
                result, state = self.run_publisher(mode)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(state["replaces"], 1)
                self.assertEqual(state["polls"], 0)
                self.assertEqual(state["updated"], mode == "timeout-applied")
                self.assertIn("outcome unconfirmed", result.stderr)
                self.assertNotIn("superseded", result.stderr)
                self.assertNotIn(SECRET, result.stdout + result.stderr)
                if mode in ("forbidden", "invalid"):
                    self.assertIn(mode.title(), result.stderr)

    def test_exhausted_conflicts(self):
        result, state = self.run_publisher("conflict-exhausted")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["replaces"], 3)
        self.assertIn("three optimistic attempts", result.stderr)
        self.assertNotIn("superseded", result.stderr)

    def test_safe_failure_diagnostics(self):
        for mode in ("failure", "sensitive-failure", "mirror-failure", "get-failure"):
            with self.subTest(mode=mode):
                result, _ = self.run_publisher(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(SECRET, result.stdout + result.stderr)
                if mode == "failure":
                    self.assertIn("RegistryUnavailable", result.stderr)
                    self.assertIn(DIGESTS[0], result.stderr)
                    self.assertIn('"generation": 11', result.stderr)

    def test_floating_source_rejected_before_writes(self):
        result, state = self.run_publisher(source="registry.build13.ci.openshift.org/job/pipeline:stream-coreos")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["commands"], [])

    def test_presubmit_rejected_before_writes(self):
        result, state = self.run_publisher(job_type="presubmit")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["commands"], [])

    def test_ci_reference_only_configuration_unchanged(self):
        path = "ci-operator/config/openshift/os/openshift-os-master__okd-scos.yaml"
        current = yaml.safe_load((ROOT / path).read_text())
        self.assertEqual(current["promotion"], {"to": [{"name": "scos-5.1", "namespace": "origin"}]})
        self.assertEqual(current["releases"], {"latest": {"integration": {
            "include_built_images": True, "name": "scos-5.1", "namespace": "origin"}}})
        payload = json.loads((ROOT / "core-services/release-controller/_releases/release-okd-scos-5.1-ci.json").read_text())
        self.assertEqual(payload["referenceMode"], "source")
        self.assertEqual(payload["referenceRelease"]["pullRepository"], "quay-proxy.ci.openshift.org/openshift/ci")

    def test_generated_publisher_is_selected(self):
        path = ROOT / "ci-operator/jobs/openshift/os/openshift-os-master-postsubmits.yaml"
        jobs = yaml.safe_load(path.read_text())["postsubmits"]["openshift/os"]
        publisher = next(job for job in jobs if job["name"] == "branch-ci-openshift-os-master-okd-scos-publish-art")
        args = publisher["spec"]["containers"][0]["args"]
        self.assertIn("--target=publish-art", args)
        self.assertNotIn("--promote", args)
        self.assertEqual(publisher["max_concurrency"], 1)
        images = next(job for job in jobs if job["name"] == "branch-ci-openshift-os-master-okd-scos-images")
        self.assertIn("--target=[images]", images["spec"]["containers"][0]["args"])
        self.assertIn("--promote", images["spec"]["containers"][0]["args"])

    def test_ci_postsubmit_yaml_validation(self):
        spec = importlib.util.spec_from_file_location("yaml_validation", ROOT / "hack/validate-yaml-indentation.py")
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        path = "ci-operator/config/openshift/os/openshift-os-master__okd-scos.yaml"
        config = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
        self.assertEqual(validator.validate_yaml_structure(path, config), [])
        for value in (True, False):
            self.assertEqual(validator.validate_yaml_structure(path, {"as": "publish-art", "postsubmit": value}), [])
        for invalid in ({"as": "publish-art", "postsubmit": "true"}, {"postsubmit": True}):
            self.assertTrue(validator.validate_yaml_structure(path, invalid))
        self.assertTrue(validator.validate_yaml_structure("ci-operator/jobs/openshift/os/jobs.yaml", {"as": "publish-art", "postsubmit": True}))


if __name__ == "__main__":
    if sys.argv[1:] == ["--mock-oc"] or "--mock-oc" in sys.argv[1:]:
        sys.exit(mock_oc())
    unittest.main()
