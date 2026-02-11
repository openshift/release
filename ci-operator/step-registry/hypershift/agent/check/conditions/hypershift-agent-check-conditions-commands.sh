#!/bin/bash

set -exuo pipefail

# Function to compare versions (returns 0 if $1 >= $2)
function version_ge() {
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Function to get all conditions from HostedCluster at once
function get_conditions() {
  local cluster_name="$1"
  local namespace="$2"
  oc get "hostedcluster/${cluster_name}" -n "$namespace" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]"
}

# Function to extract a specific condition status from cached conditions JSON
function get_condition_status_from_json() {
  local conditions="$1"
  local condition_type="$2"
  echo "${conditions}" | jq -r --arg type "${condition_type}" '.[] | select(.type == $type) | .status' 2>/dev/null || echo ""
}

function validate_condition() {
  local conditions="$1"
  local condition_type="$2"
  local expected_status="$3"
  local actual_status
  actual_status=$(get_condition_status_from_json "${conditions}" "${condition_type}")

  if [[ -z "${actual_status}" ]]; then
    echo "  ❌ ${condition_type}: NOT FOUND (expected: ${expected_status})"
    return 1
  elif [[ "${actual_status}" != "${expected_status}" ]]; then
    echo "  ❌ ${condition_type}: ${actual_status} (expected: ${expected_status})"
    return 1
  else
    echo "  ✓ ${condition_type}: ${actual_status}"
    return 0
  fi
}

# Function to validate all HostedCluster conditions
function validate_hosted_cluster_conditions() {
  local cluster_name="$1"
  local namespace="$2"

  # Reduce logging
  set +x

  echo "Validating HostedCluster conditions"

  # Get OpenShift version for version-specific assertions
  local openshift_version
  openshift_version=$(oc get "hostedcluster/${cluster_name}" -n "$namespace" -o jsonpath='{.status.version.history[0].version}' | grep -oE '^[0-9]+\.[0-9]+' 2>/dev/null || echo "")
  echo "HostedCluster OpenShift version: ${openshift_version}"

  local validation_timeout=900  # 15 minutes

  echo "Validating HostedCluster conditions (polling for up to ${validation_timeout} seconds)..."

  local validation_start
  validation_start=$(date +%s)
  local validation_success="false"

  while [[ $(($(date +%s) - validation_start)) -lt ${validation_timeout} ]]; do
    echo "Checking conditions at $(date)"
    local failed=0

    # Fetch all conditions at once for efficiency
    local conditions
    conditions=$(get_conditions "${cluster_name}" "$namespace")

    # Get etcd management type for conditional validation
    local etcd_management_type
    etcd_management_type=$(oc get "hostedcluster/${cluster_name}" -n "$namespace" -o jsonpath="{.spec.etcd.managementType}" 2>/dev/null)

    # Expected True conditions
    validate_condition "${conditions}" "Available" "True" || ((++failed))
    validate_condition "${conditions}" "InfrastructureReady" "True" || ((++failed))
    validate_condition "${conditions}" "KubeAPIServerAvailable" "True" || ((++failed))
    validate_condition "${conditions}" "IgnitionEndpointAvailable" "True" || ((++failed))
    validate_condition "${conditions}" "EtcdAvailable" "True" || ((++failed))
    validate_condition "${conditions}" "ValidReleaseInfo" "True" || ((++failed))
    validate_condition "${conditions}" "ValidConfiguration" "True" || ((++failed))
    validate_condition "${conditions}" "SupportedHostedCluster" "True" || ((++failed))
    validate_condition "${conditions}" "ClusterVersionSucceeding" "True" || ((++failed))
    validate_condition "${conditions}" "ClusterVersionAvailable" "True" || ((++failed))
    validate_condition "${conditions}" "ClusterVersionReleaseAccepted" "True" || ((++failed))
    validate_condition "${conditions}" "ReconciliationActive" "True" || ((++failed))
    validate_condition "${conditions}" "ReconciliationSucceeded" "True" || ((++failed))
    validate_condition "${conditions}" "ValidHostedControlPlaneConfiguration" "True" || ((++failed))
    validate_condition "${conditions}" "ValidReleaseImage" "True" || ((++failed))
    validate_condition "${conditions}" "PlatformCredentialsFound" "True" || ((++failed))

    # Expected False conditions
    validate_condition "${conditions}" "Progressing" "False" || ((++failed))
    validate_condition "${conditions}" "Degraded" "False" || ((++failed))
    validate_condition "${conditions}" "ClusterVersionProgressing" "False" || ((++failed))

    # UnmanagedEtcdAvailable - only validate if etcd management type is Unmanaged
    if [[ "${etcd_management_type}" == "Unmanaged" ]]; then
      validate_condition "${conditions}" "UnmanagedEtcdAvailable" "True" || ((++failed))
    fi

    # This is Unknown on Agent platform.
    validate_condition "${conditions}" "ExternalDNSReachable" "Unknown" || ((++failed))

    # Version-specific conditions

    # DataPlaneConnectionAvailable: only validate if version >= 4.21
    if [[ -n "${openshift_version}" ]] && version_ge "${openshift_version}" "4.21"; then
      validate_condition "${conditions}" "DataPlaneConnectionAvailable" "True" || ((++failed))
    fi

    # ControlPlaneConnectionAvailable: only validate if version >= 4.22
    if [[ -n "${openshift_version}" ]] && version_ge "${openshift_version}" "4.22"; then
      validate_condition "${conditions}" "ControlPlaneConnectionAvailable" "True" || ((++failed))
    fi

    if [[ ${failed} -eq 0 ]]; then
      echo "✓ All HostedCluster conditions validated successfully"
      validation_success="true"
      break
    else
      echo "Failed conditions: ${failed}. Retrying in 5 seconds..."
      sleep 5
    fi
  done

  if [[ "${validation_success}" != "true" ]]; then
    echo "❌ HostedCluster condition validation failed after ${validation_timeout} seconds"
    echo "Dumping HostedCluster status for debugging:"
    oc get "hostedcluster/${cluster_name}" -n "$namespace" -o jsonpath='{.status.conditions}' | jq '.'
    set -ex
    return 1
  fi

  echo "HostedCluster condition validation completed in $(($(date +%s) - validation_start)) seconds"
  set -x

  return 0
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
NAMESPACE="local-cluster"

validate_hosted_cluster_conditions "${CLUSTER_NAME}" "${NAMESPACE}"
