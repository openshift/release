#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CREATE_NMSTATE_CR="${NMSTATE_OPERATOR_CREATE_CUSTOM_RESOURCE:-false}"
CATALOGSOURCE_IMAGE="${NMSTATE_OPERATOR_SUB_SOURCE_IMAGE:-}"

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

if [[ -n "${CATALOGSOURCE_IMAGE}" ]]; then
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: "${NMSTATE_OPERATOR_SUB_SOURCE}"
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators
  grpcPodConfig:
    securityContextConfig: restricted
  image: "${CATALOGSOURCE_IMAGE}"
  publisher: redhat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
fi

ensure_nmstate_cr() {
  if ! oc get nmstate nmstate >/dev/null 2>&1; then
    oc apply -f - <<'EOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF
  fi

  if ! oc wait --for=condition=Available nmstate/nmstate --timeout=300s; then
    echo "Error: NMState custom resource did not become Available" >&2
    oc get nmstate nmstate -o jsonpath='{range .status.conditions[*]}{.type}={.status}{": "}{.reason}{": "}{.message}{"\n"}{end}' >&2 || true
    oc get pods -n "${NMSTATE_OPERATOR_SUB_INSTALL_NAMESPACE}" \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,WAITING_REASON:.status.containerStatuses[*].state.waiting.reason,RESTARTS:.status.containerStatuses[*].restartCount' \
      --no-headers >&2 || true
    exit 1
  fi
}

if oc get crd nodenetworkconfigurationpolicies.nmstate.io >/dev/null 2>&1; then
  echo "${NMSTATE_OPERATOR_SUB_PACKAGE} CRD already present"
  if [[ "${CREATE_NMSTATE_CR}" == "true" ]]; then
    ensure_nmstate_cr
  fi
  exit 0
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

if [[ "${CREATE_NMSTATE_CR}" == "true" ]]; then
  ensure_nmstate_cr
fi

echo "successfully installed ${NMSTATE_OPERATOR_SUB_PACKAGE}"
