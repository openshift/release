"""Execute the registry runner without network access, including hostile PR content."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = (
    Path(__file__).resolve().parents[2]
    / "ci-operator/step-registry/ocp-art/validate/build-data/ocp-art-validate-build-data-commands.sh"
)


class TestRunner(unittest.TestCase):
    def test_pr_python_modules_cannot_shadow_installed_validator(self):
        """Execute the trusted validator despite hostile import hooks in the PR checkout."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / "checkout"
            checkout.mkdir()
            marker = root / "token-stolen"
            payload = f"from pathlib import Path\nPath({str(marker)!r}).touch()\n"
            (checkout / "validator").mkdir()
            (checkout / "validator/__init__.py").write_text(payload)
            (checkout / "validator/ci.py").write_text("raise SystemExit(0)\n")
            (checkout / "sitecustomize.py").write_text(payload)
            (checkout / "group.yml").write_text(
                "name: test\nvars: {MAJOR: 1, MINOR: 0}\n"
            )
            binaries = root / "bin"
            binaries.mkdir()
            # Only network/setup boundaries are stubbed; the real installed validator executes.
            git = binaries / "git"
            git.write_text("""#!/bin/bash
if [[ "$1" == clone || "$1" == init ]]; then
  for destination; do :; done
  mkdir -p "${destination}/config"
fi
if [[ " $* " == *" fetch "* ]]; then
  for ref; do :; done
  printf '%s\\n' "${ref}" > "${ART_TEST_FETCHED_REF}"
fi
""")
            uv = binaries / "uv"
            uv.write_text("""#!/bin/bash
mkdir -p "${UV_PROJECT_ENVIRONMENT}/bin"
cat > "${UV_PROJECT_ENVIRONMENT}/bin/python" <<'PYTHON'
#!/bin/bash
exec "${ART_TEST_PYTHON}" "$@"
PYTHON
chmod +x "${UV_PROJECT_ENVIRONMENT}/bin/python"
""")
            git.chmod(0o755)
            uv.chmod(0o755)
            environment = dict(
                os.environ,
                PATH=f"{binaries}:{os.environ['PATH']}",
                ART_TEST_PYTHON=sys.executable,
                ART_TOOLS_REF="a" * 40,
                RELEASE_DATA_REF="main",
                KONFLUX_APPLICATION="test",
                ARTIFACT_DIR=str(root / "artifacts"),
                ART_TEST_FETCHED_REF=str(root / "fetched-art-ref"),
            )
            result = subprocess.run(
                ["bash", str(RUNNER)],
                cwd=checkout,
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertFalse(marker.exists(), result.stdout + result.stderr)
            self.assertTrue(
                (root / "fetched-art-ref").exists(),
                "ART revision must be fetched as a ref, not cloned as a branch",
            )
            self.assertEqual((root / "fetched-art-ref").read_text().strip(), "a" * 40)
            self.assertIn("Validated", result.stdout, result.stderr)
            self.assertTrue((root / "artifacts/validation.json").is_file())
            # The token is intentionally unavailable in this local test; it must fail clearly.
            self.assertEqual(result.returncode, 1)


class TestSharedJob(unittest.TestCase):
    def test_future_y_streams_use_shared_job_and_protection(self):
        """Future LP y-streams automatically receive the shared job and force-push protection."""
        import re
        import yaml

        root = Path(__file__).resolve().parents[2]
        job = yaml.safe_load(
            (
                root
                / "ci-operator/jobs/openshift-eng/ocp-build-data/openshift-eng-ocp-build-data-validation-presubmits.yaml"
            ).read_text()
        )["presubmits"]["openshift-eng/ocp-build-data"][0]
        policy = yaml.safe_load(
            (
                root
                / "core-services/prow/02_config/openshift-eng/ocp-build-data/_prowconfig.yaml"
            ).read_text()
        )["branch-protection"]["orgs"]["openshift-eng"]["repos"]["ocp-build-data"]
        for branch in ("oadp-1.999", "logging-7.0", "zero-trust-2.0", "acm-6.42"):
            with self.subTest(branch=branch):
                self.assertTrue(
                    any(re.search(pattern, branch) for pattern in job["branches"])
                )
                self.assertTrue(
                    any(re.search(pattern, branch) for pattern in policy["include"])
                )
        for branch in (
            "main",
            "openshift-5.0",
            "rhel-9-golang-1.26",
            "oadp-1.6-my-fix",
        ):
            with self.subTest(branch=branch):
                self.assertFalse(
                    any(re.search(pattern, branch) for pattern in job["branches"])
                )
                self.assertFalse(
                    any(re.search(pattern, branch) for pattern in policy["include"])
                )
        self.assertFalse(policy["unmanaged"])
        self.assertTrue(policy["protect"])
        self.assertFalse(policy["allow_force_pushes"])
        self.assertTrue(policy["enforce_admins"])
        self.assertNotIn("branches", policy)
        environment = {
            item["name"]: item for item in job["spec"]["containers"][0]["env"]
        }
        # ci-operator requires this input when resolving registry workflows remotely.
        config = yaml.safe_load(environment["UNRESOLVED_CONFIG"]["value"])
        self.assertEqual(config["tests"][0]["steps"]["workflow"], "ocp-art-build-data")
        dockerfile = config["build_root"]["project_image"]["dockerfile_literal"]
        users = [
            line.split()[1]
            for line in dockerfile.splitlines()
            if line.startswith("USER ")
        ]
        self.assertEqual(
            users[-1], "1001", "Package installation must not leave the runtime as root"
        )


if __name__ == "__main__":
    unittest.main()
