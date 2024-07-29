#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure vsphere_portgroup is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [[ "${CLUSTER_PROFILE_NAME:-}" == "vsphere-elastic" ]]; then
  echo "using VCM sibling of this step"
  exit 0
fi

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null

declare -a vips
mapfile -t vips <"${SHARED_DIR}/vips.txt"

SUBNETS_CONFIG=/var/run/vault/vsphere-ibmcloud-config/subnets.json

CONFIG="${SHARED_DIR}/install-config.yaml"
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)

VSPHERE_INFO="${SHARED_DIR}/vsphere_info.json"

router=$(awk -F. '{print $1}' <(echo "${LEASED_RESOURCE}"))
phydc=$(awk -F. '{print $2}' <(echo "${LEASED_RESOURCE}"))
vlanid=$(awk -F. '{print $3}' <(echo "${LEASED_RESOURCE}"))
primaryrouterhostname="${router}.${phydc}"

cat >>"${CONFIG}" <<EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: 3
  platform:
    vsphere:
      zones:
EOF

for zone in $(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].FailureDomains[].name' "${SUBNETS_CONFIG}")
do
  cat >>"${CONFIG}" <<EOF
      - "$zone"
EOF
done

cat >>"${CONFIG}" <<EOF
compute:
- name: "worker"
  replicas: 3
  platform:
    vsphere:
      zones:
EOF

for zone in $(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].FailureDomains[].name' "${SUBNETS_CONFIG}")
do
  cat >>"${CONFIG}" <<EOF
      - "$zone"
EOF
done

cat >>"${CONFIG}" <<EOF
platform:
  vsphere:
    apiVIPs:
    - "${vips[0]}"
    ingressVIPs:
    - "${vips[1]}"
    failureDomains:
EOF

for fd in $(jq -c --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].FailureDomains[]' "${SUBNETS_CONFIG}")
do
  cat >>"${CONFIG}" <<EOF
    - name: $(echo $fd | jq -r '.name')
      region: $(echo $fd | jq -r '.region')
      server: $(echo $fd | jq -r '.vcenter')
      zone: $(echo $fd | jq -r '.zone')
      topology:
        computeCluster: $(echo $fd | jq -r '.computeCluster')
        datacenter: $(echo $fd | jq -r '.datacenter')
        datastore: $(echo $fd | jq -r '.datastore')
        networks:
        - ci-vlan-${vlanid}
        resourcePool: $(echo $fd | jq -r '.computeCluster')/Resources/ipi-ci-clusters
EOF
done

cat >>"${CONFIG}" <<EOF
    vcenters:
EOF

for vcenter in $(jq -c '.vcenters[]' "${VSPHERE_INFO}")
do
  cat >>"${CONFIG}" <<EOF
    - datacenters:
      - IBMCloud
      port: 443
      password: $(echo $vcenter | jq '.pass')
      server: $(echo $vcenter | jq '.vcenter')
      user: $(echo $vcenter | jq '.user')
EOF
done

cat >>"${CONFIG}" <<EOF
networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF