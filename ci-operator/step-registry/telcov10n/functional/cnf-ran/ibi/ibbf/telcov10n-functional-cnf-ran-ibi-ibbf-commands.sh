#!/bin/bash
set +x
set -euo pipefail
umask 077

TEMP_DIR=
SSH_READY=false

finish() {
  local result=$1 copy_rc=0
  trap - EXIT
  set +e
  if [[ "${SSH_READY}" == true ]]; then
    collect_reports
    copy_rc=$?
    (( result != 0 )) || result=${copy_rc}
    ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
      "rm -f -- '${BMC_ENV_FILE}' '${SPOKE_KUBECONFIG}' '${POLICY_BASELINE}'" \
      2>&1 | redact_bastion
  fi
  [[ -z "${TEMP_DIR}" ]] || rm -rf -- "${TEMP_DIR}"
  echo "IBBF step status: ${result}; report-copy status: ${copy_rc}."
  exit "${result}"
}

validate_inputs() {
  : "${TARGET_CLUSTER_NAME:?TARGET_CLUSTER_NAME is required}"
  : "${TARGET_SPOKE_CLUSTER:?TARGET_SPOKE_CLUSTER is required}"
  : "${VERSION:?VERSION is required}"
  : "${IBI_IBBF_ORIGINAL_BMC_HOST:?Original target BMC is required}"
  : "${IBI_IBBF_REPLACEMENT_BMC_HOST:?Replacement BMC is required}"
  : "${IBI_IBBF_TARGET_IP:?Static target IPv4 address is required}"
  [[ "${IBI_REPLACEMENT_PREINSTALL_ENABLED}" == true ]]
  [[ "${IBI_IBBF_ORIGINAL_BMC_HOST}" != "${IBI_IBBF_REPLACEMENT_BMC_HOST}" ]]
  [[ "${IBI_IBBF_ORIGINAL_BMC_HOST}" =~ ^[0-9.]+$ ]]
  [[ "${IBI_IBBF_REPLACEMENT_BMC_HOST}" =~ ^[0-9.]+$ ]]
  [[ "${IBI_IBBF_TARGET_IP}" =~ ^[0-9.]+$ ]]
  [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]
  TARGET_SPOKE_NAME=$(printf '%s' "${TARGET_SPOKE_CLUSTER}" | tr -d "[]'\" ")
  [[ "${TARGET_CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  [[ "${TARGET_SPOKE_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  HUB_CONFIG_DIR="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}"
}

restore_target_inventory() {
  local name
  INVENTORY_PATH=/eco-ci-cd/inventories/ocp-deployment
  mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"
  for name in all bastions; do
    cp "${SHARED_DIR}/target-${name}" "${INVENTORY_PATH}/group_vars/${name}"
  done
  cp "${SHARED_DIR}/target-bastion" "${INVENTORY_PATH}/host_vars/bastion"
}

create_work_directories() {
  TEMP_DIR=$(mktemp -d /tmp/ibi-ibbf.XXXXXX)
  WORK_DIR="/tmp/eco_gotests_ibi_ibbf/${TEMP_DIR##*/}"
  # The preparation playbook deletes WORK_DIR, so keep the kubeconfig outside it.
  SPOKE_KUBECONFIG="/tmp/${TEMP_DIR##*/}-kubeconfig"
  REPORT_DIR="${ARTIFACT_DIR}/ibi-ibbf"
  mkdir -p "${REPORT_DIR}"
  BMC_ENV_FILE="/tmp/${TEMP_DIR##*/}-bmc.env"
  POLICY_BASELINE="/tmp/${TEMP_DIR##*/}-policies.json"
}

configure_ssh() {
  cp /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"
  chmod 600 "${TEMP_DIR}/ssh-key"
  BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
  BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")
  [[ -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]
  SSH_OPTS=(
    -i "${TEMP_DIR}/ssh-key"
    -o BatchMode=yes
    -o ConnectTimeout=30
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=6
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
  SSH_READY=true
}

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//${BASTION_USER}@${BASTION_IP}/<bastion>}"
    line="${line//${BASTION_IP}/<bastion>}"
    printf '%s\n' "${line}"
  done
}

fetch_target_kubeconfig() {
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "set -euo pipefail; umask 077
     oc --kubeconfig='${HUB_CONFIG_DIR}/auth/kubeconfig' -n '${TARGET_SPOKE_NAME}' \
       get secret '${TARGET_SPOKE_NAME}-admin-kubeconfig' \
       -o jsonpath='{.data.kubeconfig}' | base64 -d > '${SPOKE_KUBECONFIG}'
     test -s '${SPOKE_KUBECONFIG}'" \
    2>&1 | redact_bastion
}

prepare_launcher() {
  cd /eco-ci-cd
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook ./playbooks/deploy-run-eco-gotests.yaml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --private-key "${TEMP_DIR}/ssh-key" \
    --extra-vars "kubeconfig=${SPOKE_KUBECONFIG}" \
    --extra-vars "hub_clusterconfigs_path=${HUB_CONFIG_DIR}" \
    --extra-vars "eco_gotest_dir=${WORK_DIR}" \
    --extra-vars "additional_test_env_variables='--env-file ${BMC_ENV_FILE}'" \
    --extra-vars '{
      "features": "gitopsztp",
      "labels": "\"ibbf-end-to-end && test_id:78333\"",
      "eco_gotests_tag": "latest",
      "test_timeout": "3h",
      "eco_worker_label": "",
      "eco_cnf_core_net_switch_user": "",
      "eco_cnf_core_net_switch_pass": "",
      "eco_cnf_core_net_switch_ip": "",
      "eco_cnf_core_net_mlb_addr_list": "",
      "switch_lag_names": "",
      "report_test_case_tag": "test_id",
      "report_parameter_tag": "parameters",
      "report_tc_prefix": "ibi"
    }' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/setup.log"
}

run_tests() {
  local -a status
  set +e
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "cd '${WORK_DIR}' &&
     sed -i 's/^podman run -it /podman run -i /' eco-gotests-run.sh &&
     exec ./eco-gotests-run.sh" \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/runner.log"
  status=("${PIPESTATUS[@]}")
  set -e
  echo "Test execution status: ${status[0]}; log-write status: ${status[2]}."
  (( status[0] == 0 )) || return "${status[0]}"
  (( status[1] == 0 )) || return "${status[1]}"
  return "${status[2]}"
}

collect_reports() {
  scp -q -r "${SSH_OPTS[@]}" \
    "${BASTION_USER}@${BASTION_IP}:${WORK_DIR}/report" "${REPORT_DIR}/" \
    2>&1 | redact_bastion
}

prepare_bmc_environment() {
  # Read credentials directly on the target bastion; never put them in arguments or reports.
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    python3 - "${HUB_CONFIG_DIR}/auth/kubeconfig" "${TARGET_SPOKE_NAME}" \
    "${VERSION}" "${IBI_IBBF_ORIGINAL_BMC_HOST}" "${IBI_IBBF_REPLACEMENT_BMC_HOST}" \
    "${IBI_IBBF_TARGET_IP}" "${BMC_ENV_FILE}" "${SPOKE_KUBECONFIG}" "${POLICY_BASELINE}" <<'PY' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/preflight.log"
import base64
import ipaddress
import json
import os
import ssl
import subprocess
import sys
import urllib.parse
import urllib.request

kubeconfig, spoke, version, original, replacement, target_ip, env_file, spoke_config, baseline_file = sys.argv[1:]
os.umask(0o077)
for address in (original, replacement, target_ip):
    ipaddress.IPv4Address(address)

def get(resource, name, namespace):
    return json.loads(subprocess.check_output([
        "oc", "--kubeconfig=" + kubeconfig, "--request-timeout=30s", "-n", namespace,
        "get", resource, name, "-o", "json",
    ], timeout=45))

def listing(resource, config, *scope):
    return json.loads(subprocess.check_output([
        "oc", "--kubeconfig=" + config, "--request-timeout=30s",
        "get", resource, *scope, "-o", "json",
    ], timeout=45))["items"]

def require(condition, message):
    if not condition:
        sys.exit(message)

siteconfigs = listing("configmaps", kubeconfig, "-A", "--field-selector",
                      "metadata.name=siteconfig-operator-configuration")
require(len(siteconfigs) == 1 and not siteconfigs[0]["metadata"].get("deletionTimestamp"),
        "Expected exactly one active SiteConfig configuration ConfigMap.")
siteconfig_namespace = siteconfigs[0]["metadata"]["namespace"]
controller = get("deployment", "siteconfig-controller-manager", siteconfig_namespace)
status = controller.get("status", {})
desired = controller.get("spec", {}).get("replicas", 1)
require(not controller["metadata"].get("deletionTimestamp") and desired > 0 and
        status.get("observedGeneration", 0) >= controller["metadata"]["generation"] and
        status.get("updatedReplicas", 0) == desired and
        status.get("availableReplicas", 0) == desired,
        "SiteConfig controller is not ready in its configuration namespace.")
require(get("configmap", "import-controller-config", "multicluster-engine")
        .get("data", {}).get("autoImportStrategy") == "ImportAndSync",
        "Target hub must use ImportAndSync before IBBF.")

# Capture the complete expected policy set before replacing the node. A later
# empty or partial list must not count as successful policy recovery.
policies = listing("policies.policy.open-cluster-management.io", kubeconfig, "-n", spoke)
require(bool(policies) and all(item.get("status", {}).get("compliant") == "Compliant"
                              for item in policies), "Target policies must be Compliant before IBBF.")
config_policies = listing("configurationpolicies.policy.open-cluster-management.io", spoke_config, "-A")
baseline = {}
for policy in policies:
    name = policy["metadata"]["name"]
    templates = policy["spec"].get("policy-templates", [])
    require(bool(templates), "Expected policy templates in target policy.")
    baseline[name] = []
    for template in templates:
        definition = template["objectDefinition"]
        require(definition.get("kind") == "ConfigurationPolicy",
                "IBBF policy gate requires ConfigurationPolicy templates.")
        matches = [item for item in config_policies
                   if item["metadata"]["name"] == definition["metadata"]["name"]]
        require(len(matches) == 1, "Target ConfigurationPolicy is missing or ambiguous.")
        baseline[name].append({key: matches[0]["metadata"][key] for key in ("name", "namespace")})
for name in ("common-config-policy", "common-subscriptions-policy"):
    replica = next((item for item in policies if item["metadata"]["name"] == "ztp-common." + name), {})
    require(replica.get("metadata", {}).get("labels", {}).get("policy.open-cluster-management.io/root-policy")
            == "ztp-common." + name, "Expected common policy is not assigned to the target.")
    get("policies.policy.open-cluster-management.io", name, "ztp-common")
original_cgu = get("clustergroupupgrades.ran.openshift.io", spoke, "ztp-install")
require(any(condition.get("type") == "Succeeded" and condition.get("status") == "True"
            for condition in original_cgu.get("status", {}).get("conditions", [])),
        "Initial target policy remediation has not completed.")
original_nodes = listing("nodes", spoke_config)
require(len(original_nodes) == 1 and original_nodes[0]["metadata"].get("uid"),
        "Expected one original target node with a UID.")
with open(baseline_file, "w") as output:
    json.dump({"node_uid": original_nodes[0]["metadata"]["uid"], "policies": baseline}, output)

for name, suffix in (("clusters", "clusterinstance"), ("policies", "policygentemplate")):
    app = get("applications.argoproj.io", name, "openshift-gitops")
    require(app["spec"].get("source", {}).get("path") == f"{version}/{spoke}/{suffix}",
            "Argo application is not on the original target path.")
    require(not app.get("operation") and
            app.get("status", {}).get("sync", {}).get("status") == "Synced",
            "Argo application is not idle and synced.")

ci = get("clusterinstances.siteconfig.open-cluster-management.io", spoke, spoke)
require(not ci["spec"].get("reinstall"), "Target already has a reinstall request; use a fresh workflow run.")
nodes = ci["spec"]["nodes"]
require(len(nodes) == 1, "IBBF requires exactly one target node.")
node = nodes[0]
interfaces = node["nodeNetwork"]["config"]["interfaces"]
require(any(not interface.get("ipv4", {}).get("dhcp", True) and
            any(item.get("ip") == target_ip for item in interface.get("ipv4", {}).get("address", []))
            for interface in interfaces), "Target must already use the reserved static IPv4 address.")

bmh = get("baremetalhosts.metal3.io", node["hostName"], spoke)
endpoint = urllib.parse.urlparse(bmh["spec"]["bmc"]["address"])
require(endpoint.hostname == original, "Original BMC does not match the target BareMetalHost.")
require(urllib.parse.urlparse(node["bmcAddress"]).hostname == original,
        "Original BMC does not match the ClusterInstance.")
secret_name = bmh["spec"]["bmc"]["credentialsName"]
require(secret_name == node["bmcCredentialsName"]["name"], "BMC secret references differ.")
secret = get("secret", secret_name, spoke)["data"]
user = base64.b64decode(secret["username"]).decode()
password = base64.b64decode(secret["password"]).decode()
require(all(value and not any(char in value for char in "\r\n\0")
            for value in (user, password)), "BMC credentials cannot be stored in an env file.")

# The reinstall retains this secret name. Verify it authenticates both BMCs
# before the suite is allowed to power off the original target.
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)
authorization = base64.b64encode(f"{user}:{password}".encode()).decode()
for role, host in (("original", original), ("replacement", replacement)):
    request = urllib.request.Request(
        f"https://{host}/redfish/v1/Systems/System.Embedded.1",
        headers={"Authorization": "Basic " + authorization},
    )
    try:
        with opener.open(request, timeout=30) as response:
            require(response.status == 200, "BMC authentication failed.")
            require("PowerState" in json.load(response), "BMC system response has no power state.")
    except Exception:
        sys.exit(f"Cannot authenticate to the {role} BMC with the target BMC secret.")
os.umask(0o077)
with open(env_file, "w") as output:
    for key, value in {
        "ECO_CNF_RAN_BMC_HOSTS": original,
        "ECO_CNF_RAN_BMC_USERNAME": user,
        "ECO_CNF_RAN_BMC_PASSWORD": password,
        "ECO_CNF_RAN_SKIP_TLS_VERIFY": "true",
        "ECO_CNF_RAN_ACM_OPERATOR_NAMESPACE": siteconfig_namespace,
        "ECO_TEST_TRACE": "true",
        "ECO_VERBOSE_SCRIPT": "true",
    }.items():
        output.write(f"{key}={value}\n")
print("IBBF target scope, static IP and both BMC credentials verified.")
PY
}

verify_hardware_test() {
  # A missing Git fixture makes the suite skip with exit 0. Require a real pass.
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    python3 - "${WORK_DIR}/report" <<'PY' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/coverage.log"
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

cases = []
for report in Path(sys.argv[1]).glob("*junit*.xml"):
    cases.extend(ET.parse(report).getroot().iter("testcase"))
hardware = [case for case in cases if "tests HW replacement via IBBF" in case.get("name", "")]
if len(hardware) != 1 or any(hardware[0].find(tag) is not None for tag in ("skipped", "failure", "error")):
    sys.exit("IBBF hardware replacement did not execute and pass exactly once.")
print("IBBF hardware replacement test executed and passed.")
print("Policy compliance is checked separately after TALM remediation; image policy spec 87996 is not selected.")
PY
}

remediate_and_verify_policies() {
  # Run remediation before this independent compliance assertion. The image
  # runs only the hardware spec because its policy spec can skip on a changed path.
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    python3 - "${HUB_CONFIG_DIR}/auth/kubeconfig" "${TARGET_SPOKE_NAME}" \
    "${SPOKE_KUBECONFIG}" "${POLICY_BASELINE}" "${WORK_DIR}/report" <<'PY' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/policy-gate.log"
from datetime import datetime, timezone
from pathlib import Path
import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

hub_config, spoke, spoke_config, baseline_file, report_dir = sys.argv[1:]
report_dir = Path(report_dir)
started = time.monotonic()
deadline = started + 3000
# Use the replacement node's creation time, not completion of the test: watch
# policies may already have evaluated by then and need not evaluate again.
cutoff = None
passed = False
failure = "Post-replacement policy recovery did not complete."
cgu_status = {}

def oc(config, *args, manifest=None):
    try:
        result = subprocess.run(
            ["oc", "--kubeconfig=" + config, "--request-timeout=30s", *args],
            input=json.dumps(manifest) if manifest is not None else None,
            capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Policy recovery API request timed out.") from None
    if result.returncode:
        raise RuntimeError("Policy recovery API request failed: " + " ".join(args[:2]))
    return json.loads(result.stdout)

def wait_for(description, check, limit=deadline):
    while time.monotonic() < limit:
        if check():
            print(description + ": complete.", flush=True)
            return
        print("Waiting for " + description + ".", flush=True)
        time.sleep(30)
    raise RuntimeError(description + ": timed out.")

def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is not None:
            return parsed
        return datetime.min.replace(tzinfo=timezone.utc)
    except (AttributeError, ValueError):
        return datetime.min.replace(tzinfo=timezone.utc)

def replacement_ready():
    global cutoff
    try:
        nodes = oc(spoke_config, "get", "nodes", "-o", "json")["items"]
    except RuntimeError as error:
        print(str(error), flush=True)
        return False
    if len(nodes) != 1:
        return False
    node = nodes[0]
    if (node["metadata"]["uid"] == original_node_uid or node["metadata"].get("deletionTimestamp") or
            not any(item.get("type") == "Ready" and item.get("status") == "True"
                    for item in node.get("status", {}).get("conditions", []))):
        return False
    cutoff = timestamp(node["metadata"].get("creationTimestamp"))
    if cutoff == datetime.min.replace(tzinfo=timezone.utc):
        raise RuntimeError("Replacement node has no valid creation timestamp.")
    return True

def policy_state():
    try:
        hub = oc(hub_config, "-n", spoke, "get", "policies.policy.open-cluster-management.io", "-o", "json")
        leaf = oc(spoke_config, "get", "configurationpolicies.policy.open-cluster-management.io",
                  "-A", "-o", "json")
    except RuntimeError as error:
        # ACM availability can precede the policy add-on and its CRDs.
        print(str(error), flush=True)
        return False, False
    hub = {item["metadata"]["name"]: item for item in hub["items"]}
    leaf = {(item["metadata"]["namespace"], item["metadata"]["name"]): item for item in leaf["items"]}
    fresh = True
    compliant = True
    for name, templates in baseline.items():
        policy = hub.get(name, {})
        if not policy or policy["metadata"].get("deletionTimestamp"):
            return False, False
        states = []
        for template in templates:
            item = leaf.get((template["namespace"], template["name"]), {})
            status = item.get("status", {})
            state = status.get("compliant")
            if (not item or item["metadata"].get("deletionTimestamp") or
                    status.get("lastEvaluatedGeneration") != item["metadata"]["generation"] or
                    timestamp(status.get("lastEvaluated")) < cutoff or
                    state not in ("Compliant", "NonCompliant")):
                return False, False
            states.append(state)
        expected = "Compliant" if all(state == "Compliant" for state in states) else "NonCompliant"
        fresh = fresh and policy.get("status", {}).get("compliant") == expected
        compliant = compliant and expected == "Compliant"
    # Also reject newly assigned noncompliant policies, beyond the baseline set.
    compliant = compliant and all(item.get("status", {}).get("compliant") == "Compliant"
                                  for item in hub.values())
    return fresh, fresh and compliant

def cgu_completed():
    global cgu_status
    obj = oc(hub_config, "-n", "ztp-install", "get", "clustergroupupgrades.ran.openshift.io",
             cgu_name, "-o", "json")
    if obj["metadata"]["uid"] != cgu_uid:
        raise RuntimeError("Post-IBBF remediation object was replaced.")
    cgu_status = {"name": cgu_name, "uid": cgu_uid,
                  "conditions": obj.get("status", {}).get("conditions", []),
                  "clusters": obj.get("status", {}).get("clusters", [])}
    return any(item.get("type") == "Succeeded" and item.get("status") == "True"
               for item in cgu_status["conditions"])

try:
    saved = json.loads(Path(baseline_file).read_text())
    baseline, original_node_uid = saved["policies"], saved["node_uid"]
    if not original_node_uid or not baseline or any(not templates for templates in baseline.values()):
        raise RuntimeError("Expected policy baseline is empty.")
    (report_dir / "expected-policies.json").write_text(json.dumps(baseline, indent=2))
    # Inform policies must be evaluated on the replacement before TALM reads
    # their status; otherwise old Compliant values can skip needed remediation.
    wait_for("replacement node readiness", replacement_ready, started + 900)
    wait_for("fresh replacement policy evaluations", lambda: policy_state()[0], started + 900)
    obj = oc(hub_config, "create", "-f", "-", "-o", "json", manifest={
        "apiVersion": "ran.openshift.io/v1alpha1", "kind": "ClusterGroupUpgrade",
        "metadata": {"generateName": spoke + "-post-ibbf-", "namespace": "ztp-install"},
        "spec": {
            "clusters": [spoke], "enable": True, "backup": False, "preCaching": False,
            "managedPolicies": ["common-config-policy", "common-subscriptions-policy"],
            "remediationStrategy": {"maxConcurrency": 1, "timeout": 30},
        },
    })
    cgu_name, cgu_uid = obj["metadata"]["name"], obj["metadata"]["uid"]
    print("Created target-only policy remediation: " + cgu_name, flush=True)
    wait_for("post-IBBF TALM remediation", cgu_completed)
    wait_for("target policy compliance", lambda: policy_state()[1])
    passed = True
    print(f"All {len(baseline)} expected target policies are present, freshly evaluated and Compliant.",
          flush=True)
except Exception as error:
    failure = str(error)
finally:
    (report_dir / "post-ibbf-cgu-status.json").write_text(json.dumps(cgu_status, indent=2))
    suite = ET.Element("testsuite", name="IBBF policy recovery", tests="1",
                       failures="0" if passed else "1",
                       time=str(round(time.monotonic() - started, 3)))
    case = ET.SubElement(suite, "testcase", name="target policies compliant after TALM remediation",
                         classname="ibi.ibbf.policy-gate")
    if not passed:
        ET.SubElement(case, "failure", message=failure)
    ET.ElementTree(suite).write(report_dir / "junit_ibbf_policy_gate.xml",
                               encoding="utf-8", xml_declaration=True)
if not passed:
    sys.exit(failure)
PY
}

main() {
  if [[ -f "${SHARED_DIR}/skip.txt" || "${IBI_IBBF_ENABLED:-false}" == false ]]; then
    echo "Skipping IBI IBBF tests."
    return 0
  fi
  [[ "${IBI_IBBF_ENABLED}" == true ]]
  validate_inputs
  restore_target_inventory
  create_work_directories
  trap 'finish "$?"' EXIT
  configure_ssh
  fetch_target_kubeconfig
  prepare_bmc_environment
  prepare_launcher
  run_tests
  verify_hardware_test
  remediate_and_verify_policies
}

main "$@"
