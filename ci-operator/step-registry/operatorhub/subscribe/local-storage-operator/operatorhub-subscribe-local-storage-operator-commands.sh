#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${LOCAL_STORAGE_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${LOCAL_STORAGE_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  LOCAL_STORAGE_SUB_TARGET_NAMESPACES="${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi
echo "Installing ${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE} from channel: ${LOCAL_STORAGE_OPERATOR_SUB_CHANNEL} in source: ${LOCAL_STORAGE_OPERATOR_SUB_SOURCE} into ${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}, targeting ${LOCAL_STORAGE_SUB_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${LOCAL_STORAGE_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE}"
  namespace: "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${LOCAL_STORAGE_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE}"
  source: "${LOCAL_STORAGE_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}" "${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n ${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${LOCAL_STORAGE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${LOCAL_STORAGE_OPERATOR_SUB_PACKAGE}"
