#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -z "${LO_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${LO_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${LO_SUB_CHANNEL}" ]]; then
  echo "ERROR: LO_SUB_CHANNEL is not defined"
  exit 1
fi

if [[ "${LO_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  LO_SUB_TARGET_NAMESPACES="${LO_SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${LO_SUB_PACKAGE} from ${LO_SUB_CHANNEL} into ${LO_SUB_INSTALL_NAMESPACE}, targeting ${LO_SUB_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${LO_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${LO_SUB_INSTALL_NAMESPACE}"
  namespace: "${LO_SUB_INSTALL_NAMESPACE}"
spec: {}
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${LO_SUB_PACKAGE}"
  namespace: "${LO_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${LO_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${LO_SUB_PACKAGE}"
  source: "${LO_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${LO_SUB_INSTALL_NAMESPACE}" "${LO_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${LO_SUB_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${LO_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${LO_SUB_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${LO_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${LO_SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${LO_SUB_PACKAGE}"
  echo "oc get catsrc -n openshift-marketplace"
  oc get catsrc -n openshift-marketplace
  echo "oc get pod -n openshift-marketplace"
  oc get pod -n openshift-marketplace
  echo "oc describe sub -n ${LO_SUB_INSTALL_NAMESPACE} ${LO_SUB_PACKAGE}"
  oc describe sub -n ${LO_SUB_INSTALL_NAMESPACE} ${LO_SUB_PACKAGE}
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${LO_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${LO_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${LO_SUB_PACKAGE}"
