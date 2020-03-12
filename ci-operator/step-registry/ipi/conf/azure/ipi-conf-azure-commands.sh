#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_TYPE}" != azure4 ]]; then
    echo "no Azure configuration for ${CLUSTER_TYPE}"
    exit
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

cluster_variant=
if [[ -e "${SHARED_DIR}/install-config-variant.txt" ]]; then
    cluster_variant=$(<"${SHARED_DIR}/install-config-variant.txt")
fi

function has_variant() {
    regex="(^|,)$1($|,)"
    if [[ $cluster_variant =~ $regex ]]; then
        return 0
    fi
    return 1
}

base_domain=
if [[ -e "${SHARED_DIR}/install-config-base-domain.txt" ]]; then
    base_domain=$(<"${SHARED_DIR}/install-config-base-domain.txt")
else
    base_domain=ci.azure.devcluster.openshift.com
fi

echo "Installing from release ${RELEASE_IMAGE_LATEST}"

workers=3
if has_variant compact; then
    workers=0
fi

case $((RANDOM % 8)) in
0) azure_region=centralus;;
1) azure_region=centralus;;
2) azure_region=centralus;;
3) azure_region=centralus;;
4) azure_region=centralus;;
5) azure_region=eastus;;
6) azure_region=eastus2;;
7) azure_region=westus;;
*) echo >&2 "invalid Azure region index"; exit 1;;
esac
echo "Azure region: ${azure_region}"
vnetrg=""
vnetname=""
ctrlsubnet=""
computesubnet=""
if has_variant shared-vpc; then
    vnetrg="os4-common"
    vnetname="do-not-delete-shared-vnet-${azure_region}"
    ctrlsubnet="subnet-1"
    computesubnet="subnet-2"
fi
cat >> "${CONFIG}" << EOF
baseDomain: ${base_domain}
controlPlane:
  name: master
  replicas: 3
compute:
- name: worker
  replicas: ${workers}
platform:
  azure:
    baseDomainResourceGroupName: os4-common
    region: ${azure_region}
    networkResourceGroupName: ${vnetrg}
    virtualNetwork: ${vnetname}
    controlPlaneSubnet: ${ctrlsubnet}
    computeSubnet: ${computesubnet}
EOF

# TODO proxy variant
# TODO CLUSTER_NETWORK_TYPE / ovn variant
# TODO mirror variant
# TODO CLUSTER_NETWORK_MANIFEST
