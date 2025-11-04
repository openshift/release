#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ASSISTED_SERVICE_URL="https://api.stage.openshift.com/api/assisted-install/v2"
UNIQUE_ID=$(cat ${SHARED_DIR}/eval_test_unique_id)
echo "${UNIQUE_ID}"

OCM_TOKEN=$(curl -X POST https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=$(cat /var/run/secrets/sso-ci/client_id)" \
  -d "client_secret=$(cat /var/run/secrets/sso-ci/client_secret)" | jq '.access_token' | sed "s/^['\"]*//; s/['\"]*$//")

curl -H "Authorization: Bearer ${OCM_TOKEN}" "${ASSISTED_SERVICE_URL}/clusters" > ${ARTIFACT_DIR}/available_clusters.json

if [[ $(cat ${ARTIFACT_DIR}/available_clusters.json | jq 'length') -eq 0 ]]; then
  echo "No clusters were found, exiting."
  exit 0
fi

echo "Cluster were found, you can see the data in artifacts/available_clusters.json"

cat ${ARTIFACT_DIR}/available_clusters.json | jq '[.[] |{id, name, created_at}]' > ${ARTIFACT_DIR}/relevant_cluster_data.json
touch ${ARTIFACT_DIR}/clusters_to_delete

jq -c '.[]' ${ARTIFACT_DIR}/relevant_cluster_data.json | while read item; do
  id=$(echo "$item" | jq -r '.id')
  name=$(echo "$item" | jq -r '.name')
  if [[ "$name" == *"-${UNIQUE_ID}" ]]; then
    echo "The cluster '${name}' is going to be deleted"
    echo "$id" >> ${ARTIFACT_DIR}/clusters_to_delete
  fi
done

if [[ ! -s "${ARTIFACT_DIR}/clusters_to_delete" ]]; then
  echo "No clusters were found whith '${UNIQUE_ID}' in it's name."
  exit 0
fi

echo "Deleting the clusters enumerated in artifacts/clusters_to_delete"

cat ${ARTIFACT_DIR}/clusters_to_delete | xargs -I@ curl -X DELETE -H "Authorization: Bearer ${OCM_TOKEN}" "${ASSISTED_SERVICE_URL}/clusters/@"

curl -H "Authorization: Bearer ${OCM_TOKEN}" "${ASSISTED_SERVICE_URL}/clusters" | jq '[.[] |{id, name, created_at}]' > ${ARTIFACT_DIR}/clusters_after_delete.json