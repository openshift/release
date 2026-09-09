#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"
patch_dedicated_host="${SHARED_DIR}/install-config-dedicated-host.yaml.patch"
usage_tag_file="${SHARED_DIR}/dedicated-host-usage-tag"

if test ! -f "${patch_dedicated_host}"
then
  echo "No dedicated hosts patch file found, so assuming patch never occurred."
  exit 0
fi

echo "Deprovisioning dedicated hosts..."

# We get the region information from the install-config.yaml.  For the dedicated hosts, we are pulling from the patch file in
# the event that an error occurred during creation of the dedicated host.
REGION=$(yq-v4 -r '.platform.aws.region' ${CONFIG})

# Get the usage tag key for this job
USAGE_TAG_KEY=""
if test -f "${usage_tag_file}"; then
  USAGE_TAG_KEY=$(cat "${usage_tag_file}")
fi

for HOST in $(yq-v4 -r '.compute[] | select(.name == "worker") | .platform.aws.hostPlacement.dedicatedHost[] | .id' "${patch_dedicated_host}"); do
  echo "Processing host ${HOST}..."

  # If we have a usage tag, remove it first
  if [[ -n "${USAGE_TAG_KEY}" ]]; then
    echo "Removing usage tag ${USAGE_TAG_KEY} from host ${HOST}"
    # Delete the tag (ignore errors if tag doesn't exist)
    aws ec2 delete-tags \
      --region "${REGION}" \
      --resources "${HOST}" \
      --tags "Key=${USAGE_TAG_KEY}" 2>/dev/null || echo "Warning: Could not remove tag ${USAGE_TAG_KEY} (may not exist)"
  fi

  # Check if any other jobs are still using this host
  HOST_TAGS=$(aws ec2 describe-tags \
    --region "${REGION}" \
    --filters "Name=resource-id,Values=${HOST}" \
    --query 'Tags[*].Key' \
    --output json)

  # Count how many in-use-by-* tags remain
  ACTIVE_JOBS=$(echo "${HOST_TAGS}" | jq -r 'map(select(startswith("in-use-by-"))) | length')

  if [[ "${ACTIVE_JOBS}" -eq 0 ]]; then
    echo "No other jobs using host ${HOST}, releasing..."
    if aws ec2 release-hosts --region "${REGION}" --host-ids "${HOST}"; then
      echo "Successfully released host ${HOST}"
    else
      echo "Warning: Failed to release host ${HOST}, it may have instances running"
    fi
  else
    echo "Host ${HOST} still in use by ${ACTIVE_JOBS} other job(s), not releasing"
  fi
done