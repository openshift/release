#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
function wait_for_nodes_readiness()
{
  local expected_nodes=${1}
  local max_retries=${2:-10}
  local period=${3:-5}
  for i in $(seq 1 "${max_retries}") max; do
    if [ "${i}" == "max" ]; then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      return 1
    fi
    sleep "${period}m"
    ready_nodes=$(get_ready_nodes_count)
    if [ x"${ready_nodes}" == x"${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

# Make sure yq-v4 is installed
if [ ! -f /tmp/yq-v4 ]; then
  # TODO move to image
  curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
fi
PATH=${PATH}:/tmp

echo "Fetching Worker MachineSet..."

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

EXPECTED_NODES=$(( $(get_ready_nodes_count) + ADDITIONAL_WORKERS ))

#there will be two kind of machinesets when cluster-api is enabled, using full name to get the correct machinesets
MACHINE_SET=$(oc -n openshift-machine-api get -o yaml machinesets.machine.openshift.io | yq-v4 "$(cat <<EOF
  [.items[] | select(.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] == "worker")][0]
  | .metadata.name += "-additional"
  | .spec.replicas = ${ADDITIONAL_WORKERS}
  | .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = .metadata.name
  | .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = .metadata.name
  | del(.status) | del(.metadata.creationTimestamp) | del(.metadata.uid) | del(.metadata.resourceVersion)
  | del(.metadata.generation)
EOF
)")

echo "Cluster type is ${CLUSTER_TYPE}"
# AMI for AWS ARM
case $CLUSTER_TYPE in
*aws*)
  echo "Extracting AMI..."
  REGION=${LEASED_RESOURCE}
  amiid_workers_additional=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml | \
    yq-v4 ".data.stream
      | eval(.).architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.images.aws.regions.\"${REGION}\".image")

  echo "Updating the machineset with ${ADDITIONAL_WORKER_VM_TYPE} and ami ${amiid_workers_additional} ..."

  MACHINE_SET=$(yq-v4 ".spec.template.spec.providerSpec.value.ami.id = \"${amiid_workers_additional}\"
                     | .spec.template.spec.providerSpec.value.instanceType = \"${ADDITIONAL_WORKER_VM_TYPE}\"
              " <<< "${MACHINE_SET}")
;;
*azure*)
  echo "az version:"
  az version
  azure_auth_location=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
  echo "Logging in with az"
  azure_auth_client_id=$(yq-v4 .clientId < "$azure_auth_location")
  azure_auth_client_secret=$(yq-v4 .clientSecret < "$azure_auth_location")
  azure_auth_tenant_id=$(yq-v4 .tenantId < "$azure_auth_location")
  azure_subscription_id=$(yq-v4 .subscriptionId < "$azure_auth_location")
  az login --service-principal -u "$azure_auth_client_id" -p "$azure_auth_client_secret"\
    --tenant "$azure_auth_tenant_id" --output none
  az account set --subscription "${azure_subscription_id}"
  echo "Setting up the boot image for the ${ADDITIONAL_WORKER_ARCHITECTURE} workers..."
  vhd_url=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml | \
    yq-v4 ".data.stream \
         | eval(.).architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.\"rhel-coreos-extensions\".\"azure-disk\".url")
  vhd_name=$(basename "${vhd_url}")
  infra_id=$(yq-v4 '.infraID' < "${SHARED_DIR}"/metadata.json)
  rg_name="${infra_id}-rg"
  sa_name=$(az storage account list -g "${rg_name}" | yq-v4 '.[] | select(.name == "cluster*").name')
  AZURE_STORAGE_KEY=$(az storage account keys list -g "${rg_name}" --account-name "${sa_name}" --query "[0].value" -o tsv)
  export AZURE_STORAGE_KEY
  az storage blob copy start --account-name "${sa_name}" \
      --destination-blob "${vhd_name}" --destination-container vhd --source-uri "$vhd_url"
  gallery_name=$(az sig list -g "${rg_name}" | yq-v4 '.[].name')
  image_name="${infra_id}-gen2-${ADDITIONAL_WORKER_ARCHITECTURE}"
  storage_blob_url=$(az storage blob url --account-name "${sa_name}" --container-name vhd --name "${vhd_name}" -o tsv)
  az sig image-definition create --resource-group "${rg_name}" --gallery-name "${gallery_name}" \
    --gallery-image-definition "${image_name}" --publisher "RedHat" --offer "rhcos" \
    --sku "rhcos-${ADDITIONAL_WORKER_ARCHITECTURE}" --os-type linux --hyper-v-generation V2 \
    --architecture "$(sed 's/aarch64/Arm64/;s/x86_64/x64/' <<< "${ADDITIONAL_WORKER_ARCHITECTURE}")"

  region=$(az group show --name "${rg_name}" | yq-v4 '.location')
  for i in $(seq 1 15) max; do
    [ "$i" == max ] && { echo "Timeout exceeded while waiting for the VHD blob copy to conclude. Failing..."; exit 3; }
    sleep 60
    [ X"$(az storage blob show --container-name vhd --name "${vhd_name}" --account-name "${sa_name}" \
      -o tsv --query properties.copy.status)" == X"success" ] && break
    echo "Waiting for the VHD blob copy to conclude... (timeout in $(( 15 - i )) minutes)"
  done
  echo "The VHD image is now available. Creating the image version..."
  az sig image-version create --resource-group "${rg_name}" \
    --gallery-name "${gallery_name}" --gallery-image-definition "${image_name}" \
    --gallery-image-version "${vhd_name:6:15}"  --target-regions "${region}" \
    --os-vhd-uri "${storage_blob_url}" --os-vhd-storage-account "${sa_name}"
  echo "The image version for the ${ADDITIONAL_WORKER_ARCHITECTURE} workers has been created... "
  echo "Patching the MachineSet..."
  resource_id="/resourceGroups/${rg_name}/providers/Microsoft.Compute/galleries/${gallery_name}/images/${image_name}/versions/latest"
  MACHINE_SET=$(yq-v4 ".spec.template.spec.providerSpec.value.vmSize = \"${ADDITIONAL_WORKER_VM_TYPE}\"
       | .spec.template.spec.providerSpec.value.image.resourceID = \"${resource_id}\"" <<< "$MACHINE_SET")
;;
*)
  echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

echo "Creating the ${ADDITIONAL_WORKER_ARCHITECTURE} worker MachineSet..."
echo "$MACHINE_SET" | oc create -o yaml -f -

echo "Wait for the nodes to become ready..."
wait_for_nodes_readiness ${EXPECTED_NODES}
ret="$?"
echo "Exiting with ${ret}."
exit ${ret}
