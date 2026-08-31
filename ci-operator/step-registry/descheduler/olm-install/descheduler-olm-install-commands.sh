#!/bin/bash
set -euo pipefail

OPERATOR_NAMESPACE="openshift-kube-descheduler-operator"
PACKAGE_NAME="cluster-kube-descheduler-operator"
OPERATOR_DEPLOYMENT="descheduler-operator"
OPERAND_DEPLOYMENT="descheduler"
CATALOG_SOURCE="redhat-operators"
CATALOG_NAMESPACE="openshift-marketplace"

echo "Discovering default channel for ${PACKAGE_NAME}..."
CHANNEL=$(oc get packagemanifest "${PACKAGE_NAME}" -n "${CATALOG_NAMESPACE}" -o jsonpath='{.status.defaultChannel}')
echo "Using channel: ${CHANNEL}"

oc create namespace "${OPERATOR_NAMESPACE}" || true

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: descheduler-operatorgroup
  namespace: ${OPERATOR_NAMESPACE}
spec:
  targetNamespaces:
  - ${OPERATOR_NAMESPACE}
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: "${CHANNEL}"
  installPlanApproval: Automatic
  name: ${PACKAGE_NAME}
  source: ${CATALOG_SOURCE}
  sourceNamespace: ${CATALOG_NAMESPACE}
EOF

echo "Waiting for CSV to be installed..."
for i in $(seq 1 60); do
  CSV=$(oc get subscription "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  if [ -n "${CSV}" ]; then
    PHASE=$(oc get csv "${CSV}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "${PHASE}" = "Succeeded" ]; then
      echo "CSV ${CSV} installed successfully"
      break
    fi
    echo "CSV ${CSV} phase: ${PHASE}, waiting..."
  else
    echo "No CSV found yet, waiting..."
  fi
  if [ "${i}" -eq 60 ]; then
    echo "ERROR: Timed out waiting for CSV to install"
    oc get csv -n "${OPERATOR_NAMESPACE}" -o yaml || true
    oc get subscription -n "${OPERATOR_NAMESPACE}" -o yaml || true
    oc get installplan -n "${OPERATOR_NAMESPACE}" -o yaml || true
    exit 1
  fi
  sleep 10
done

echo "${CSV}" > "${SHARED_DIR}/pre-upgrade-csv"
echo "Pre-upgrade CSV: ${CSV}"

echo "Waiting for operator deployment/${OPERATOR_DEPLOYMENT} to be running..."
for i in $(seq 1 30); do
  READY=$(oc get deployment "${OPERATOR_DEPLOYMENT}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY}" -ge 1 ] 2>/dev/null; then
    oc wait "deployment/${OPERATOR_DEPLOYMENT}" -n "${OPERATOR_NAMESPACE}" --for=condition=Available --timeout=300s
    echo "Operator deployment/${OPERATOR_DEPLOYMENT} is running with ${READY} ready replica(s)"
    break
  fi
  if [ "${i}" -eq 30 ]; then
    echo "ERROR: Timed out waiting for operator deployment/${OPERATOR_DEPLOYMENT}"
    oc get deployments -n "${OPERATOR_NAMESPACE}" -o wide || true
    oc get pods -n "${OPERATOR_NAMESPACE}" -o wide || true
    exit 1
  fi
  echo "Waiting for operator deployment/${OPERATOR_DEPLOYMENT}... (${i}/30)"
  sleep 10
done

cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  name: cluster
  namespace: ${OPERATOR_NAMESPACE}
spec:
  managementState: Managed
  deschedulingIntervalSeconds: 30
  mode: Predictive
  profiles:
    - LifecycleAndUtilization
  profileCustomizations:
    podLifetime: 10s
  evictionLimits:
    total: 4
EOF

echo "Waiting for operand deployment/${OPERAND_DEPLOYMENT} to be running..."
for i in $(seq 1 30); do
  READY=$(oc get deployment "${OPERAND_DEPLOYMENT}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY}" -ge 1 ] 2>/dev/null; then
    oc wait "deployment/${OPERAND_DEPLOYMENT}" -n "${OPERATOR_NAMESPACE}" --for=condition=Available --timeout=300s
    echo "Operand deployment/${OPERAND_DEPLOYMENT} is running with ${READY} ready replica(s)"
    break
  fi
  if [ "${i}" -eq 30 ]; then
    echo "ERROR: Timed out waiting for operand deployment/${OPERAND_DEPLOYMENT}"
    oc get deployments -n "${OPERATOR_NAMESPACE}" -o wide || true
    oc get pods -n "${OPERATOR_NAMESPACE}" -o wide || true
    exit 1
  fi
  echo "Waiting for operand deployment/${OPERAND_DEPLOYMENT}... (${i}/30)"
  sleep 10
done

echo "Descheduler operator and operand installed and running via OLM"
