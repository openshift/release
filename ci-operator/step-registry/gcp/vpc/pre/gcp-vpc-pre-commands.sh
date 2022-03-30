#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN VPC..." && exit 0
fi

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"
if [ ! -s ${CONFIG} ]; then
  echo "${CONFIG} not found or empty, abort." && exit 1
fi

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "$(/tmp/yq r "${CONFIG}" 'platform.gcp.projectID')"
fi

echo "$(date -u --rfc-3339=seconds) - Copying resource files from lib dir..."
dir=/tmp/installer
mkdir -p "${dir}"
pushd "${dir}"
cp -t "${dir}" \
    "/var/lib/openshift-install/upi/${CLUSTER_TYPE}"/*

## Create the VPC
echo "$(date -u --rfc-3339=seconds) - Creating the VPC..."

CLUSTER_NAME="$(/tmp/yq r "${CONFIG}" 'metadata.name')"
REGION="$(/tmp/yq r "${CONFIG}" 'platform.gcp.region')"
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

PATCH=/tmp/install-config-patch.yaml
cat > "${PATCH}" << EOF
platform:
  gcp:
    network: ${CLUSTER_NAME}-network
    controlPlaneSubnet: ${CLUSTER_NAME}-master-subnet
    computeSubnet: ${CLUSTER_NAME}-worker-subnet
EOF
/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
echo "$(date -u --rfc-3339=seconds) - ${CONFIG} is patched with VPC info."

rm -f "${PATCH}"
popd
