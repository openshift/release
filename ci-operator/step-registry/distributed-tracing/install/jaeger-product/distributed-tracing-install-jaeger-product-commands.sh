#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${JAEGER_NAMESPACE}" ]]; then
  echo "ERROR: JAEGER_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${JAEGER_PACKAGE}" ]]; then
  echo "ERROR: JAEGER_PACKAGE is not defined"
  exit 1
fi

if [[ -z "${JAEGER_CHANNEL}" ]]; then
  echo "ERROR: JAEGER_CHANNEL is not defined"
  exit 1
fi

if [[ "${JAEGER_TARGET_NAMESPACES}" == "!install" ]]; then
  JAEGER_TARGET_NAMESPACES="${JAEGER_NAMESPACE}"
fi

echo "Installing ${JAEGER_PACKAGE} from ${JAEGER_CHANNEL} into ${JAEGER_NAMESPACE}, targeting ${JAEGER_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${JAEGER_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${JAEGER_NAMESPACE}"
  namespace: "${JAEGER_NAMESPACE}"
spec: {}
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${JAEGER_PACKAGE}"
  namespace: "${JAEGER_NAMESPACE}"
spec:
  channel: "${JAEGER_CHANNEL}"
  config:
    env:
      - name: LOG-LEVEL
        value: debug
      - name: KAFKA-PROVISIONING-MINIMAL
        value: 'true'
  installPlanApproval: Automatic
  name: "${JAEGER_PACKAGE}"
  source: "${JAEGER_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${JAEGER_NAMESPACE}" "${JAEGER_PACKAGE}" -o jsonpath='{.status.installedCSV}')
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${JAEGER_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
  fi

  if [[ $(oc get csv -n ${JAEGER_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${JAEGER_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${JAEGER_PACKAGE} is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n "${JAEGER_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${JAEGER_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${JAEGER_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${JAEGER_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${JAEGER_PACKAGE}"
