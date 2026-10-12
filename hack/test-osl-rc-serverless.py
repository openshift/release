#!/usr/bin/env python3
"""Cluster-free checks: python3 hack/test-osl-rc-serverless.py."""

import json
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / (
    "ci-operator/step-registry/redhat-developer/rhdh-plugin-export-overlays/"
    "ocp/helm/osl/rc/"
    "redhat-developer-rhdh-plugin-export-overlays-ocp-helm-osl-rc-commands.sh"
)
SOURCE = SCRIPT.read_text()


def run(body, manifest=None):
    """Run the real shell functions with fake oc responses, never a cluster."""
    functions = "\n".join(re.findall(r"^\w+\(\) \{\n.*?^\}", SOURCE, re.M | re.S))
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "release.json"
        path.write_text(json.dumps(manifest or {}))
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", functions + "\n" + body],
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "MANIFEST": str(path)},
            text=True, capture_output=True, check=False,
        )


def check(condition, result):
    assert condition, result.stdout + result.stderr


# No Serverless stanza must select standard latest; a version must select Manual.
for manifest, expected in [
    ({}, ["serverless-operator", "stable", "redhat-operators", "openshift-marketplace", "", "", "Automatic"]),
    ({"serverless": {"expectedVersion": "1.37.1"}},
     ["serverless-operator", "stable", "redhat-operators", "openshift-marketplace", "1.37.1", "serverless-operator.v1.37.1", "Manual"]),
    ({"serverless": {"expectedVersion": "v1.37.1", "expectedCSV": "custom.v1.37.1", "source": "custom-catalog"}},
     ["serverless-operator", "stable", "custom-catalog", "openshift-marketplace", "1.37.1", "custom.v1.37.1", "Manual"]),
]:
    result = run('''load_serverless_config
printf '%s\n' "$SERVERLESS_PACKAGE" "$SERVERLESS_CHANNEL" "$SERVERLESS_SOURCE" "$SERVERLESS_SOURCE_NAMESPACE" "$SERVERLESS_VERSION" "$SERVERLESS_EXPECTED_CSV" "$SERVERLESS_APPROVAL"
''', manifest)
    check(result.returncode == 0 and result.stdout.splitlines() == expected, result)

for settings in [False, {"expectedVersion": False}, {"expectedVersion": ""},
                 {"expectedVersion": "latest"}, {"expectedVersion": "v"}, {"expectedVersion": "1.37\nbad"},
                 {"expectedCSV": "serverless-operator.v1.37.1"}]:
    result = run("load_serverless_config", {"serverless": settings})
    check(result.returncode != 0, result)

# Assert the Subscription emitted to oc, including the existing Logic call shape.
for args, approval, csv in [
    ("", "Automatic", None),
    ("serverless-operator.v1.37.1 Manual", "Manual", "serverless-operator.v1.37.1"),
    ("logic-operator.v1.39.0", "Automatic", "logic-operator.v1.39.0"),
]:
    result = run('oc() { cat; }\ninstall_subscription name namespace package stable source source-namespace ' + args)
    check(result.returncode == 0 and f"installPlanApproval: {approval}" in result.stdout, result)
    check((f"startingCSV: {csv}" in result.stdout) if csv else "startingCSV:" not in result.stdout, result)

# Pin verification must reject an accidentally automatic Subscription.
for actual_approval, success in [("Manual", True), ("Automatic", False)]:
    subscription = {"spec": {
        "channel": "stable", "source": "redhat-operators", "sourceNamespace": "openshift-marketplace",
        "startingCSV": "serverless-operator.v1.37.1", "installPlanApproval": actual_approval,
    }}
    result = run('''
subscription_diagnostics() { :; }
oc() { printf '%s' 'SUBSCRIPTION_JSON'; }
verify_subscription serverless-operator openshift-operators stable redhat-operators openshift-marketplace serverless-operator.v1.37.1 Manual
'''.replace("SUBSCRIPTION_JSON", json.dumps(subscription)))
    check((result.returncode == 0) == success, result)

# A combined Logic plan must not sneak in a Serverless upgrade.
for plan_csvs, other_csv, success in [
    (["serverless-operator.v1.37.1"], "", True),
    (["serverless-operator.v1.38.0"], "", False),
    (["serverless-operator.v1.37.1", "logic-operator.v1.39.0"], "logic-operator.v1.39.0", True),
    (["serverless-operator.v1.38.0", "logic-operator.v1.39.0"], "logic-operator.v1.39.0", False),
    (["serverless-operator.v1.37.1", "logic-operator.v1.40.0"], "logic-operator.v1.39.0", False),
]:
    result = run('''
sleep() { :; }
oc() {
    case "$*" in
        *"get subscription"*) printf 'install-test' ;;
        *"get installplan"*) printf '%s' 'PLAN_JSON' ;;
        *"patch installplan"*) printf 'APPROVAL %s\n' "$*" ;;
        *) return 1 ;;
    esac
}
approve_initial_install_plan serverless-operator openshift-operators serverless-operator.v1.37.1 'OTHER_CSV'
'''.replace("PLAN_JSON", json.dumps({"spec": {"clusterServiceVersionNames": plan_csvs, "approved": False}}))
       .replace("'OTHER_CSV'", repr(other_csv)))
    check((result.returncode == 0) == success, result)
    check(("APPROVAL" in result.stdout) == success, result)
    if success:
        check('"approved":true' in result.stdout, result)

result = run('''
sleep() { :; }
subscription_diagnostics() { :; }
oc() { return 0; }
approve_initial_install_plan serverless-operator openshift-operators serverless-operator.v1.37.1
''')
check(result.returncode != 0 and "no InstallPlan" in result.stderr, result)

# Latest accepts any successful version; a pin rejects wrong versions and CSVs.
for expected_version, expected_csv, phase, version, success in [
    ("", "", "Succeeded", "1.37.1", True),
    ("1.37.1", "serverless-operator.v1.37.1", "Succeeded", "1.37.1", True),
    ("1.37.1", "serverless-operator.v1.37.1", "Succeeded", "1.38.0", False),
    ("1.37.1", "serverless-operator.v1.38.0", "Succeeded", "1.37.1", False),
    ("", "", "Pending", "1.37.1", False),
]:
    result = run('''
sleep() { :; }
subscription_diagnostics() { :; }
oc() {
    case "$*" in
        *"get subscription"*) printf 'serverless-operator.v1.37.1' ;;
        *"get csv"*) printf '%s' 'CSV_JSON' ;;
        *) return 1 ;;
    esac
}
wait_for_subscription serverless-operator openshift-operators 'VERSION' 'CSV'
'''.replace("CSV_JSON", json.dumps({"spec": {"version": version}, "status": {"phase": phase}}))
       .replace("'VERSION'", repr(expected_version)).replace("'CSV'", repr(expected_csv)))
    check((result.returncode == 0) == success, result)
    if success:
        check("1.37.1" in result.stdout, result)

print("PASS: latest defaults, exact pins, validation, Subscription payloads, install-plan approval, and CSV readiness")
