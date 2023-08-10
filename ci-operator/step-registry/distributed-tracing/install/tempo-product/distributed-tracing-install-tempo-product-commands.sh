#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${TEMPO_NAMESPACE}" ]]; then
  echo "ERROR: TEMPO_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${TEMPO_PACKAGE}" ]]; then
  echo "ERROR: TEMPO_PACKAGE is not defined"
  exit 1
fi

if [[ -z "${TEMPO_CHANNEL}" ]]; then
  echo "ERROR: TEMPO_CHANNEL is not defined"
  exit 1
fi

if [[ "${TEMPO_TARGET_NAMESPACES}" == "!install" ]]; then
  TEMPO_TARGET_NAMESPACES="${TEMPO_NAMESPACE}"
fi

echo "Installing ${TEMPO_PACKAGE} from ${TEMPO_CHANNEL} into ${TEMPO_NAMESPACE}, targeting ${TEMPO_TARGET_NAMESPACES}"

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${TEMPO_PACKAGE}"
  namespace: "${TEMPO_NAMESPACE}"
spec:
  channel: "${TEMPO_CHANNEL}"
  installPlanApproval: Automatic
  name: "${TEMPO_PACKAGE}"
  source: "${TEMPO_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${TEMPO_NAMESPACE}" "${TEMPO_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${TEMPO_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${TEMPO_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${TEMPO_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${TEMPO_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${TEMPO_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${TEMPO_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${TEMPO_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${TEMPO_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${TEMPO_PACKAGE}"
