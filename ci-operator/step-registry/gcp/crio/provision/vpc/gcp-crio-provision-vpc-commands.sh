#!/bin/bash

set -xeuo pipefail

python3 --version
export CLOUDSDK_PYTHON=python3

GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"; then
	gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
	gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

cd /tmp

## Create the VPC
echo "$(date -u --rfc-3339=seconds) - Creating the VPC..."

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
REGION="${LEASED_RESOURCE}"
SUBNET_CIDR='10.0.0.0/19'

cat <<EOF >01_vpc.py
def GenerateConfig(context):

    resources = [{
        'name': context.properties['infra_id'] + '-network',
        'type': 'compute.v1.network',
        'properties': {
            'region': context.properties['region'],
            'routingConfig': {
              'routingMode': 'REGIONAL'
            },
            'autoCreateSubnetworks': False
        }
    }, {
        'name': context.properties['infra_id'] + '-subnet',
        'type': 'compute.v1.subnetwork',
        'properties': {
            'region': context.properties['region'],
            'network': '\$(ref.' + context.properties['infra_id'] + '-network.selfLink)',
            'ipCidrRange': context.properties['subnet_cidr']
        }
    }, {
        'name': context.properties['infra_id'] + '-router',
        'type': 'compute.v1.router',
        'properties': {
            'region': context.properties['region'],
            'network': '\$(ref.' + context.properties['infra_id'] + '-network.selfLink)',
            'nats': [{
                'name': context.properties['infra_id'] + '-nat',
                'natIpAllocateOption': 'AUTO_ONLY',
                'minPortsPerVm': 7168,
                'sourceSubnetworkIpRangesToNat': 'LIST_OF_SUBNETWORKS',
                'subnetworks': [{
                    'name': '\$(ref.' + context.properties['infra_id'] + '-subnet.selfLink)',
                    'sourceIpRangesToNat': ['ALL_IP_RANGES']
                }]
            }]
        }
    }]

    return {'resources': resources}
EOF

cat <<EOF >01_vpc.yaml
imports:
- path: 01_vpc.py
resources:
- name: cluster-vpc
  type: 01_vpc.py
  properties:
    infra_id: '${CLUSTER_NAME}'
    region: '${REGION}'
    subnet_cidr: '${SUBNET_CIDR}'
EOF

gcloud deployment-manager deployments create "${CLUSTER_NAME}-vpc" --config 01_vpc.yaml
cat >"${SHARED_DIR}/vpc-destroy.sh" <<EOF
gcloud deployment-manager deployments delete -q "${CLUSTER_NAME}-vpc"
EOF

cat >"${SHARED_DIR}/customer_vpc_subnets.yaml" <<EOF
platform:
  gcp:
    network: ${CLUSTER_NAME}-network
    controlPlaneSubnet: ${CLUSTER_NAME}-subnet
EOF
