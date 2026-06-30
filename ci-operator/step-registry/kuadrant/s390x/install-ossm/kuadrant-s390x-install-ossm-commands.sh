#!/bin/bash

set -euo pipefail

echo "=== Installing Gateway API CRDs (${GATEWAY_API_CHANNEL} ${GATEWAY_API_VERSION}) ==="
oc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/${GATEWAY_API_CHANNEL}-install.yaml"

echo "=== Resolving OpenShift Service Mesh channel ==="
if [[ "${OSSM_CHANNEL}" == "!default" ]]; then
  OSSM_CHANNEL="$(oc get packagemanifest "${OSSM_SUBSCRIPTION_NAME}" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')"
  echo "Resolved default channel: ${OSSM_CHANNEL}"
fi

# Pin to an exact CSV with Manual approval when OSSM_STARTING_CSV is provided,
# otherwise track the channel head with Automatic approval.
if [[ -n "${OSSM_STARTING_CSV}" ]]; then
  APPROVAL="Manual"
else
  APPROVAL="Automatic"
fi

echo "=== Subscribing to OpenShift Service Mesh 3.x (${OSSM_SUBSCRIPTION_NAME}, approval=${APPROVAL}, startingCSV=${OSSM_STARTING_CSV:-<head>}) ==="
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OSSM_SUBSCRIPTION_NAME}
  namespace: openshift-operators
spec:
  channel: ${OSSM_CHANNEL}
  installPlanApproval: ${APPROVAL}
  name: ${OSSM_SUBSCRIPTION_NAME}
  source: ${OSSM_CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
$( [[ -n "${OSSM_STARTING_CSV}" ]] && echo "  startingCSV: ${OSSM_STARTING_CSV}" )
EOF

if [[ "${APPROVAL}" == "Manual" ]]; then
  echo "=== Approving the install plan for ${OSSM_STARTING_CSV} ==="
  APPROVED=false
  for _ in $(seq 1 60); do
    IP="$(oc get installplan -n openshift-operators \
      -o jsonpath="{range .items[?(@.spec.approved==false)]}{.metadata.name}{' '}{.spec.clusterServiceVersionNames[*]}{'\n'}{end}" 2>/dev/null \
      | grep -F "${OSSM_STARTING_CSV}" | awk '{print $1}' | head -n1 || true)"
    if [[ -n "${IP}" ]]; then
      oc patch installplan "${IP}" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
      echo "Approved install plan ${IP}"
      APPROVED=true
      break
    fi
    sleep 10
  done
  [[ "${APPROVED}" == "true" ]] || { echo "ERROR: no install plan found for ${OSSM_STARTING_CSV}" >&2; exit 1; }
fi

echo "=== Waiting for the Service Mesh operator CSV to succeed ==="
TARGET_CSV="${OSSM_STARTING_CSV}"
for _ in $(seq 1 60); do
  CSV="$(oc get subscription "${OSSM_SUBSCRIPTION_NAME}" -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  if [[ -n "${CSV}" ]]; then
    PHASE="$(oc get csv "${CSV}" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    echo "CSV ${CSV} phase: ${PHASE:-<none>}"
    [[ "${PHASE}" == "Succeeded" ]] && break
  fi
  sleep 10
done
[[ -n "${TARGET_CSV}" ]] && CSV="${TARGET_CSV}"
oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${CSV}" -n openshift-operators --timeout=300s

echo "=== Creating IstioCNI (required on OpenShift) ==="
oc new-project istio-cni 2>/dev/null || oc project istio-cni
cat <<EOF | oc apply -f -
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  namespace: istio-cni
$( [[ -n "${ISTIO_VERSION}" ]] && echo "  version: ${ISTIO_VERSION}" )
EOF

echo "=== Creating Istio control plane ==="
oc new-project istio-system 2>/dev/null || oc project istio-system
cat <<EOF | oc apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  namespace: istio-system
$( [[ -n "${ISTIO_VERSION}" ]] && echo "  version: ${ISTIO_VERSION}" )
EOF

echo "=== Waiting for IstioCNI and Istio to become Ready ==="
oc wait --for=condition=Ready istiocni/default --timeout=300s || true
oc wait --for=condition=Ready istio/default --timeout=600s

echo "=== OpenShift Service Mesh 3.x install complete ==="
oc get istio,istiocni -A
