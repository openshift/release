#!/usr/bin/env python3

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STEP = ROOT / "ci-operator/step-registry/rosa/cluster/upgrade/cluster/rosa-cluster-upgrade-cluster-commands.sh"


class RosaUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        capture_directory = self.directory / "capture"
        capture_directory.mkdir()
        self.artifacts = self.directory / "artifacts"
        self.profile = self.directory / "profile"
        self.profile.mkdir()
        (self.profile / ".awscred").touch()
        (self.profile / "ocm-token").write_text("fixture-not-a-real-token", encoding="utf-8")
        (self.directory / "cluster-id").write_text("fixture-cluster", encoding="utf-8")
        self.stdout = self.directory / "stdout"
        self.stderr = self.directory / "stderr"
        self.stdout.write_text("VERSION  NOTES\n4.20.1  recommended\n", encoding="utf-8")
        self.stderr.write_text("", encoding="utf-8")
        self.calls = self.directory / "calls"
        self.environment = {
            **os.environ,
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "SHARED_DIR": str(self.directory),
            "ARTIFACT_DIR": str(self.artifacts),
            "CLUSTER_PROFILE_DIR": str(self.profile),
            "LEASED_RESOURCE": "fixture-region",
            "OCM_LOGIN_ENV": "fixture",
            "HOSTED_CP": "false",
            "UPGRADED_TO_VERSION": "4.20",
            "UPGRADE_CHANNEL": "candidate-4.20",
            "TEST_STDOUT": str(self.stdout),
            "TEST_STDERR": str(self.stderr),
            "TEST_CALLS": str(self.calls),
            "TEST_LIST_STATUS": "0",
            "TMPDIR": str(capture_directory),
        }
        self.write_executable("rosa", '''#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$1 $2" in
  'login --env'|'edit cluster') exit 0 ;;
  'describe cluster') printf '{"openshift_version":"4.19.9"}' ;;
  'list upgrade') cat "$TEST_STDOUT"; cat "$TEST_STDERR" >&2; exit "$TEST_LIST_STATUS" ;;
  'list gates') exit 73 ;;
  'upgrade cluster')
    if [[ " $* " == *' --dry-run '* ]]; then exit 0; fi
    exit 73 ;;
  *) exit 99 ;;
esac
''')
        self.write_executable("oc", "#!/bin/bash\nexit 99\n")
        self.write_executable("sleep", "#!/bin/bash\nexit 0\n")

    def write_executable(self, name, content):
        path = self.directory / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def run_step(self):
        result = subprocess.run(
            ["bash", str(STEP)], env=self.environment,
            capture_output=True, text=True, check=False,
        )
        if not (self.directory / "rm").exists():
            self.assertEqual(list(Path(self.environment["TMPDIR"]).iterdir()), [])
        return result

    def assert_query_count(self, expected):
        calls = self.calls.read_text(encoding="utf-8").splitlines() if self.calls.exists() else []
        self.assertEqual(sum(line.startswith("list upgrade ") for line in calls), expected)
        return calls

    def test_cli_failure_preserves_status_and_ignores_recommended_stdout(self):
        self.environment["TEST_LIST_STATUS"] = "42"
        self.stderr.write_text("unauthorized: fixture-private-value\n", encoding="utf-8")
        result = self.run_step()
        self.assertEqual(result.returncode, 42, result.stderr)
        calls = self.assert_query_count(1)
        self.assertFalse(any(line.startswith("upgrade cluster ") for line in calls))
        diagnostic = (self.artifacts / "upgrade-discovery.txt").read_text(encoding="utf-8")
        self.assertIn("exit status: 42", diagnostic)
        self.assertIn("unauthorized", diagnostic)
        self.assertIn("4.20.1 recommended", diagnostic)
        self.assertNotIn("fixture-private-value", diagnostic)
        self.assertNotIn("fixture-cluster", diagnostic)

    def test_no_matching_recommendation_retains_bounded_safe_diagnostics(self):
        self.stdout.write_text(
            "VERSION  NOTES\n4.19.9  recommended\n"
            + "4.20.1\n" * 100
            + "There are no available upgrades for fixture-cluster\n"
            + "fixture-private-value\n", encoding="utf-8",
        )
        result = self.run_step()
        self.assertEqual(result.returncode, 1, result.stderr)
        calls = self.assert_query_count(1)
        self.assertFalse(any(line.startswith("upgrade cluster ") for line in calls))
        diagnostic = (self.artifacts / "upgrade-discovery.txt").read_text(encoding="utf-8")
        self.assertIn("exit status: 0", diagnostic)
        self.assertIn("no available upgrades", diagnostic)
        self.assertIn("4.19.9 recommended", diagnostic)
        self.assertEqual(diagnostic.count("4.20.1"), 19)
        self.assertLess(len(diagnostic), 2048)
        self.assertNotIn("fixture-private-value", diagnostic)
        self.assertNotIn("fixture-cluster", diagnostic)

    def test_recommendation_reaches_gates_and_metrics_schema(self):
        self.stderr.write_text("4.20.99 recommended\n", encoding="utf-8")
        result = self.run_step()
        self.assertEqual(result.returncode, 73, result.stderr)
        calls = self.assert_query_count(1)
        self.assertIn("list gates -c fixture-cluster --version 4.20.1 -o json", calls)
        self.assertIn("upgrade cluster -y -m auto --version 4.20.1 -c fixture-cluster --dry-run", calls)
        self.assertFalse(any(line.endswith("-c fixture-cluster") and line.startswith("upgrade cluster ") for line in calls))
        self.assertFalse((self.artifacts / "upgrade-discovery.txt").exists())
        metrics = json.loads((self.artifacts / "upgrade-metrics.json").read_text(encoding="utf-8"))
        self.assertEqual(set(metrics), {
            "start", "end", "start_epoch", "end_epoch", "duration_seconds", "from_version", "to_version",
        })
        self.assertRegex(metrics["start"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertRegex(metrics["end"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        for key in ("start_epoch", "end_epoch", "duration_seconds"):
            self.assertIsInstance(metrics[key], int)
        self.assertEqual(metrics["duration_seconds"], metrics["end_epoch"] - metrics["start_epoch"])
        self.assertEqual(metrics["from_version"], "4.19.9")
        self.assertEqual(metrics["to_version"], "4.20.1")
        self.assertIn("Wrote upgrade-metrics.json", result.stdout)

    def test_prerelease_diagnostics_reject_sensitive_text_and_preserve_bounds(self):
        boundary_version = "4.20.0-rc." + "1" * 22
        rejected_versions = [
            boundary_version + "1", "4.20.0-rc.", "4.20.0-ec.-3", "4.20.0-rc.2.private",
            "4.20.0-ec.3/private", "4.20.0-rc.2+private", "4.20.0-fixture-private-value",
            "prefix4.20.0-rc.2", "https://fixture-private-value/4.20.0-rc.2",
        ]
        self.stdout.write_text(
            "4.20.0-rc.2  recommended fixture-private-value\n4.20.0-ec.3\n"
            + boundary_version + "\n" + "\n".join(rejected_versions) + "\n"
            + "\n".join(f"4.20.{index}" for index in range(25)) + "\n",
            encoding="utf-8",
        )
        self.stderr.write_text("4.20.0-ec.99 recommended fixture-private-value\n", encoding="utf-8")
        self.environment["TEST_LIST_STATUS"] = "42"
        result = self.run_step()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_query_count(1)
        diagnostic = (self.artifacts / "upgrade-discovery.txt").read_text(encoding="utf-8")
        rows = diagnostic.split("recommendation markers only):\n", 1)[1].splitlines()
        self.assertEqual(len(rows), 20)
        self.assertEqual(rows[0], "4.20.0-rc.2 recommended")
        self.assertEqual(rows[1].split(), ["4.20.0-ec.3"])
        self.assertEqual(rows[2].split(), [boundary_version])
        self.assertEqual(rows[-1].split(), ["4.20.16"])
        self.assertTrue(all(len(row.split()[0]) <= 32 for row in rows))
        for rejected_version in rejected_versions:
            self.assertNotIn(rejected_version, [row.split()[0] for row in rows])
        self.assertNotIn("fixture-private-value", diagnostic)
        self.assertNotIn("4.20.0-ec.99", diagnostic)
        self.assertLess(len(diagnostic), 2048)

    def test_prerelease_recommendation_selection_is_unchanged(self):
        self.stdout.write_text("VERSION  NOTES\n4.20.0-rc.2  recommended\n", encoding="utf-8")
        result = self.run_step()
        self.assertEqual(result.returncode, 73, result.stderr)
        calls = self.assert_query_count(1)
        self.assertIn("list gates -c fixture-cluster --version 4.20.0-rc.2 -o json", calls)
        metrics = json.loads((self.artifacts / "upgrade-metrics.json").read_text(encoding="utf-8"))
        self.assertEqual(metrics["to_version"], "4.20.0-rc.2")
        self.assertFalse((self.artifacts / "upgrade-discovery.txt").exists())

    def test_metrics_writer_failure_is_best_effort_without_success_log(self):
        real_jq = shutil.which("jq")
        self.assertIsNotNone(real_jq)
        self.write_executable("jq", f'''#!/bin/bash
if [[ "$1" == '-n' ]]; then exit 9; fi
exec '{real_jq}' "$@"
''')
        self.environment["TEST_LIST_STATUS"] = "42"
        result = self.run_step()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn("Wrote upgrade-metrics.json", result.stdout)
        self.assertIn("WARNING: failed to write upgrade-metrics.json", result.stdout)

    def test_early_exit_does_not_write_metrics(self):
        (self.profile / "ocm-token").unlink()
        result = self.run_step()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_query_count(0)
        self.assertFalse((self.artifacts / "upgrade-metrics.json").exists())
        self.assertNotIn("Wrote upgrade-metrics.json", result.stdout)

    def test_artifact_failure_does_not_mask_cli_status(self):
        self.artifacts.touch()
        self.environment["TEST_LIST_STATUS"] = "42"
        result = self.run_step()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_query_count(1)
        self.assertNotIn("Wrote upgrade-metrics.json", result.stdout)

    def test_artifact_file_write_failures_do_not_mask_cli_status(self):
        self.artifacts.mkdir()
        (self.artifacts / "upgrade-discovery.txt").mkdir()
        (self.artifacts / "upgrade-metrics.json").mkdir()
        self.environment["TEST_LIST_STATUS"] = "42"
        result = self.run_step()
        self.assertEqual(result.returncode, 42, result.stderr)
        calls = self.assert_query_count(1)
        self.assertFalse(any(line.startswith("upgrade cluster ") for line in calls))
        self.assertIn("WARNING: failed to write upgrade-discovery.txt", result.stdout)
        self.assertIn("WARNING: failed to write upgrade-metrics.json", result.stdout)
        self.assertNotIn("Wrote upgrade-metrics.json", result.stdout)

    def test_cleanup_failure_does_not_mask_cli_status(self):
        self.write_executable("rm", "#!/bin/bash\nexit 9\n")
        self.environment["TEST_LIST_STATUS"] = "42"
        result = self.run_step()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_query_count(1)
        self.assertIn("WARNING: failed to remove private upgrade discovery output", result.stdout)


if __name__ == "__main__":
    unittest.main()
