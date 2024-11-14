#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -z "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${HYPERSHIFT_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${HYPERSHIFT_SUB_SOURCE}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${HYPERSHIFT_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  HYPERSHIFT_SUB_TARGET_NAMESPACES="${HYPERSHIFT_SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${HYPERSHIFT_SUB_PACKAGE} from ${HYPERSHIFT_SUB_SOURCE} into ${HYPERSHIFT_SUB_INSTALL_NAMESPACE}, targeting ${HYPERSHIFT_SUB_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}-operator-group"
  namespace: "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${HYPERSHIFT_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${HYPERSHIFT_SUB_PACKAGE}"
  namespace: "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${HYPERSHIFT_SUB_SOURCE}"
  installPlanApproval: Automatic
  name: "${HYPERSHIFT_SUB_PACKAGE}"
  source: "${HYPERSHIFT_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}" "${HYPERSHIFT_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${HYPERSHIFT_SUB_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${HYPERSHIFT_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${HYPERSHIFT_SUB_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${HYPERSHIFT_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${HYPERSHIFT_SUB_PACKAGE}"
  echo "CSV ${CSV} YAML"
  oc get CSV "${CSV}" -n "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "CSV ${CSV} Describe"
  oc describe CSV "${CSV}" -n "${HYPERSHIFT_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${HYPERSHIFT_SUB_PACKAGE}"
