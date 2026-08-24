#!/bin/bash

set -uo pipefail
set -x

NAMESPACE="quay-enterprise"
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

collect_debug_info() {
  echo "=== Collecting debug info for failed deployment ==="

  echo "--- Deployment describe ---"
  oc -n "${NAMESPACE}" describe "deployment/${QUAY_DEPLOY}" 2>&1 | tee "${ARTIFACT_DIR}/deployment-describe.txt"

  echo "--- Pod status ---"
  oc -n "${NAMESPACE}" get pods -o wide 2>&1 | tee "${ARTIFACT_DIR}/pod-status.txt"

  echo "--- Describe non-Ready quay-app pods ---"
  oc -n "${NAMESPACE}" get pods -l quay-component=quay-app -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}' | while read -r pod; do
    if [[ -n "${pod}" ]]; then
      echo "--- Describe pod: ${pod} ---"
      oc -n "${NAMESPACE}" describe pod "${pod}"
    fi
  done 2>&1 | tee "${ARTIFACT_DIR}/non-ready-pods-describe.txt"

  echo "--- Quay-app pod logs ---"
  oc -n "${NAMESPACE}" get pods -l quay-component=quay-app -o name | while read -r pod; do
    echo "--- Logs for ${pod} ---"
    oc -n "${NAMESPACE}" logs "${pod}" --tail=100 2>&1 || true
    echo "--- Previous logs for ${pod} ---"
    oc -n "${NAMESPACE}" logs "${pod}" --previous --tail=50 2>&1 || true
  done 2>&1 | tee "${ARTIFACT_DIR}/quay-app-pod-logs.txt"

  echo "--- Namespace events (last 10 min) ---"
  oc -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' 2>&1 | tee "${ARTIFACT_DIR}/namespace-events.txt"
}

echo "Swapping Quay image to CI-built: ${QUAY_CI_IMAGE}"

# Debug: show current state of the namespace
oc -n "${NAMESPACE}" get deployments
oc -n "${NAMESPACE}" get pods
oc -n "${NAMESPACE}" get subscription quay-operator -o yaml || true

# Scale down operator to prevent reconciliation overwriting our image change
# The operator is deployed via OLM, so we find it through the CSV
echo "Scaling down quay-operator..."
CSV=$(oc -n "${NAMESPACE}" get subscription quay-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
if [[ -n "${CSV}" ]]; then
  OPERATOR_DEPLOY=$(oc -n "${NAMESPACE}" get csv "${CSV}" -o jsonpath='{.spec.install.spec.deployments[0].name}' 2>/dev/null || true)
  if [[ -n "${OPERATOR_DEPLOY}" ]]; then
    echo "Found operator deployment from CSV: ${OPERATOR_DEPLOY}"
    oc -n "${NAMESPACE}" scale deployment "${OPERATOR_DEPLOY}" --replicas=0
    oc -n "${NAMESPACE}" wait --for=delete pod -l name="${OPERATOR_DEPLOY}" --timeout=120s 2>/dev/null || true
  else
    echo "WARNING: Could not determine operator deployment name from CSV ${CSV}" >&2
  fi
else
  echo "WARNING: Could not find installedCSV from subscription quay-operator" >&2
fi

# Find the quay-app deployment by name pattern (operator names it {registry}-quay-app)
QUAY_DEPLOY=$(oc -n "${NAMESPACE}" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep 'quay-app' | head -n1)
if [[ -z "${QUAY_DEPLOY}" ]]; then
  echo "ERROR: Could not find quay-app deployment" >&2
  exit 1
fi
echo "Found quay-app deployment: ${QUAY_DEPLOY}"

# Add CI build-cluster registry credentials so ROSA/external clusters can
# pull CI-built images.
echo "Injecting CI registry credentials..."
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

CI_REGISTRY_AUTH=$(mktemp)

# Extract registry hostname from the CI image reference so credentials target
# the exact host the kubelet will contact (e.g. registry.build01.ci.openshift.org).
CI_REGISTRY=$(echo "${QUAY_CI_IMAGE}" | cut -d/ -f1)
echo "CI image: ${QUAY_CI_IMAGE}"
echo "CI registry: ${CI_REGISTRY}"

# Build Docker auth directly from the build-cluster SA token.
# Previous attempts with `oc registry login` were unreliable:
#  - KUBECONFIG="" does not fall back to in-cluster auth on all images
#  - oc registry login may register credentials for the internal hostname
#    (image-registry.openshift-image-registry.svc) instead of the external one
# Using the SA token as HTTP Basic Auth (serviceaccount:<token>) targets the
# exact hostname the ROSA nodes will pull from.
SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
if [[ -f "${SA_TOKEN_FILE}" ]]; then
  SA_TOKEN=$(cat "${SA_TOKEN_FILE}")
  AUTH=$(printf 'serviceaccount:%s' "${SA_TOKEN}" | base64 | tr -d '\n')
  printf '{"auths":{"%s":{"auth":"%s"}}}' "${CI_REGISTRY}" "${AUTH}" > "${CI_REGISTRY_AUTH}"
  echo "CI registry auth created for ${CI_REGISTRY} via SA token"
else
  echo "SA token not found at ${SA_TOKEN_FILE}, trying oc registry login fallback..."
  (unset KUBECONFIG; oc registry login --to="${CI_REGISTRY_AUTH}") 2>&1 || true
fi

if [[ -s "${CI_REGISTRY_AUTH}" ]]; then
  jq -r '.auths | keys[]' "${CI_REGISTRY_AUTH}" 2>/dev/null || true

  # 1) Merge into global pull secret so nodes can pull the image
  CURRENT_PS=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  MERGED_PS=$(echo "${CURRENT_PS}" | jq -s '.[0] * .[1]' - "${CI_REGISTRY_AUTH}")
  echo "${MERGED_PS}" > /tmp/merged-pull-secret.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json
  echo "Global pull secret updated"

  # 2) Create namespace-level pull secret for immediate use (global pull secret
  #    propagation to nodes can take minutes on ROSA HCP)
  oc -n "${NAMESPACE}" create secret docker-registry ci-registry-pull-secret \
    --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
    --dry-run=client -o yaml | oc apply -f -
  for sa in default deployer $(oc -n "${NAMESPACE}" get sa -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -i quay); do
    oc -n "${NAMESPACE}" secrets link "${sa}" ci-registry-pull-secret --for=pull 2>/dev/null || true
  done
  echo "Namespace pull secret configured"

  rm -f /tmp/merged-pull-secret.json
else
  echo "ERROR: Could not obtain CI registry credentials — aborting" >&2
  rm -f "${CI_REGISTRY_AUTH}"
  $WAS_TRACING && set -x
  exit 1
fi
rm -f "${CI_REGISTRY_AUTH}"
$WAS_TRACING && set -x

# 3) Add imagePullSecret directly to the deployment pod template so the
#    kubelet definitely has credentials regardless of SA linking propagation
oc -n "${NAMESPACE}" patch "deployment/${QUAY_DEPLOY}" --type=strategic \
  -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ci-registry-pull-secret"}]}}}}'
echo "Deployment imagePullSecrets patched"

# Patch the container image
oc -n "${NAMESPACE}" set image "deployment/${QUAY_DEPLOY}" "quay-app=${QUAY_CI_IMAGE}"

# Switch entrypoint from registry-nomigrate to registry so the new image
# runs alembic migrations before starting (the operator default skips them).
oc -n "${NAMESPACE}" set env "deployment/${QUAY_DEPLOY}" QUAYENTRY=registry

# Wait for rollout
echo "Waiting for rollout of deployment/${QUAY_DEPLOY}..."
if ! oc -n "${NAMESPACE}" rollout status "deployment/${QUAY_DEPLOY}" --timeout=600s; then
  echo "ERROR: Rollout of deployment/${QUAY_DEPLOY} timed out" >&2
  collect_debug_info
  exit 1
fi

# Verify Quay health
QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
if [[ -z "${QUAY_ROUTE}" ]]; then
  echo "ERROR: quayroute not found in SHARED_DIR" >&2
  exit 1
fi

echo "Verifying Quay health at ${QUAY_ROUTE}..."
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "${QUAY_ROUTE}/health/instance" || true)
  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "Quay is healthy after custom image swap"
    exit 0
  fi
  echo "Attempt ${i}/30: health check returned ${HTTP_CODE}, retrying..."
  sleep 10
done

echo "ERROR: Quay health check failed after image swap" >&2
collect_debug_info
exit 1
