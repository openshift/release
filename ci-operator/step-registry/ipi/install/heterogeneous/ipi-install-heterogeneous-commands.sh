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
*gcp*)
  echo "Extracting gcp boot image..."
  workers_addi_rhcos_image_project=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml | \
    yq-v4 ".data.stream
      | eval(.).architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.images.gcp.project")
  workers_addi_rhcos_image_name=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml | \
    yq-v4 ".data.stream
      | eval(.).architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.images.gcp.name")
  MACHINE_SET=$(yq-v4 ".spec.template.spec.providerSpec.value.machineType = \"${ADDITIONAL_WORKER_VM_TYPE}\"
                     | .spec.template.spec.providerSpec.value.disks[0].image = \"projects/$workers_addi_rhcos_image_project/global/images/$workers_addi_rhcos_image_name\"
              " <<< "${MACHINE_SET}")
;;
*ibmcloud*)
  FULL_CLUSTER_NAME=$(yq-v4 '.metadata.labels."machine.openshift.io/cluster-api-cluster"' <<< $MACHINE_SET)
  REGION="${LEASED_RESOURCE}"
  RESOURCE_GROUP=$(yq-v4 ".spec.template.spec.providerSpec.value.resourceGroup" <<< $MACHINE_SET)

  IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
  mkdir -p ${IBMCLOUD_HOME_FOLDER}

  if [ -z "$(command -v ibmcloud)" ]; then
    echo "ibmcloud CLI doesn't exist, installing"
    curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
  fi

  function ic() {
    HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
  }

  ic version
  ic login --quiet --apikey @${CLUSTER_PROFILE_DIR}/ibmcloud-api-key -r ${REGION} -g ${RESOURCE_GROUP}
  ic plugin install --quiet -f cloud-internet-services vpc-infrastructure cloud-object-storage

  case $ADDITIONAL_WORKER_ARCHITECTURE in
  s390x)
    # there currently is no suitable os type for rhcos 8/9 for s390x
    OS_NAME=red-8-s390x-byol
  ;;
  x86_64 | amd64)
    OS_NAME=rhel-coreos-stable-amd64
  ;;
  *)
    echo "Additional worker architecture \"${ADDITIONAL_WORKER_ARCHITECTURE}\" not supported for provider ibmcloud"
    exit 5
  esac

  # ensure that a suitable image for the target architecture exists. If it doesn't, download the image and upload it to
  # cloud object storage (cos), then create an image.
  RHCOS_IMAGE_NAME=${FULL_CLUSTER_NAME}-rhcos-${ADDITIONAL_WORKER_ARCHITECTURE}
  IMAGE_EXISTS=$(ic is images --output json | jq ".[] | select(.name == \"${RHCOS_IMAGE_NAME}\") | [ .name ] | length")
  if [ "${IMAGE_EXISTS}" != "1" ]; then
    echo "Image \"${RHCOS_IMAGE_NAME}\" does not exist, creating"
    BUCKET_NAME=${FULL_CLUSTER_NAME}-vsi-image
    RHCOS_IMAGE_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml | yq-v4 ".data.stream | eval(.).architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.artifacts.ibmcloud.formats.[].disk.location")
    if [ -z $RHCOS_IMAGE_URL ]; then
      echo "Image location for architecture ${ADDITIONAL_WORKER_ARCHITECTURE} could not be found"
      exit 5
    fi
    QCOW_GZ_BASENAME=$(basename ${RHCOS_IMAGE_URL})
    QCOW_GZ_FILE_LOCATION=/tmp/${QCOW_GZ_BASENAME}
    QCOW_NAME=$(basename -s .gz ${QCOW_GZ_BASENAME})
    QCOW_FILE_LOCATION=/tmp/${QCOW_NAME}

    echo "Downloading image from ${RHCOS_IMAGE_URL} (to ${QCOW_GZ_FILE_LOCATION})"
    curl -s -L -o ${QCOW_GZ_FILE_LOCATION} ${RHCOS_IMAGE_URL}

    echo "Extracting image"
    gunzip -f ${QCOW_GZ_FILE_LOCATION}

    echo "Uploading image to bucket ${BUCKET_NAME} under key ${QCOW_NAME}"
    ic cos object-put --bucket ${BUCKET_NAME} --key ${QCOW_NAME} --body ${QCOW_FILE_LOCATION} --region ${REGION}
    COS_URL="cos://${REGION}/${BUCKET_NAME}/${QCOW_NAME}"

    echo "Creating image ${RHCOS_IMAGE_NAME} from ${COS_URL} with OS ${OS_NAME}"
    ic is image-create ${RHCOS_IMAGE_NAME} --file ${COS_URL} --os-name ${OS_NAME} --resource-group-name ${RESOURCE_GROUP}
  else
    echo "Image \"${RHCOS_IMAGE_NAME}\" exists, reusing"
  fi

  # security groups do not correctly apply port ranges to s390x nodes in IBM Cloud VPC right now.
  # for now, allow connections between the VSIs as a workaround.
  if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" == "s390x" ]; then
    echo "Patching security groups to allow all TCP/UDP traffic between amd64 and s390x VSIs"
    SECURITY_GROUPS=$(yq-v4 '.spec.template.spec.providerSpec.value.primaryNetworkInterface.securityGroups | join(" ")' <<< $MACHINE_SET)
    for security_group in $SECURITY_GROUPS; do
      echo $security_group

      # remove all groups that are specific port ranges inside the security group for udp and tcp
      rules_to_delete=$(\
        ic is security-group $security_group --output json | \
        jq -r ".rules[] | select((.protocol | index(\"udp\", \"tcp\")) and (.direction == \"inbound\") and (.remote.name == \"${security_group}\")) | .id")

      if [ "${rules_to_delete}" ]; then
        ic is security-group-rule-delete --force $security_group $rules_to_delete
      fi

      for protocol in tcp udp; do
        ic is security-group-rule-add $security_group inbound $protocol --remote $security_group --port-min 1 --port-max 65535
      done
    done
  fi

  # explicitly disabling UDP aggregation since it is not supported on s390x. see https://issues.redhat.com/browse/OCPBUGS-18394
  oc create -oyaml -f - <<EOF
apiVersion: v1
kind: ConfigMap
data:
  disable-udp-aggregation: "true"
metadata:
  name: udp-aggregation-config
  namespace: openshift-network-operator
EOF

  MACHINE_SET=$(yq-v4 ".spec.template.spec.providerSpec.value.profile = \"${ADDITIONAL_WORKER_VM_TYPE}\"
       | .spec.template.spec.providerSpec.value.image = \"${RHCOS_IMAGE_NAME}\"" <<< "$MACHINE_SET")
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
