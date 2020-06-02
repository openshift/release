#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

case $((RANDOM % 8)) in
0) AZURE_REGION=centralus;;
1) AZURE_REGION=centralus;;
2) AZURE_REGION=centralus;;
3) AZURE_REGION=centralus;;
4) AZURE_REGION=centralus;;
5) AZURE_REGION=centralus;;
6) AZURE_REGION=eastus2;;
7) AZURE_REGION=westus;;
*) echo >&2 "invalid Azure region index"; exit 1;;
esac
echo "Azure region: ${AZURE_REGION}"

cat >> "${CONFIG}" << EOF
baseDomain: ci.azure.devcluster.openshift.com
compute:
- name: worker
  platform:
    azure:
      type: Standard_D4s_v3
platform:
  azure:
    baseDomainResourceGroupName: os4-common
    region: ${AZURE_REGION}
EOF
