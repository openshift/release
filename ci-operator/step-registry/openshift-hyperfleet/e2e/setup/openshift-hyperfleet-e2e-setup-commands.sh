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

# Generate namespace name with build_id suffix
NAMESPACE_NAME=${NAMESPACE_PREFIX}-${BUILD_ID}
echo "${NAMESPACE_NAME}" > "${SHARED_DIR}/namespace_name"

# Export chart parameters for the deployment
export API_CHART_REPO="${API_CHART_REPO:-https://github.com/openshift-hyperfleet/hyperfleet-api.git}"
export API_CHART_REF="${API_CHART_REF:-main}"
export API_CHART_PATH="${API_CHART_PATH:-charts}"
export ADAPTER_CHART_REPO="${ADAPTER_CHART_REPO:-https://github.com/openshift-hyperfleet/hyperfleet-adapter.git}"
export ADAPTER_CHART_REF="${ADAPTER_CHART_REF:-main}"
export ADAPTER_CHART_PATH="${ADAPTER_CHART_PATH:-charts}"
export SENTINEL_CHART_REPO="${SENTINEL_CHART_REPO:-https://github.com/openshift-hyperfleet/hyperfleet-sentinel.git}"
export SENTINEL_CHART_REF="${SENTINEL_CHART_REF:-main}"
export SENTINEL_CHART_PATH="${SENTINEL_CHART_PATH:-charts}"

# Export image parameters for the deployment
export IMAGE_REGISTRY="${IMAGE_REGISTRY:-registry.ci.openshift.org}"
export API_IMAGE_REPO="${API_IMAGE_REPO:-ci/hyperfleet-api}"
export API_IMAGE_TAG="${API_IMAGE_TAG:-latest}"
export ADAPTER_IMAGE_REPO="${ADAPTER_IMAGE_REPO:-ci/hyperfleet-adapter}"
export ADAPTER_IMAGE_TAG="${ADAPTER_IMAGE_TAG:-latest}"
export SENTINEL_IMAGE_REPO="${SENTINEL_IMAGE_REPO:-ci/hyperfleet-sentinel}"
export SENTINEL_IMAGE_TAG="${SENTINEL_IMAGE_TAG:-latest}"

# copy the deploy scripts to /tmp to avoid any potential permission issue when running deploy-clm.sh
cp -r /e2e/ /tmp/
cd "/tmp/e2e/deploy-scripts/"
cp .env.example .env
source .env
./deploy-clm.sh --action install --namespace $NAMESPACE_NAME --debug-log-dir ${ARTIFACT_DIR}

log "=== Checking all deployed resources ==="
kubectl get all -n $NAMESPACE_NAME > "${ARTIFACT_DIR}/all-resources.txt"

log "=== Checking pod logs for all pods ==="
for pod in $(kubectl get pods -n $NAMESPACE_NAME -o jsonpath='{.items[*].metadata.name}'); do
  log "Collecting logs for pod: $pod"
  kubectl logs "$pod" -n $NAMESPACE_NAME > "${ARTIFACT_DIR}/${pod}-logs.txt" 2>&1 || log "WARNING: Cannot retrieve logs for pod $pod"
done

log "SUCCESS: All pods are Running and deployment is healthy"


API_EXTERNAL_IP=$(kubectl get svc hyperfleet-api -n $NAMESPACE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [[ -z "${API_EXTERNAL_IP}" ]]; then
  log "ERROR: Failed to resolve Hyperfleet API external IP. Is the LoadBalancer ready?"
  exit 1
fi

MAESTRO_EXTERNAL_IP=$(kubectl get svc maestro -n maestro -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [[ -z "${MAESTRO_EXTERNAL_IP}" ]]; then
  log "ERROR: Failed to resolve Maestro external IP. Is the LoadBalancer ready?"
  exit 1
fi

export HYPERFLEET_API_URL=http://${API_EXTERNAL_IP}:8000
echo "${HYPERFLEET_API_URL}" > "${SHARED_DIR}/hyperfleet_api_url"

export MAESTRO_URL=http://${MAESTRO_EXTERNAL_IP}:8000
echo "${MAESTRO_URL}" > "${SHARED_DIR}/maestro_url"


log "=== Checking Hyperfleet API accessibility ==="
if ! curl -f -X GET ${HYPERFLEET_API_URL}/api/hyperfleet/v1/clusters/; then
  log "ERROR: Hyperfleet API is not accessible at ${HYPERFLEET_API_URL}"
  exit 1
fi

log "=== Checking Maestro API accessibility ==="
if ! curl -f -X GET ${MAESTRO_URL}/api/maestro/v1/consumers; then
  log "ERROR: Maestro API is not accessible at ${MAESTRO_URL}"
  exit 1
fi
