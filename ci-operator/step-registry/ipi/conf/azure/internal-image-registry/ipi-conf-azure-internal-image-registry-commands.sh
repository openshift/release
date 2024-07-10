#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

vnet_rg=$(yq-go r ${CONFIG} 'platform.azure.networkResourceGroupName')
vnet_name=$(yq-go r ${CONFIG} 'platform.azure.virtualNetwork')
compute_subnet=$(yq-go r ${CONFIG} 'platform.azure.computeSubnet')

cat > ${SHARED_DIR}/manifest_image_registry-config.yml <<EOF
apiVersion: imageregistry.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  managementState: "Managed"
  replicas: 2
  rolloutStrategy: RollingUpdate
  storage:
    azure:
      networkAccess:
        internal:
          networkResourceGroupName: ${vnet_rg}
          subnetName: ${compute_subnet}
          vnetName: ${vnet_name}
        type: Internal
EOF
