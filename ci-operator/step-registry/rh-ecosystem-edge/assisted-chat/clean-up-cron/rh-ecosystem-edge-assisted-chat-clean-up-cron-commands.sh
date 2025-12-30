#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ASSISTED_SERVICE_URL="https://api.stage.openshift.com/api/assisted-install/v2"

n=4 # number of hours to subtract
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
past_time=$(date -u -d "$current_time -$n hours" +"%Y-%m-%dT%H:%M:%SZ")
unix_past_time=$(date -d "${past_time}" +"%s")

echo "Current UTC time: $current_time"
echo "Time $n hours ago (UTC): $past_time"

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

cat ${ARTIFACT_DIR}/available_clusters.json | jq '[.[] |{id, name, created_at}]' > ${ARTIFACT_DIR}/relevant_cluster_data.json
touch ${ARTIFACT_DIR}/clusters_to_delete

jq -c '.[]' ${ARTIFACT_DIR}/relevant_cluster_data.json | while read item; do
  id=$(echo "$item" | jq -r '.id')
  created_at=$(echo "$item" | jq -r '.created_at')
  name=$(echo "$item" | jq -r '.name')
  unix_created_at=$(date -d "${created_at}" +"%s")
  if [[ $unix_created_at -lt $unix_past_time ]]; then
    echo "The cluster with id: '${id}' and name '${name}' has to be deleted, because it was created before '${past_time}'."
    echo "It's creation time is '${created_at}'."
    echo "${id}" >> ${ARTIFACT_DIR}/clusters_to_delete
  else
    echo "The cluster with id: '${id}' and name: '${name}' was created at '${created_at}', which is after '${past_time}'."
  fi
done

if [[ ! -s "${ARTIFACT_DIR}/clusters_to_delete" ]]; then
  echo "No clusters were found which are older than '${past_time}'."
  exit 0
fi

cat ${ARTIFACT_DIR}/clusters_to_delete | xargs -I@ curl -X DELETE -H "Authorization: Bearer ${OCM_TOKEN}" "${ASSISTED_SERVICE_URL}/clusters/@"

curl -H "Authorization: Bearer ${OCM_TOKEN}" "${ASSISTED_SERVICE_URL}/clusters" | jq '[.[] |{id, name, created_at}]' > ${ARTIFACT_DIR}/clusters_after_delete.json