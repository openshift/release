#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ci-operator/step-registry/rosa/cluster/deprovision/rosa-cluster-deprovision-commands.sh"


class DeprovisionTest(unittest.TestCase):
    def run_case(self, scenario, expected=1, sts="true"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("bin", "shared", "profile", "artifacts"):
                (root / name).mkdir()
            (root / "profile/.awscred").touch()
            (root / "profile/ocm-token").write_text("mock-token")
            (root / "shared/cluster-id").write_text("mock-cluster")
            (root / "shared/cluster-config").write_text('{"timers":{}}')
            mocks = {
                "rosa": '''#!/bin/bash
echo "$*" >> "$MOCK_ROOT/calls"
case "$1 $2" in
  "login --env") exit 0 ;;
  "delete cluster") [[ "$SCENARIO" != delete-failure ]]; exit ;;
  "delete operator-roles"|"delete oidc-provider") exit 0 ;;
  "describe cluster")
    if [[ ! -f "$MOCK_ROOT/polled" ]]; then
      touch "$MOCK_ROOT/polled"
      case "$SCENARIO" in
        success) exit 0 ;;
        timeout) echo '{"state":"uninstalling"}' ;;
        *) echo '{"state":"error"}' ;;
      esac
    else
      case "$SCENARIO" in
        command-failure) echo 'SENSITIVE-MARKER' >&2; exit 7 ;;
        hang) sleep 60 ;;
        stubborn-hang) trap '' TERM; sleep 60 ;;
        malformed) echo 'SENSITIVE-MARKER not json' ;;
        multiple) echo '{} {}' ;;
        oversized) printf '{"state":"error","description":"'; head -c 65536 /dev/zero | tr '\\0' a; printf '"}' ;;
        error) echo '{"state":"error"}' ;;
        read-only) echo '{"state":"error","status":{"configuration_mode":"read_only","description":"SENSITIVE-MARKER"},"delete_protection":{"enabled":false}}' ;;
        protected) echo '{"state":"error","status":{"configuration_mode":"full"},"delete_protection":{"enabled":true}}' ;;
        unrestricted) echo '{"state":"error","status":{"configuration_mode":"full"},"delete_protection":{"enabled":false}}' ;;
        invalid-fields) echo '{"state":"error","status":{"configuration_mode":"SENSITIVE-MARKER"},"delete_protection":{"enabled":"SENSITIVE-MARKER"}}' ;;
        invalid-containers) echo '{"state":"error","status":"SENSITIVE-MARKER","delete_protection":[true]}' ;;
        injected-state) echo '{"state":"SENSITIVE-MARKER"}' ;;
        wrong-type) echo '[{"state":"error"}]' ;;
        *) echo '{"state":"uninstalling","id":"SENSITIVE-MARKER","status":{"description":"SENSITIVE-MARKER"},"aws":{"account_id":"SENSITIVE-MARKER"},"credentials":"SENSITIVE-MARKER"}' ;;
      esac
    fi ;;
  *) exit 99 ;;
esac
''',
                "timeout": '''#!/bin/bash
[[ "$*" == --signal=TERM\\ --kill-after=2s\\ 15s\\ rosa\\ describe\\ cluster* ]] || exit 98
shift 3
exec /usr/bin/timeout --signal=TERM --kill-after=0.1s 0.1s "$@"
''',
                "date": "#!/bin/bash\necho 100\n",
                "sleep": "#!/bin/bash\n[[ $1 == 60 ]] && exec /bin/sleep 60\nexit 0\n",
            }
            for name, contents in mocks.items():
                executable = root / "bin" / name
                executable.write_text(contents)
                executable.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                MOCK_ROOT=str(root), SCENARIO=scenario,
                SHARED_DIR=str(root / "shared"), CLUSTER_PROFILE_DIR=str(root / "profile"),
                ARTIFACT_DIR=str(root / "artifacts"), LEASED_RESOURCE="mock-region",
                OCM_LOGIN_ENV="mock-env", DESTROY_TIMEOUT="0" if scenario == "timeout" else "3600",
                STS=sts,
            )
            if scenario == "artifact-failure":
                environment["ARTIFACT_DIR"] = str(root / "missing")
            command = ["bash", "-x", str(SCRIPT)] if scenario == "traced" else ["bash", str(SCRIPT)]
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=5, check=False)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertNotIn("SENSITIVE-MARKER", result.stdout + result.stderr)
            calls = (root / "calls").read_text()
            artifact = root / "artifacts/rosa-deprovision-diagnostics.json"
            if scenario in ("success", "delete-failure"):
                self.assertFalse(artifact.exists())
                self.assertEqual(calls.count("describe cluster"), int(scenario == "success"))
            else:
                self.assertEqual(calls.count("describe cluster"), 2)
                if scenario != "artifact-failure":
                    diagnostics = json.loads(artifact.read_text())
                    self.assertEqual(set(diagnostics), {"reason", "describe_result", "state", "configuration_mode", "delete_protection_enabled"})
                    self.assertEqual(diagnostics["reason"], "timeout" if scenario == "timeout" else "error")
                    if scenario in ("command-failure", "hang", "stubborn-hang", "malformed", "multiple", "oversized", "wrong-type"):
                        self.assertEqual(diagnostics["describe_result"], "unavailable")
                        self.assertEqual(diagnostics["state"], "unavailable")
                        self.assertEqual(diagnostics["configuration_mode"], "unavailable")
                        self.assertIsNone(diagnostics["delete_protection_enabled"])
                    else:
                        self.assertEqual(diagnostics["describe_result"], "available")
                        field_scenarios = ("read-only", "protected", "unrestricted", "invalid-fields", "invalid-containers")
                        expected_state = "error" if scenario == "error" or scenario in field_scenarios else "uninstalling"
                        self.assertEqual(diagnostics["state"], "withheld" if scenario == "injected-state" else expected_state)
                        expected_mode = {"read-only": "read_only", "protected": "full", "unrestricted": "full"}.get(scenario, "withheld")
                        self.assertEqual(diagnostics["configuration_mode"], expected_mode)
                        expected_protection = {"read-only": False, "protected": True, "unrestricted": False}.get(scenario)
                        self.assertIs(diagnostics["delete_protection_enabled"], expected_protection)
            cleanup = scenario == "success" and sts == "true"
            self.assertEqual("delete operator-roles" in calls, cleanup)
            self.assertEqual("delete oidc-provider" in calls, cleanup)
            config = json.loads((root / "shared/cluster-config").read_text())
            self.assertEqual("destroy" in config["timers"], scenario == "success")
            self.assertEqual("sts_destroy" in config["timers"], cleanup)

    def test_failure_paths(self):
        for scenario in ("timeout", "error", "command-failure", "hang", "stubborn-hang", "malformed", "multiple", "oversized", "injected-state", "wrong-type", "artifact-failure", "delete-failure", "traced"):
            with self.subTest(scenario=scenario):
                self.run_case(scenario)

    def test_success(self):
        for sts in ("true", "false"):
            with self.subTest(sts=sts):
                self.run_case("success", expected=0, sts=sts)

    def test_deletion_controls(self):
        for scenario in ("read-only", "protected", "unrestricted", "invalid-fields", "invalid-containers"):
            with self.subTest(scenario=scenario):
                self.run_case(scenario)


if __name__ == "__main__":
    unittest.main(verbosity=2)
