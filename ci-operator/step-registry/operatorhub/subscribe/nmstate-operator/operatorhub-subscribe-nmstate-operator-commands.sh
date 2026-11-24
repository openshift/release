#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${NMSTATE_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${NMSTATE_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${NMSTATE_OPERATOR_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  NMSTATE_OPERATOR_SUB_TARGET_NAMESPACES="${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi
echo "Installing ${NMSTATE_OPERATOR_SUB_PACKAGE} from channel: ${NMSTATE_OPERATOR_SUB_CHANNEL} in source: ${NMSTATE_OPERATOR_SUB_SOURCE} into ${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${NMSTATE_OPERATOR_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${NMSTATE_OPERATOR_SUB_PACKAGE}"
  namespace: "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${NMSTATE_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${NMSTATE_OPERATOR_SUB_PACKAGE}"
  source: "${NMSTATE_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" "${NMSTATE_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n ${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${NMSTATE_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${NMSTATE_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${NMSTATE_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${NMSTATE_OPERATOR_SUB_PACKAGE}"

echo "Waiting for nmstates.nmstate.io CRD to be established..."
CRD_RETRIES=30
for k in $(seq "${CRD_RETRIES}") max; do
  [[ "${k}" == "max" ]] && break
  if [[ "$(oc get crd nmstates.nmstate.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || true)" == "True" ]]; then
    echo "nmstates.nmstate.io CRD is established"
    break
  fi
  echo "Try ${k}/${CRD_RETRIES}: nmstates.nmstate.io CRD not established yet. Checking again in 30 seconds"
  sleep 30
done

if [[ "${k}" == "max" ]]; then
  echo "Error: nmstates.nmstate.io CRD was not established"
  oc get crd nmstates.nmstate.io -o yaml 2>/dev/null || echo "CRD nmstates.nmstate.io not found"
  exit 1
fi

echo "Creating NMState operand CR to activate the operator..."
oc apply -f - <<EOF
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
  namespace: "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}"
EOF

echo "Waiting for NMState handler pods to be ready..."
HANDLER_RETRIES=20
for j in $(seq "${HANDLER_RETRIES}") max; do
  [[ "${j}" == "max" ]] && break
  sleep 15
  READY_PODS=$(oc get pods -n "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" -l component=kubernetes-nmstate-handler --no-headers 2>/dev/null | grep -c "Running" || true)
  if [[ "${READY_PODS}" -gt 0 ]]; then
    echo "NMState handler pods are running (${READY_PODS} pods)"
    break
  fi
  echo "Try ${j}/${HANDLER_RETRIES}: NMState handler pods not ready yet. Checking again in 15 seconds"
done

if [[ "${j}" == "max" ]]; then
  echo "Warning: NMState handler pods did not reach Running state"
  oc get pods -n "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" || true
fi

echo "NMState operator and operand setup complete"
