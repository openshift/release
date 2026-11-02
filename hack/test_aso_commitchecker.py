import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "ci-operator/config/openshift/azure-service-operator/openshift-azure-service-operator-main.yaml"
IMAGE = "quay.io/openshift/ci@sha256:1e87dd1e2913c0d5ae68d8694ec987d97894ed73a5fc40953f6b199f717d9315"


class ASOCommitcheckerTests(unittest.TestCase):
    def setUp(self):
        self.checkout = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.checkout)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.com")
        self.git("config", "commit.gpgsign", "false")
        self.commit("Base commit")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.foreign = "a2a6922f741835114ccff1e604ff65ab16a13d3b"
        self.refs = {"org": "openshift", "repo": "azure-service-operator", "base_ref": "main",
                     "base_sha": self.base, "pulls": [{"number": 1, "sha": self.base}]}
        self.spec = {"type": "presubmit", "job": "pull-ci-openshift-azure-service-operator-main-verify-commits",
                     "refs": copy.deepcopy(self.refs)}
        config = yaml.safe_load(CONFIG.read_text())
        self.commands = next(test["commands"] for test in config["tests"] if test["as"] == "verify-commits")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.checkout, text=True, stderr=subprocess.DEVNULL)

    def commit(self, message, signoff=True):
        args = ["commit", "--allow-empty", "-m", message]
        if signoff:
            args.append("--signoff")
        self.git(*args)

    def rehearse(self):
        self.spec = {"type": "presubmit", "job": "rehearse-87819-pull-ci-openshift-azure-service-operator-main-verify-commits",
                     "refs": {"org": "openshift", "repo": "release", "base_ref": "main",
                              "base_sha": self.foreign, "pulls": [{"number": 87819, "sha": self.foreign}]},
                     "extra_refs": [{"org": "openshift", "repo": "azure-service-operator", "base_ref": "main",
                                     "path_alias": "github.com/Azure/azure-service-operator", "workdir": True}]}

    def run_commands(self, commands=None, job_spec=None):
        script = 'commitchecker() { printf "%s\\n" "$@" > /fixture/arguments; /usr/bin/commitchecker "$@"; }\n'
        script += self.commands if commands is None else commands
        (self.checkout / "command.sh").write_text(script)
        return subprocess.run([
            "podman", "run", "--rm", "--network=none", "-v", f"{self.checkout}:/fixture:z", "-w", "/fixture",
            "-e", "GIT_CONFIG_COUNT=1", "-e", "GIT_CONFIG_KEY_0=safe.directory", "-e", "GIT_CONFIG_VALUE_0=/fixture",
            "-e", f"JOB_SPEC={json.dumps(self.spec) if job_spec is None else job_spec}",
            "-e", f"PULL_BASE_SHA={self.foreign if 'extra_refs' in self.spec else self.base}",
            "--entrypoint", "/bin/bash", IMAGE, "command.sh"], text=True, capture_output=True, check=False)

    def assert_pass(self, expected):
        result = self.run_commands()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.checkout / "arguments").read_text().splitlines(), ["--start", expected])
        return result

    def assert_metadata_failure(self):
        result = self.run_commands()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.checkout / "arguments").exists())

    def test_original_cross_repo_failure_and_fixed_empty_range(self):
        self.rehearse()
        original = self.run_commands('commitchecker --start ${PULL_BASE_SHA:-main}')
        self.assertNotEqual(original.returncode, 0)
        self.assertIn("Invalid revision range", original.stdout + original.stderr)
        result = self.assert_pass("refs/heads/main")
        self.assertIn("No ASO pull requests", result.stdout)

    def test_normal_pr_checks_commits_after_base(self):
        self.git("checkout", "-b", "pull")
        self.commit("UPSTREAM: <carry>: Add fixture")
        self.assert_pass(self.base)

    def test_normal_pr_invalid_commit_is_rejected(self):
        self.git("checkout", "-b", "pull")
        self.commit("Invalid summary", signoff=False)
        result = self.run_commands()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has invalid summary", result.stdout + result.stderr)
        self.assertEqual((self.checkout / "arguments").read_text().splitlines(), ["--start", self.base])

    def test_extra_ref_pr_uses_its_own_base(self):
        self.rehearse()
        self.spec["extra_refs"][0].update(self.refs)
        self.git("checkout", "-b", "pull")
        self.commit("UPSTREAM: <carry>: ASO pull in extra refs")
        self.assert_pass(self.base)

    def test_missing_or_malformed_job_spec(self):
        for value in ["", "not json", "null", "{}"]:
            with self.subTest(value=value):
                result = self.run_commands(job_spec=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.checkout / "arguments").exists())

    def test_missing_duplicate_and_wrong_repo_refs(self):
        for spec in [{"refs": {}}, {"refs": self.refs, "extra_refs": [self.refs]},
                     {"refs": {"org": "Azure", "repo": "other"}}]:
            with self.subTest(spec=spec):
                self.spec = spec
                self.assert_metadata_failure()

    def test_invalid_or_missing_base(self):
        for value in [None, "", "main", self.foreign]:
            with self.subTest(base=value):
                self.spec["refs"]["base_sha"] = value
                self.assert_metadata_failure()

    def test_rehearsal_requires_workdir_main_and_expected_primary(self):
        for key, value in [("workdir", False), ("base_ref", "release-4.23")]:
            with self.subTest(key=key):
                self.rehearse()
                self.spec["extra_refs"][0][key] = value
                self.assert_metadata_failure()
        self.rehearse()
        self.spec["refs"]["repo"] = "other"
        self.assert_metadata_failure()

    def test_rehearsal_requires_type_and_job_prefix(self):
        for key, value in [("type", None), ("type", "periodic"), ("job", None), ("job", "ordinary-job")]:
            with self.subTest(key=key, value=value):
                self.rehearse()
                self.spec[key] = value
                self.assert_metadata_failure()

    def test_normal_pr_requires_pulls(self):
        del self.spec["refs"]["pulls"]
        self.assert_metadata_failure()

    def test_missing_local_main_or_changed_checkout(self):
        self.rehearse()
        self.git("checkout", "-b", "other")
        self.git("branch", "-D", "main")
        self.assert_metadata_failure()
        self.git("branch", "main", self.base)
        self.commit("Unexpected extra commit")
        self.assert_metadata_failure()


if __name__ == "__main__":
    unittest.main(verbosity=2)
