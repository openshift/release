#!/bin/bash
set -euo pipefail

NAMESPACE="openshift-kueue-operator"
PACKAGE_NAME="kueue-operator"
CATSRC_NAME="redhat-operators"
CHANNEL="${KUEUE_CHANNEL:-stable-v1.2}"

echo "Installing kueue operator from ${CATSRC_NAME}, channel ${CHANNEL}..."

echo "Waiting for PackageManifest..."
for i in $(seq 1 24); do
  if oc get packagemanifest -n openshift-marketplace -l "catalog=${CATSRC_NAME}" \
     --field-selector "metadata.name=${PACKAGE_NAME}" 2>/dev/null | grep -q "${PACKAGE_NAME}"; then
    echo "PackageManifest found."
    break
  fi
  echo "Waiting... ($i/24)"
  sleep 10
done

if ! oc get packagemanifest -n openshift-marketplace "${PACKAGE_NAME}" &>/dev/null; then
  echo "ERROR: PackageManifest '${PACKAGE_NAME}' not found."
  oc get packagemanifest -n openshift-marketplace 2>/dev/null | grep -i kueue || true
  oc get catalogsource -n openshift-marketplace
  exit 1
fi

oc create namespace "${NAMESPACE}" 2>/dev/null || true

echo "Creating OperatorGroup and Subscription..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kueue-operator-og
  namespace: ${NAMESPACE}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kueue-operator
  namespace: ${NAMESPACE}
spec:
  channel: "${CHANNEL}"
  name: ${PACKAGE_NAME}
  source: ${CATSRC_NAME}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for CSV to succeed..."
for i in $(seq 1 60); do
  CSV=$(oc get subscription kueue-operator -n "${NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [ -n "$CSV" ]; then
    PHASE=$(oc get csv "$CSV" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$PHASE" = "Succeeded" ]; then
      echo "CSV '${CSV}' succeeded."
      break
    fi
    echo "CSV phase: ${PHASE} ($i/60)"
  else
    echo "Waiting for CSV... ($i/60)"
  fi
  sleep 10
done

CSV=$(oc get subscription kueue-operator -n "${NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
PHASE=$(oc get csv "$CSV" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$PHASE" != "Succeeded" ]; then
  echo "ERROR: CSV failed"
  oc get subscription kueue-operator -n "${NAMESPACE}" -o yaml
  oc get csv -n "${NAMESPACE}" -o yaml 2>/dev/null || true
  oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
  exit 1
fi

echo "Waiting for operator deployment..."
oc wait --for=condition=Available deployment -n "${NAMESPACE}" --all --timeout=5m

echo "Creating default Kueue CR..."
oc apply -f - <<EOF
apiVersion: kueue.openshift.io/v1
kind: Kueue
metadata:
  name: cluster
  namespace: ${NAMESPACE}
spec:
  managementState: Managed
  config:
    integrations:
      frameworks:
      - BatchJob
      - Pod
      - Deployment
      - StatefulSet
      - JobSet
      - LeaderWorkerSet
EOF

echo "Waiting for kueue CRDs..."
for i in $(seq 1 30); do
  if oc get crd clusterqueues.kueue.x-k8s.io &>/dev/null && \
     oc get crd localqueues.kueue.x-k8s.io &>/dev/null && \
     oc get crd resourceflavors.kueue.x-k8s.io &>/dev/null; then
    echo "Kueue CRDs available."
    break
  fi
  echo "Waiting for CRDs... ($i/30)"
  sleep 10
done

for crd in clusterqueues.kueue.x-k8s.io localqueues.kueue.x-k8s.io resourceflavors.kueue.x-k8s.io workloads.kueue.x-k8s.io; do
  if ! oc get crd "$crd" &>/dev/null; then
    echo "ERROR: CRD ${crd} not found"
    oc get kueue cluster -n "${NAMESPACE}" -o yaml 2>/dev/null || true
    oc logs -n "${NAMESPACE}" deployment/openshift-kueue-operator --tail=30 2>/dev/null || true
    exit 1
  fi
done

echo "Kueue operator installed successfully."
oc get csv -n "${NAMESPACE}"
