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

cd ${SHARED_DIR}
git clone https://github.com/yasun1/hyperfleet-credential-provider.git
cd hyperfleet-credential-provider
make build
chmod +x bin/hyperfleet-credential-provider
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

bin/hyperfleet-credential-provider get-token \
  --provider=gcp \
  --cluster-name="$GKE_CLUSTER_NAME" \
  --project-id=$PROJECT_ID

# Test CMD
kubectl get namespaces
