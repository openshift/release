#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# No set -x: the API key, IAM token and HMAC keys must never reach the log.

export IBMCLOUD_HOME=/output
region="${LEASED_RESOURCE}"
endpoint="s3.${region}.cloud-object-storage.appdomain.cloud"
# Bucket names must be DNS-compliant: lowercase, at most 63 characters.
base="$(printf '%s' "${NAMESPACE}-${UNIQUE_HASH}-quay" | tr '[:upper:]' '[:lower:]' | cut -c1-63)"

ibmcloud config --check-version=false
ibmcloud login -r "${region}" --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"

# Recorded before anything is created so quay-ibmcloud-cos-deprovision can
# clean up a half-provisioned run.
printf '%s' "${base}-cos" > "${SHARED_DIR}/QUAY_IBMCLOUD_COS_INSTANCE_NAME"
echo "Creating COS instance ${base}-cos"
ibmcloud resource service-instance-create "${base}-cos" cloud-object-storage standard global
guid="$(ibmcloud resource service-instance "${base}-cos" --output json -q | jq -er '.[0].guid')"
printf '%s' "${guid}" > "${SHARED_DIR}/QUAY_IBMCLOUD_COS_INSTANCE_ID"

echo "Creating HMAC service key ${base}-hmac"
ibmcloud resource service-key-create "${base}-hmac" Writer --instance-id "${guid}" \
  --parameters '{"HMAC":true}' > /dev/null
key_json="$(mktemp)"
ibmcloud resource service-key "${base}-hmac" --output json -q > "${key_json}"
jq -er '.[0].credentials.cos_hmac_keys.access_key_id' "${key_json}" > "${SHARED_DIR}/quay-ibmcloud-cos-access-key"
jq -er '.[0].credentials.cos_hmac_keys.secret_access_key' "${key_json}" > "${SHARED_DIR}/quay-ibmcloud-cos-secret-key"
rm -f "${key_json}"

echo "Creating bucket ${base} at ${endpoint}"
printf '%s' "${base}" > "${SHARED_DIR}/QUAY_IBMCLOUD_COS_BUCKET"
printf '%s' "${endpoint}" > "${SHARED_DIR}/QUAY_IBMCLOUD_COS_ENDPOINT"
token="$(ibmcloud iam oauth-tokens --output json | jq -er '.iam_token')"
curl -sS --fail -X PUT "https://${endpoint}/${base}" \
  -H "Authorization: ${token}" \
  -H "ibm-service-instance-id: ${guid}"
