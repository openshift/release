#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${OTEL_NAMESPACE}" ]]; then
  echo "ERROR: OTEL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${OTEL_PACKAGE}" ]]; then
  echo "ERROR: OTEL_PACKAGE is not defined"
  exit 1
fi

if [[ -z "${OTEL_CHANNEL}" ]]; then
  echo "ERROR: OTEL_CHANNEL is not defined"
  exit 1
fi

if [[ "${OTEL_TARGET_NAMESPACES}" == "!install" ]]; then
  OTEL_TARGET_NAMESPACES="${OTEL_NAMESPACE}"
fi

echo "Installing ${OTEL_PACKAGE} from ${OTEL_CHANNEL} into ${OTEL_NAMESPACE}, targeting ${OTEL_TARGET_NAMESPACES}"

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${OTEL_PACKAGE}"
  namespace: "${OTEL_NAMESPACE}"
spec:
  channel: "${OTEL_CHANNEL}"
  installPlanApproval: Automatic
  name: "${OTEL_PACKAGE}"
  source: "${OTEL_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${OTEL_NAMESPACE}" "${OTEL_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${OTEL_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${OTEL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${OTEL_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${OTEL_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${OTEL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${OTEL_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${OTEL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${OTEL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${OTEL_PACKAGE}"
