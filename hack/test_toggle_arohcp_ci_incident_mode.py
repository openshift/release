#!/usr/bin/env python3
"""Exercise the incident toggle CLI against isolated configuration files."""

from contextlib import ExitStack
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


SCRIPT = Path(__file__).with_name("toggle_arohcp_ci_incident_mode.py").resolve()
PIPELINE_PATH = Path("core-services/pipeline-controller/config.yaml")
RETESTER_PATH = Path("core-services/retester/_config.yaml")
PIPELINE = """orgs:
- org: Azure
  repos:
    - name: ARO-HCP
      branches:
        - main
      mode:
        trigger: {trigger}
    - name: another-repository
      mode:
        trigger: manual
- org: another-org
  repos:
    - name: another-project
      mode:
        trigger: auto
"""
RETESTER = """retester:
  max_retests_for_sha: 3
  orgs:
    Azure:
      enabled: true
      repos:
        ARO-HCP:
          enabled: {enabled}
        another-repository:
          enabled: true
    another-org:
      enabled: true
"""


class IncidentModeTest(unittest.TestCase):
    def setUp(self):
        resources = ExitStack()
        self.addCleanup(resources.close)
        self.root = Path(resources.enter_context(tempfile.TemporaryDirectory()))
        self.pipeline = self.root / PIPELINE_PATH
        self.retester = self.root / RETESTER_PATH
        self.pipeline.parent.mkdir(parents=True)
        self.retester.parent.mkdir(parents=True)

    def write_state(self, trigger="auto", enabled="true"):
        self.pipeline.write_text(PIPELINE.format(trigger=trigger), encoding="utf-8")
        self.retester.write_text(RETESTER.format(enabled=enabled), encoding="utf-8")

    def snapshot(self):
        return self.pipeline.read_bytes(), self.retester.read_bytes()

    def run_toggle(self, action):
        return subprocess.run(
            [sys.executable, str(SCRIPT), action], cwd=self.root,
            capture_output=True, text=True, check=False,
        )

    def assert_rejected_without_writes(self, action):
        before = self.snapshot()
        result = self.run_toggle(action)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_round_trip_preserves_unrelated_settings(self):
        self.write_state()
        before = self.snapshot()
        result = self.run_toggle("enable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.pipeline.read_text(), PIPELINE.format(trigger="manual"))
        self.assertEqual(self.retester.read_text(), RETESTER.format(enabled="false"))
        result = self.run_toggle("disable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_checked_in_configs_round_trip(self):
        repository = SCRIPT.parent.parent
        self.pipeline.write_bytes((repository / PIPELINE_PATH).read_bytes())
        self.retester.write_bytes((repository / RETESTER_PATH).read_bytes())
        before = self.snapshot()
        expected_pipeline = yaml.safe_load(before[0])
        expected_retester = yaml.safe_load(before[1])
        azure = next(org for org in expected_pipeline["orgs"] if org["org"] == "Azure")
        target = next(repo for repo in azure["repos"] if repo["name"] == "ARO-HCP")
        mode = target["mode"]["trigger"]
        self.assertIn(mode, ("auto", "manual"))
        actions = ("enable", "disable") if mode == "auto" else ("disable", "enable")
        target["mode"]["trigger"] = "manual" if mode == "auto" else "auto"
        expected_retester["retester"]["orgs"]["Azure"]["repos"]["ARO-HCP"]["enabled"] = mode != "auto"
        result = self.run_toggle(actions[0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(yaml.safe_load(self.pipeline.read_bytes()), expected_pipeline)
        self.assertEqual(yaml.safe_load(self.retester.read_bytes()), expected_retester)
        result = self.run_toggle(actions[1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_repeated_and_mixed_states_are_rejected(self):
        for action, trigger, enabled in (
            ("enable", "manual", "false"),
            ("disable", "auto", "true"),
            ("enable", "manual", "true"),
            ("enable", "auto", "false"),
            ("disable", "manual", "true"),
            ("disable", "auto", "false"),
        ):
            with self.subTest(action=action, trigger=trigger, enabled=enabled):
                self.write_state(trigger, enabled)
                self.assert_rejected_without_writes(action)

    def test_ambiguous_missing_and_reformatted_targets_are_rejected(self):
        mutations = (
            ("duplicate pipeline repo", "pipeline", "    - name: another-repository\n",
             '    - name: "ARO-HCP"\n      mode:\n        trigger: manual\n'),
            ("duplicate pipeline org", "pipeline", "- org: another-org\n",
             '- org: "Azure"\n'),
            ("missing pipeline repo", "pipeline", "name: ARO-HCP", "name: missing"),
            ("missing pipeline org", "pipeline", "org: Azure", "org: missing"),
            ("duplicate pipeline mode", "pipeline", "        trigger: auto\n",
             "        trigger: auto\n        trigger: manual\n"),
            ("duplicate retester repo", "retester", "        another-repository:\n",
             '        "ARO-HCP":\n'),
            ("duplicate retester org", "retester", "    another-org:\n",
             '    "Azure":\n'),
            ("missing retester repo", "retester", "        ARO-HCP:\n", "        missing:\n"),
            ("missing retester org", "retester", "    Azure:\n", "    missing:\n"),
            ("duplicate retester state", "retester", "          enabled: true\n",
             "          enabled: true\n          enabled: false\n"),
            ("pipeline formatting drift", "pipeline", "org: Azure", 'org: "Azure"'),
            ("retester formatting drift", "retester", "        ARO-HCP:\n", '        "ARO-HCP":\n'),
            ("additional pipeline branch", "pipeline", "        - main\n",
             "        - main\n        - release\n"),
        )
        for action, trigger, enabled in (("enable", "auto", "true"), ("disable", "manual", "false")):
            for name, target, old, new in mutations:
                with self.subTest(action=action, mutation=name):
                    self.write_state(trigger, enabled)
                    # Apply state-dependent mutations in either transition direction.
                    if name == "duplicate pipeline mode":
                        old = f"        trigger: {trigger}\n"
                        new = old + f"        trigger: {'manual' if trigger == 'auto' else 'auto'}\n"
                    elif name == "duplicate retester state":
                        old = f"          enabled: {enabled}\n"
                        new = old + f"          enabled: {'false' if enabled == 'true' else 'true'}\n"
                    path = getattr(self, target)
                    contents = path.read_text(encoding="utf-8")
                    self.assertIn(old, contents)
                    path.write_text(contents.replace(old, new, 1), encoding="utf-8")
                    self.assert_rejected_without_writes(action)


if __name__ == "__main__":
    unittest.main()
