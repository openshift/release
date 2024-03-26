#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function logger() {
  local -r log_level=$1; shift
  local -r log_msg=$1; shift
  echo "$(date -u --rfc-3339=seconds) - ${log_level}: ${log_msg}"
}

function backoff() {
  local attempt=0
  local failed=0
  logger "INFO" "Running Command '$*'"
  while true; do
    eval "$@" && failed=0 || failed=1
    if [[ $failed -eq 0 ]]; then
      break
    fi
    attempt=$(( attempt + 1 ))
    if [[ $attempt -gt 5 ]]; then
      break
    fi
    echo "command failed, retrying in $(( 2 ** attempt )) seconds"
    sleep $(( 2 ** attempt ))
  done
  return $failed
}

# add IAM policy bindings for the ephemeral service account, in the host project
# parameters:
#   $1 - the email of the ephemeral service account
#   $2 - the VPC project ID (the host project)
function add_iam_policy_binding()
{
  local -r sa_email=$1;  shift
  local -r vpc_project_id=$1;  shift

  if ! which gcloud; then
    GCLOUD_TAR="google-cloud-sdk-468.0.0-linux-x86_64.tar.gz"
    GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
    logger "INFO" "gcloud not installed, installing from $GCLOUD_URL"
    pushd ${HOME}
    curl -O "$GCLOUD_URL"
    tar -xzf "$GCLOUD_TAR"
    export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
    popd
  fi

  # login to the service project
  service_project_id="$(jq -r -c .project_id "${GCP_CREDENTIALS_FILE}")"
  gcloud auth activate-service-account --key-file="${GCP_CREDENTIALS_FILE}"
  gcloud config set project "${service_project_id}"

  local interested_roles=("roles/compute.networkAdmin" "roles/compute.securityAdmin" "roles/dns.admin")
  local cmd
  for role in "${interested_roles[@]}"; do
    cmd="gcloud projects add-iam-policy-binding ${vpc_project_id} --member \"serviceAccount:${sa_email}\" --role ${role} 1>/dev/null"
    backoff "${cmd}"
  done

  for project in "${service_project_id}" "${vpc_project_id}"; do
    cmd="gcloud projects get-iam-policy ${project} --flatten='bindings[].members' --format='table(bindings.role)' --filter='bindings.members:${sa_email}'"
    logger "INFO" "Running Command '${cmd}'"
    eval "${cmd}"
  done
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ "${ENABLE_SHARED_VPC}" == "yes" ] && [ ! -f "${SHARED_DIR}/xpn.json" ]; then
  logger "ERROR" "Failed to find the Shared VPC configuration file, abort."
  exit 1
fi

suffix=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)
CLUSTER_NAME=${CLUSTER_NAME:-"ci-osd-gcp-$suffix"}
COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"custom-4-16384"}
MULTI_AZ=${MULTI_AZ:-false}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP:-"stable"}
ETCD_ENCRYPTION=${ETCD_ENCRYPTION:-false}
DISABLE_WORKLOAD_MONITORING=${DISABLE_WORKLOAD_MONITORING:-false}
SUBSCRIPTION_TYPE=${SUBSCRIPTION_TYPE:-"standard"}
REGION=${REGION:-"${LEASED_RESOURCE}"}
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}

if [ "${ENABLE_SHARED_VPC}" == "yes" ]; then
  logger "INFO" "Extracting the Shared VPC configurations..."
  VPC_PROJECT_ID=$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")
  VPC_NAME=$(jq -r '.clusterNetwork' "${SHARED_DIR}/xpn.json" | grep -o '[^/]*$')
  CONTROL_PLANE_SUBNET=$(jq -r '.controlSubnet' "${SHARED_DIR}/xpn.json" | grep -o '[^/]*$')
  COMPUTE_SUBNET=$(jq -r '.computeSubnet' "${SHARED_DIR}/xpn.json" | grep -o '[^/]*$')

  SHARED_VPC_SWITCH="--vpc-project-id ${VPC_PROJECT_ID} --vpc-name ${VPC_NAME} --control-plane-subnet ${CONTROL_PLANE_SUBNET} --compute-subnet ${COMPUTE_SUBNET}"
fi

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
logger "INFO" "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Check whether the cluster with the same cluster name existes.
OLD_CLUSTER_ID=$(ocm list clusters --columns=id --parameter search="name is '${CLUSTER_NAME}'" | tail -n 1)
if [[ "$OLD_CLUSTER_ID" != ID* ]]; then
  # Previous cluster was orphaned somehow. Shut it down.
  logger "ERROR" "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster-id: ${OLD_CLUSTER_ID}"
  exit 1
fi

# Required
GCP_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/osd-ccs-gcp.json"

versionList=$(ocm list versions --channel-group ${CHANNEL_GROUP})
logger "INFO" "Available cluster versions:\n${versionList}"
if [[ -z "$OPENSHIFT_VERSION" ]]; then
  OPENSHIFT_VERSION=$(echo "$versionList" | tail -1)
elif [[ $OPENSHIFT_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
  OPENSHIFT_VERSION=$(echo "$versionList" | grep "^${OPENSHIFT_VERSION}" | tail -1 || true)
else
  # Match the whole line
  OPENSHIFT_VERSION=$(echo "$versionList" | { grep -x "${OPENSHIFT_VERSION}" || true; })
fi
if [[ -z "$OPENSHIFT_VERSION" ]]; then
  logger "ERROR" "Requested cluster version not available!"
  exit 1
fi

default_compute_nodes=2
if [[ "$MULTI_AZ" == "true" ]]; then
  default_compute_nodes=3
fi
COMPUTE_NODES=${COMPUTE_NODES:-$default_compute_nodes}

# Switches
MARKETPLACE_GCP_TERMS_SWITCH=""
if [[ ! -z "$SUBSCRIPTION_TYPE" ]]; then
  MARKETPLACE_GCP_TERMS_SWITCH="--marketplace-gcp-terms"
fi

DISABLE_WORKLOAD_MONITORING_SWITCH=""
if [[ "$DISABLE_WORKLOAD_MONITORING" == "true" ]]; then
  DISABLE_WORKLOAD_MONITORING_SWITCH="--disable-workload-monitoring"
fi

ETCD_ENCRYPTION_SWITCH=""
if [[ "$ETCD_ENCRYPTION" == "true" ]]; then
  ETCD_ENCRYPTION_SWITCH="--etcd-encryption"
fi

SECURE_BOOT_FOR_SHIELDED_VMS_SWITCH=""
if [[ "$SECURE_BOOT_FOR_SHIELDED_VMS" == "true" ]]; then
  SECURE_BOOT_FOR_SHIELDED_VMS_SWITCH="--secure-boot-for-shielded-vms"
fi

# Cluster parameters
logger "INFO" "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  Cloud provider: gcp"
echo "  Cloud provider region: ${REGION}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Compute nodes: ${COMPUTE_NODES}"
echo "  Multi-az: ${MULTI_AZ}"
echo "  Openshift version: ${OPENSHIFT_VERSION}"
echo "  Channel group: ${CHANNEL_GROUP}"
echo "  Etcd encryption: ${ETCD_ENCRYPTION}"
echo "  Disable workload monitoring: ${DISABLE_WORKLOAD_MONITORING}"
echo "  Subscription type: ${SUBSCRIPTION_TYPE}"
echo "  Secure boot for shielded VMs: ${SECURE_BOOT_FOR_SHIELDED_VMS}"
if [ "${ENABLE_SHARED_VPC}" == "yes" ]; then
  echo "  VPC project id: ${VPC_PROJECT_ID}"
  echo "  VPC name: ${VPC_NAME}"
  echo "  Control-plane subnet: ${CONTROL_PLANE_SUBNET}"
  echo "  Compute subnet: ${COMPUTE_SUBNET}"
fi

cmd="ocm create cluster ${CLUSTER_NAME} \
--ccs \
--provider=gcp \
--region ${REGION} \
--service-account-file ${GCP_CREDENTIALS_FILE} \
--version ${OPENSHIFT_VERSION} \
--channel-group ${CHANNEL_GROUP} \
--compute-machine-type ${COMPUTE_MACHINE_TYPE} \
--subscription-type ${SUBSCRIPTION_TYPE} \
${MARKETPLACE_GCP_TERMS_SWITCH} \
${DISABLE_WORKLOAD_MONITORING_SWITCH} \
${ETCD_ENCRYPTION_SWITCH} \
${SECURE_BOOT_FOR_SHIELDED_VMS_SWITCH} \
${SHARED_VPC_SWITCH:-}"

# Create GCP cluster
logger "INFO" "Running Command '${cmd}'"
eval "${cmd}" > "${ARTIFACT_DIR}/cluster.txt"

# Store the cluster ID for the post steps and the cluster deprovision
mkdir -p "${SHARED_DIR}"
CLUSTER_ID=$(cat "${ARTIFACT_DIR}/cluster.txt" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2)
logger "INFO" "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
echo -n "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

echo "Waiting for cluster ready..."
start_time=$(date +"%s")
while true; do
  sleep 60
  CLUSTER_STATE=$(ocm get cluster "${CLUSTER_ID}" | jq -r '.status.state')
  echo "Cluster state: ${CLUSTER_STATE}"
  if [[ "${ENABLE_SHARED_VPC}" == "yes" ]] && [[ "${CLUSTER_STATE}" == "waiting" ]]; then
    logger "INFO" "Granting the required permissions in the host project..."
    ephemeral_sa_email=$(ocm describe cluster "${CLUSTER_ID}" | grep -Po "osd-managed-admin-[^\s\t]+")
    add_iam_policy_binding "${ephemeral_sa_email}" "${VPC_PROJECT_ID}"
    continue
  fi
  if [[ "${CLUSTER_STATE}" == "ready" ]]; then
    echo "Cluster ${CLUSTER_ID} is reported as ready"
    break
  fi
  if (( $(date +"%s") - $start_time >= $CLUSTER_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster to be ready"
    exit 1
  fi
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" ]]; then
    ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.cluster_install.log" || echo "error: Unable to pull installation log."
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    exit 1
  fi
done

ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.cluster_install.log"

# Print console.url
CONSOLE_URL=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.console.url')
logger "INFO" "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"

PRODUCT_ID=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"

INFRA_ID=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.infra_id')
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
