#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -z "${CLO_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${CLO_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${CLO_SUB_CHANNEL}" ]]; then
  echo "ERROR: CLO_SUB_CHANNEL is not defined"
  exit 1
fi

if [[ "${CLO_TARGET_NAMESPACES}" == "!install" ]]; then
  CLO_TARGET_NAMESPACES="${CLO_SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${CLO_PACKAGE} from ${CLO_SUB_CHANNEL} into ${CLO_SUB_INSTALL_NAMESPACE}, targeting ${CLO_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${CLO_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
if [[ "${CLO_TARGET_NAMESPACES}" == "" ]]; then
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${CLO_SUB_INSTALL_NAMESPACE}"
  namespace: "${CLO_SUB_INSTALL_NAMESPACE}"
spec: {}
EOF
else
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${CLO_SUB_INSTALL_NAMESPACE}"
  namespace: "${CLO_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${CLO_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF
fi

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${CLO_PACKAGE}"
  namespace: "${CLO_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${CLO_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${CLO_PACKAGE}"
  source: "${CLO_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${CLO_SUB_INSTALL_NAMESPACE}" "${CLO_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${CLO_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${CLO_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${CLO_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${CLO_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${CLO_SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${CLO_PACKAGE}"
  echo "oc get catsrc -n openshift-marketplace"
  oc get catsrc -n openshift-marketplace
  echo "oc get pod -n openshift-marketplace"
  oc get pod -n openshift-marketplace
  echo "oc describe sub -n ${CLO_SUB_INSTALL_NAMESPACE} ${CLO_PACKAGE}"
  oc describe sub -n ${CLO_SUB_INSTALL_NAMESPACE} ${CLO_PACKAGE}
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${CLO_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${CLO_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${CLO_PACKAGE}"
