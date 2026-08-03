#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

error(){
    echo -e "\033[1;31m$(date "+%d-%m-%YT%H:%M:%S") ERROR: " "${*}\033[0m" >&2
}

success(){
    echo -e "\033[1;32m$(date "+%d-%m-%YT%H:%M:%S") SUCCESS: " "${*}\033[0m" >&2
}

# Configure AWS
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE}}"
else
  error "No AWS credentials found in cluster profile"
  exit 1
fi

# Log into OCM
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  error "No OCM credentials found in cluster profile"
  exit 1
fi

# Get cluster info
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Running gap-analysis validation for cluster: ${CLUSTER_ID}"

# Initialize validation report
VALIDATION_REPORT="${ARTIFACT_DIR}/gap-analysis-validation-report.txt"

cat > "${VALIDATION_REPORT}" <<EOF
========================================
ROSA Gap Analysis Validation Report
========================================
Cluster ID: ${CLUSTER_ID}
Region: ${AWS_DEFAULT_REGION}
Test Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
========================================

EOF

VALIDATION_FAILED=0

# Get cluster kubeconfig
log "Fetching cluster credentials..."
if ! rosa describe cluster -c "${CLUSTER_ID}" &>/dev/null; then
  error "Failed to describe cluster ${CLUSTER_ID}"
  exit 1
fi

KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"
log "Generating kubeconfig for cluster access..."
# Disable tracing due to kubeconfig handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/credentials 2>/dev/null | jq -r '.kubeconfig' > "${KUBECONFIG_FILE}" || {
  error "Failed to fetch kubeconfig via OCM API"
  exit 1
}
$WAS_TRACING && set -x

export KUBECONFIG="${KUBECONFIG_FILE}"

# Validate kubeconfig
if ! oc whoami &>/dev/null; then
  error "Failed to authenticate with cluster kubeconfig"
  exit 1
fi

log "Successfully authenticated with cluster"

###########################################
# Validation 1: Wait for cluster ready state
###########################################
log "Validation 1: Waiting for cluster ready state (timeout: ${VALIDATION_TIMEOUT})..."
CLUSTER_READY=false
TIMEOUT_SECONDS=$(($(echo "${VALIDATION_TIMEOUT}" | sed 's/m$//' | sed 's/h$//' | awk '{print $1}') * 60))
START_TIME=$(date +%s)

echo "" >> "${VALIDATION_REPORT}"
echo "1. Cluster Ready State" >> "${VALIDATION_REPORT}"
echo "----------------------" >> "${VALIDATION_REPORT}"

while true; do
  ELAPSED=$(($(date +%s) - START_TIME))
  if [[ ${ELAPSED} -ge ${TIMEOUT_SECONDS} ]]; then
    error "Timeout waiting for cluster ready state after ${VALIDATION_TIMEOUT}"
    echo "Status: FAILED (timeout after ${VALIDATION_TIMEOUT})" >> "${VALIDATION_REPORT}"
    VALIDATION_FAILED=1
    break
  fi

  CLUSTER_STATE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json 2>/dev/null | jq -r '.state // "unknown"')
  if [[ "${CLUSTER_STATE}" == "ready" ]]; then
    success "Cluster is in ready state"
    echo "Status: READY" >> "${VALIDATION_REPORT}"
    echo "Time to ready: ${ELAPSED}s" >> "${VALIDATION_REPORT}"
    CLUSTER_READY=true
    break
  else
    log "Cluster state: ${CLUSTER_STATE}, waiting... (${ELAPSED}s elapsed)"
    sleep 30
  fi
done

###########################################
# Validation 2: Validate ClusterOperators
###########################################
log "Validation 2: Validating ClusterOperators..."
echo "" >> "${VALIDATION_REPORT}"
echo "2. ClusterOperators Status" >> "${VALIDATION_REPORT}"
echo "--------------------------" >> "${VALIDATION_REPORT}"

CO_OUTPUT="${ARTIFACT_DIR}/clusteroperators.txt"
oc get co -o wide > "${CO_OUTPUT}" 2>&1 || {
  error "Failed to get ClusterOperators"
  echo "Status: FAILED (unable to retrieve ClusterOperators)" >> "${VALIDATION_REPORT}"
  VALIDATION_FAILED=1
}

if [[ -f "${CO_OUTPUT}" ]]; then
  cat "${CO_OUTPUT}" >> "${VALIDATION_REPORT}"
  echo "" >> "${VALIDATION_REPORT}"

  # Check for degraded or unavailable operators
  DEGRADED_CO=$(oc get co -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name' 2>/dev/null || true)
  UNAVAILABLE_CO=$(oc get co -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null || true)

  if [[ -n "${DEGRADED_CO}" ]]; then
    error "Degraded ClusterOperators found: ${DEGRADED_CO}"
    echo "Degraded Operators: ${DEGRADED_CO}" >> "${VALIDATION_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ -n "${UNAVAILABLE_CO}" ]]; then
    error "Unavailable ClusterOperators found: ${UNAVAILABLE_CO}"
    echo "Unavailable Operators: ${UNAVAILABLE_CO}" >> "${VALIDATION_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ -z "${DEGRADED_CO}" && -z "${UNAVAILABLE_CO}" ]]; then
    success "All ClusterOperators are healthy"
    echo "All operators: HEALTHY" >> "${VALIDATION_REPORT}"
  fi
fi

###########################################
# Validation 3: Validate nodes
###########################################
log "Validation 3: Validating nodes..."
echo "" >> "${VALIDATION_REPORT}"
echo "3. Nodes Status" >> "${VALIDATION_REPORT}"
echo "---------------" >> "${VALIDATION_REPORT}"

NODES_OUTPUT="${ARTIFACT_DIR}/nodes.txt"
oc get nodes -o wide > "${NODES_OUTPUT}" 2>&1 || {
  error "Failed to get nodes"
  echo "Status: FAILED (unable to retrieve nodes)" >> "${VALIDATION_REPORT}"
  VALIDATION_FAILED=1
}

if [[ -f "${NODES_OUTPUT}" ]]; then
  cat "${NODES_OUTPUT}" >> "${VALIDATION_REPORT}"
  echo "" >> "${VALIDATION_REPORT}"

  # Check for NotReady nodes
  NOTREADY_NODES=$(oc get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status!="True")) | .metadata.name' 2>/dev/null || true)

  if [[ -n "${NOTREADY_NODES}" ]]; then
    error "NotReady nodes found: ${NOTREADY_NODES}"
    echo "NotReady Nodes: ${NOTREADY_NODES}" >> "${VALIDATION_REPORT}"
    VALIDATION_FAILED=1
  else
    success "All nodes are Ready"
    echo "All nodes: READY" >> "${VALIDATION_REPORT}"
  fi

  # Count nodes
  NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "Total nodes: ${NODE_COUNT}" >> "${VALIDATION_REPORT}"
fi

###########################################
# Collect cluster logs (always)
###########################################
log "Collecting cluster logs and diagnostics..."
echo "" >> "${VALIDATION_REPORT}"
echo "4. Cluster Logs and Diagnostics" >> "${VALIDATION_REPORT}"
echo "--------------------------------" >> "${VALIDATION_REPORT}"

# Collect cluster-version logs
log "Collecting cluster-version operator logs..."
oc logs deployment/cluster-version-operator -n openshift-cluster-version --tail=500 > "${ARTIFACT_DIR}/cvo-logs.txt" 2>&1 || true

# Collect degraded operator logs if any
if [[ -n "${DEGRADED_CO:-}" ]]; then
  for co in ${DEGRADED_CO}; do
    log "Collecting logs for degraded operator: ${co}"
    oc describe co "${co}" > "${ARTIFACT_DIR}/co-${co}-describe.txt" 2>&1 || true
  done
fi

# Collect pod status from critical namespaces
for ns in openshift-cluster-version openshift-kube-apiserver openshift-etcd openshift-monitoring; do
  log "Collecting pod status from namespace: ${ns}"
  oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/pods-${ns}.txt" 2>&1 || true
done

echo "Cluster logs collected in ${ARTIFACT_DIR}/" >> "${VALIDATION_REPORT}"

###########################################
# Generate final validation report
###########################################
echo "" >> "${VALIDATION_REPORT}"
echo "========================================" >> "${VALIDATION_REPORT}"
echo "Validation Summary" >> "${VALIDATION_REPORT}"
echo "========================================" >> "${VALIDATION_REPORT}"

if [[ ${VALIDATION_FAILED} -eq 1 ]]; then
  echo "Overall Status: FAILED" >> "${VALIDATION_REPORT}"
  error "Gap-analysis validation FAILED. See ${VALIDATION_REPORT} for details."
else
  echo "Overall Status: PASSED" >> "${VALIDATION_REPORT}"
  success "Gap-analysis validation PASSED."
fi

echo "Report generated at: ${VALIDATION_REPORT}"
echo "Artifacts directory: ${ARTIFACT_DIR}"

log "Gap-analysis validation complete."
exit ${VALIDATION_FAILED}
