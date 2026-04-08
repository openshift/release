#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

python3 --version 
export CLOUDSDK_PYTHON=python3

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function create_vpc()
{
  local -r cluster_name="$1"; shift
  local -r region="$1"; shift
  local -r subnet1_cidr="$1"; shift
  local -r subnet2_cidr="$1"; shift
  local -r restricted_network="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD=""

  # create network
  CMD="gcloud compute networks create ${cluster_name}-network --subnet-mode=custom"
  run_command "${CMD}"

  # create subnets
  CMD="gcloud compute networks subnets create ${cluster_name}-master-subnet --network=${cluster_name}-network --range=${subnet1_cidr} --region=${region}"
  run_command "${CMD}"
  CMD="gcloud compute networks subnets create ${cluster_name}-worker-subnet --network=${cluster_name}-network --range=${subnet2_cidr} --region=${region}"
  run_command "${CMD}"

  if [[ "${restricted_network}" == "yes" ]]; then
    gcloud compute networks subnets update "${cluster_name}-master-subnet" --region "${region}" --enable-private-ip-google-access
    gcloud compute networks subnets update "${cluster_name}-worker-subnet" --region "${region}" --enable-private-ip-google-access
  else
    # create router
    CMD="gcloud compute routers create ${cluster_name}-router --network=${cluster_name}-network --region=${region}"
    run_command "${CMD}"

    # create nats
    CMD="gcloud compute routers nats create ${cluster_name}-nat-master --router=${cluster_name}-router --auto-allocate-nat-external-ips --nat-custom-subnet-ip-ranges=${cluster_name}-master-subnet --region=${region}"
    run_command "${CMD}"
    CMD="gcloud compute routers nats create ${cluster_name}-nat-worker --router=${cluster_name}-router --auto-allocate-nat-external-ips --nat-custom-subnet-ip-ranges=${cluster_name}-worker-subnet --region=${region}"
    run_command "${CMD}"

    # for deprovision
    cat > "${deprovision_commands_file}" << EOF
gcloud compute routers nats delete -q ${cluster_name}-nat-master --router ${cluster_name}-router --region ${region}
gcloud compute routers nats delete -q ${cluster_name}-nat-worker --router ${cluster_name}-router --region ${region}
gcloud compute routers delete -q ${cluster_name}-router --region ${region}
EOF
  fi

  # for deprovision
  cat >> "${deprovision_commands_file}" << EOF
gcloud compute networks subnets delete -q ${cluster_name}-master-subnet --region ${region}
gcloud compute networks subnets delete -q ${cluster_name}-worker-subnet --region ${region}
gcloud compute networks delete -q ${cluster_name}-network
EOF
}

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

echo "$(date -u --rfc-3339=seconds) - Copying resource files from lib dir..."
dir=/tmp/installer
mkdir -p "${dir}"
pushd "${dir}"
cp -t "${dir}" \
    "/var/lib/openshift-install/upi/${CLUSTER_TYPE}"/*

## Create the VPC
echo "$(date -u --rfc-3339=seconds) - Creating the VPC..."

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
REGION="${LEASED_RESOURCE}"
MASTER_SUBNET_CIDR='10.0.0.0/19'
WORKER_SUBNET_CIDR='10.0.32.0/19'

create_vpc "${CLUSTER_NAME}" "${REGION}" "${MASTER_SUBNET_CIDR}" "${WORKER_SUBNET_CIDR}" "${RESTRICTED_NETWORK}" "${SHARED_DIR}/vpc-destroy.sh"

cat > "${SHARED_DIR}/customer_vpc_subnets.yaml" << EOF
platform:
  gcp:
    network: ${CLUSTER_NAME}-network
    controlPlaneSubnet: ${CLUSTER_NAME}-master-subnet
    computeSubnet: ${CLUSTER_NAME}-worker-subnet
EOF

popd
