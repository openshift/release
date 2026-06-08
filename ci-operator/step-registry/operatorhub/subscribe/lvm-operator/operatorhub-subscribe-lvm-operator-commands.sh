#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
  LVM_OPERATOR_SUB_CHANNEL="stable-${CLUSTER_VERSION}"
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
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" "${LVM_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${LVM_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${LVM_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${LVM_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${LVM_OPERATOR_SUB_PACKAGE}"
