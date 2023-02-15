#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${CO_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${CO_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${CO_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${CO_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  CO_SUB_TARGET_NAMESPACES="${CO_SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${CO_SUB_PACKAGE} from ${CO_SUB_CHANNEL} into ${CO_SUB_INSTALL_NAMESPACE}, targeting ${CO_SUB_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${CO_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${CO_SUB_INSTALL_NAMESPACE}"
  namespace: "${CO_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${CO_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${CO_SUB_PACKAGE}"
  namespace: "${CO_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${CO_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${CO_SUB_PACKAGE}"
  source: "${CO_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${CO_SUB_INSTALL_NAMESPACE}" "${CO_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${CO_SUB_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${CO_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${CO_SUB_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${CO_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${CO_SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${CO_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${CO_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${CO_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${CO_SUB_PACKAGE}"
