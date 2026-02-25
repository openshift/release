#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

HYPERFLEET_E2E_CREDENTIALS_PATH="/var/run/hyperfleet-e2e/"
export GOOGLE_APPLICATION_CREDENTIALS="${HYPERFLEET_E2E_CREDENTIALS_PATH}/hcm-hyperfleet-e2e.json"
PROJECT_ID="$(jq -r -c .project_id "${GOOGLE_APPLICATION_CREDENTIALS}")"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

hyperfleet-credential-provider generate-kubeconfig \
  --provider=gcp \
  --project-id="$PROJECT_ID" \
  --region="${REGION}" \
  --cluster-name="$CLUSTER_NAME" \
  --output="${SHARED_DIR}/kubeconfig" 

# Generate namespace name with date suffix
NAMESPACE_NAME=${NAMESPACE_PREFIX}-$(date "+%Y%m%d")
echo "${NAMESPACE_NAME}" > "${SHARED_DIR}/namespace_name"

sleep 1800

# copy the deploy scripts to /tmp to avoid any potential permission issue when running deploy-clm.sh
cp -r /e2e/ /tmp/
cd "/tmp/e2e/deploy-scripts/"
./deploy-clm.sh --action install --namespace $NAMESPACE_NAME

log "=== Checking all deployed resources ==="
kubectl get all -n $NAMESPACE_NAME > "${ARTIFACT_DIR}/all-resources.txt"

log "=== Checking pod logs for all pods ==="
for pod in $(kubectl get pods -n $NAMESPACE_NAME -o jsonpath='{.items[*].metadata.name}'); do
  log "Collecting logs for pod: $pod"
  kubectl logs "$pod" -n $NAMESPACE_NAME > "${ARTIFACT_DIR}/${pod}-logs.txt" 2>&1 || log "WARNING: Cannot retrieve logs for pod $pod"
done

log "SUCCESS: All pods are Running and deployment is healthy"


EXTERNAL_IP=$(kubectl get svc hyperfleet-api -n $NAMESPACE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

export HYPERFLEET_API_URL=http://${EXTERNAL_IP}:8000
echo "${HYPERFLEET_API_URL}" > "${SHARED_DIR}/hyperfleet_api_url"

log "=== Checking Hyperfleet API accessibility ==="
curl -X GET ${HYPERFLEET_API_URL}/api/hyperfleet/v1/clusters/


