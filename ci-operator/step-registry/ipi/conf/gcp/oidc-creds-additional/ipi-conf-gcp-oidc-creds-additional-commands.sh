#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

image_registry_credential_yaml="${SHARED_DIR}/manifest_openshift-image-registry-installer-cloud-credentials-credentials.yaml"
if [[ ! -f "${image_registry_credential_yaml}" ]]; then
  echo "'${image_registry_credential_yaml}' not found, abort." && exit 1
fi

PROJECT_NAME=$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GOOGLE_CLOUD_KEYFILE_JSON})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
  gcloud config set project "${PROJECT_NAME}"
fi

infra_name=${NAMESPACE}-${UNIQUE_HASH}
working_dir=`mktemp -d`
pushd "${working_dir}"

echo -e "\n$(date -u --rfc-3339=seconds) - Creating long-live key for image-registry (https://docs.openshift.com/container-platform/4.10/authentication/managing_cloud_provider_credentials/cco-mode-gcp-workload-identity.html#cco-ccoctl-gcp-image-registry_cco-mode-gcp-workload-identity)"
image_registry_sa=$(gcloud iam service-accounts list --filter="displayName=${infra_name}-openshift-image-registry-gcs" --format=json | jq -r '.[].email')

new_key_json="image_registry_key.json"
gcloud iam service-accounts keys create "${new_key_json}" --iam-account="${image_registry_sa}"
new_key_str_b64=$(cat "${new_key_json}" | base64 -w 0)

yq-go r -j "${image_registry_credential_yaml}" > tmp1.json
jq --arg k "${new_key_str_b64}" '.data["service_account.json"] = $k' < tmp1.json > tmp2.json
cat tmp2.json | yq-go r -P - > "${image_registry_credential_yaml}"
popd
echo -e "\n$(date -u --rfc-3339=seconds) - Updated image-registry SA with long-live key."
