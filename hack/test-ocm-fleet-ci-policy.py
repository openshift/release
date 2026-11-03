#!/usr/bin/env python3
"""Check OCM Fleet PR scheduling and merge gates (requires PyYAML)."""

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
REPO = "stolostron/ocm-fleet"
PREFIX = "stolostron-ocm-fleet-main"


def load(path):
    with (ROOT / path).open(encoding="utf-8") as source:
        return yaml.safe_load(source)


class CIPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = load(f"ci-operator/config/{REPO}/{PREFIX}.yaml")
        cls.jobs = load(f"ci-operator/jobs/{REPO}/{PREFIX}-presubmits.yaml")["presubmits"][REPO]

    def test_only_build_sensitive_changes_automatically_build_images(self):
        pattern = self.config["images"].get("run_if_changed", "")
        self.assertTrue(pattern, "ordinary source PRs must not automatically run Prow image builds")
        for path in [
            "Dockerfile", "Dockerfile.local", "Dockerfile.web", "Dockerfile.aio",
            ".dockerignore", ".containerignore", ".npmrc", "server/go.mod", "server/go.sum",
            "package.json", "package-lock.json", "sdk/common/package.json",
            "nx.json", "project.json", "client/web/project.json", "client/web/tsconfig.app.json",
            "client/web/rspack.config.ts", "extensions/core/client/module-federation.config.ts",
            "tools/merge-web.mjs", "sdk/build-utils/src/index.ts", "sdk/node-plugin/src/index.ts",
            "deploy/aio/s6/init/run", "deploy/aio/cmd/aio-init/main.go",
            ".github/workflows/e2e.yml", ".github/actions/setup-e2e/action.yml",
            "server/internal/transport/socket_arm64.go", "server/internal/transport/socket_amd64.s",
            "server/internal/transport/socket_arm64_test.go",
        ]:
            with self.subTest(build=path):
                self.assertRegex(path, pattern)
        for path in [
            "server/internal/service/cluster.go", "client/web/src/App.tsx",
            "sdk/common/src/components/Cluster.tsx", "extensions/core/client/src/index.ts",
            "e2e/cli/tests/scenarios/gateway.spec.ts", "docs/testing/end-to-end.md", "README.md",
        ]:
            with self.subTest(ordinary=path):
                self.assertNotRegex(path, pattern)
        job = next(job for job in self.jobs if job["context"] == "ci/prow/images")
        self.assertFalse(job["always_run"])
        self.assertEqual(job["run_if_changed"], pattern)
        self.assertFalse(job.get("optional", False), "matching builds must gate Tide merges")
        self.assertRegex("/test images", job["trigger"])

    def test_pr_publication_requires_explicit_commands_and_is_optional(self):
        tests = {test["as"]: test for test in self.config["tests"]}
        for suffix in ["server", "local", "web", "aio"]:
            name = f"pr-image-mirror-{suffix}"
            with self.subTest(name=name):
                config = tests[name]
                self.assertIs(config.get("always_run"), False)
                self.assertIs(config.get("optional"), True)
                self.assertNotIn("run_if_changed", config)
                job = next(job for job in self.jobs if job["context"] == f"ci/prow/{name}")
                self.assertFalse(job["always_run"])
                self.assertTrue(job["optional"])
                self.assertNotIn("run_if_changed", job)
                self.assertEqual(job["rerun_command"], f"/test {name}")
                self.assertRegex(f"/test {name}", job["trigger"])
                self.assertNotRegex("/test all", job["trigger"])

    def test_main_and_periodic_publication_keep_both_architectures(self):
        for image in self.config["images"]["items"]:
            self.assertIn("arm64", image["additional_architectures"])
        post = load(f"ci-operator/jobs/{REPO}/{PREFIX}-postsubmits.yaml")["postsubmits"][REPO]
        post = [job for job in post if "-nx-cache-proxy-" not in job["name"]]
        self.assertEqual(len([job for job in post if "pr-merge-image-mirror-" in job["name"]]), 4)
        self.assertTrue(all(job["always_run"] for job in post))
        periodic = load(f"ci-operator/jobs/{REPO}/{PREFIX}-periodics.yaml")["periodics"]
        periodic = [job for job in periodic if "-nx-cache-proxy-" not in job["name"]]
        self.assertEqual(len(periodic), 4)
        for test in self.config["tests"]:
            if test.get("postsubmit"):
                self.assertEqual(test["steps"]["env"]["ALSO_TAG_LATEST"], "true")
                self.assertNotIn("run_if_changed", test)
            if test["as"].startswith("republish-"):
                self.assertEqual(test["cron"], "30 2,8,14,20 * * *")
                self.assertEqual(test["steps"]["env"]["IMAGE_TAG"], "latest")

    def test_unconditional_branch_protection_requires_github_actions(self):
        config = load(f"core-services/prow/02_config/{REPO}/_prowconfig.yaml")
        branch = config["branch-protection"]["orgs"]["stolostron"]["repos"]["ocm-fleet"]["branches"]["main"]
        self.assertEqual(set(branch["required_status_checks"]["contexts"]), {"CI", "E2E"})


if __name__ == "__main__":
    unittest.main()
