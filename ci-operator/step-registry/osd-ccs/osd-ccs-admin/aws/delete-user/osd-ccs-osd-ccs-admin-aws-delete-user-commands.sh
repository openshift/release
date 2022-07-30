#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_OUTPUT="json"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Validate whether the user osdCcsAdmin exists and get the accountID.
username="osdCcsAdmin"
userInfo=$(aws iam get-user --user-name ${username} || true)
if [[ -z "${userInfo}" ]]; then
  echo "Warning: No ${username} is found. Give up deletion..."
  exit 0
fi

# Delete the access keys udner the user
readarray -t AccessKeyIDList < <(aws iam list-access-keys --user-name ${username} | jq -r '.AccessKeyMetadata[].AccessKeyId')
if [ "${#AccessKeyIDList[@]}" -gt 0 ]; then
  for access_key_id in "${AccessKeyIDList[@]}"; do
    echo "Delete the access key ${access_key_id} under the user ${username}..."
    aws iam delete-access-key --user-name ${username} --access-key-id ${access_key_id}
  done
fi

# Remove the user from groups
readarray -t GroupNameList < <(aws iam list-groups-for-user --user-name ${username}| jq -r '.Groups[].GroupName')
if [ "${#GroupNameList[@]}" -gt 0 ]; then
  for group_name in "${GroupNameList[@]}"; do
    echo "Remove the user ${username} from the group ${group_name}..."
    aws iam remove-user-from-group --user-name ${username} --group-name ${group_name}
  done
fi

# Delete the user
echo "Delete the user ${username}..."
aws iam delete-user --user-name ${username}
echo "Deletion is successfully!"
