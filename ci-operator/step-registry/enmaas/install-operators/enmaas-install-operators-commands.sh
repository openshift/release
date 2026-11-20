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
ELAPSED=0

while true; do
  CNPG_READY=false
  CERT_READY=false

  CNPG_CSV=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep cloudnative-pg || true)
  if [[ -n "${CNPG_CSV}" ]]; then
    CNPG_PHASE=$(oc get "${CNPG_CSV}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${CNPG_PHASE}" == "Succeeded" ]]; then
      CNPG_READY=true
    fi
  fi

  CERT_CSV=$(oc get csv -n cert-manager-operator -o name 2>/dev/null | grep cert-manager || true)
  if [[ -n "${CERT_CSV}" ]]; then
    CERT_PHASE=$(oc get "${CERT_CSV}" -n cert-manager-operator -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${CERT_PHASE}" == "Succeeded" ]]; then
      CERT_READY=true
    fi
  fi

  if [[ "${CNPG_READY}" == "true" ]] && [[ "${CERT_READY}" == "true" ]]; then
    echo "Both operator CSVs are in Succeeded phase."
    break
  fi

  if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    echo "ERROR: Timed out waiting for operator CSVs to reach Succeeded phase after ${TIMEOUT}s."
    echo "CloudNativePG CSV phase: ${CNPG_PHASE:-not found}"
    echo "cert-manager CSV phase: ${CERT_PHASE:-not found}"
    exit 1
  fi

  echo "Waiting for operator CSVs... (${ELAPSED}s/${TIMEOUT}s)"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "EnMaaS operator prerequisites installed successfully."
