#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "saving ipv4 vip configuration"

API_VIP=$(/tmp/yq e '.platform.vsphere.apiVIP' ${SHARED_DIR}/install-config.yaml)
INGRESS_VIP=$(/tmp/yq e '.platform.vsphere.ingressVIP' ${SHARED_DIR}/install-config.yaml)
export API_VIP
export INGRESS_VIP

echo "removing networking config if already exists"
/tmp/yq e --inplace 'del(.networking)' ${SHARED_DIR}/install-config.yaml
/tmp/yq e --inplace 'del(.platform.vsphere.apiVIP)' ${SHARED_DIR}/install-config.yaml
/tmp/yq e --inplace 'del(.platform.vsphere.ingressVIP)' ${SHARED_DIR}/install-config.yaml

echo "applying dual-stack networking config"

/tmp/yq e --inplace '.platform.vsphere.apiVIPs += [strenv(API_VIP), "fd65:a1a8:60ad:271c::200"]' ${SHARED_DIR}/install-config.yaml
/tmp/yq e --inplace '.platform.vsphere.ingressVIPs += [strenv(INGRESS_VIP), "fd65:a1a8:60ad:271c::201"]' ${SHARED_DIR}/install-config.yaml

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 192.168.0.0/16
  - cidr: fd65:a1a8:60ad:271c::/64
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  - cidr: fd65:10:128::/56
    hostPrefix: 64
  serviceNetwork:
  - 172.30.0.0/16
  - fd65:172:16::/112
EOF
