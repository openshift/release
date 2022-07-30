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
CREDENTIAL_FILE="${SHARED_DIR}/${username}.awscred"
userInfo=$(aws iam get-user --user-name ${username} || true)
if [[ -z "${userInfo}" ]]; then
  echo "No ${username} is found. Create it..."
  userInfo=$(aws iam create-user --user-name ${username})
  if [ $? -ne 0 ]; then
    echo "Failed!! Can not create the user ${username}"
    exit 1
  fi

  echo "Add ${username} to the Admin group..."
  aws iam add-user-to-group --group-name Admin --user-name ${username}
else
  echo "Find ${username}..."
fi

AWSAccountID=$(echo $userInfo | jq .User.Arn | cut -d ':' -f 5)
if [[ -z "${AWSAccountID}" ]] || [[ ! $AWSAccountID =~ ^[0-9]+$ ]]; then
  echo "Failed to get the aws accountID. Please check the aws user information of ${username}"
  exit 1
fi
echo "aws_account_id=${AWSAccountID}" > "${CREDENTIAL_FILE}"

# AWS only allows two access keys under a user. If there are two, delete the first one and generate a new one
# to get the creadentials.
# AccessKeyList=($(aws iam list-access-keys --user-name ${username} | jq -r '.AccessKeyMetadata[].AccessKeyId'))
readarray -t AccessKeyIDList < <(aws iam list-access-keys --user-name ${username} | jq -r '.AccessKeyMetadata[].AccessKeyId')
if [ "${#AccessKeyIDList[@]}" -ge 2 ]; then
  echo "Delete the first credential ${AccessKeyIDList[0]}"
  aws iam delete-access-key --user-name ${username}  --access-key-id ${AccessKeyIDList[0]}
fi
echo "Create a new credential..."
readarray -t AWSToken < <(aws iam create-access-key --user-name ${username} | jq -r '.AccessKey.AccessKeyId,.AccessKey.SecretAccessKey')
echo "Store the credential in $CREDENTIAL_FILE"
echo "aws_access_key_id=${AWSToken[0]}" >> "${CREDENTIAL_FILE}"
echo "aws_secret_access_key=${AWSToken[1]}" >> "${CREDENTIAL_FILE}"

echo "List access keys under the user ${username}..."
aws iam list-access-keys --user-name ${username}
