#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"
patch_dedicated_host="${SHARED_DIR}/install-config-dedicated-host.yaml.patch"

if test ! -f "${patch_dedicated_host}"
then
  echo "No dedicated hosts patch file found, so assuming patch never occurred."
  exit 0
fi

echo "Deprovisioning dedicated hosts..."

# We get the region information from the install-config.yaml.  For the dedicated hosts, we are pulling from the patch file in
# the event that an error occurred during creation of the dedicated host.
REGION=$(yq-v4 -r '.platform.aws.region' ${CONFIG})
for HOST in $(yq-v4 -r '.compute[] | select(.name == "worker") | .platform.aws.hostPlacement.dedicatedHost[] | .id' "${patch_dedicated_host}"); do
  echo "Release host ${HOST}"
  aws ec2 release-hosts --region "${REGION}" --host-ids "${HOST}"
done