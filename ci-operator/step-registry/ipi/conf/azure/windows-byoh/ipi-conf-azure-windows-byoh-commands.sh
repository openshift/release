# ci-operator/step-registry/ipi/conf/azure/windows-byoh/ipi-conf-azure-windows-byoh-commands.sh
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Wait for WMCO to be up and running
oc wait deployment windows-machine-config-operator -n openshift-windows-machine-config-operator --for condition=Available=True --timeout=5m

# Ensure userDataSecret exists
timeout 3m bash -c 'until oc -n openshift-machine-api get secret "${WINDOWS_USER_DATA_SECRET}" 2> /dev/null; do echo -n "." && sleep 15; done'

# Get reference machineset name
ref_machineset_name=$(oc -n openshift-machine-api get -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' machinesets | grep worker | head -n1)
winworker_machineset_name="windows"
export ref_machineset_name winworker_machineset_name

# Create Windows MachineSets
echo "Creating Windows MachineSets..."
oc get machineset "${ref_machineset_name}" -n openshift-machine-api -o json |
  jq --arg winworker_machineset_name "${winworker_machineset_name}" \
     --arg win_os_id "${WINDOWS_OS_ID}" \
     --arg user_data_secret "${WINDOWS_USER_DATA_SECRET}" \
     '
      .metadata.name = $winworker_machineset_name |
      .spec.replicas = 0 |
      .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $winworker_machineset_name |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $winworker_machineset_name |
      .spec.template.metadata.labels."machine.openshift.io/exclude-node-draining" = "" |
      .spec.template.metadata.labels."machine.openshift.io/os-id" = "Windows" |
      .spec.template.spec.metadata.labels."node-role.kubernetes.io/worker" = "" |
      .spec.template.spec.providerSpec.value.disks[0].image = $win_os_id |
      .spec.template.spec.providerSpec.value.machineType = $instance_type |
      .spec.template.spec.providerSpec.value.userDataSecret.name = $user_data_secret |
      del(.status) |
      del(.metadata.selfLink) |
      del(.metadata.uid)
     ' | oc create -f -

# Scale Windows MachineSets
echo "Scaling Windows MachineSets to ${WINDOWS_NODE_REPLICAS} replicas..."
oc -n openshift-machine-api scale machineset/"${winworker_machineset_name}" --replicas="${WINDOWS_NODE_REPLICAS}"

# Setup BYOH nodes
echo "Setting up Windows BYOH nodes..."

# Configure BYOH parameters
BYOH_NAME="${BYOH_INSTANCE_NAME:-byoh-winc}"
BYOH_COUNT="${BYOH_NODE_COUNT:-2}"
WIN_VERSION="${WINDOWS_VERSION:-2022}"

# Execute byoh-auto
echo "Creating ${BYOH_COUNT} BYOH nodes using byoh-auto..."
pushd "${SHARED_DIR}/ci-operator/config/openshift/byoh"
./byoh.sh apply "${BYOH_NAME}" "${BYOH_COUNT}" '' "${WIN_VERSION}" || {
    echo "ERROR: Failed to create Windows BYOH nodes"
    exit 1
}
popd

# Wait for all Windows nodes to be ready
echo "Waiting for all Windows nodes (MachineSets and BYOH) to be ready..."
timeout 20m bash -c 'until oc get nodes -l kubernetes.io/os=windows | grep -q "Ready"; do 
    echo "Current Windows nodes status:"
    oc get nodes -l kubernetes.io/os=windows
    sleep 30
done'

