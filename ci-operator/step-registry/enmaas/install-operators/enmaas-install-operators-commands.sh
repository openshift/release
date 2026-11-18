#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Installing CloudNativePG operator..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cloudnative-pg
  namespace: openshift-operators
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: cloudnative-pg
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Creating cert-manager-operator namespace and OperatorGroup..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
EOF

echo "Installing cert-manager operator..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for operator CSVs to reach Succeeded phase..."
TIMEOUT=600
INTERVAL=15
DEADLINE=$((SECONDS + TIMEOUT))

operator_ready() {
  local namespace="$1" subscription="$2" remaining csv phase
  remaining=$((DEADLINE - SECONDS))
  ((remaining > 0)) || return 1
  csv=$(timeout "${remaining}s" oc --request-timeout="${remaining}s" get subscription "${subscription}" \
    -n "${namespace}" -o jsonpath='{.status.installedCSV}') || return 1
  [[ -n "${csv}" ]] || return 1
  remaining=$((DEADLINE - SECONDS))
  ((remaining > 0)) || return 1
  phase=$(timeout "${remaining}s" oc --request-timeout="${remaining}s" get csv "${csv}" \
    -n "${namespace}" -o jsonpath='{.status.phase}') || return 1
  [[ "${phase}" == Succeeded ]]
}

while true; do
  CNPG_READY=false
  CERT_READY=false

  if operator_ready openshift-operators cloudnative-pg; then
    CNPG_READY=true
  fi

  if operator_ready cert-manager-operator openshift-cert-manager-operator; then
    CERT_READY=true
  fi

  if [[ "${CNPG_READY}" == "true" ]] && [[ "${CERT_READY}" == "true" ]]; then
    echo "Both operator CSVs are in Succeeded phase."
    break
  fi

  REMAINING=$((DEADLINE - SECONDS))
  if ((REMAINING <= 0)); then
    echo "ERROR: Timed out waiting for operator CSVs to reach Succeeded phase after ${TIMEOUT}s."
    exit 1
  fi

  echo "Waiting for installed operator CSVs..."
  ((REMAINING < INTERVAL)) && INTERVAL=${REMAINING}
  sleep "${INTERVAL}"
done

echo "EnMaaS operator prerequisites installed successfully."
