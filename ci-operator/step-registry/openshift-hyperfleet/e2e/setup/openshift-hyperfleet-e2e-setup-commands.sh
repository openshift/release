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
export PROJECT_ID=${PROJECT_ID}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
# Generates the kubeconfig and saves it to shared dir
hyperfleet-credential-provider generate-kubeconfig \
  --provider=gcp \
  --project-id="$PROJECT_ID" \
  --region="${REGION}" \
  --cluster-name="$CLUSTER_NAME" \
  --output="${SHARED_DIR}/kubeconfig" 

# Resolve Gangway-overridable params (prefix is required for ci-operator to
# inject overrides; bare names are used by downstream scripts and deploy-clm.sh).
NAMESPACE_PREFIX="${MULTISTAGE_PARAM_OVERRIDE_NAMESPACE_PREFIX:-e2e}"

# Generate namespace name with build_id suffix
NAMESPACE_NAME=${NAMESPACE_PREFIX}-${BUILD_ID}
# Saves namespace and project id to shared dir so test and cleanup have shared values
echo "${NAMESPACE_NAME}" > "${SHARED_DIR}/namespace_name"
echo "${PROJECT_ID}" > "${SHARED_DIR}/gcp_project_id"

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
export API_IMAGE_TAG="${MULTISTAGE_PARAM_OVERRIDE_API_IMAGE_TAG:-latest}"
export ADAPTER_IMAGE_REPO="${ADAPTER_IMAGE_REPO:-ci/hyperfleet-adapter}"
export ADAPTER_IMAGE_TAG="${MULTISTAGE_PARAM_OVERRIDE_ADAPTER_IMAGE_TAG:-latest}"
export SENTINEL_IMAGE_REPO="${SENTINEL_IMAGE_REPO:-ci/hyperfleet-sentinel}"
export SENTINEL_IMAGE_TAG="${MULTISTAGE_PARAM_OVERRIDE_SENTINEL_IMAGE_TAG:-latest}"

# Install hyperfleet components via infra repo
# Will inherit all exported values here
git clone --depth 1 "https://github.com/openshift-hyperfleet/hyperfleet-infra.git" /tmp/hyperfleet-infra
cd /tmp/hyperfleet-infra

HELMFILE_ENV="e2e-gcp"
NAMESPACE=${NAMESPACE_NAME} HELMFILE_ENV="${HELMFILE_ENV}" make install-hyperfleet

# Save installed charts for cleanup
HELMFILE_JSON="${SHARED_DIR}/helm-release-${NAMESPACE_NAME}.json"
NAMESPACE="${NAMESPACE_NAME}" helmfile -f helmfile/helmfile.yaml.gotmpl list -e "${HELMFILE_ENV}" --output json > "${HELMFILE_JSON}"

# Verify deployed components
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


wait_for_api() {
  local url="$1"
  local name="$2"
  local max_attempts="${API_RETRY_ATTEMPTS:-30}"
  local wait_seconds="${API_RETRY_INTERVAL:-10}"

  log "=== Waiting for ${name} to become accessible at ${url} ==="
  for attempt in $(seq 1 "$max_attempts"); do
    if curl -sf --connect-timeout 5 --max-time 10 -X GET "${url}" > /dev/null 2>&1; then
      log "SUCCESS: ${name} is accessible (attempt ${attempt}/${max_attempts})"
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      log "Attempt ${attempt}/${max_attempts}: ${name} not yet accessible, retrying in ${wait_seconds}s..."
      sleep "$wait_seconds"
    else
      log "Attempt ${attempt}/${max_attempts}: ${name} not yet accessible, no retries remaining"
    fi
  done

  log "ERROR: ${name} is not accessible at ${url} after ${max_attempts} attempts"
  log "Final attempt output for diagnostics:"
  curl --connect-timeout 5 --max-time 10 -X GET "${url}" 2>&1 || true
  return 1
}

if ! wait_for_api "${HYPERFLEET_API_URL}/api/hyperfleet/v1/clusters/" "Hyperfleet API"; then
  exit 1
fi

if ! wait_for_api "${MAESTRO_URL}/api/maestro/v1/consumers" "Maestro API"; then
  exit 1
fi
