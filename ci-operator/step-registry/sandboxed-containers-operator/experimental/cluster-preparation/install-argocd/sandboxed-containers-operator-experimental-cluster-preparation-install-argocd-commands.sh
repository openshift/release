#!/bin/bash
set -euo pipefail

echo "*** Installing Red Hat OpenShift GitOps Operator (ArgoCD)..."

GITOPS_NAMESPACE="${GITOPS_NAMESPACE:-openshift-gitops}"
WAIT_DEPLOY_TIMEOUT="${WAIT_DEPLOY_TIMEOUT:-20m}"
WAIT_CSV_TIMEOUT="${WAIT_CSV_TIMEOUT:-20m}"
WAIT_APP_TIMEOUT="${WAIT_APP_TIMEOUT:-20m}"

dump_gitops_status() {
  echo "===== GitOps diagnostics (ns: ${GITOPS_NAMESPACE}) ====="
  oc -n openshift-marketplace get catalogsource redhat-operators -o wide
  oc -n openshift-marketplace get pods -l olm.catalogSource=redhat-operators -o wide
  oc -n "${GITOPS_NAMESPACE}" get subscription openshift-gitops-operator -o yaml
  oc -n "${GITOPS_NAMESPACE}" get csv -o wide
  [ -n "${1:-}" ] && oc -n "${GITOPS_NAMESPACE}" describe csv "$1"
  oc -n "${GITOPS_NAMESPACE}" get deploy -o wide
  oc -n "${GITOPS_NAMESPACE}" get pods -o wide
  oc -n "${GITOPS_NAMESPACE}" get events --sort-by=.lastTimestamp | tail -n 80
}

cleanup() {
  code=$?
  if [ $code -ne 0 ]; then
    echo "***Script failed, collecting diagnostics..."
    dump_gitops_status "${csv:-}"
  fi
  exit $code
}
trap cleanup EXIT

echo "*** Creating namespace, OperatorGroup, and Subscription..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${GITOPS_NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator-group
  namespace: ${GITOPS_NAMESPACE}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: ${GITOPS_NAMESPACE}
spec:
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "*** Listing operator catalog (quick visibility)..."
oc -n openshift-marketplace get packagemanifests openshift-gitops-operator -o json \
  | jq -r '.status.defaultChannel as $d | "Default channel: \($d)\nChannels:", (.status.channels[].name)' 2>/dev/null || true

echo "*** Waiting for the operator Deployment to roll out (image pulls can be slow on cold cache)..."
# The operator CSV creates this Deployment; tolerate it not existing yet and poll.
for i in {1..120}; do
  if oc -n "${GITOPS_NAMESPACE}" get deploy openshift-gitops-operator-controller-manager >/dev/null 2>&1; then
    oc -n "${GITOPS_NAMESPACE}" rollout status deploy/openshift-gitops-operator-controller-manager --timeout="${WAIT_DEPLOY_TIMEOUT}"
    break
  fi
  echo "*** awaiting operator Deployment creation... (${i}/120)"
  sleep 10
done

echo "*** Polling Subscription until installedCSV appears..."
csv=""
for i in {1..120}; do
  csv=$(oc -n "${GITOPS_NAMESPACE}" get subscription openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  state=$(oc -n "${GITOPS_NAMESPACE}" get subscription openshift-gitops-operator -o jsonpath='{.status.state}' 2>/dev/null || true)
  echo "*** Subscription state: ${state:-<none>} installedCSV: ${csv:-<none>} (${i}/120)"
  [ -n "$csv" ] && break
  sleep 10
done
if [ -z "$csv" ]; then
  echo "*** installedCSV not reported in time."
  dump_gitops_status ""
  exit 1
fi

echo "*** Waiting for CSV $csv to reach phase=Succeeded..."
phase=""
for i in {1..120}; do
  phase=$(oc -n "${GITOPS_NAMESPACE}" get csv "${csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  echo "*** CSV phase: ${phase:-<none>} (${i}/120)"
  [ "${phase}" = "Succeeded" ] && break
  sleep 10
done
if [ "${phase}" != "Succeeded" ]; then
  dump_gitops_status "${csv}"
  exit 1
fi

echo "*** Ensuring key CRDs are Established..."
oc wait --for=condition=Established crd/argocds.argoproj.io --timeout=10m

echo "*** Waiting for the default ArgoCD server Deployment to become Available..."
oc -n "${GITOPS_NAMESPACE}" wait --for=condition=Available deploy/openshift-gitops-server --timeout="${WAIT_APP_TIMEOUT}"

# Discover the route
if ! ARGOCD_ROUTE=$(oc -n "${GITOPS_NAMESPACE}" get route openshift-gitops-server -o jsonpath='{.spec.host}' 2>/dev/null); then
  api_host=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' | sed 's|https://api\.||; s|:6443||')
  ARGOCD_ROUTE="openshift-gitops-server-${GITOPS_NAMESPACE}.apps.${api_host}"
fi

echo "OpenShift GitOps installation completed."
echo "ArgoCD URL: https://${ARGOCD_ROUTE}"
echo "Default credentials: admin / <pod-name>"

out="${SHARED_DIR:-$(pwd)}/gitops-info.yaml"
cat <<EOF > "$out"
gitops_namespace: ${GITOPS_NAMESPACE}
argocd_route: ${ARGOCD_ROUTE}
gitops_operator: openshift-gitops-operator
csv: ${csv}
EOF
echo "Saved: $out"