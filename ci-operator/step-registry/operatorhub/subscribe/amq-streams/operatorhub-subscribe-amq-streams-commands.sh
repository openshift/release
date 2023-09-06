#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${AMQ_NAMESPACE}" ]]; then
  echo "ERROR: AMQ_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${AMQ_PACKAGE}" ]]; then
  echo "ERROR: AMQ_PACKAGE is not defined"
  exit 1
fi

if [[ -z "${AMQ_CHANNEL}" ]]; then
  echo "ERROR: AMQ_CHANNEL is not defined"
  exit 1
fi

if [[ "${AMQ_TARGET_NAMESPACES}" == "!install" ]]; then
  AMQ_TARGET_NAMESPACES="${AMQ_NAMESPACE}"
fi

echo "Installing ${AMQ_PACKAGE} from ${AMQ_CHANNEL} into ${AMQ_NAMESPACE}, targeting ${AMQ_TARGET_NAMESPACES}"

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${AMQ_PACKAGE}"
  namespace: "${AMQ_NAMESPACE}"
spec:
  channel: "${AMQ_CHANNEL}"
  installPlanApproval: Automatic
  name: "${AMQ_PACKAGE}"
  source: "${AMQ_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${AMQ_NAMESPACE}" "${AMQ_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${AMQ_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${AMQ_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${AMQ_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${AMQ_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${AMQ_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${AMQ_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${AMQ_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${AMQ_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${AMQ_PACKAGE}"
