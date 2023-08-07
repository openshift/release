#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN VPC..." && exit 0
fi

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

cat <<EOF > 01_vpc.yaml
imports:
- path: 01_vpc.py
resources:
- name: cluster-vpc
  type: 01_vpc.py
  properties:
    infra_id: '${CLUSTER_NAME}'
    region: '${REGION}'
    master_subnet_cidr: '${MASTER_SUBNET_CIDR}'
    worker_subnet_cidr: '${WORKER_SUBNET_CIDR}'
EOF

gcloud deployment-manager deployments create "${CLUSTER_NAME}-vpc" --config 01_vpc.yaml
cat > "${SHARED_DIR}/vpc-destroy.sh" << EOF
gcloud deployment-manager deployments delete -q "${CLUSTER_NAME}-vpc"
EOF

if [[ "${RESTRICTED_NETWORK}" = "yes" ]]; then
  echo "Updating the VPC into a disconnected network (removing NAT and enabling Private Google Access)..."
  gcloud compute routers nats delete -q "${CLUSTER_NAME}-nat-master" --router "${CLUSTER_NAME}-router" --region "${REGION}"
  gcloud compute routers nats delete -q "${CLUSTER_NAME}-nat-worker" --router "${CLUSTER_NAME}-router" --region "${REGION}"
  gcloud compute networks subnets update "${CLUSTER_NAME}-master-subnet" --region "${REGION}" --enable-private-ip-google-access
  gcloud compute networks subnets update "${CLUSTER_NAME}-worker-subnet" --region "${REGION}" --enable-private-ip-google-access
fi

cat > "${SHARED_DIR}/customer_vpc_subnets.yaml" << EOF
platform:
  gcp:
    network: ${CLUSTER_NAME}-network
    controlPlaneSubnet: ${CLUSTER_NAME}-master-subnet
    computeSubnet: ${CLUSTER_NAME}-worker-subnet
EOF

popd
