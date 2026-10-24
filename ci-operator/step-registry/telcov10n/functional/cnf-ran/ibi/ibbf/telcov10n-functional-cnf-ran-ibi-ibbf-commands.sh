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
  : "${IBI_IBBF_TARGET_IP:?Static target IP address is required}"
  [[ "${IBI_REPLACEMENT_PREINSTALL_ENABLED}" == true ]]
  [[ "${IBI_IBBF_ORIGINAL_BMC_HOST}" != "${IBI_IBBF_REPLACEMENT_BMC_HOST}" ]]
  [[ "${IBI_IBBF_ORIGINAL_BMC_HOST}" =~ ^[0-9.]+$ ]]
  [[ "${IBI_IBBF_REPLACEMENT_BMC_HOST}" =~ ^[0-9.]+$ ]]
  [[ "${IBI_IBBF_TARGET_IP}" =~ ^[0-9a-fA-F:.]+$ ]]
  python3 - "${IBI_IBBF_ORIGINAL_BMC_HOST}" "${IBI_IBBF_REPLACEMENT_BMC_HOST}" "${IBI_IBBF_TARGET_IP}" <<'PY'
import ipaddress
import sys

ipaddress.IPv4Address(sys.argv[1])
ipaddress.IPv4Address(sys.argv[2])
ipaddress.ip_address(sys.argv[3])
PY
  [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]
  TARGET_SPOKE_NAME=$(printf '%s' "${TARGET_SPOKE_CLUSTER}" | tr -d "[]'\" ")
  [[ "${TARGET_CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  [[ "${TARGET_SPOKE_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  REPLACEMENT_POLICY_PATH=${IBI_IBBF_REPLACEMENT_POLICY_PATH:-}
  POLICY_REVISION=none
  POLICY_REPO=none
  if [[ -n "${REPLACEMENT_POLICY_PATH}" ]]; then
    [[ "${REPLACEMENT_POLICY_PATH}" == "${VERSION}/${TARGET_SPOKE_NAME}/policygentemplate/ztp-test/ibbf-test" ]]
    POLICY_REPO=${ZTP_GIT_REPO:?ZTP_GIT_REPO is required for replacement policies}
    [[ "${POLICY_REPO}" =~ ^https://[a-zA-Z0-9./:_-]+$ ]]
    POLICY_REVISION=$(<"${SHARED_DIR}/ibi-seed-git-revision")
    [[ "${POLICY_REVISION}" =~ ^[a-f0-9]{40}$ ]]
  fi
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
  printf '%s\n' "${WORK_DIR}/report" > "${SHARED_DIR}/ibi-rp-ibbf-dir"
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

verify_policy_fixture() {
  [[ -n "${REPLACEMENT_POLICY_PATH}" ]] || return 0
  # Check real YAML at the seed's immutable revision, not a HEAD response that
  # could be a GitLab login page. PyYAML is supplied by the Ansible runner.
  python3 - "${POLICY_REPO}" "${POLICY_REVISION}" "${REPLACEMENT_POLICY_PATH}" <<'PY' \
    2>&1 | tee "${REPORT_DIR}/policy-fixture.log"
import ssl
import sys
import urllib.error
import urllib.request
import yaml

repo, revision, replacement_path = sys.argv[1:]
base_path = replacement_path.removesuffix("/ztp-test/ibbf-test")

# Match the IBI mirror step's GitLab TLS workaround without changing global trust.
# This context is used only for the policy fixture requests below.
context = ssl._create_unverified_context()
read_count = 0

def read(path):
    global read_count
    try:
        url = repo.removesuffix(".git") + "/-/raw/" + revision + "/" + path
        with urllib.request.urlopen(url, timeout=60, context=context) as response:
            result = yaml.safe_load(response.read())
        if not isinstance(result, dict):
            sys.exit("Policy fixture is not a YAML mapping: " + path)
        read_count += 1
        print("Parsed policy fixture: " + path, flush=True)
        return result
    except urllib.error.HTTPError as error:
        sys.exit(f"Policy fixture {path}: HTTP {error.code}")
    except urllib.error.URLError as error:
        sys.exit(f"Policy fixture {path}: transport error ({type(error.reason).__name__})")
    except (ssl.SSLError, TimeoutError) as error:
        sys.exit(f"Policy fixture {path}: {type(error).__name__}")
    except yaml.YAMLError:
        sys.exit("Policy fixture contains invalid YAML: " + path)
    except Exception as error:
        sys.exit(f"Policy fixture {path}: {type(error).__name__}")

def policies(path):
    kustomization = read(path + "/kustomization.yaml")
    generators = kustomization.get("generators", [])
    if not generators or kustomization.get("patches") or kustomization.get("components"):
        sys.exit("Expected standalone PolicyGenTemplate generators in the policy fixture.")
    result = {}
    for filename in generators:
        if not isinstance(filename, str) or "/" in filename or not filename.endswith(".yaml"):
            sys.exit("Unexpected policy generator path.")
        template = read(path + "/" + filename)
        if template.get("kind") != "PolicyGenTemplate":
            sys.exit("Expected PolicyGenTemplate in the policy fixture.")
        metadata = template["metadata"]
        for source in template["spec"]["sourceFiles"]:
            name = metadata["namespace"] + "." + metadata["name"] + "-" + source["policyName"]
            result.setdefault(name, []).append(source)
    return result

original, replacement = policies(base_path), policies(replacement_path)
if original.keys() != replacement.keys():
    sys.exit("Replacement policies must preserve all original policy identities.")
spoke = base_path.split("/")[1]
for name in ("ztp-group.group-du-sno-config-policy", "ztp-site." + spoke + "-config-policy"):
    if name not in replacement or original[name] == replacement[name]:
        sys.exit("Replacement fixture must contain the changed group and site hardware policies.")
print(f"Successfully downloaded and parsed {read_count} policy fixture files.")
print("Original and replacement policy fixtures have matching identities and changed hardware settings.")
print("Policy rendering and synchronization will be checked by Argo CD during handover.")
PY
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
    "${IBI_IBBF_TARGET_IP}" "${BMC_ENV_FILE}" "${SPOKE_KUBECONFIG}" "${POLICY_BASELINE}" \
    "${REPLACEMENT_POLICY_PATH:-none}" "${POLICY_REPO}" "${POLICY_REVISION}" <<'PY' \
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

(kubeconfig, spoke, version, original, replacement, target_ip, env_file, spoke_config,
 baseline_file, policy_path, policy_repo, policy_revision) = sys.argv[1:]
policy_handoff = policy_path != "none"
os.umask(0o077)
for address in (original, replacement):
    ipaddress.IPv4Address(address)
target_address = ipaddress.ip_address(target_ip)

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
roots = [("ztp-common", "common-config-policy"), ("ztp-common", "common-subscriptions-policy")]
if policy_handoff:
    roots.extend([("ztp-group", "group-du-sno-config-policy"), ("ztp-site", spoke + "-config-policy")])
root_templates = {}
for namespace, name in roots:
    replica_name = namespace + "." + name
    replica = next((item for item in policies if item["metadata"]["name"] == replica_name), {})
    require(replica.get("metadata", {}).get("labels", {}).get("policy.open-cluster-management.io/root-policy")
            == replica_name, "Expected remediation policy is not assigned to the target.")
    root_templates[replica_name] = get("policies.policy.open-cluster-management.io", name, namespace)["spec"]["policy-templates"]
original_cgu = get("clustergroupupgrades.ran.openshift.io", spoke, "ztp-install")
require(any(condition.get("type") == "Succeeded" and condition.get("status") == "True"
            for condition in original_cgu.get("status", {}).get("conditions", [])),
        "Initial target policy remediation has not completed.")
original_nodes = listing("nodes", spoke_config)
require(len(original_nodes) == 1 and original_nodes[0]["metadata"].get("uid"),
        "Expected one original target node with a UID.")
for name, suffix in (("clusters", "clusterinstance"), ("policies", "policygentemplate")):
    app = get("applications.argoproj.io", name, "openshift-gitops")
    require(app["spec"].get("source", {}).get("path") == f"{version}/{spoke}/{suffix}",
            "Argo application is not on the original target path.")
    require(not app.get("operation") and
            app.get("status", {}).get("operationState", {}).get("phase") not in ("Running", "Terminating") and
            app.get("status", {}).get("sync", {}).get("status") == "Synced",
            "Argo application is not idle and synced.")
    if policy_handoff:
        require(app["spec"]["source"].get("repoURL") == policy_repo and
                app["status"]["sync"].get("revision") == policy_revision,
                "Target applications must match the fork and recorded seed Git revision.")
    if name == "policies":
        policy_app = {"uid": app["metadata"]["uid"], "source": app["spec"]["source"]}
        if policy_handoff:
            automated = app["spec"].get("syncPolicy", {}).get("automated")
            require(isinstance(automated, dict) and automated.get("enabled") is not False,
                    "Replacement policy handoff requires automated Argo synchronization.")

ci = get("clusterinstances.siteconfig.open-cluster-management.io", spoke, spoke)
require(not ci["spec"].get("reinstall"), "Target already has a reinstall request; use a fresh workflow run.")
nodes = ci["spec"]["nodes"]
require(len(nodes) == 1, "IBBF requires exactly one target node.")
node = nodes[0]
interfaces = node["nodeNetwork"]["config"]["interfaces"]
family = "ipv" + str(target_address.version)
require(any(interface.get(family, {}).get("enabled", True) and
            interface.get(family, {}).get("dhcp") is False and
            (family != "ipv6" or interface[family].get("autoconf") is False) and
            any(ipaddress.ip_address(item["ip"]) == target_address
                for item in interface.get(family, {}).get("address", []))
            for interface in interfaces), "Target must already use the reserved static IP address.")

bmh = get("baremetalhosts.metal3.io", node["hostName"], spoke)
endpoint = urllib.parse.urlparse(bmh["spec"]["bmc"]["address"])
require(endpoint.hostname == original, "Original BMC does not match the target BareMetalHost.")
require(urllib.parse.urlparse(node["bmcAddress"]).hostname == original,
        "Original BMC does not match the ClusterInstance.")
secret_name = bmh["spec"]["bmc"]["credentialsName"]
require(secret_name == node["bmcCredentialsName"]["name"], "BMC secret references differ.")
with open(baseline_file, "w") as output:
    json.dump({"node_uid": original_nodes[0]["metadata"]["uid"], "policies": baseline,
               "roots": roots, "root_templates": root_templates, "policy_app": policy_app,
               "policy_path": policy_path, "policy_revision": policy_revision,
               "original_bmc": original, "replacement_bmc": replacement,
               "bmc_secret": secret_name}, output)
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
import base64
import json
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request
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
expected_templates = {}
expected_source = None

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

def wait_for(description, check, limit=None):
    limit = deadline if limit is None else min(deadline, limit)
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

def verify_handover():
    ci = oc(hub_config, "-n", spoke, "get", "clusterinstances.siteconfig.open-cluster-management.io",
            spoke, "-o", "json")
    nodes = ci["spec"]["nodes"]
    if len(nodes) != 1 or urllib.parse.urlparse(nodes[0]["bmcAddress"]).hostname != saved["replacement_bmc"]:
        raise RuntimeError("ClusterInstance does not reference the replacement BMC.")
    bmh = oc(hub_config, "-n", spoke, "get", "baremetalhosts.metal3.io", nodes[0]["hostName"], "-o", "json")
    if (bmh["metadata"].get("deletionTimestamp") or
            urllib.parse.urlparse(bmh["spec"]["bmc"]["address"]).hostname != saved["replacement_bmc"]):
        raise RuntimeError("BareMetalHost does not reference the replacement BMC.")
    secret = oc(hub_config, "-n", spoke, "get", "secret", saved["bmc_secret"], "-o", "json")["data"]
    credentials = b":".join(base64.b64decode(secret[key]) for key in ("username", "password"))
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    for host, expected in ((saved["original_bmc"], "Off"), (saved["replacement_bmc"], "On")):
        request = urllib.request.Request(
            f"https://{host}/redfish/v1/Systems/System.Embedded.1",
            headers={"Authorization": "Basic " + base64.b64encode(credentials).decode()})
        try:
            with opener.open(request, timeout=30) as response:
                if json.load(response).get("PowerState") != expected:
                    raise ValueError("Unexpected power state")
        except Exception:
            raise RuntimeError("Original fencing and replacement power state could not be verified.") from None

def policy_application_synced():
    app = oc(hub_config, "-n", "openshift-gitops", "get", "applications.argoproj.io", "policies", "-o", "json")
    if app["metadata"].get("deletionTimestamp") or app["metadata"]["uid"] != saved["policy_app"]["uid"]:
        raise RuntimeError("Policies Application was deleted or replaced.")
    if app["spec"].get("source") != expected_source:
        raise RuntimeError("Policies Application source changed during handover.")
    status = app.get("status", {})
    if any(item.get("type") in ("ComparisonError", "InvalidSpecError", "SyncError")
           for item in status.get("conditions", [])):
        raise RuntimeError("Argo CD could not render or sync the replacement policies.")
    sync = status.get("sync", {})
    operation = status.get("operationState", {})
    result = operation.get("syncResult", {})
    return (not app.get("operation") and sync.get("status") == "Synced" and
            sync.get("revision") == saved["policy_revision"] and
            sync.get("comparedTo", {}).get("source") == expected_source and
            operation.get("phase") == "Succeeded" and
            result.get("revision") == saved["policy_revision"] and result.get("source") == expected_source)

def definitions(templates):
    result = {}
    for template in templates:
        obj = template["objectDefinition"]
        if obj.get("kind") != "ConfigurationPolicy" or "{{hub" in json.dumps(obj):
            raise RuntimeError("Replacement policy gate requires ConfigurationPolicies without hub templates.")
        name = obj["metadata"]["name"]
        if name in result:
            raise RuntimeError("Duplicate ConfigurationPolicy template name.")
        result[name] = obj["spec"]
    if not result:
        raise RuntimeError("Replacement policy has no ConfigurationPolicy templates.")
    return result

def matches_spec(actual, expected):
    def normalized(spec):
        result = dict(spec)
        if "object-templates" in result:
            # This typed envelope field defaults on the spoke ConfigurationPolicy.
            # Keep explicit values and the opaque objectDefinition payload intact.
            result["object-templates"] = [
                dict(template, recreateOption=template.get("recreateOption", "None"))
                for template in result["object-templates"]
            ]
        return result

    actual, expected = normalized(actual), normalized(expected)
    # Preserve the existing top-level defaults and TALM remediationAction handling.
    return all(actual.get(key) == value for key, value in expected.items() if key != "remediationAction")

def activate_replacement_policies():
    global expected_source
    verify_handover()
    expected_source = dict(saved["policy_app"]["source"], path=saved["policy_path"],
                           targetRevision=saved["policy_revision"])
    # JSON Patch tests prevent overwriting a concurrent source or Application change.
    oc(hub_config, "-n", "openshift-gitops", "patch", "applications.argoproj.io", "policies",
       "--type=json", "--patch-file=/dev/stdin", "-o", "json", manifest=[
           {"op": "test", "path": "/metadata/uid", "value": saved["policy_app"]["uid"]},
           {"op": "test", "path": "/spec/source", "value": saved["policy_app"]["source"]},
           {"op": "replace", "path": "/spec/source", "value": expected_source},
       ])
    wait_for("replacement policy Application synchronization", policy_application_synced,
             min(deadline, time.monotonic() + 600))
    for namespace, name in saved["roots"]:
        root = oc(hub_config, "-n", namespace, "get", "policies.policy.open-cluster-management.io",
                  name, "-o", "json")
        key = namespace + "." + name
        templates = definitions(root["spec"]["policy-templates"])
        if set(templates) != {item["name"] for item in baseline[key]}:
            raise RuntimeError("Replacement ConfigurationPolicy identities changed.")
        if namespace in ("ztp-group", "ztp-site") and templates == definitions(saved["root_templates"][key]):
            raise RuntimeError("Hardware policy specification did not change after Argo synchronization.")
        expected_templates[key] = templates

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
    if expected_source is not None and not policy_application_synced():
        return False, False
    for name, templates in baseline.items():
        policy = hub.get(name, {})
        if not policy or policy["metadata"].get("deletionTimestamp"):
            return False, False
        if name in expected_templates:
            replicated = definitions(policy["spec"]["policy-templates"])
            expected = expected_templates[name]
            if replicated.keys() != expected.keys() or any(
                    not matches_spec(replicated[key], value) for key, value in expected.items()):
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
            if name in expected_templates and not matches_spec(
                    item.get("spec", {}), expected_templates[name][template["name"]]):
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
    # Allow handoff/propagation time without taking away TALM's 30-minute
    # remediation budget. Jobs without a policy switch keep the old 50 minutes.
    if saved["policy_path"] != "none":
        deadline = started + 4500
    baseline, original_node_uid = saved["policies"], saved["node_uid"]
    if not original_node_uid or not baseline or any(not templates for templates in baseline.values()):
        raise RuntimeError("Expected policy baseline is empty.")
    (report_dir / "expected-policies.json").write_text(json.dumps(baseline, indent=2))
    # Inform policies must be evaluated on the replacement before TALM reads
    # their status; otherwise old Compliant values can skip needed remediation.
    wait_for("replacement node readiness", replacement_ready, started + 900)
    if saved["policy_path"] != "none":
        activate_replacement_policies()
    wait_for("fresh replacement policy specifications and evaluations", lambda: policy_state()[0],
             min(deadline, time.monotonic() + 900))
    obj = oc(hub_config, "create", "-f", "-", "-o", "json", manifest={
        "apiVersion": "ran.openshift.io/v1alpha1", "kind": "ClusterGroupUpgrade",
        "metadata": {"generateName": spoke + "-post-ibbf-", "namespace": "ztp-install"},
        "spec": {
            "clusters": [spoke], "enable": True, "backup": False, "preCaching": False,
            "managedPolicies": [name for _, name in saved["roots"]],
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
  verify_policy_fixture
  prepare_bmc_environment
  prepare_launcher
  run_tests
  verify_hardware_test
  remediate_and_verify_policies
}

main "$@"
