#!/usr/bin/env python3

import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / (
    "ci-operator/step-registry/etcd-encryption/vault-install/"
    "etcd-encryption-vault-install-commands.sh"
)


def function_source(name):
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}", SCRIPT.read_text(), re.MULTILINE | re.DOTALL)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group()


class VaultPodWaitTest(unittest.TestCase):
    def run_wait(self, states, previous_uid="", diagnostics_fail=False, sleep_advance=""):
        with tempfile.TemporaryDirectory() as directory:
            count_path = Path(directory) / "count"
            count_path.write_text("0")
            shell = "set -euo pipefail\n" + function_source("wait_for_vault_pod_running")
            shell += "\n" + function_source("describe_vault_workload")
            shell += "\nstates=(" + " ".join(map(shlex.quote, states)) + ")\n"
            shell += f"count_path={shlex.quote(str(count_path))}\n"
            shell += f"diagnostics_fail={str(diagnostics_fail).lower()}\n"
            shell += f"sleep_advance={shlex.quote(sleep_advance)}\n"
            shell += r'''
unset SECONDS
SECONDS=0
sleep() {
  echo "sleep: $1" >&2
  SECONDS=$((SECONDS + ${sleep_advance:-$1}))
}
oc() {
  if [[ "$*" == *--ignore-not-found* ]]; then
    [[ "$*" == *--request-timeout=*s* ]]
    echo "probe: $*" >&2
    local count state
    count=$(cat "${count_path}")
    state="${states[count]-${states[-1]}}"
    echo "$((count + 1))" > "${count_path}"
    if [[ "${state}" == error ]]; then
      echo "Error from server (Forbidden): pods is forbidden" >&2
      return 1
    fi
    printf '%s' "${state}"
  else
    echo "diagnostic: $*" >&2
    if [[ "$*" == *'.spec.initContainers'* ]]; then echo 'init vault'; fi
    if ${diagnostics_fail} && [[ "$*" != *'.spec.initContainers'* ]]; then return 1; fi
  fi
}
'''
            shell += f'wait_for_vault_pod_running vault-kms vault-0 {shlex.quote(previous_uid)}\n'
            result = subprocess.run(
                ["bash", "-c", shell], capture_output=True, text=True, check=False, timeout=10
            )
            return result, int(count_path.read_text())

    def test_running_without_readiness(self):
        result, count = self.run_wait(["new||Running"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 1)

    def test_terminating_scheduled_pod_missing_gap_and_replacement(self):
        result, count = self.run_wait(
            ["old|2026-10-01T00:00:00Z|Running", "", "new||Pending", "new||Running"], "old"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 4)

    def test_old_running_uid_before_controller_starts_replacement(self):
        result, count = self.run_wait(["old||Running", "new||Running"], "old")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 2)

    def test_terminating_running_pod_without_previous_uid(self):
        result, count = self.run_wait(["old|2026-10-01T00:00:00Z|Running", "new||Running"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 2)

    def test_initial_missing_pod(self):
        result, count = self.run_wait(["", "new||Running"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 2)

    def test_timeout_is_shared_across_replacements_and_missing_pods(self):
        result, count = self.run_wait(["old||Running", "", "new||Pending"], "old")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(count, 120)
        self.assertIn("timeout: 10m", result.stdout)
        self.assertIn("new||Pending", result.stdout)
        self.assertIn("get statefulset,pod,pvc", result.stderr)
        self.assertIn("--- logs: vault ---", result.stdout)
        self.assertIn("get events", result.stderr)

    def test_missing_pod_times_out(self):
        result, count = self.run_wait([""])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(count, 120)

    def test_api_failure_is_not_treated_as_missing(self):
        result, count = self.run_wait(["error"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(count, 1)
        self.assertIn("Forbidden", result.stderr)
        self.assertIn("Unable to get Vault pod", result.stdout)
        self.assertIn("get statefulset,pod,pvc", result.stderr)

    def test_request_and_sleep_budgets_shrink_near_deadline(self):
        result, count = self.run_wait(["new||Pending"], sleep_advance="599")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(count, 2)
        self.assertIn("--request-timeout=10s", result.stderr)
        self.assertIn("--request-timeout=1s", result.stderr)
        self.assertIn("sleep: 1", result.stderr)

    def test_diagnostic_failures_preserve_failure(self):
        result, count = self.run_wait(["error"], diagnostics_fail=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(count, 1)
        self.assertIn("describe pod/vault-0", result.stderr)
        self.assertIn("get events", result.stderr)
        self.assertIn("logs pod/vault-0 -n vault-kms -c vault", result.stderr)

    def test_previous_uid_reaches_wait_for_both_storage_modes(self):
        for storage_class in ("", "vault-local-storage"):
            with self.subTest(storage_class=storage_class):
                shell = "set -euo pipefail\n" + function_source("wait_for_vault_data_volume")
                shell += '''
wait_until() { :; }
wait_for_vault_data_pvc_bound() { :; }
oc() { :; }
wait_for_vault_pod_running() { printf 'wait: %s %s %s\\n' "$@"; }
'''
                shell += f"wait_for_vault_data_volume ns vault-0 {shlex.quote(storage_class)} old\n"
                result = subprocess.run(
                    ["bash", "-c", shell], capture_output=True, text=True, check=False, timeout=10
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("wait: ns vault-0 old", result.stdout)

    def test_install_captures_existing_uid_before_restart(self):
        for capture_fails in (False, True):
            with self.subTest(capture_fails=capture_fails), tempfile.TemporaryDirectory() as directory:
                count_path = Path(directory) / "count"
                count_path.write_text("0")
                install = function_source("install_vault")
                start = install.index('  wait_for_vault_pod_created "${namespace}" "${pod_name}"')
                end = install.index('  echo "Initializing and unsealing Vault..."')
                shell = "set -euo pipefail\n" + function_source("wait_for_vault_pod_created")
                shell += f"\ncount_path={shlex.quote(str(count_path))}\n"
                shell += f"capture_fails={str(capture_fails).lower()}\n"
                shell += r'''
sleep() { :; }
oc() {
  if [[ "$*" == *'jsonpath={.metadata.uid}'* ]]; then
    echo capture >&2
    if ${capture_fails}; then return 1; fi
    echo old
  elif [[ "$*" == 'get pod/vault-0 -n ns' ]]; then
    local count
    count=$(cat "${count_path}")
    echo "$((count + 1))" > "${count_path}"
    if (( count == 0 )); then return 1; fi
  elif [[ "$*" == 'get events'* ]]; then
    return 0
  fi
}
restart_vault_statefulset() { echo restart >&2; }
wait_for_vault_data_volume() { echo "forward: $*" >&2; }
install_restart() {
  local namespace=ns pod_name=vault-0 release_name=vault vault_storage_class=local
'''
                shell += install[start:end] + "\n}\ninstall_restart\n"
                result = subprocess.run(
                    ["bash", "-c", shell], capture_output=True, text=True, check=False, timeout=10
                )
                self.assertEqual(int(count_path.read_text()), 2)
                if capture_fails:
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertNotIn("restart", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr.splitlines(), ["capture", "restart", "forward: ns vault-0 local old"])


if __name__ == "__main__":
    unittest.main()
