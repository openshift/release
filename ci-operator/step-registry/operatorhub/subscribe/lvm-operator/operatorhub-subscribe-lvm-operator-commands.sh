#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Check if a custom redhat-operators CatalogSource was created and use it
if [[ -f "${SHARED_DIR}/redhat_operators_catalog_source_name" ]]; then
  CUSTOM_CATALOG_SOURCE=$(cat "${SHARED_DIR}/redhat_operators_catalog_source_name")
  echo "Found custom CatalogSource name from lvms-catalogsource step: ${CUSTOM_CATALOG_SOURCE}"
  LVM_OPERATOR_SUB_SOURCE="${CUSTOM_CATALOG_SOURCE}"
  
  # Also derive the channel from the CatalogSource name if not explicitly set
  # CatalogSource name format: redhat-operators-v4-20 -> extract version -> stable-4.20
  if [[ -z "${LVM_OPERATOR_SUB_CHANNEL}" ]]; then
    # Extract version from CatalogSource name (e.g., redhat-operators-v4-20 -> 4.20)
    EXTRACTED_VERSION=$(echo "${CUSTOM_CATALOG_SOURCE}" | sed -n 's/.*-v\([0-9]*\)-\([0-9]*\)$/\1.\2/p')
    if [[ -n "${EXTRACTED_VERSION}" ]]; then
      LVM_OPERATOR_SUB_CHANNEL="stable-${EXTRACTED_VERSION}"
      echo "Derived LVM_OPERATOR_SUB_CHANNEL from CatalogSource: ${LVM_OPERATOR_SUB_CHANNEL}"
    fi
  fi
fi

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)

# Auto-detect namespace based on cluster version if not explicitly set
if [[ -z "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  MINOR_VERSION=$(echo $CLUSTER_VERSION | cut -d. -f2)

  echo "Detected OpenShift version: ${CLUSTER_VERSION}"

  # For OpenShift 4.20+, use openshift-lvm-storage, otherwise use openshift-storage
  if [[ ${MINOR_VERSION} -ge 20 ]]; then
    LVM_OPERATOR_SUB_INSTALL_NAMESPACE="openshift-lvm-storage"
  else
    LVM_OPERATOR_SUB_INSTALL_NAMESPACE="openshift-storage"
  fi

  echo "Auto-detected namespace: ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
else
  echo "Using explicitly set namespace: ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi

if [[ -z "${LVM_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${LVM_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "CHANNEL is not defined, use the channel for current cluster version"
  # For 5.0+, cap at 4.22 since LVM catalog may not have newer channels yet
  MAJOR_VERSION=$(echo "${CLUSTER_VERSION}" | cut -d. -f1)
  MIN_VERSION=$(echo "${CLUSTER_VERSION}" | cut -d. -f2)
  if (( MAJOR_VERSION > 4 )) || (( MAJOR_VERSION == 4 && MIN_VERSION > 22 )); then
    LVM_OPERATOR_SUB_CHANNEL="stable-4.22"
    echo "Cluster is ${CLUSTER_VERSION} but LVM operator catalog may not have stable-${CLUSTER_VERSION}, using stable-4.22"
  else
    LVM_OPERATOR_SUB_CHANNEL="stable-${CLUSTER_VERSION}"
  fi
  echo "Set LVM_OPERATOR_SUB_CHANNEL to: ${LVM_OPERATOR_SUB_CHANNEL}"
fi

if [[ -n "$MULTISTAGE_PARAM_OVERRIDE_LVM_OPERATOR_SUB_CHANNEL" ]]; then
    LVM_OPERATOR_SUB_CHANNEL="$MULTISTAGE_PARAM_OVERRIDE_LVM_OPERATOR_SUB_CHANNEL"
fi
echo "$LVM_OPERATOR_SUB_CHANNEL"

if [[ "${LVM_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  LVM_SUB_TARGET_NAMESPACES="${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi
echo "Installing ${LVM_OPERATOR_SUB_PACKAGE} from channel: ${LVM_OPERATOR_SUB_CHANNEL} in source: ${LVM_OPERATOR_SUB_SOURCE} into ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${LVM_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${LVM_OPERATOR_SUB_PACKAGE}"
  namespace: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${LVM_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${LVM_OPERATOR_SUB_PACKAGE}"
  source: "${LVM_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

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

for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  
  # Check if subscription is in a failed state due to orphaned CSV
  if check_subscription_failed_state "${LVM_OPERATOR_SUB_PACKAGE}" "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"; then
    if cleanup_orphaned_csv "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" "${LVM_OPERATOR_SUB_PACKAGE}"; then
      # After cleanup, recreate the subscription
      echo "Recreating subscription after cleanup..."
      cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${LVM_OPERATOR_SUB_PACKAGE}"
  namespace: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${LVM_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${LVM_OPERATOR_SUB_PACKAGE}"
  source: "${LVM_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF
      CSV=  # Reset CSV so we fetch it again
    fi
  fi
  
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    set +e
    CSV=$(oc get subscription -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" "${LVM_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    set -e
    continue
  fi

  set +e
  phase=$(oc get csv -n ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}' 2>/dev/null)
  set -e
  
  if [[ "${phase}" == "Succeeded" ]]; then
    echo "${LVM_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${LVM_OPERATOR_SUB_PACKAGE} is not deployed yet (phase: ${phase}). Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${LVM_OPERATOR_SUB_PACKAGE}"
  echo "subscription YAML"
  oc get subscription "${LVM_OPERATOR_SUB_PACKAGE}" -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml || true
  if [[ -n "${CSV}" ]]; then
    echo "csv ${CSV} YAML"
    oc get csv "${CSV}" -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml || true
    echo
    echo "csv ${CSV} Describe"
    oc describe csv "${CSV}" -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" || true
  fi
  exit 1
fi

echo "successfully installed ${LVM_OPERATOR_SUB_PACKAGE}"
