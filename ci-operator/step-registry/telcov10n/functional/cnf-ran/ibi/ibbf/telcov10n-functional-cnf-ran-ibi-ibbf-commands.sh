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
      "rm -f -- '${BMC_ENV_FILE}' '${SPOKE_KUBECONFIG}'" \
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
      "labels": "ibbf-end-to-end",
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
    "${IBI_IBBF_TARGET_IP}" "${BMC_ENV_FILE}" <<'PY' \
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

kubeconfig, spoke, version, original, replacement, target_ip, env_file = sys.argv[1:]
for address in (original, replacement, target_ip):
    ipaddress.IPv4Address(address)

def get(resource, name, namespace):
    return json.loads(subprocess.check_output([
        "oc", "--kubeconfig=" + kubeconfig, "-n", namespace,
        "get", resource, name, "-o", "json",
    ]))

def require(condition, message):
    if not condition:
        sys.exit(message)

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
        "ECO_CNF_RAN_ACM_OPERATOR_NAMESPACE": "open-cluster-management",
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
policy = [case for case in cases if "verifies policies are compliant after IBBF" in case.get("name", "")]
if not policy or any(case.find("skipped") is not None for case in policy):
    print("Image policy spec skipped/missing; the separate policy gate will provide this check.")
PY
}

wait_for_policies() {
  # Some original images skip the second spec after changing the Argo path.
  # Keep that Ginkgo result intact and record this independent check separately.
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    python3 - "${HUB_CONFIG_DIR}/auth/kubeconfig" "${TARGET_SPOKE_NAME}" \
    "${WORK_DIR}/report/junit_ibbf_policy_gate.xml" <<'PY' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/policy-gate.log"
import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

kubeconfig, spoke, report = sys.argv[1:]
started = time.monotonic()
passed = False
try:
    while time.monotonic() - started < 1800:
        result = subprocess.run([
            "oc", "--kubeconfig=" + kubeconfig, "--request-timeout=30s",
            "-n", spoke, "get", "policies.policy.open-cluster-management.io", "-o", "json",
        ], capture_output=True, text=True, timeout=45)
        if result.returncode != 0:
            sys.exit("Cannot read target policies.")
        policies = json.loads(result.stdout)["items"]
        pending = [item["metadata"]["name"] for item in policies
                   if item.get("status", {}).get("compliant") != "Compliant"]
        if policies and not pending:
            passed = True
            print(f"All {len(policies)} target policies are Compliant.", flush=True)
            break
        print(f"Waiting for target policies: {len(policies)} present, {len(pending)} not Compliant.",
              flush=True)
        time.sleep(30)
finally:
    suite = ET.Element("testsuite", name="IBBF supplemental policy gate", tests="1",
                       failures="0" if passed else "1",
                       time=str(round(time.monotonic() - started, 3)))
    case = ET.SubElement(suite, "testcase", name="target policies compliant after replacement",
                         classname="ibi.ibbf.policy-gate")
    if not passed:
        ET.SubElement(case, "failure", message="Target policy compliance was not confirmed.")
    ET.ElementTree(suite).write(report, encoding="utf-8", xml_declaration=True)
if not passed:
    sys.exit("Target policies did not become Compliant within 30 minutes.")
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
  wait_for_policies
}



main "$@"
