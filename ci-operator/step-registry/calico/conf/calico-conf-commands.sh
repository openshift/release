#!/bin/bash

set -xeuo pipefail

if [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
  sed -i "s/networkType: .*/networkType: Calico/" "${SHARED_DIR}/install-config.yaml"
fi

cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: Calico
  serviceNetwork:
  - 172.30.0.0/16
EOF

calico_dir=/tmp/calico
mkdir $calico_dir

wget -qO- "https://github.com/projectcalico/calico/releases/download/v${CALICO_VERSION}/ocp.tgz" | \
  tar xvz --strip-components=1 -C $calico_dir

# Install namespaces, operator, custom resources Installation and ApiServer.
while IFS= read -r src; do
  cp "$src" "${SHARED_DIR}/manifest_$(basename "$src")"
done <<< "$(find $calico_dir -name "00*" -o -name "02*")"

# Install API Server
cp "${calico_dir}/01-cr-apiserver.yaml" "${SHARED_DIR}/manifest_01-cr-apiserver.yaml"

# Install Calico with specific setting for node address auto-detection.
# The specific setting is required as some tests create NetworkAttachmentDefinitions
# which add network interfaces to the host. Calico then incorrectly chooses this interface
# and breaks connectivity between nodes.
cat > "${SHARED_DIR}/manifest_01-cr-installation.yaml" << EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  variant: Calico
  calicoNetwork:
    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP
EOF
