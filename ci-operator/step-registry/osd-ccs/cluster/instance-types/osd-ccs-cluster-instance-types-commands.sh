#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLOUD_PROVIDER=${CLOUD_PROVIDER:-"AWS"}
ZONE=${ZONES:-}
LOCAL_ZONE=${LOCAL_ZONE:-"false"}

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ ! -z "$REGION" ]]; then
  CLOUD_PROVIDER_REGION="${REGION}"
fi
payload=$(echo -e '{
  "region": {
    "id": "'${CLOUD_PROVIDER_REGION}'"
  }
}')

if [[ "${CLOUD_PROVIDER}" == "AWS" ]]; then
  AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
  AWS_ACCOUNT_ID=$(cat "${AWSCRED}" | grep aws_account_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
  payload=$(echo "${payload}" | jq \
    --arg account_id ${AWS_ACCOUNT_ID} \
    --arg access_key_id ${AWS_ACCESS_KEY_ID} \
    --arg secret_access_key ${AWS_SECRET_ACCESS_KEY} \
    '.aws +={"account_id": $account_id, "access_key_id": $access_key_id, "secret_access_key": $secret_access_key}' \
    )
fi

if [[ -z "$ZONE" ]] && [[ "${LOCAL_ZONE}" == "true" ]]; then
  ZONE=$(head -n 1 "${SHARED_DIR}/edge-zone-name.txt")
fi
if [[ ! -z "$ZONE" ]]; then
  payload=$(echo "${payload}" | jq --arg z $ZONE '.availability_zones +=[$z]')
fi

echo "List the supported instance types in $REGION:$ZONE"
echo $payload | ocm post /api/clusters_mgmt/v1/aws_inquiries/machine_types --parameter size=1000 | jq -r '.items[].id' > "${SHARED_DIR}/instance-types.txt"
cat "${SHARED_DIR}/instance-types.txt"
