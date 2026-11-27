#!/usr/bin/env python3
"""Synthetic tests for the Secrets Store CSI Azure API diagnostic rehearsal.

The step scripts run against fake az, curl, openssl, oc, git and sleep
binaries. The fixtures feed inert sentinel strings (never credential values)
through every sensitive input path: the service principal file, installer
metadata, kubeconfig, kubeadmin-password file, Azure CLI responses and error
text, and serial console text. The tests assert that none of the sentinels,
identifiers, addresses or hostnames reach public output (the artifact
directory, stdout or stderr) while collection continues through a simulated
API outage.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DIAG = ROOT / "ci-operator/step-registry/openshift/e2e/azure/csi/secrets-store/api-diag"
OBSERVER = DIAG / "observer/openshift-e2e-azure-csi-secrets-store-api-diag-observer-commands.sh"
PRE_ROLLOUT = DIAG / "pre-rollout/openshift-e2e-azure-csi-secrets-store-api-diag-pre-rollout-commands.sh"
GUARD = DIAG / "revision-guard/openshift-e2e-azure-csi-secrets-store-api-diag-revision-guard-commands.sh"
CONFIG_DIR = ROOT / "ci-operator/config/openshift/secrets-store-csi-driver-operator"
MAIN_CONFIG = CONFIG_DIR / "openshift-secrets-store-csi-driver-operator-main.yaml"
VARIANT_CONFIG = CONFIG_DIR / "openshift-secrets-store-csi-driver-operator-main__azure-api-diag.yaml"
WORKFLOW = (ROOT / "ci-operator/step-registry/openshift/e2e/azure/csi/secrets-store/"
            "openshift-e2e-azure-csi-secrets-store-workflow.yaml")
TARGET_REVISION = "e1bdf0d5a6a617638c0c47b4440ac1543c4b034f"
# ci-operator runs step and observer commands as `/bin/bash -c PREFIX+commands`
# (ci-tools pkg/steps/multi_stage: CommandPrefix), so tests do the same.
CI_OPERATOR_COMMAND_PREFIX = "#!/bin/bash\nset -eu\n"

# Inert test data only. Identifiers use patterned placeholder GUIDs, example
# domains, and RFC 1918 or documentation (RFC 5737) addresses. Values for
# sensitive input fields are plain sentinel words that only mark where data
# came from, so the assertions can detect them in public output.
CLIENT_ID = "11111111-2222-3333-4444-555555555555"
SP_FIELD_SENTINEL = "inert-sentinel-service-principal-field"
TENANT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SUBSCRIPTION_ID = "99999999-8888-7777-6666-555555555555"
INFRA_ID = "ci-op-fixture-abcde-x7k2q"
CLUSTER_NAME = "ci-op-fixture-abcde"
API_HOST = "api.ci-op-fixture-abcde.fixture.example.com"
PUBLIC_IP = "203.0.113.10"
MASTER_IPS = ["10.0.0.5", "10.0.0.6", "10.0.0.7"]
WORKER_IP = "10.0.128.4"
SERIAL_TEXT_SENTINEL = "inert-sentinel-serial-console-text"
URL_MARKER_SENTINEL = "inert-sentinel-url-marker"
KUBECONFIG_USER_SENTINEL = "inert-sentinel-kubeconfig-user"
KUBEADMIN_FILE_SENTINEL = "inert-sentinel-kubeadmin-file"

FIXTURE_SENTINELS = [CLIENT_ID, SP_FIELD_SENTINEL, TENANT_ID, SUBSCRIPTION_ID, INFRA_ID, CLUSTER_NAME,
                     API_HOST, PUBLIC_IP, WORKER_IP, SERIAL_TEXT_SENTINEL, URL_MARKER_SENTINEL,
                     KUBECONFIG_USER_SENTINEL, KUBEADMIN_FILE_SENTINEL, "inert-sentinel", "fixture.example.com",
                     "example.invalid", "/subscriptions/"] + MASTER_IPS
GENERIC_LEAK = re.compile(r"([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                          r"|https?://|eyJ[A-Za-z0-9_-]{10,}")

FAKE_AZ = r'''#!/usr/bin/env python3
import json
import os
import sys

argv = sys.argv[1:]
state = os.environ["FAKE_STATE"]
with open(os.path.join(state, "az-calls"), "a", encoding="utf-8") as calls:
    calls.write(json.dumps(argv) + "\n")
fx = json.loads(os.environ["FAKE_FIXTURE"])
sub, infra = fx["subscription"], fx["infra"]
rg = f"/subscriptions/{sub}/resourceGroups/{infra}-rg/providers"


def opt(name):
    return argv[argv.index(name) + 1] if name in argv else ""


def samples_done():
    try:
        with open(os.path.join(state, "curl-count"), encoding="utf-8") as handle:
            return int(handle.read().strip() or 0)
    except FileNotFoundError:
        return 0


def leak_error(code):
    sys.stderr.write(f"ERROR: (AuthorizationFailed) client '{fx['client']}' field "
                     f"{fx['sp_field']} cannot read {rg}/x on {fx['host']} {fx['public_ip']}\n")
    sys.exit(code)


if argv[:1] == ["login"]:
    if os.environ.get("FAKE_AZ_LOGIN_FAIL"):
        sys.stderr.write(f"AADSTS7000215: invalid_client {fx['client']} field {fx['sp_field']}\n")
        sys.exit(1)
    print(json.dumps([{"id": sub, "tenantId": fx["tenant"], "user": {"name": fx["client"]}}]))
    sys.exit(0)
if argv[:1] == ["logout"]:
    sys.exit(0)
if argv[:3] == ["network", "lb", "list"]:
    def lb(name, public, rules):
        frontend = {"name": name + "-fe", "privateIPAddress": None if public else "10.0.0.100"}
        if public:
            frontend["publicIPAddress"] = {"id": rg + "/Microsoft.Network/publicIPAddresses/" + name + "-pip",
                                           "ipAddress": fx["public_ip"]}
        return {"id": rg + "/Microsoft.Network/loadBalancers/" + name, "name": name,
                "frontendIPConfigurations": [frontend],
                "probes": [{"name": "api-probe", "protocol": "Https", "port": 6443, "requestPath": "/readyz",
                            "intervalInSeconds": 5, "numberOfProbes": 2, "probeThreshold": 2},
                           {"name": "mcs-probe", "protocol": "Https", "port": 22623,
                            "requestPath": "/healthz?ref=" + fx["sp_field"], "intervalInSeconds": 5,
                            "numberOfProbes": 2}],
                "loadBalancingRules": [{"frontendPort": port, "backendPort": port,
                                        "probe": {"id": rg + "/lb/probes/" + probe}} for port, probe in rules]}
    print(json.dumps([lb(infra, True, [(6443, "api-probe"), (80, "api-probe")]),
                      lb(infra + "-internal", False, [(6443, "api-probe"), (22623, "mcs-probe")]),
                      {"id": rg + "/Microsoft.Network/loadBalancers/" + infra + "-outbound", "name": infra + "-outbound",
                       "frontendIPConfigurations": [], "probes": [], "loadBalancingRules": []}]))
    sys.exit(0)
if argv[:3] == ["network", "nic", "list"]:
    nics = [{"name": f"{infra}-master-{i}-nic",
             "virtualMachine": {"id": rg + f"/Microsoft.Compute/virtualMachines/{infra}-master-{i}"},
             "ipConfigurations": [{"privateIPAddress": ip}]} for i, ip in enumerate(fx["master_ips"])]
    nics.append({"name": "worker-nic",
                 "virtualMachine": {"id": rg + f"/Microsoft.Compute/virtualMachines/{infra}-worker-eastus1-abcde"},
                 "ipConfigurations": [{"privateIPAddress": fx["worker_ip"]}]})
    print(json.dumps(nics))
    sys.exit(0)
if argv[:2] == ["vm", "list"]:
    storage = "https://storage.example.invalid/" if os.environ.get("FAKE_AZ_USER_MANAGED") else None
    boot = {"diagnosticsProfile": {"bootDiagnostics": {"enabled": True, "storageUri": storage}}}
    print(json.dumps([{"name": f"{infra}-master-{i}", **boot} for i in range(3)] +
                     [{"name": f"{infra}-worker-eastus1-abcde", **boot}]))
    sys.exit(0)
if argv[:2] == ["vm", "get-instance-view"]:
    if os.environ.get("FAKE_AZ_ODD_STATE"):
        print(json.dumps(["ProvisioningState/" + fx["sp_field"], "PowerState/" + fx["host"]]))
        sys.exit(0)
    print(json.dumps(["ProvisioningState/succeeded", "PowerState/running"]))
    sys.exit(0)
if argv[:3] == ["vm", "boot-diagnostics", "get-boot-log"]:
    if os.environ.get("FAKE_AZ_FAIL_BOOTLOG"):
        leak_error(1)
    text = "\n".join(["[    0.000000] Linux version 5.14.0-570.el9.x86_64 (mockbuild@" + fx["host"] + ")",
                      f"{infra}-master-0 login: address {fx['master_ips'][0]} note {fx['serial_text']}",
                      "https://serial.example.invalid/console?ref=" + fx["url_marker"],
                      "systemd[1]: Failed to start fixture.service", "reboot: Restarting system"])
    print(json.dumps(text) if os.environ.get("FAKE_AZ_BOOTLOG_JSON") else text)
    sys.exit(0)
if argv[:3] == ["monitor", "metrics", "list"]:
    metric = opt("--metrics")
    if os.environ.get("FAKE_AZ_FAIL_METRICS") and metric == "DipAvailability":
        leak_error(1)
    if os.environ.get("FAKE_AZ_SLOW") and metric == "DipAvailability":
        import time
        time.sleep(float(os.environ["FAKE_AZ_SLOW"]))
    done = samples_done()
    outage_after = int(os.environ.get("FAKE_OUTAGE_AFTER", "1000000"))
    minutes = range(0, max(done, 1) + (3 if os.environ.get("FAKE_FINAL_EXTRA") else 0))

    def points(ip=None):
        mixed_down = os.environ.get("FAKE_MIXED") and ip == fx["master_ips"][1]
        return [{"timeStamp": f"2026-11-26T05:{40 + m:02d}:00Z",
                 "average": 0.0 if (m >= outage_after or (mixed_down and m >= 1)) else 100.0}
                for m in minutes]
    series = []
    if metric == "DipAvailability":
        for ip in fx["master_ips"]:
            for port in (6443, 22623):
                series.append({"metadatavalues": [{"name": {"value": "BackendIPAddress"}, "value": ip},
                                                  {"name": {"value": "BackendPort"}, "value": str(port)}],
                               "data": points(ip)})
        series.append({"metadatavalues": [{"name": {"value": "BackendIPAddress"}, "value": fx["worker_ip"]},
                                          {"name": {"value": "BackendPort"}, "value": "80"}], "data": points()})
    elif metric == "VipAvailability":
        for port in (6443, 22623, 80):
            series.append({"metadatavalues": [{"name": {"value": "FrontendIPAddress"}, "value": fx["public_ip"]},
                                              {"name": {"value": "FrontendPort"}, "value": str(port)}],
                           "data": points()})
    else:
        series.append({"metadatavalues": [], "data": [{"timeStamp": "2026-11-26T05:40:00Z", "average": 12.4}]})
    print(json.dumps({"value": [{"id": rg + "/metric", "name": {"value": metric}, "timeseries": series}]}))
    sys.exit(0)
sys.stderr.write("unexpected az call\n")
sys.exit(2)
'''

FAKE_CURL = r'''#!/bin/bash
count=$(( $(cat "${FAKE_STATE}/curl-count" 2>/dev/null || echo 0) + 1 ))
echo "${count}" > "${FAKE_STATE}/curl-count"
if (( count > ${FAKE_OUTAGE_AFTER:-1000000} )); then
  printf '000'
  exit 28
fi
printf '200'
'''

FAKE_OPENSSL = r'''#!/bin/bash
count=$(cat "${FAKE_STATE}/curl-count" 2>/dev/null || echo 0)
if [[ "$*" == *MLKEM* && -n "${FAKE_OPENSSL_NO_PQC:-}" ]]; then
  echo "Error with command: \"-groups SecP384r1MLKEM1024\"" >&2
  exit 1
fi
if (( count > ${FAKE_OUTAGE_AFTER:-1000000} )); then
  echo "40C7:error:8000006E:system library:BIO_connect:Connection timed out:connect:errno=110 ${FAKE_PUBLIC_IP}" >&2
  exit 1
fi
echo "subject=CN = ${FAKE_HOST}"
echo "New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384"
'''

FAKE_SLEEP = '''#!/bin/bash
echo "$*" >> "${FAKE_STATE}/sleep-calls"
exec /bin/sleep "${FAKE_SLEEP_SECONDS:-0}"
'''


class Harness(unittest.TestCase):
    """Shared fake-binary environment."""

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.state = self.directory / "state"
        self.shared = self.directory / "shared"
        self.artifacts = self.directory / "artifacts"
        self.tmp = self.directory / "tmp"
        for path in (self.directory / "bin", self.state, self.shared, self.artifacts, self.directory / "profile",
                     self.tmp):
            path.mkdir()
        fixture = {"subscription": SUBSCRIPTION_ID, "infra": INFRA_ID, "client": CLIENT_ID,
                   "sp_field": SP_FIELD_SENTINEL, "tenant": TENANT_ID, "host": API_HOST, "public_ip": PUBLIC_IP,
                   "master_ips": MASTER_IPS, "worker_ip": WORKER_IP, "url_marker": URL_MARKER_SENTINEL,
                   "serial_text": SERIAL_TEXT_SENTINEL}
        self.env = {
            "PATH": f"{self.directory / 'bin'}:{os.environ['PATH']}",
            "HOME": str(self.directory),
            "TMPDIR": str(self.tmp),
            "SHARED_DIR": str(self.shared),
            "ARTIFACT_DIR": str(self.artifacts),
            "CLUSTER_PROFILE_DIR": str(self.directory / "profile"),
            "AZURE_API_DIAG_SHARED_MOUNT": str(self.directory / "no-mount"),
            "FAKE_STATE": str(self.state),
            "FAKE_FIXTURE": json.dumps(fixture),
            "FAKE_HOST": API_HOST,
            "FAKE_PUBLIC_IP": PUBLIC_IP,
            "AZURE_API_DIAG_SAMPLE_INTERVAL": "1",
            "AZURE_API_DIAG_BOOTLOG_EVERY": "3",
        }
        self.write_executable("az", FAKE_AZ)
        self.write_executable("curl", FAKE_CURL)
        self.write_executable("openssl", FAKE_OPENSSL)
        self.write_executable("sleep", FAKE_SLEEP)

    def write_executable(self, name, content):
        path = self.directory / "bin" / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def write_identity(self):
        (self.directory / "profile" / "osServicePrincipal.json").write_text(json.dumps(
            {"clientId": CLIENT_ID, "clientSecret": SP_FIELD_SENTINEL, "tenantId": TENANT_ID,
             "subscriptionId": SUBSCRIPTION_ID}), encoding="utf-8")

    def write_cluster(self):
        (self.shared / "metadata.json").write_text(json.dumps(
            {"clusterName": CLUSTER_NAME, "clusterID": "12345678-1234-1234-1234-123456789abc",
             "infraID": INFRA_ID, "azure": {"region": "centralus", "resourceGroupName": ""}}), encoding="utf-8")
        (self.shared / "kubeconfig").write_text(
            f"apiVersion: v1\nclusters:\n- cluster:\n    server: https://{API_HOST}:6443\n  name: x\n"
            f"users:\n- name: admin\n  user:\n    username: {KUBECONFIG_USER_SENTINEL}\n", encoding="utf-8")
        (self.shared / "kubeadmin-password").write_text(KUBEADMIN_FILE_SENTINEL, encoding="utf-8")

    @staticmethod
    def command(script):
        return ["/bin/bash", "-c", CI_OPERATOR_COMMAND_PREFIX + script.read_text(encoding="utf-8")]

    def run_script(self, script, extra=None, timeout=120):
        env = {**self.env, **(extra or {})}
        return subprocess.run(self.command(script), env=env, capture_output=True, text=True,
                              timeout=timeout, check=False)

    def az_calls(self):
        path = self.state / "az-calls"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def public_text(self, *streams):
        texts = list(streams)
        for path in self.artifacts.rglob("*"):
            if path.is_file():
                texts.append(path.read_text(encoding="utf-8", errors="replace"))
        return "\n".join(texts)

    def assert_no_leak(self, *streams):
        text = self.public_text(*streams)
        for sentinel in FIXTURE_SENTINELS:
            self.assertNotIn(sentinel, text, f"fixture sentinel {sentinel!r} reached public output")
        match = GENERIC_LEAK.search(text)
        self.assertIsNone(match, f"identifier-like value {match.group(0) if match else ''!r} reached public output")

    def summary(self):
        return json.loads((self.artifacts / "azure-api-diag/summary.json").read_text(encoding="utf-8"))

    def samples(self):
        path = self.artifacts / "azure-api-diag/samples.jsonl"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def assert_workdir_removed(self):
        self.assertEqual([p.name for p in self.tmp.iterdir() if p.name.startswith("azure-api-diag")], [])


class ObserverTests(Harness):
    """Observer behaviour with fake Azure, TLS and HTTP clients."""

    READ_ONLY_AZ = [["login"], ["logout"], ["network", "lb", "list"], ["network", "nic", "list"], ["vm", "list"],
                    ["vm", "get-instance-view"], ["monitor", "metrics", "list"],
                    ["vm", "boot-diagnostics", "get-boot-log"]]

    def test_collection_continues_through_api_outage(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "6", "FAKE_OUTAGE_AFTER": "2"})
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary()
        self.assertEqual(summary["termination_reason"], "max_samples")
        self.assertEqual(summary["samples_taken"], 6)
        self.assertEqual(summary["api_probe"]["readyz"], {"http_200": 2, "timeout": 4})
        self.assertEqual(summary["api_probe"]["tls_classical"], {"handshake_ok": 2, "tcp_failed": 4})
        self.assertEqual([t["value"] for t in summary["api_probe"]["readyz_transitions"]], ["http_200", "timeout"])
        self.assertEqual(summary["lb_health_source"], "backfill")
        api = [s for s in summary["lb_health"] if s["metric"] == "DipAvailability" and s["port"] == 6443]
        self.assertEqual({(s["role"], s["idx"]) for s in api}, {("public", 0), ("internal", 0)})
        for series in api:
            self.assertEqual(series["backends"], ["master-0", "master-1", "master-2"])
            self.assertEqual(series["minutes_all_up"], 2)
            self.assertGreater(series["minutes_all_down"], 0)
            self.assertEqual(series["first_all_down"], "2026-11-26T05:42:00Z")
        self.assertFalse([s for s in summary["lb_health"] if s["port"] == 80], "non-API ports must be excluded")
        samples = [r for r in self.samples() if r["kind"] == "sample"]
        down = [lb for lb in samples[-1]["lb"] if lb["metric"] == "DipAvailability"]
        self.assertTrue(down and all(set(lb["backends"].values()) == {0} for lb in down))
        self.assertEqual(samples[-1]["vms"]["master-1"], {"power": "running", "provisioning": "succeeded"})
        serial = summary["serial_console_last"]["vms"]["master-0"]
        self.assertEqual((serial["boot_banner"], serial["systemd_unit_failed"], serial["reboot"]), (1, 1, 1))
        inventory = {lb["role"]: lb for lb in summary["lb_inventory"]}
        self.assertEqual(inventory["internal"]["probes"][0],
                         {"idx": 0, "protocol": "Https", "port": 6443, "request_path": "/readyz", "interval": 5,
                          "count": 2, "threshold": 2})
        self.assertEqual(inventory["internal"]["probes"][1]["request_path"], "other")
        self.assertEqual(summary["errors"], {})
        self.assertIn("sample 6: api readyz=timeout tls_classical=tcp_failed", result.stdout)
        self.assert_no_leak(result.stdout, result.stderr)
        self.assert_workdir_removed()

    def test_only_read_only_azure_operations(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "3"})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.az_calls()
        self.assertTrue(calls)
        for call in calls:
            self.assertTrue(any(call[:len(p)] == p for p in self.READ_ONLY_AZ), call)
            if call[0] not in ("login", "logout"):
                self.assertIn(SUBSCRIPTION_ID, call)
            if "--resource-group" in call:
                self.assertEqual(call[call.index("--resource-group") + 1], f"{INFRA_ID}-rg")
        self.assertIn(["logout"], calls)

    def test_errors_are_visible_without_leaking(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "3", "FAKE_AZ_FAIL_METRICS": "1",
                                            "FAKE_OPENSSL_NO_PQC": "1", "FAKE_AZ_ODD_STATE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary()
        self.assertEqual(summary["samples_taken"], 3)
        self.assertGreaterEqual(summary["errors"]["metric_DipAvailability"]["permission_denied"], 3)
        self.assertEqual(summary["api_probe"]["tls_pqc"], {"client_unsupported": 3})
        self.assertEqual(summary["api_probe"]["readyz"], {"http_200": 3})
        last = [r for r in self.samples() if r["kind"] == "sample"][-1]
        self.assertEqual(last["vms"]["master-0"], {"power": "other", "provisioning": "other"})
        self.assert_no_leak(result.stdout, result.stderr)

    def test_login_failure_still_probes_api(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "5", "FAKE_AZ_LOGIN_FAIL": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary()
        self.assertFalse(summary["azure_login"])
        self.assertEqual(summary["errors"]["az_login"], {"auth_failed": 2})
        self.assertEqual(summary["api_probe"]["readyz"], {"http_200": 5})
        self.assert_no_leak(result.stdout, result.stderr)

    def test_missing_identity_and_target(self):
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_TARGET_WAIT": "0"})
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary()
        self.assertEqual(summary["termination_reason"], "target_unresolved")
        self.assertFalse(summary["identity_loaded"])
        self.assertEqual(summary["errors"]["identity"], {"unavailable": 1})
        self.assertEqual(self.az_calls(), [])
        self.assert_workdir_removed()

    def test_sigterm_runs_final_collection_and_cleanup(self):
        self.write_identity()
        self.write_cluster()
        env = {**self.env, "AZURE_API_DIAG_MAX_SAMPLES": "1000", "FAKE_SLEEP_SECONDS": "30", "FAKE_OUTAGE_AFTER": "1"}
        with subprocess.Popen(self.command(OBSERVER), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            deadline = time.time() + 60
            summary_path = self.artifacts / "azure-api-diag/summary.json"
            while time.time() < deadline and not summary_path.exists():
                time.sleep(0.2)
            self.assertTrue(summary_path.exists(), "observer never published a summary")
            started = time.time()
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=60)
            self.assertLess(time.time() - started, 20, "SIGTERM must interrupt the sampling sleep")
        self.assertEqual(process.returncode, 0, stderr)
        summary = self.summary()
        self.assertEqual(summary["termination_reason"], "sigterm")
        self.assertEqual(summary["lb_health_source"], "backfill")
        self.assertTrue(any(r["kind"] == "backfill" for r in self.samples()))
        self.assert_no_leak(stdout, stderr)
        self.assert_workdir_removed()

    def test_sigterm_during_azure_call_stops_at_next_boundary(self):
        self.write_identity()
        self.write_cluster()
        env = {**self.env, "AZURE_API_DIAG_MAX_SAMPLES": "1000", "FAKE_AZ_SLOW": "3",
               "AZURE_API_DIAG_FINAL_BUDGET": "30"}
        with subprocess.Popen(self.command(OBSERVER), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            deadline = time.time() + 60
            calls = self.state / "az-calls"
            while time.time() < deadline and not (calls.exists() and "DipAvailability" in calls.read_text()):
                time.sleep(0.1)
            process.send_signal(signal.SIGTERM)
            started = time.time()
            stdout, stderr = process.communicate(timeout=90)
            self.assertLess(time.time() - started, 45, "in-flight sampling must stop at the next call boundary")
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(self.summary()["termination_reason"], "sigterm")
        self.assert_no_leak(stdout, stderr)
        self.assert_workdir_removed()

    def test_serial_console_failure_does_not_stop_collection(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "4", "AZURE_API_DIAG_BOOTLOG_EVERY": "1",
                                            "FAKE_AZ_FAIL_BOOTLOG": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary()
        self.assertEqual((summary["termination_reason"], summary["samples_taken"]), ("max_samples", 4))
        self.assertEqual(summary["lb_health_source"], "backfill")
        # 3 control-plane VMs x (4 samples + final collection)
        self.assertEqual(summary["errors"]["serial_console"], {"permission_denied": 15})
        self.assert_no_leak(result.stdout, result.stderr)

    def test_serial_console_every_sample_and_json_string_output(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "2", "AZURE_API_DIAG_BOOTLOG_EVERY": "1",
                                            "FAKE_AZ_BOOTLOG_JSON": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        serial = [r for r in self.samples() if r["kind"] == "serial_console"]
        self.assertEqual(len(serial), 3)
        counts = serial[-1]["vms"]["master-2"]
        self.assertEqual((counts["lines"], counts["boot_banner"], counts["reboot"]), (5, 1, 1))
        self.assert_no_leak(result.stdout, result.stderr)

    def test_user_managed_boot_diagnostics_are_not_read(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "2", "FAKE_AZ_USER_MANAGED": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse([c for c in self.az_calls() if c[:2] == ["vm", "boot-diagnostics"]])
        self.assertEqual(self.summary()["errors"]["serial_console"], {"skipped_not_managed_boot_diagnostics": 1})

    def test_single_backend_down_is_counted(self):
        self.write_identity()
        self.write_cluster()
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "4", "FAKE_MIXED": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        series = [s for s in self.summary()["lb_health"] if s["metric"] == "DipAvailability" and s["port"] == 6443]
        for stats in series:
            self.assertEqual((stats["minutes_all_up"], stats["minutes_all_down"]), (1, 0))
            self.assertEqual((stats["minutes_mixed"], stats["minutes_any_down"]), (3, 3))
            self.assertEqual(stats["first_any_down"], "2026-11-26T05:41:00Z")

    def test_live_shared_mount_is_followed(self):
        # In CI the observer's SHARED_DIR is a snapshot taken at pod start;
        # installer metadata, kubeconfig and the T0 marker appear later
        # through the live shared-dir secret mount.
        self.write_identity()
        mount = self.directory / "mount"
        mount.mkdir()
        env = {**self.env, "AZURE_API_DIAG_SHARED_MOUNT": str(mount), "AZURE_API_DIAG_MAX_SAMPLES": "3",
               "FAKE_SLEEP_SECONDS": "0.2"}
        with subprocess.Popen(self.command(OBSERVER), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            time.sleep(1)
            self.assertIsNone(process.poll(), "observer must keep waiting for the cluster metadata")
            self.write_cluster()
            for name in ("metadata.json", "kubeconfig", "kubeadmin-password"):
                shutil.move(str(self.shared / name), str(mount / name))
            (mount / "azure-api-diag-t0").write_text("2000-01-01T00:00:00Z\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 0, stderr)
        summary = self.summary()
        self.assertEqual((summary["termination_reason"], summary["samples_taken"]), ("max_samples", 3))
        self.assertTrue(summary["target_resolved"] and summary["discovered"])
        self.assertEqual(summary["api_probe"]["readyz"], {"http_200": 3})
        self.assertEqual(summary["t0"], "2000-01-01T00:00:00Z")
        self.assertTrue(all(c[c.index("--resource-group") + 1] == f"{INFRA_ID}-rg"
                            for c in self.az_calls() if "--resource-group" in c))
        self.assert_no_leak(stdout, stderr)
        self.assert_workdir_removed()

    def test_t0_marker_splits_samples(self):
        self.write_identity()
        self.write_cluster()
        (self.shared / "azure-api-diag-t0").write_text("2000-01-01T00:00:00Z\n", encoding="utf-8")
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "2"})
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary()
        self.assertEqual(summary["t0"], "2000-01-01T00:00:00Z")
        self.assertEqual((summary["samples_before_t0"], summary["samples_at_or_after_t0"]), (0, 2))

    def test_redaction_guard_withholds_detail(self):
        self.write_identity()
        self.write_cluster()
        # A cluster name equal to a published category forces the guard to trip.
        metadata = json.loads((self.shared / "metadata.json").read_text(encoding="utf-8"))
        metadata["clusterName"] = "handshake_ok"
        (self.shared / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        result = self.run_script(OBSERVER, {"AZURE_API_DIAG_MAX_SAMPLES": "2"})
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary()
        self.assertEqual(summary["redaction_guard"], "tripped")
        self.assertFalse((self.artifacts / "azure-api-diag/samples.jsonl").exists())
        self.assertIn("redaction guard tripped", result.stdout)

    def test_leak_guard_function(self):
        sensitive = self.directory / "sensitive.txt"
        sensitive.write_text(SP_FIELD_SENTINEL + "\n", encoding="utf-8")
        cases = {"clean": ('{"readyz":"http_200","t":"2026-11-26T05:40:00Z","backends":{"master-0":100}}', 0),
                 "sentinel": (f'{{"x":"{SP_FIELD_SENTINEL}"}}', 1), "ip": ('{"x":"10.1.2.3"}', 1),
                 "ipv6": ('{"x":"fd00:1234::5"}', 1), "ipv6-full": ('{"x":"2001:db8:20e:3:0:0:0:23c"}', 1),
                 "guid": (f'{{"x":"{SUBSCRIPTION_ID.upper()}"}}', 1), "url": ('{"x":"https://a.b"}', 1),
                 "sig-param": ('{"x":"ref sig="}', 1), "sig-param-encoded": ('{"x":"sig%3D"}', 1),
                 "subscriptions": ('{"x":"/SUBSCRIPTIONS/x"}', 1), "host": ('{"x":"vm.cloudapp.azure"}', 1)}
        for name, (content, expected) in cases.items():
            sample = self.directory / f"{name}.json"
            sample.write_text(content, encoding="utf-8")
            result = subprocess.run(["bash", "-c", f'source "{OBSERVER}"; SENSITIVE="{sensitive}"; leak_guard "{sample}"'],
                                    env=self.env, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, expected, name)
        missing = subprocess.run(["bash", "-c", f'source "{OBSERVER}"; SENSITIVE="{sensitive}"; '
                                  f'leak_guard "{self.directory}/does-not-exist"'],
                                 env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(missing.returncode, 1, "grep errors must fail closed")

    def test_guard_patterns_match_between_steps(self):
        def pattern(path):
            return [line for line in path.read_text(encoding="utf-8").splitlines()
                    if line.startswith("GENERIC_PATTERNS=")]
        self.assertEqual(len(pattern(OBSERVER)), 1)
        self.assertEqual(pattern(OBSERVER), pattern(PRE_ROLLOUT))


class LeakAssertionTests(Harness):
    """The confidentiality assertion itself rejects every inert sentinel."""

    def test_sentinel_in_stream_fails_assertion(self):
        for sentinel in FIXTURE_SENTINELS:
            with self.subTest(sentinel=sentinel), self.assertRaises(AssertionError):
                self.assert_no_leak(f"log line {sentinel} end")

    def test_sentinel_in_artifact_fails_assertion(self):
        artifact = self.artifacts / "azure-api-diag" / "summary.json"
        artifact.parent.mkdir()
        artifact.write_text(json.dumps({"note": SERIAL_TEXT_SENTINEL}), encoding="utf-8")
        with self.assertRaises(AssertionError):
            self.assert_no_leak()
        artifact.write_text('{"readyz":"http_200","t":"2026-11-26T05:40:00Z"}', encoding="utf-8")
        self.assert_no_leak()

    def test_identifier_patterns_fail_assertion(self):
        for sample in ("10.9.8.7", "0f0f0f0f-1111-2222-3333-444444444444", "https://a.b/x"):
            with self.subTest(sample=sample), self.assertRaises(AssertionError):
                self.assert_no_leak(f"value {sample}")


FAKE_OC_HEALTHY = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
host = os.environ["FAKE_HOST"]
what = " ".join(a for a in args if not a.startswith("-") and a not in ("get", "json"))
if os.environ.get("FAKE_OC_OUTAGE"):
    sys.stderr.write(f"Unable to connect to the server: dial tcp {os.environ['FAKE_PUBLIC_IP']}:6443: i/o timeout https://{host}\n")
    sys.exit(1)
if what == "clusteroperator kube-apiserver":
    out = {"status": {"conditions": [{"type": "Available", "status": "True", "message": f"https://{host}:6443"},
                                     {"type": "Progressing", "status": "False"},
                                     {"type": "Degraded", "status": "False", "message": "10.0.0.5 ok"}]}}
elif what == "kubeapiserver cluster":
    out = {"status": {"latestAvailableRevision": 7, "nodeStatuses": [
        {"nodeName": "master-0.fixture", "currentRevision": 7}, {"nodeName": "m1", "currentRevision": 7},
        {"nodeName": "m2", "currentRevision": 6, "targetRevision": 7}]}}
elif what == "featuregate cluster":
    out = {"spec": {}}
elif what == "apiserver cluster":
    out = {"spec": {"tlsSecurityProfile": {"type": "Custom", "custom": {"minTLSVersion": "VersionTLS13",
                    "groups": ["SecP384r1MLKEM1024", "Fixture-" + host]}}, "tlsAdherence": "StrictAllComponents"}}
elif what == "nodes":
    ready = [{"type": "Ready", "status": "True"}]
    out = {"items": [{"metadata": {"name": host, "labels": {"node-role.kubernetes.io/master": ""}},
                      "status": {"conditions": ready}} for _ in range(3)] +
           [{"metadata": {"name": "w", "labels": {}}, "status": {"conditions": [{"type": "Ready", "status": "False"}]}}]}
elif what == "clusteroperators":
    out = {"items": [{"status": {"conditions": [{"type": "Available", "status": "True"}]}}] * 30}
else:
    sys.exit(3)
print(json.dumps(out))
'''


class PreRolloutTests(Harness):
    """Pre-rollout baseline and T0 marker."""

    def setUp(self):
        super().setUp()
        self.write_executable("oc", FAKE_OC_HEALTHY)
        self.write_cluster()

    def test_baseline_is_allowlisted_and_marks_t0(self):
        result = self.run_script(PRE_ROLLOUT)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((self.artifacts / "azure-api-diag/pre-rollout.json").read_text(encoding="utf-8"))
        self.assertEqual(report["kube_apiserver_conditions"],
                         {"Available": "True", "Progressing": "False", "Degraded": "False"})
        self.assertEqual(report["kube_apiserver_revisions"],
                         {"latest_available_revision": 7, "nodes": 3, "nodes_at_latest": 2, "nodes_rolling": 1})
        self.assertEqual(report["feature_set"], "Default")
        self.assertEqual(report["tls_profile"], {"type": "Custom", "adherence": "StrictAllComponents",
                                                 "custom_min_version": "VersionTLS13",
                                                 "custom_groups": ["SecP384r1MLKEM1024", "other"]})
        self.assertEqual(report["nodes"], {"control_plane_ready": 3, "control_plane_not_ready": 0,
                                           "other_ready": 0, "other_not_ready": 1})
        self.assertEqual(report["settle_seconds"], 300)
        self.assertEqual((self.state / "sleep-calls").read_text(encoding="utf-8").split(), ["300"])
        self.assertEqual((self.shared / "azure-api-diag-t0").read_text(encoding="utf-8").strip(), report["t0"])
        self.assert_no_leak(result.stdout, result.stderr)

    def test_api_outage_never_fails_and_is_visible(self):
        result = self.run_script(PRE_ROLLOUT, {"FAKE_OC_OUTAGE": "1", "AZURE_API_DIAG_PRE_ROLLOUT_SETTLE": "99999"})
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((self.artifacts / "azure-api-diag/pre-rollout.json").read_text(encoding="utf-8"))
        self.assertEqual(set(report["api_status"].values()), {"timeout"})
        self.assertIsNone(report["kube_apiserver_conditions"])
        self.assertEqual(report["settle_seconds"], 1800)
        self.assertTrue((self.shared / "azure-api-diag-t0").exists())
        self.assert_no_leak(result.stdout, result.stderr)


class RevisionGuardTests(Harness):
    """Operator revision guard."""

    def guard(self, head, job_spec=None, expected=TARGET_REVISION, git_fails=False):
        self.write_executable("git", "#!/bin/bash\n" + ("exit 128\n" if git_fails else
                                                         f'[[ "$*" == *rev-parse\\ HEAD* ]] && echo {head}\nexit 0\n'))
        extra = {"EXPECTED_OPERATOR_REVISION": expected}
        if job_spec is not None:
            extra["JOB_SPEC"] = json.dumps(job_spec)
        result = self.run_script(GUARD, extra)
        report = json.loads((self.artifacts / "revision-guard.json").read_text(encoding="utf-8"))
        return result, report

    def test_matching_revision_passes(self):
        spec = {"refs": {"org": "openshift", "repo": "release", "pulls": [{"number": 1}]},
                "extra_refs": [{"org": "openshift", "repo": "secrets-store-csi-driver-operator", "base_ref": "main"}]}
        result, report = self.guard(TARGET_REVISION, spec)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((report["result"], report["pull_requests_merged"], report["job_spec_check"]),
                         ("ok", "0", "checked"))

    def test_moved_branch_fails(self):
        result, report = self.guard("35f997b2a566d91b0d9d153c1865c54bd904eae4")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["result"], "revision_mismatch")

    def test_merged_pull_request_fails(self):
        spec = {"refs": {"org": "openshift", "repo": "secrets-store-csi-driver-operator",
                         "pulls": [{"number": 157, "sha": "35f997b2a566d91b0d9d153c1865c54bd904eae4"}]}}
        result, report = self.guard(TARGET_REVISION, spec)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["result"], "pull_requests_merged")

    def test_job_spec_without_operator_repo_is_reported(self):
        spec = {"refs": {"org": "openshift", "repo": "release", "pulls": [{"number": 1}]}}
        result, report = self.guard(TARGET_REVISION, spec)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(report["job_spec_check"], "repo_not_in_job_spec")

    def test_unverifiable_or_invalid_input_fails_closed(self):
        result, report = self.guard(TARGET_REVISION, git_fails=True)
        self.assertEqual((result.returncode, report["result"]), (1, "revision_unverifiable"))
        result, report = self.guard(TARGET_REVISION, expected="main")
        self.assertEqual((result.returncode, report["result"]), (1, "invalid_expected_revision"))


class VariantConfigTests(unittest.TestCase):
    """The diagnostic variant only adds instrumentation around the unchanged test."""

    @classmethod
    def setUpClass(cls):
        cls.main = yaml.safe_load(MAIN_CONFIG.read_text(encoding="utf-8"))
        cls.variant = yaml.safe_load(VARIANT_CONFIG.read_text(encoding="utf-8"))
        cls.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["workflow"]
        cls.original = next(t for t in cls.main["tests"] if t["as"] == "tls-groups-scanner")
        cls.test = cls.variant["tests"][0]

    def test_build_inputs_match_main(self):
        for key in ("base_images", "build_root", "operator", "releases", "resources", "binary_build_commands",
                    "test_binary_build_commands"):
            self.assertEqual(self.variant[key], self.main[key], key)
        self.assertEqual(self.variant["images"]["items"], self.main["images"]["items"])
        self.assertNotIn("promotion", self.variant)
        self.assertEqual(self.variant["zz_generated_metadata"]["variant"], "azure-api-diag")

    def test_single_optional_manual_test(self):
        self.assertEqual(len(self.variant["tests"]), 1)
        self.assertEqual((self.test["as"], self.test["always_run"], self.test["optional"]),
                         ("tls-groups-scanner", False, True))
        self.assertEqual(self.variant["images"]["run_if_changed"], "x^")
        self.assertTrue(self.variant["prowgen"]["skip_operator_presubmits"])

    def test_steps_wrap_unchanged_tls_settings(self):
        steps, original = self.test["steps"], self.original["steps"]
        for key in ("cluster_profile", "dependencies", "workflow"):
            self.assertEqual(steps[key], original[key], key)
        env = dict(steps["env"])
        self.assertEqual(env.pop("EXPECTED_OPERATOR_REVISION"), TARGET_REVISION)
        self.assertEqual(env, original["env"])
        self.assertEqual(steps["test"], [{"ref": "openshift-e2e-azure-csi-secrets-store-api-diag-pre-rollout"}]
                         + original["test"])
        self.assertEqual(steps["pre"], [{"ref": "openshift-e2e-azure-csi-secrets-store-api-diag-revision-guard"}]
                         + self.workflow["steps"]["pre"])
        self.assertNotIn("post", steps)
        self.assertEqual(steps["observers"], {"enable": ["openshift-e2e-azure-csi-secrets-store-api-diag-observer"]})


if __name__ == "__main__":
    unittest.main()
