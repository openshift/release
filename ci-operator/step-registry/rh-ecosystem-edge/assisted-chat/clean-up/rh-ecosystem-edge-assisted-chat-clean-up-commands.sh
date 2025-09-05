#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OC_URL="https://api.stage.openshift.com/api/assisted-install/v2"

n=4 # number of hours to subtract
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
past_time=$(date -u -d "$current_time -$n hours" +"%Y-%m-%dT%H:%M")

echo "Current UTC time: $current_time"
echo "Time $n hours ago (UTC): $past_time"

if ! command -v ocm >/dev/null 2>&1; then \
  mkdir -p "${HOME}/.local/bin" && \
  curl -sSL -o "${HOME}/.local/bin/ocm" "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" && \
  chmod +x "${HOME}/.local/bin/ocm"; \
  export PATH="${HOME}/.local/bin:${PATH}"
fi

ocm login --client-id "$(cat /var/run/secrets/sso-ci/client_id)" \
          --client-secret "$(cat /var/run/secrets/sso-ci/client_secret)" \
          --url "${OC_URL}"

curl -H "Authorization: Bearer $(ocm token)" "${OC_URL}/clusters" > ${ARTIFACT_DIR}/available_clusters.json
cat ${ARTIFACT_DIR}/available_clusters.json | jq '[.[] |{id, name, created_at}]' > ${ARTIFACT_DIR}/relevant_cluster_data.json
cat ${ARTIFACT_DIR}/relevant_cluster_data.json | jq -r ".[] | select(.created_at < \"${past_time}\") | .id" > ${ARTIFACT_DIR}/clusters_to_delete

cat ${ARTIFACT_DIR}/clusters_to_delete | xargs -I@ curl -X DELETE -H "Authorization: Bearer $(ocm token)" "${OC_URL}/clusters/@"