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
    "ocp/helm/"
    "redhat-developer-rhdh-plugin-export-overlays-ocp-helm-osl-rc-commands.sh"
)
SOURCE = SCRIPT.read_text()


def run(body, release_data=None):
    """Run the real shell functions with fake oc responses, never a cluster."""
    functions = "\n".join(re.findall(r"^\w+\(\) \{\n.*?^\}", SOURCE, re.M | re.S))
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "release.json"
        path.write_text(json.dumps(release_data or {}))
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", functions + "\n" + body],
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "MANIFEST": str(path)},
            text=True, capture_output=True, check=False,
        )


def check(condition, process_result):
    assert condition, process_result.stdout + process_result.stderr


OSL_IMAGE_MIRRORS = [
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-rhel9-operator",
     "registry.redhat.io/openshift-serverless-1/logic-rhel9-operator"),
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-jobs-service-postgresql-rhel9",
     "registry.redhat.io/openshift-serverless-1/logic-jobs-service-postgresql-rhel9"),
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-jobs-service-ephemeral-rhel9",
     "registry.redhat.io/openshift-serverless-1/logic-jobs-service-ephemeral-rhel9"),
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-data-index-postgresql-rhel9",
     "registry.redhat.io/openshift-serverless-1/logic-data-index-postgresql-rhel9"),
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-data-index-ephemeral-rhel9",
     "registry.redhat.io/openshift-serverless-1/logic-data-index-ephemeral-rhel9"),
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-db-migrator-tool-rhel9",
     "registry.redhat.io/openshift-serverless-1/logic-db-migrator-tool-rhel9"),
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-swf-builder-rhel9",
     "registry.redhat.io/openshift-serverless-1/logic-swf-builder-rhel9"),
    ("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-swf-devmode-rhel9",
     "registry.redhat.io/openshift-serverless-1/logic-swf-devmode-rhel9"),
]
result = run("oc() { cat; }\napply_osl_candidate_mirrors")
emitted_mirrors = set(re.findall(
    r"(?m)^[ \t]*-[ \t]+(brew\.registry\.redhat\.io/\S+)[ \t]*\n"
    r"[ \t]*source:[ \t]+(registry\.redhat\.io/\S+)[ \t]*$",
    result.stdout,
))
check(result.returncode == 0 and set(OSL_IMAGE_MIRRORS) <= emitted_mirrors, result)
check("source: registry-proxy.engineering.redhat.com" in result.stdout, result)
check("source: registry.stage.redhat.io" in result.stdout, result)


# Serverless always uses the stable channel from the standard Red Hat catalog.
result = run('''set_serverless_defaults
printf '%s\n' "$SERVERLESS_PACKAGE" "$SERVERLESS_CHANNEL" "$SERVERLESS_SOURCE" "$SERVERLESS_SOURCE_NAMESPACE"
''')
check(result.returncode == 0 and result.stdout.splitlines() == [
    "serverless-operator", "stable", "redhat-operators", "openshift-marketplace",
], result)

# Reject obsolete release.json pins before the job can install a different version.
for manifest, success in [
    ({}, True),
    ({"serverless": None}, True),
    ({"serverless": {"expectedVersion": "1.37.1"}}, False),
    ({"serverless": {"expectedCSV": "serverless-operator.v1.37.1"}}, False),
]:
    result = run("reject_serverless_config", manifest)
    check((result.returncode == 0) == success, result)
    if not success:
        check("remove .serverless" in result.stderr.lower(), result)

main = SOURCE[SOURCE.index('if [[ ! -s "${MANIFEST}" ]]'):]
assert main.index("reject_serverless_config") < main.index("ACTUAL_OCP=$(oc version"), \
    "Serverless manifest validation must happen before cluster access"

# Assert the Subscription emitted to oc, including the existing Logic call shape.
for args, csv, approval in [
    ("serverless-operator openshift-operators serverless-operator stable redhat-operators openshift-marketplace", None, "Automatic"),
    ("logic-operator openshift-operators logic-operator stable osl-rc-logic openshift-marketplace logic-operator.v1.39.0 Manual", "logic-operator.v1.39.0", "Manual"),
]:
    result = run('oc() { cat; }\ninstall_subscription ' + args)
    check(result.returncode == 0 and f"installPlanApproval: {approval}" in result.stdout, result)
    check((f"startingCSV: {csv}" in result.stdout) if csv else "startingCSV:" not in result.stdout, result)

# Serverless uses automatic approval; Logic uses manual approval for its pinned CSV.
for name, starting_csv, subscription_starting_csv, actual_approval, success in [
    ("serverless-operator", "", "", "Automatic", True),
    ("serverless-operator", "", "serverless-operator.v1.37.1", "Automatic", False),
    ("logic-operator", "logic-operator.v1.39.0", "logic-operator.v1.39.0", "Manual", True),
    ("logic-operator", "logic-operator.v1.39.0", "logic-operator.v1.39.0", "Automatic", False),
]:
    subscription = {"spec": {
        "channel": "stable",
        "source": "osl-rc-logic" if name == "logic-operator" else "redhat-operators",
        "sourceNamespace": "openshift-marketplace",
        "installPlanApproval": actual_approval,
    }}
    if subscription_starting_csv:
        subscription["spec"]["startingCSV"] = subscription_starting_csv
    result = run('''
subscription_diagnostics() { :; }
oc() { printf '%s' 'SUBSCRIPTION_JSON'; }
verify_subscription NAME openshift-operators stable SOURCE openshift-marketplace "STARTING_CSV" "APPROVAL"
'''.replace("NAME", name)
       .replace("SOURCE", subscription["spec"]["source"])
       .replace("STARTING_CSV", starting_csv)
       .replace("APPROVAL", "Manual" if name == "logic-operator" else "Automatic")
       .replace("SUBSCRIPTION_JSON", json.dumps(subscription)))
    check((result.returncode == 0) == success, result)

# Only approve the expected Logic CSV, with optional Serverless CSVs in a combined plan.
for plan_csvs, success in [
    (["logic-operator.v1.39.0"], True),
    (["logic-operator.v1.39.0", "serverless-operator.v1.37.1"], True),
    (["logic-operator.v1.40.0"], False),
    (["logic-operator.v1.39.0", "unrelated-operator.v1.2.3"], False),
]:
    result = run('''
SERVERLESS_PACKAGE=serverless-operator
sleep() { :; }
subscription_diagnostics() { :; }
oc() {
    case "$*" in
        *"get subscription"*) printf 'install-test' ;;
        *"get installplan"*) printf '%s' 'PLAN_JSON' ;;
        *"patch installplan"*) printf 'APPROVED\n' ;;
        *) return 1 ;;
    esac
}
approve_initial_install_plan logic-operator openshift-operators logic-operator.v1.39.0
'''.replace("PLAN_JSON", json.dumps({"spec": {"clusterServiceVersionNames": plan_csvs, "approved": False}})))
    check((result.returncode == 0) == success, result)
    check(("APPROVED" in result.stdout) == success, result)

# The default Serverless path accepts any succeeded CSV. Logic remains exact.
for name, expected_version, expected_csv, actual_csv, phase, version, success in [
    ("serverless-operator", "", "", "serverless-operator.v1.37.1", "Succeeded", "1.37.1", True),
    ("serverless-operator", "", "", "serverless-operator.v1.37.1", "Pending", "1.37.1", False),
    ("logic-operator", "1.39.0", "logic-operator.v1.39.0", "logic-operator.v1.39.0", "Succeeded", "1.39.0", True),
    ("logic-operator", "1.39.0", "logic-operator.v1.39.0", "logic-operator.v1.39.0", "Succeeded", "1.40.0", False),
    ("logic-operator", "1.39.0", "logic-operator.v1.39.0", "logic-operator.v1.40.0", "Succeeded", "1.39.0", False),
]:
    result = run('''
sleep() { :; }
subscription_diagnostics() { :; }
oc() {
    case "$*" in
        *"get subscription"*) printf 'ACTUAL_CSV' ;;
        *"get csv"*) printf '%s' 'CSV_JSON' ;;
        *) return 1 ;;
    esac
}
wait_for_subscription NAME openshift-operators 'VERSION' 'CSV'
'''.replace("CSV_JSON", json.dumps({"spec": {"version": version}, "status": {"phase": phase}}))
       .replace("ACTUAL_CSV", actual_csv).replace("NAME", name)
       .replace("'VERSION'", repr(expected_version)).replace("'CSV'", repr(expected_csv)))
    check((result.returncode == 0) == success, result)

print("PASS: Serverless defaults, approval policies, Logic InstallPlan filtering, and CSV readiness")
