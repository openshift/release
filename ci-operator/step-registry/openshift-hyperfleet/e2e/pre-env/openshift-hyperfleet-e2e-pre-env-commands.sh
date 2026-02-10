#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

export GOOGLE_APPLICATION_CREDENTIALS="${HYPERFLEET_E2E_PATH}/hcm-hyperfleet-e2e.json"
PROJECT_ID="$(jq -r -c .project_id "${GOOGLE_APPLICATION_CREDENTIALS}")"
cp /app/hyperfleet-credential-provider ${SHARED_DIR}/
export PATH=${SHARED_DIR}:${PATH}

hyperfleet-credential-provider generate-kubeconfig \
  --provider=gcp \
  --project-id="$PROJECT_ID" \
  --region="us-central1-a" \
  --cluster-name="$GKE_CLUSTER_NAME" \
  --output="${SHARED_DIR}/kubeconfig"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
# Test CMD
kubectl get namespaces

