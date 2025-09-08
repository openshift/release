#!/bin/bash
set -euo pipefail

function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Installing Windows Machine Config Operator..."

# Check if we have a dynamically fetched WMCO index image
if [[ -f "${SHARED_DIR}/wmco_index_image" ]]; then
  WMCO_INDEX_IMAGE=$(cat "${SHARED_DIR}/wmco_index_image")
  log "Using dynamically fetched WMCO index image: ${WMCO_INDEX_IMAGE}"
else
  log "No dynamically fetched WMCO index image found. Proceeding with default configuration."
fi

# Create namespace and operator group
if [[ ! -f "${SHARED_DIR}/manifests/windows/namespace.yaml" ]]; then
  log "Creating Windows namespace manifests..."
  mkdir -p "${SHARED_DIR}/manifests/windows"
  
  cat <<EOF > "${SHARED_DIR}/manifests/windows/namespace.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-windows-machine-config-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

  cat <<EOF > "${SHARED_DIR}/manifests/windows/operatorgroup.yaml"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: windows-machine-config-operator
  namespace: openshift-windows-machine-config-operator
spec:
  targetNamespaces:
  - openshift-windows-machine-config-operator
EOF
fi

# Apply namespace and operatorgroup
log "Applying Windows namespace and operatorgroup..."
oc apply -f "${SHARED_DIR}/manifests/windows/namespace.yaml"
oc apply -f "${SHARED_DIR}/manifests/windows/operatorgroup.yaml"

# Create SSH key secret
log "Creating SSH key secret for Windows nodes..."
oc create secret generic cloud-private-key \
  --from-file=private-key.pem="${SHARED_DIR}/ssh-privatekey" \
  -n openshift-windows-machine-config-operator || true

# Create subscription using our catalog source if available
if [[ -n "${WMCO_INDEX_IMAGE:-}" ]]; then
  log "Creating WMCO subscription using dynamically fetched catalog source..."
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: windows-machine-config-operator
  namespace: openshift-windows-machine-config-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: windows-machine-config-operator
  source: wmco
  sourceNamespace: openshift-marketplace
EOF
else
  # Fallback to standard subscription
  log "No dynamic catalog source available. Creating standard WMCO subscription..."
  if [[ ! -f "${SHARED_DIR}/manifests/windows/subscription.yaml" ]]; then
    cat <<EOF > "${SHARED_DIR}/manifests/windows/subscription.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: windows-machine-config-operator
  namespace: openshift-windows-machine-config-operator
spec:
  channel: stable
  name: windows-machine-config-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  fi
  oc apply -f "${SHARED_DIR}/manifests/windows/subscription.yaml"
fi

# Wait for WMCO operator to be ready
log "Waiting for WMCO operator to be installed..."
timeout 300 bash -c 'until oc -n openshift-windows-machine-config-operator get deployment windows-machine-config-operator &>/dev/null; do sleep 10; done'
timeout 300 bash -c 'until [[ $(oc -n openshift-windows-machine-config-operator get deployment windows-machine-config-operator -o jsonpath="{.status.availableReplicas}") -eq 1 ]]; do sleep 10; done'

log "WMCO operator installed successfully:"
oc -n openshift-windows-machine-config-operator get deployment windows-machine-config-operator
oc -n openshift-windows-machine-config-operator get subscription windows-machine-config-operator -o jsonpath='{.status.state}'

