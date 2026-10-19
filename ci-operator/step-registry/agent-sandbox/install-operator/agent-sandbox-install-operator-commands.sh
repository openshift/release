#!/usr/bin/env bash
#
# Install the agent-sandbox operator via OLM on OpenShift.
#
# Applies Konflux image mirror sets, creates a CatalogSource from a
# Konflux FBC image, then installs via Namespace + OperatorGroup +
# Subscription. Waits for CSV Succeeded and controller deployment
# Available.
#
# Environment Variables:
#   AGENT_SANDBOX_INSTALL         - "true" to install, "false" to skip
#   AGENT_SANDBOX_CATALOG_IMAGE   - FBC catalog image digest (required when installing)
#   AGENT_SANDBOX_PACKAGE         - OLM package name (default: agent-sandbox-operator)
#   AGENT_SANDBOX_CHANNEL         - Subscription channel (default: preview-0.9)
#   AGENT_SANDBOX_NAMESPACE       - Target namespace (default: agent-sandbox-system)

set -euo pipefail

export SHARED_DIR=${SHARED_DIR:-/tmp}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}

AGENT_SANDBOX_INSTALL=${AGENT_SANDBOX_INSTALL:-false}
AGENT_SANDBOX_CATALOG_IMAGE=${AGENT_SANDBOX_CATALOG_IMAGE:-}
AGENT_SANDBOX_PACKAGE=${AGENT_SANDBOX_PACKAGE:-agent-sandbox-operator}
AGENT_SANDBOX_CHANNEL=${AGENT_SANDBOX_CHANNEL:-preview-0.9}
AGENT_SANDBOX_NAMESPACE=${AGENT_SANDBOX_NAMESPACE:-agent-sandbox-system}

CATALOG_SOURCE_NAME="agent-sandbox-ci"
MIRROR_SET_URL="https://raw.githubusercontent.com/openshift/kubernetes-sigs-agent-sandbox/refs/heads/main/.tekton/images-mirror-set.yaml"

OC_RETRY_COUNT=3
OC_RETRY_INTERVAL=20

if [[ "${AGENT_SANDBOX_INSTALL}" != "true" ]]; then
  echo ">>> Skipping agent-sandbox operator installation (AGENT_SANDBOX_INSTALL=${AGENT_SANDBOX_INSTALL})"
  exit 0
fi

if [[ -z "${AGENT_SANDBOX_CATALOG_IMAGE}" ]]; then
  echo ">>> ERROR: AGENT_SANDBOX_CATALOG_IMAGE is required when AGENT_SANDBOX_INSTALL=true"
  exit 1
fi

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo ">>> Agent-sandbox operator installation"
echo ">>> Package: ${AGENT_SANDBOX_PACKAGE}"
echo ">>> Channel: ${AGENT_SANDBOX_CHANNEL}"
echo ">>> Namespace: ${AGENT_SANDBOX_NAMESPACE}"
echo ">>> Catalog image: ${AGENT_SANDBOX_CATALOG_IMAGE}"

function exit_handler() {
  local exitcode=$?
  set +e
  if [[ ${exitcode} -ne 0 ]]; then
    echo ">>> ERROR: agent-sandbox operator installation failed"
    echo ">>> Namespace status:"
    oc get all -n "${AGENT_SANDBOX_NAMESPACE}" 2>/dev/null || true
    echo ">>> CSV status:"
    oc get csv -n "${AGENT_SANDBOX_NAMESPACE}" 2>/dev/null || true
    echo ">>> CatalogSource status:"
    oc get catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace -o yaml 2>/dev/null || true
    echo ">>> Operator logs:"
    oc logs -n "${AGENT_SANDBOX_NAMESPACE}" deployment/agent-sandbox-controller --tail=50 2>/dev/null || true
  fi
}
trap 'exit_handler' EXIT

function wait_until() {
  local description="$1"
  local timeout_seconds="$2"
  local check_interval="$3"
  local condition_command="$4"

  local max_iterations=$((timeout_seconds / check_interval))
  local progress_interval=$((60 / check_interval))
  [[ ${progress_interval} -lt 1 ]] && progress_interval=1

  echo ">>> Waiting for ${description} (timeout: ${timeout_seconds}s)..." >&2

  for (( i = 1; i <= max_iterations; i++ )); do
    if eval "${condition_command}" 2>/dev/null; then
      echo ">>> ${description} - OK (after $((i * check_interval))s)" >&2
      return 0
    fi
    if [[ $((i % progress_interval)) -eq 0 ]]; then
      echo ">>> Still waiting for ${description} ($((i * check_interval))s elapsed)..." >&2
    fi
    [[ ${i} -lt ${max_iterations} ]] && sleep "${check_interval}"
  done

  echo ">>> ERROR: ${description} - TIMEOUT after ${timeout_seconds}s" >&2
  return 1
}

function oc_with_retry() {
  local err_file
  err_file=$(mktemp)
  for (( attempt = 1; attempt <= OC_RETRY_COUNT; attempt++ )); do
    if "$@" 2>"${err_file}"; then
      rm -f "${err_file}"
      return 0
    fi
    local err_output
    err_output=$(cat "${err_file}")
    if echo "${err_output}" | grep -qiE 'Unable to connect|connection refused|dial tcp|i/o timeout|EOF|network is unreachable|TLS handshake timeout'; then
      echo ">>> Connection error (attempt ${attempt}/${OC_RETRY_COUNT}): ${err_output}" >&2
      [[ ${attempt} -lt ${OC_RETRY_COUNT} ]] && sleep "${OC_RETRY_INTERVAL}" && continue
      rm -f "${err_file}"
      echo ">>> ERROR: Cannot reach cluster after ${OC_RETRY_COUNT} attempts" >&2
      return 1
    fi
    rm -f "${err_file}"
    echo ">>> ERROR: Command failed: $*" >&2
    echo "${err_output}" >&2
    return 1
  done
}

#========================================
# Step 1: Apply Konflux image mirror sets
#========================================

if oc get imagedigestmirrorset agent-sandbox-registry &>/dev/null; then
  echo ">>> ImageDigestMirrorSet/agent-sandbox-registry already exists, skipping mirror setup"
else
  echo ">>> Applying Konflux image mirror sets"
  oc_with_retry oc apply -f "${MIRROR_SET_URL}"

  echo ">>> Waiting for MachineConfigPools to begin updating..."
  sleep 30

  if ! wait_until "all MachineConfigPools updated" 1800 30 \
    "oc wait mcp --all --for=condition=Updated --timeout=0s 2>/dev/null"; then
    echo ">>> ERROR: MachineConfigPools did not settle after 30 minutes"
    oc get mcp || true
    exit 1
  fi
fi

#========================================
# Step 2: Create CatalogSource
#========================================

echo ">>> Creating CatalogSource ${CATALOG_SOURCE_NAME}"
oc_with_retry oc apply -f - <<CSEOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${AGENT_SANDBOX_CATALOG_IMAGE}
CSEOF

wait_until "CatalogSource ${CATALOG_SOURCE_NAME} ready" 300 10 \
  "oc get catalogsource ${CATALOG_SOURCE_NAME} -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' | grep -q READY"

#========================================
# Step 3: Create Namespace + OperatorGroup
#========================================

echo ">>> Creating namespace ${AGENT_SANDBOX_NAMESPACE}"
oc_with_retry oc apply -f - <<NSEOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${AGENT_SANDBOX_NAMESPACE}
NSEOF

echo ">>> Creating OperatorGroup (AllNamespaces)"
oc_with_retry oc apply -f - <<OGEOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: agent-sandbox-og
  namespace: ${AGENT_SANDBOX_NAMESPACE}
spec: {}
OGEOF

#========================================
# Step 4: Create Subscription
#========================================

echo ">>> Creating Subscription for ${AGENT_SANDBOX_PACKAGE} (channel: ${AGENT_SANDBOX_CHANNEL})"
oc_with_retry oc apply -f - <<SUBEOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${AGENT_SANDBOX_PACKAGE}
  namespace: ${AGENT_SANDBOX_NAMESPACE}
spec:
  channel: ${AGENT_SANDBOX_CHANNEL}
  name: ${AGENT_SANDBOX_PACKAGE}
  source: ${CATALOG_SOURCE_NAME}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
SUBEOF

#========================================
# Step 5: Wait for CSV Succeeded
#========================================

wait_until "Subscription InstallPlan created" 300 10 \
  "oc get subscription ${AGENT_SANDBOX_PACKAGE} -n ${AGENT_SANDBOX_NAMESPACE} -o jsonpath='{.status.installPlanRef.name}' | grep -q ."

CSV_NAME=""
wait_until "CSV created" 300 10 \
  "CSV_NAME=\$(oc get csv -n ${AGENT_SANDBOX_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [[ -n \"\${CSV_NAME}\" ]]"

CSV_NAME=$(oc get csv -n "${AGENT_SANDBOX_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
echo ">>> CSV: ${CSV_NAME}"

wait_until "CSV ${CSV_NAME} Succeeded" 300 10 \
  "oc get csv ${CSV_NAME} -n ${AGENT_SANDBOX_NAMESPACE} -o jsonpath='{.status.phase}' | grep -q Succeeded"

#========================================
# Step 6: Wait for controller deployment
#========================================

wait_until "agent-sandbox-controller deployment Available" 300 10 \
  "oc rollout status deployment/agent-sandbox-controller -n ${AGENT_SANDBOX_NAMESPACE} --timeout=0s 2>/dev/null"

echo ">>> Controller deployment is ready"

#========================================
# Step 7: Verify CRDs
#========================================

echo ">>> Verifying CRDs"
oc_with_retry oc get crd \
  sandboxes.agents.x-k8s.io \
  sandboxtemplates.extensions.agents.x-k8s.io \
  sandboxwarmpools.extensions.agents.x-k8s.io \
  sandboxclaims.extensions.agents.x-k8s.io

echo ">>> Agent-sandbox operator installation complete"
