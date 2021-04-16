#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cilium_olm_rev=bdf0e8fd6c5e82708fe9c95adb0d3142e21fabe1
cilium_version=1.9.5

cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: Cilium
  serviceNetwork:
  - 172.30.0.0/16
EOF

# Include all Cilium OLM manifest from https://github.com/cilium/cilium-olm/tree/${cilium_olm_rev}/manifests/cilium.v${cilium_version}

curl --silent --location --fail --show-error "https://github.com/cilium/cilium-olm/archive/${cilium_olm_rev}.tar.gz" --output /tmp/cilium-olm.tgz
tar -C /tmp -xf /tmp/cilium-olm.tgz

cd "/tmp/cilium-olm-${cilium_olm_rev}/manifests/cilium.v${cilium_version}"
for manifest in *.yaml ; do
  cp "${manifest}" "${SHARED_DIR}/manifest_${manifest}"
done

# use public image for the operator because registry.connect.redhat.com requires pull secrets
sed -i 's|image:\ registry.connect.redhat.com/isovalent/|image:\ quay.io/cilium/|g' "${SHARED_DIR}/manifest_cluster-network-06-cilium-00002-cilium-olm-deployment.yaml"
