#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        fi
        local content
        content=$(cat "$filename")
        local varname
        varname=$(basename "${filename}")
        # Check if content has newlines - if so, use literal block scalar (|)
        if [[ "$content" == *$'\n'* ]]; then
          echo "${varname}: |"
          echo "$content" | sed 's/^/  /'
        else
          echo "${varname}: '${content//\'/\'\'}'"
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}

OCP_DEPLOYMENT_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
CNF_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
MOUNTED_SPOKE_INVENTORY="/var/host_variables/${TARGET_CLUSTER_NAME}/spoke-master0"

echo "=== IBU Upgrade eco-gotests Configuration ==="
echo "TARGET_CLUSTER_NAME=${TARGET_CLUSTER_NAME}"
echo "TARGET_SPOKE_SNO=${TARGET_SPOKE_SNO}"
echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"
echo "VERSION=${VERSION}"
if [[ ! -s "${SHARED_DIR}/cluster_version" ]]; then
  echo "Error: seed hub cluster version file not found: '${SHARED_DIR}/cluster_version'" >&2
  exit 1
fi
SEED_IMAGE_VERSION="$(cat "${SHARED_DIR}/cluster_version")"
echo "Seed image version=${SEED_IMAGE_VERSION}"
echo ""

# Copy target hub inventory from SHARED_DIR (target-* prefixed files saved by ibu-target-hub-deploy)
echo "=== Copying target hub inventory from SHARED_DIR ==="

mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars"
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/target-all"        "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/target-bastions"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/bastions"
cp "${SHARED_DIR}/target-hypervisors" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/hypervisors"
cp "${SHARED_DIR}/target-nodes"      "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/nodes"
cp "${SHARED_DIR}/target-masters"    "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/masters"
cp "${SHARED_DIR}/target-bastion"    "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/bastion"
cp "${SHARED_DIR}/target-hypervisor" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/hypervisor"
cp "${SHARED_DIR}/target-master0"    "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master0"

mkdir -p "${CNF_INVENTORY_PATH}/group_vars"
mkdir -p "${CNF_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/target-bastions"   "${CNF_INVENTORY_PATH}/group_vars/bastions.yaml"
cp "${SHARED_DIR}/target-all"        "${CNF_INVENTORY_PATH}/group_vars/all.yaml"
cp "${SHARED_DIR}/target-bastion"    "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml"

echo "Processing target spoke SNO inventory with proper multi-line SSH key handling"
process_inventory "${MOUNTED_SPOKE_INVENTORY}" "${CNF_INVENTORY_PATH}/host_vars/master-0.yaml"
process_inventory "${MOUNTED_SPOKE_INVENTORY}" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master-0"

echo "Target hub inventory copied from SHARED_DIR and spoke inventory processed"

# Host directory mounted into the eco-gotests container at /clusterconfigs.
TARGET_HUB_CLUSTERCONFIGS_PATH="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}"
TARGET_HUB_KUBECONFIG="/clusterconfigs/auth/kubeconfig"

echo ""
echo "=== Step 1: Prepare IBU target SNO and retrieve kubeconfig ==="

cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${TARGET_CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${TARGET_SPOKE_SNO}"

echo ""
echo "=== Step 2: Run eco-gotests IBU upgrade suite ==="
TARGET_SPOKE_KUBECONFIG="/tmp/${TARGET_SPOKE_SNO}-kubeconfig"

# Build eco-gotests environment variables
ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE_VERSION=${SEED_IMAGE_VERSION}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_ODAP_CM_NAME=oadp-cm"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_ODAP_CM_NAMESPACE=ztp-group"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KCAT_BROKER=vran-qe-kafka.kni-qe-11.telcoqe.eng.rdu2.dc.redhat.com:9092"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_HUB=${TARGET_HUB_KUBECONFIG}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=/kubeconfig/kubeconfig"
ECO_GOTESTS_ENV_VARS+=" -e ECO_TEST_TRACE=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_VERBOSE_SCRIPT=true"

ansible-playbook playbooks/deploy-run-eco-gotests.yaml \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  --extra-vars "kubeconfig=${TARGET_SPOKE_KUBECONFIG}" \
  --extra-vars "features=${ECO_GOTESTS_FEATURES}" \
  --extra-vars '{"labels": "\"!no-container&&(!ValidateSeedReferences)\""}' \
  --extra-vars 'eco_worker_label=""' \
  --extra-vars 'eco_cnf_core_net_switch_user=""' \
  --extra-vars 'eco_cnf_core_net_switch_pass=""' \
  --extra-vars 'eco_gotests_tag=latest' \
  --extra-vars "hub_clusterconfigs_path=${TARGET_HUB_CLUSTERCONFIGS_PATH}" \
  --extra-vars "additional_test_env_variables=\"${ECO_GOTESTS_ENV_VARS}\""

echo "Set bastion SSH configuration"
PROJECT_DIR="/tmp"
trap 'rm -f "${PROJECT_DIR}/temp_ssh_key"' EXIT
grep ansible_ssh_private_key -A 100 "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed "s/'//g")

echo "Check OADP prerequisites and run eco-gotests via SSH tunnel"
REMOTE_DIAGNOSTICS="/tmp/ibu-upgrade-diagnostics-${BUILD_ID:-manual}-$$"
printf -v REMOTE_COMMAND 'bash -s -- %q %q %q' \
  "${TARGET_HUB_CLUSTERCONFIGS_PATH}/auth/kubeconfig" "${TARGET_SPOKE_KUBECONFIG}" "${REMOTE_DIAGNOSTICS}"
TEST_EXIT_CODE=0
if ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${BASTION_USER}@${BASTION_IP}" -i "${PROJECT_DIR}/temp_ssh_key" \
  "${REMOTE_COMMAND}" <<'REMOTE_SCRIPT'
set -euo pipefail
cd /tmp/eco_gotests
SPOKE_OC=(oc --kubeconfig "$2" --request-timeout=30s)
DIAGNOSTICS=$3
mkdir -m 700 "${DIAGNOSTICS}"

# TALM only copies the ConfigMap when its namespace already exists on the spoke.
"${SPOKE_OC[@]}" get namespace ztp-group -o name
"${SPOKE_OC[@]}" -n openshift-adp get dataprotectionapplications.oadp.openshift.io \
  dataprotectionapplication -o json > "${DIAGNOSTICS}/dpa-preflight.json"
if ! jq -e 'any(.status.conditions[]?; .type == "Reconciled" and .status == "True")' \
  "${DIAGNOSTICS}/dpa-preflight.json" > /dev/null; then
  echo "Target DPA is not Reconciled=True" >&2
  exit 1
fi
"${SPOKE_OC[@]}" -n openshift-adp get backupstoragelocations.velero.io \
  dataprotectionapplication-1 -o json > "${DIAGNOSTICS}/bsl-preflight.json"
if ! jq -e '.status.phase == "Available"' "${DIAGNOSTICS}/bsl-preflight.json" > /dev/null; then
  echo "Target BackupStorageLocation dataprotectionapplication-1 is not Available" >&2
  exit 1
fi
# Client dry-run decodes YAML without creating any Backup or Restore objects.
oc --kubeconfig "$1" --request-timeout=30s -n ztp-group get configmap oadp-cm -o json |
  jq -er '[.data[]] | join("\n---\n")' |
  "${SPOKE_OC[@]}" create --dry-run=client --validate=false -f - -o json |
  jq -s '[.[] | if .kind == "List" then .items[] else . end]' > "${DIAGNOSTICS}/backup-manifests.json"
if ! jq -e --arg bsl dataprotectionapplication-1 '
  any(.[]; .kind == "Backup") and
  all(.[] | select(.kind == "Backup" or .kind == "Restore");
    .metadata.namespace == "openshift-adp" and
    .metadata.labels["velero.io/storage-location"] == $bsl and
    (if .kind == "Backup" then .spec.storageLocation == $bsl else true end))
' "${DIAGNOSTICS}/backup-manifests.json" > /dev/null; then
  echo "Hub oadp-cm must use openshift-adp and storage location dataprotectionapplication-1" >&2
  exit 1
fi
echo "OADP preflight passed"

# Save events and logs before test recovery deletes evidence; reconnect after API outages.
collect() {
  local name=$1 child
  shift
  trap - EXIT
  trap 'kill "${child}" 2>/dev/null || true; wait "${child}" 2>/dev/null || true; exit 0' TERM INT HUP
  while true; do
    "$@" >> "${DIAGNOSTICS}/${name}.log" 2>&1 &
    child=$!
    wait "${child}" || true
    sleep 5 &
    child=$!
    wait "${child}" || true
  done
}
collector_pids=()
stop_collectors() {
  kill "${collector_pids[@]}" 2>/dev/null || true
  wait "${collector_pids[@]}" 2>/dev/null || true
}
trap stop_collectors EXIT
for resource in backups.velero.io restores.velero.io backupstoragelocations.velero.io \
  deletebackuprequests.velero.io dataprotectionapplications.oadp.openshift.io; do
  collect "${resource}" "${SPOKE_OC[@]}" -n openshift-adp get "${resource}" \
    --watch --output-watch-events -o json &
  collector_pids+=("$!")
done
collect ibu "${SPOKE_OC[@]}" get imagebasedupgrades.lca.openshift.io --watch --output-watch-events -o json &
collector_pids+=("$!")
for namespace in openshift-adp openshift-lifecycle-agent; do
  while read -r deployment; do
    collect "${deployment}" "${SPOKE_OC[@]}" -n "${namespace}" logs "deployment/${deployment}" \
      --all-containers=true --prefix=true --timestamps=true --since=2m --follow=true &
    collector_pids+=("$!")
  done < <("${SPOKE_OC[@]}" -n "${namespace}" get deployments -o json \
    2>> "${DIAGNOSTICS}/collector-errors.log" |
    jq -r '.items[].metadata.name | select(. == "velero" or contains("lifecycle-agent"))')
done
./eco-gotests-run.sh
REMOTE_SCRIPT
then
  echo "IBU upgrade suite completed successfully"
else
  TEST_EXIT_CODE=$?
  echo "IBU upgrade execution failed with exit code ${TEST_EXIT_CODE}; collecting reports" >&2
fi

echo "Gather artifacts from bastion"
ARTIFACT_EXIT_CODE=0
mkdir -p "${ARTIFACT_DIR}/ibu-upgrade-diagnostics"
if ! scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}:${REMOTE_DIAGNOSTICS}/." \
  "${ARTIFACT_DIR}/ibu-upgrade-diagnostics/"; then
  echo "Failed to collect IBU upgrade diagnostics" >&2
  ARTIFACT_EXIT_CODE=1
fi
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests_upgrade"
if ! scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests/report/*.xml" \
  "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/"; then
  echo "Failed to collect IBU upgrade XML reports" >&2
  ARTIFACT_EXIT_CODE=1
fi
if ! compgen -G "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/*suite_test_junit.xml" > /dev/null; then
  echo "Missing IBU upgrade suite JUnit report" >&2
  ARTIFACT_EXIT_CODE=1
fi

# ibu-report sends polarion_* files to Report Portal (POLARION_REPORT_PATH)
# and junit_* files to the Polarion converter (JUNIT_REPORT_PATH).
echo "Store Polarion and junit reports for reporter step"
for f in "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/"*suite_test_junit.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying polarion report: ${filename} -> polarion_ibu_upgrade_${filename}"
    cp "$f" "${SHARED_DIR}/polarion_ibu_upgrade_${filename}"
  fi
done
for f in "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/"*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying junit report: ${filename} -> junit_ibu_upgrade_${filename}"
    cp "$f" "${SHARED_DIR}/junit_ibu_upgrade_${filename}"
  fi
done

echo ""
echo "=== IBU Upgrade Eco-Gotests Complete ==="
echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
echo "Seed image OCP version: ${SEED_IMAGE_VERSION}"

# Preserve the test failure after saving reports for the post-phase reporter.
if [[ "${TEST_EXIT_CODE}" -ne 0 ]]; then
  exit "${TEST_EXIT_CODE}"
fi
exit "${ARTIFACT_EXIT_CODE}"
