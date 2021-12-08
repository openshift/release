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

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.gcpcred"
sa_email=$(jq -r .client_email ${GOOGLE_CLOUD_KEYFILE_JSON})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
  gcloud config set project "$(/tmp/yq r "${CONFIG}" 'platform.gcp.projectID')"
fi

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

# Save the VPC information in ${SHARED_DIR}, in case SSH bastion host needs it
cat > "${SHARED_DIR}/vpc-info.yaml" << EOF
vpc:
  network: ${CLUSTER_NAME}-network
  controlPlaneSubnet: ${CLUSTER_NAME}-master-subnet
  computeSubnet: ${CLUSTER_NAME}-worker-subnet
EOF
