#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-xpn.yaml.patch

HOST_PROJECT="openshift-dev-installer"
HOST_PROJECT_NETWORK="installer-shared-vpc"
HOST_PROJECT_CONTROL_SUBNET="installer-shared-vpc-subnet-1"
HOST_PROJECT_COMPUTE_SUBNET="installer-shared-vpc-subnet-2"

cat > "${PATCH}" << EOF
featureSet: TechPreviewNoUpgrade
credentialsMode: Passthrough
platform:
  gcp:
    computeSubnet: ${HOST_PROJECT_COMPUTE_SUBNET}
    controlPlaneSubnet: ${HOST_PROJECT_CONTROL_SUBNET}
    createFirewallRules: Disabled
    network: ${HOST_PROJECT_NETWORK}
    networkProjectID: ${HOST_PROJECT}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"

jq .client_email /var/run/secrets/ci.openshift.io/cluster-profile/gce.json
