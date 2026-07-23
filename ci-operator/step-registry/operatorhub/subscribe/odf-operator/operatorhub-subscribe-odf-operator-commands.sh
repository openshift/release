#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Check if a custom redhat-operators CatalogSource was created and use it
if [[ -f "${SHARED_DIR}/redhat_operators_catalog_source_name" ]]; then
  CUSTOM_CATALOG_SOURCE=$(cat "${SHARED_DIR}/redhat_operators_catalog_source_name")
  echo "Found custom CatalogSource name: ${CUSTOM_CATALOG_SOURCE}"
  ODF_OPERATOR_SUB_SOURCE="${CUSTOM_CATALOG_SOURCE}"
  
  # Derive the channel from the CatalogSource name
  EXTRACTED_VERSION=$(echo "${CUSTOM_CATALOG_SOURCE}" | sed -n 's/.*-v\([0-9]*\)-\([0-9]*\)$/\1.\2/p')
  if [[ -n "${EXTRACTED_VERSION}" ]]; then
    ODF_OPERATOR_SUB_CHANNEL="stable-${EXTRACTED_VERSION}"
    echo "Derived ODF_OPERATOR_SUB_CHANNEL from CatalogSource: ${ODF_OPERATOR_SUB_CHANNEL}"
  fi
fi

if [[ -z "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${ODF_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${ODF_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${ODF_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  ODF_SUB_TARGET_NAMESPACES="${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi
echo "Installing ${ODF_OPERATOR_SUB_PACKAGE} from channel: ${ODF_OPERATOR_SUB_CHANNEL} in source: ${ODF_OPERATOR_SUB_SOURCE} into ${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}, targeting ${ODF_SUB_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${ODF_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${ODF_OPERATOR_SUB_PACKAGE}"
  namespace: "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${ODF_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${ODF_OPERATOR_SUB_PACKAGE}"
  source: "${ODF_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}" "${ODF_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n ${ODF_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${ODF_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${ODF_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${ODF_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${ODF_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${ODF_OPERATOR_SUB_PACKAGE}"
