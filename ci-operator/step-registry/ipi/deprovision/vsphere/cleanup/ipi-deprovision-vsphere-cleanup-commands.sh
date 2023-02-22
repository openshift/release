#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Cleaning up OpenShift cluster objects on vSphere."
echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."

source "${SHARED_DIR}/govc.sh"

INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")

VOLUME_IDS=$(govc volume.ls -json | jq --arg INFRAID "${INFRA_ID}" '.[][] | select(.Metadata.ContainerCluster.ClusterId==$INFRAID) | .VolumeId.Id')


echo "$(date -u --rfc-3339=seconds) - Deleting CNS volumes: ${VOLUME_IDS}"
echo "$VOLUME_IDS" | xargs -I {} govc volume.rm {}
