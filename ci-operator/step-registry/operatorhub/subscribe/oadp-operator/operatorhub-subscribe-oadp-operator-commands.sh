#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${OADP_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${OADP_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${OADP_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  OADP_SUB_TARGET_NAMESPACES="${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi
echo "Installing ${OADP_OPERATOR_SUB_PACKAGE} from channel: ${OADP_OPERATOR_SUB_CHANNEL} in source: ${OADP_OPERATOR_SUB_SOURCE} into ${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${OADP_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${OADP_OPERATOR_SUB_PACKAGE}"
  namespace: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${OADP_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${OADP_OPERATOR_SUB_PACKAGE}"
  source: "${OADP_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" "${OADP_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n ${OADP_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${OADP_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${OADP_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${OADP_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${OADP_OPERATOR_SUB_PACKAGE}"
