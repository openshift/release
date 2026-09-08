#!/bin/bash

set -euo pipefail

echo "==========================================="
echo "Azure HCP Performance Testing Started v2"
echo "==========================================="

# Use the nested management cluster kubeconfig
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
if [[ -f /usr/bin/hcp ]]; then
  HCP_CLI="/usr/bin/hcp"
elif [[ -f /hypershift/bin/hypershift ]]; then
  HCP_CLI="/hypershift/bin/hypershift"
else
  HCP_CLI="hypershift"
fi
echo "Using ${HCP_CLI} for CLI"

# Generate unique cluster name
PERF_CLUSTER_NAME="perf-$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c-12)"
PERF_NAMESPACE="clusters"
PERF_RESULTS_DIR="${ARTIFACT_DIR}/performance-results"
mkdir -p "${PERF_RESULTS_DIR}"

# Ensure the hosted cluster is always torn down, even on early failure.
cleanup() {
  time_operation "hosted_cluster_deletion" delete_hosted_cluster || true
  echo ""
  echo "======================================"
  echo "Performance Test Results Summary"
  echo "======================================"
  if [[ -f "${PERF_RESULTS_DIR}/metrics.txt" ]]; then
    cat "${PERF_RESULTS_DIR}/metrics.txt"
    echo ""
    echo "Detailed metrics saved to: ${PERF_RESULTS_DIR}/metrics.json"
  else
    echo "No metrics collected (script failed before metrics initialization)"
  fi
}
trap cleanup EXIT

# Azure configuration
AZURE_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-centralus}"
BASE_DOMAIN="${HYPERSHIFT_BASE_DOMAIN:-hcp-sm-azure.azure.devcluster.openshift.com}"
AZURE_CREDS_FILE="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
AZURE_WORKLOAD_IDENTITIES_FILE="/etc/hypershift-ci-jobs-self-managed-azure-e2e/workload-identities.json"
AZURE_OIDC_ISSUER_URL="https://smazure.blob.core.windows.net/smazure"
AZURE_SA_TOKEN_KEY_PATH="/etc/hypershift-ci-jobs-self-managed-azure/serviceaccount-signer.private"
PULL_SECRET_FILE="/etc/ci-pull-credentials/.dockerconfigjson"

# Performance test configuration
INITIAL_NODEPOOL_SIZE="${HYPERSHIFT_INITIAL_NODE_COUNT:-2}"
SCALED_NODEPOOL_SIZE="${HYPERSHIFT_SCALED_NODE_COUNT:-10}"
RELEASE_IMAGE="${HYPERSHIFT_HC_RELEASE_IMAGE:-${OCP_IMAGE_LATEST}}"

# Timing function
time_operation() {
  local operation_name=$1
  local start_time
  start_time=$(date +%s)

  shift
  "$@"

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  echo "${operation_name}_duration_seconds: ${duration}" | tee -a "${PERF_RESULTS_DIR}/metrics.txt"
  echo "{\"metric\":\"${operation_name}_duration_seconds\",\"value\":${duration},\"timestamp\":${end_time}}" >> "${PERF_RESULTS_DIR}/metrics.json"

  return 0
}

# Function to create hosted cluster
create_hosted_cluster() {
  echo "Creating HostedCluster: ${PERF_CLUSTER_NAME}"

  ${HCP_CLI} create cluster azure \
    --name "${PERF_CLUSTER_NAME}" \
    --node-pool-replicas "${INITIAL_NODEPOOL_SIZE}" \
    --base-domain "${BASE_DOMAIN}" \
    --pull-secret "${PULL_SECRET_FILE}" \
    --azure-creds "${AZURE_CREDS_FILE}" \
    --workload-identities-file "${AZURE_WORKLOAD_IDENTITIES_FILE}" \
    --oidc-issuer-url "${AZURE_OIDC_ISSUER_URL}" \
    --sa-token-issuer-private-key-path "${AZURE_SA_TOKEN_KEY_PATH}" \
    --location "${AZURE_LOCATION}" \
    --release-image "${RELEASE_IMAGE}" \
    --assign-service-principal-roles \
    --dns-zone-rg-name "os4-common" \
    --generate-ssh

  echo "Waiting for HostedCluster to be available..."
  oc wait --for=condition=Available --timeout=30m \
    hostedcluster/"${PERF_CLUSTER_NAME}" -n "${PERF_NAMESPACE}"

  echo "HostedCluster ${PERF_CLUSTER_NAME} is available"
}

# Function to wait for nodepool ready
wait_nodepool_ready() {
  echo "Waiting for NodePool to be ready..."
  oc wait --timeout=30m nodepool/"${PERF_CLUSTER_NAME}" -n "${PERF_NAMESPACE}" \
    --for=condition=Ready=True
  echo "NodePool is ready"
}

# Function to scale nodepool
scale_nodepool() {
  local target_size=$1
  echo "Scaling NodePool to ${target_size} replicas..."

  oc scale nodepool "${PERF_CLUSTER_NAME}" -n "${PERF_NAMESPACE}" --replicas="${target_size}"
  wait_nodepool_ready
}

# Function to delete hosted cluster
delete_hosted_cluster() {
  echo "Deleting HostedCluster: ${PERF_CLUSTER_NAME}"

  ${HCP_CLI} destroy cluster azure \
    --azure-creds "${AZURE_CREDS_FILE}" \
    --name "${PERF_CLUSTER_NAME}" \
    --namespace "${PERF_NAMESPACE}" \
    --location "${AZURE_LOCATION}" \
    --dns-zone-rg-name "os4-common"

  echo "Waiting for HostedCluster deletion to complete..."
  timeout 15m bash -c "
    until ! oc get hostedcluster ${PERF_CLUSTER_NAME} -n ${PERF_NAMESPACE} &>/dev/null; do
      echo 'Waiting for HostedCluster deletion...'
      sleep 10
    done
  "

  echo "HostedCluster ${PERF_CLUSTER_NAME} deleted"
}

# Function to check API availability
check_api_availability() {
  echo "Checking API server availability..."

  # Get kubeconfig for the hosted cluster
  ${HCP_CLI} create kubeconfig \
    --name="${PERF_CLUSTER_NAME}" \
    --namespace="${PERF_NAMESPACE}" > "${SHARED_DIR}/guest-kubeconfig"

  local api_checks=0
  local api_successes=0

  for _ in {1..10}; do
    api_checks=$((api_checks + 1))
    if KUBECONFIG="${SHARED_DIR}/guest-kubeconfig" oc get nodes &>/dev/null; then
      api_successes=$((api_successes + 1))
    fi
    sleep 2
  done

  local availability_pct=$((api_successes * 100 / api_checks))
  echo "api_server_availability_percentage: ${availability_pct}" | tee -a "${PERF_RESULTS_DIR}/metrics.txt"
  echo "{\"metric\":\"api_server_availability_percentage\",\"value\":${availability_pct},\"timestamp\":$(date +%s)}" >> "${PERF_RESULTS_DIR}/metrics.json"
}

# Initialize metrics files
: > "${PERF_RESULTS_DIR}/metrics.json"  # Empty file for NDJSON format
echo "# Azure Self-Managed HCP Performance Metrics" > "${PERF_RESULTS_DIR}/metrics.txt"
echo "# Cluster: ${PERF_CLUSTER_NAME}" >> "${PERF_RESULTS_DIR}/metrics.txt"
echo "# Region: ${AZURE_LOCATION}" >> "${PERF_RESULTS_DIR}/metrics.txt"
echo "# Release: ${RELEASE_IMAGE}" >> "${PERF_RESULTS_DIR}/metrics.txt"
echo "# Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "${PERF_RESULTS_DIR}/metrics.txt"
echo "" >> "${PERF_RESULTS_DIR}/metrics.txt"

# Performance Test Scenarios
echo "=== Scenario 1: HostedCluster Creation (control plane) ==="
time_operation "hosted_cluster_creation" create_hosted_cluster

echo ""
echo "=== Scenario 1b: Initial NodePool Ready (data plane) ==="
time_operation "nodepool_initial_ready" wait_nodepool_ready

echo ""
echo "=== Scenario 2: API Server Availability Check ==="
check_api_availability

echo ""
echo "=== Scenario 3: NodePool Scale Up (${INITIAL_NODEPOOL_SIZE} -> ${SCALED_NODEPOOL_SIZE}) ==="
time_operation "nodepool_scale_up" scale_nodepool "${SCALED_NODEPOOL_SIZE}"

echo ""
echo "=== Scenario 4: NodePool Scale Down (${SCALED_NODEPOOL_SIZE} -> ${INITIAL_NODEPOOL_SIZE}) ==="
time_operation "nodepool_scale_down" scale_nodepool "${INITIAL_NODEPOOL_SIZE}"

echo ""
echo "Performance testing completed successfully! Finalizing teardown and report..."
