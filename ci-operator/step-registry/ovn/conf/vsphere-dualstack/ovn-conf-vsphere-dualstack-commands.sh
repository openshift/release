#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "saving ipv4 vip configuration"

API_VIP=$(/tmp/yq e '.platform.vsphere.apiVIP' "${SHARED_DIR}/install-config.yaml")
INGRESS_VIP=$(/tmp/yq e '.platform.vsphere.ingressVIP' "${SHARED_DIR}/install-config.yaml")
export API_VIP
export INGRESS_VIP

echo "removing networking config if already exists"
/tmp/yq e --inplace 'del(.networking)' ${SHARED_DIR}/install-config.yaml
/tmp/yq e --inplace 'del(.platform.vsphere.apiVIP)' ${SHARED_DIR}/install-config.yaml
/tmp/yq e --inplace 'del(.platform.vsphere.ingressVIP)' ${SHARED_DIR}/install-config.yaml

echo "applying dual-stack networking config"

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json
source "${SHARED_DIR}/vsphere_context.sh"
declare vlanid
declare primaryrouterhostname

if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
  echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
  exit 1
fi
machine_cidr_ipv6=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipv6prefix' "${SUBNETS_CONFIG}")

IPV6_API_VIP="${machine_cidr_ipv6%%::*}::4"
IPV6_INGRESS_VIP="${machine_cidr_ipv6%%::*}::5"
export IPV6_API_VIP
export IPV6_INGRESS_VIP

/tmp/yq e --inplace '.platform.vsphere.apiVIPs += [strenv(API_VIP), strenv(IPV6_API_VIP)]' ${SHARED_DIR}/install-config.yaml
/tmp/yq e --inplace '.platform.vsphere.ingressVIPs += [strenv(INGRESS_VIP), strenv(IPV6_INGRESS_VIP)]' ${SHARED_DIR}/install-config.yaml

cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 192.168.0.0/16
  - cidr: ${machine_cidr_ipv6}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  - cidr: fd65:10:128::/56
    hostPrefix: 64
  serviceNetwork:
  - 172.30.0.0/16
  - fd65:172:16::/112
EOF

if [[ "${IP_FAMILIES}" == "DualStackIPv6Primary" ]]; then
  echo Swapping IP addresses
  /tmp/yq e --inplace '.platform.vsphere.apiVIPs = (.platform.vsphere.apiVIPs | reverse)' ${SHARED_DIR}/install-config.yaml
  /tmp/yq e --inplace '.platform.vsphere.ingressVIPs = (.platform.vsphere.ingressVIPs | reverse)' ${SHARED_DIR}/install-config.yaml
  /tmp/yq e --inplace '.networking.machineNetwork = (.networking.machineNetwork | reverse)' "${SHARED_DIR}/install-config.yaml"
  /tmp/yq e --inplace '.networking.clusterNetwork = (.networking.clusterNetwork | reverse)' "${SHARED_DIR}/install-config.yaml"
  /tmp/yq e --inplace '.networking.serviceNetwork = (.networking.serviceNetwork | reverse)' "${SHARED_DIR}/install-config.yaml"
fi
