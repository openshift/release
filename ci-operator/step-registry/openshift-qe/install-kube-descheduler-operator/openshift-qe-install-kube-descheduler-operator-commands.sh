#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="openshift-cluster-kube-descheduler-operator"
PACKAGE="cluster-kube-descheduler-operator"

echo "Installing ${PACKAGE} via OLM..."

oc create namespace ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -

echo "Checking for ${PACKAGE} in redhat-operators catalog..."
if ! oc get packagemanifest ${PACKAGE} -n openshift-marketplace >/dev/null 2>&1; then
  echo "ERROR: ${PACKAGE} package not found in redhat-operators catalog."
  exit 1
fi

CHANNEL=$(oc get packagemanifest ${PACKAGE} \
  -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}')

echo "Using channel: ${CHANNEL}"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${PACKAGE}
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  name: ${PACKAGE}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "Waiting for CSV to succeed..."
oc wait csv \
  -n ${NAMESPACE} \
  --all \
  --for=condition=Succeeded \
  --timeout=5m

echo "Waiting for operator deployment..."
DEPLOY_NAME=$(oc get deploy -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "${DEPLOY_NAME}" ]]; then
  echo "ERROR: No deployment found in ${NAMESPACE}"
  exit 1
fi

oc rollout status deployment/${DEPLOY_NAME} \
  -n ${NAMESPACE} \
  --timeout=5m

echo "Verifying descheduler-operator pod exists..."
oc project ${NAMESPACE}

POD_NAME=$(oc get pods -n ${NAMESPACE} -o jsonpath='{.items[?(@.metadata.name=~"descheduler.*operator")].metadata.name}' 2>/dev/null || echo "")
if [[ -z "${POD_NAME}" ]]; then
  echo "WARNING: No pod matching 'descheduler.*operator' pattern found"
  echo "Available pods:"
  oc get pods -n ${NAMESPACE}
  exit 1
fi

echo "Found pod: ${POD_NAME}"
oc wait pod/${POD_NAME} \
  -n ${NAMESPACE} \
  --for=condition=Ready \
  --timeout=5m

echo "✅ cluster-kube-descheduler-operator installed successfully"
echo "✅ Pod ${POD_NAME} is running in namespace ${NAMESPACE}"
