#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${KUBERNETES_NMSTATE_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

echo "Installing ${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE} from ${KUBERNETES_NMSTATE_OPERATOR_SUB_CHANNEL} into ${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE}"
  namespace: "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${KUBERNETES_NMSTATE_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE}"
  source: "${KUBERNETES_NMSTATE_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" "${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n ${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${KUBERNETES_NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${KUBERNETES_NMSTATE_OPERATOR_SUB_PACKAGE}"
