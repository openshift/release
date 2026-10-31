#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  SUB_TARGET_NAMESPACES="${SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${SUB_PACKAGE} from channel: ${SUB_CHANNEL} in source: ${SUB_SOURCE} into ${SUB_INSTALL_NAMESPACE}, targeting ${SUB_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SUB_INSTALL_NAMESPACE}"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${SUB_INSTALL_NAMESPACE}-operator-group"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${SUB_PACKAGE}"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${SUB_PACKAGE}"
  source: "${SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=

# Helper function to check for OLM constraint/resolution failures
check_subscription_failed_state() {
  local sub_name=$1
  local namespace=$2
  local failed_reason failed_msg
  
  failed_reason=$(oc get subscription "${sub_name}" -n "${namespace}" --request-timeout=30s -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].reason}' 2>/dev/null || echo "")
  failed_msg=$(oc get subscription "${sub_name}" -n "${namespace}" --request-timeout=30s -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}' 2>/dev/null || echo "")
  
  if [[ -n "${failed_reason}" ]]; then
    echo "Subscription in failed state: reason=${failed_reason}"
    if [[ "${failed_msg}" == *"ConstraintsNotSatisfiable"* ]] || [[ "${failed_msg}" == *"clusterserviceversion"*"exists and is not referenced"* ]]; then
      echo "Detected orphaned CSV constraint violation. Attempting recovery..."
      return 0  # True - failed state detected
    fi
  fi
  return 1  # False - not in failed state
}

# Helper function to clean up orphaned CSV
cleanup_orphaned_csv() {
  local namespace=$1
  local package=$2
  
  echo "Searching for orphaned CSV entries for ${package}..."
  set +e
  local orphaned_csvs
  orphaned_csvs=$(oc get csv -n "${namespace}" -o jsonpath='{.items[?(@.metadata.name | test("'${package}'"))].metadata.name}' 2>/dev/null)
  set -e
  
  if [[ -n "${orphaned_csvs}" ]]; then
    echo "Found orphaned CSVs: ${orphaned_csvs}"
    for csv_name in ${orphaned_csvs}; do
      echo "Deleting orphaned CSV: ${csv_name}"
      set +e
      oc delete csv "${csv_name}" -n "${namespace}" --wait=true --timeout=60s 2>&1
      set -e
    done
    echo "Cleaned up orphaned CSVs, waiting 10s before retry..."
    sleep 10
    return 0
  fi
  return 1
}

for i in $(seq "${RETRIES}"); do
  # Check if subscription is in a failed state due to orphaned CSV
  if check_subscription_failed_state "${SUB_PACKAGE}" "${SUB_INSTALL_NAMESPACE}"; then
    if cleanup_orphaned_csv "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}"; then
      # After cleanup, recreate the subscription
      echo "Recreating subscription after cleanup..."
      cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${SUB_PACKAGE}"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${SUB_PACKAGE}"
  source: "${SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF
      CSV=  # Reset CSV so we fetch it again
      sleep 30
    fi
  fi

  if [[ -z "${CSV}" ]]; then
    set +e
    CSV=$(oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    set -e
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${SUB_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  else
    set +e
    phase=$(oc get csv -n ${SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}' 2>/dev/null)
    set -e
    
    if [[ "${phase}" == "Succeeded" ]]; then
      echo "${SUB_PACKAGE} is deployed"
      break
    else
      echo "Try ${i}/${RETRIES}: ${SUB_PACKAGE} is not deployed yet (phase: ${phase}). Checking again in 30 seconds"
      sleep 30
    fi
  fi
done

if [[ -z "${CSV}" ]] || [[ $(oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${SUB_PACKAGE}"
  echo "Subscription ${SUB_PACKAGE} YAML"
  oc get subscription "${SUB_PACKAGE}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml || true
  if [[ -n "${CSV}" ]]; then
    echo
    echo "CSV ${CSV} YAML"
    oc get CSV "${CSV}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml || true
    echo
    echo "CSV ${CSV} Describe"
    oc describe CSV "${CSV}" -n "${SUB_INSTALL_NAMESPACE}" || true
  fi
  exit 1
fi

echo "successfully installed ${SUB_PACKAGE}"
