#!/usr/bin/env bash

set -euo pipefail

# This step installs prerequisites on a GKE cluster that are available
# by default on OpenShift but required for HyperShift:
# 1. CRDs (Prometheus operator, OpenShift Route, DNSEndpoint)
# 2. cert-manager with GKE Autopilot compatibility

set -x

# ============================================================================
# Step 1: Install CRDs
# ============================================================================
echo "Installing required CRDs..."

# Prometheus operator CRDs (for monitoring resources)
oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml

# OpenShift Route CRD (for hosted cluster ingress)
oc apply -f https://raw.githubusercontent.com/openshift/api/6bababe9164ea6c78274fd79c94a3f951f8d5ab2/route/v1/zz_generated.crd-manifests/routes.crd.yaml

# DNSEndpoint CRD (for external-dns zone delegation)
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/external-dns/v0.15.0/docs/contributing/crd-source/crd-manifest.yaml

# ============================================================================
# Step 2: Install cert-manager
# GKE Autopilot doesn't allow kube-system modifications, so we change
# leader election namespace to cert-manager
# See: https://cert-manager.io/docs/installation/compatibility/#gke-autopilot
# ============================================================================
CERT_MANAGER_VERSION="v1.14.0"
echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."
curl -sL "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
  | sed 's/kube-system/cert-manager/g' \
  | oc apply -f -

echo "Waiting for cert-manager to be ready..."
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s

# Wait for webhook to be fully operational (CA bundle injection takes time)
echo "Waiting for cert-manager webhook to be fully operational..."
for i in {1..30}; do
  if oc get validatingwebhookconfigurations cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; then
    echo "Webhook CA bundle is ready"
    break
  fi
  echo "Waiting for webhook CA bundle injection... (attempt $i/30)"
  sleep 10
done

# ============================================================================
# Step 3: Create self-signed ClusterIssuer for internal certificates
# ============================================================================
echo "Creating ClusterIssuer..."
for i in {1..10}; do
  if cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
  then
    echo "ClusterIssuer created successfully"
    break
  fi
  echo "Failed to create ClusterIssuer, retrying... (attempt $i/10)"
  sleep 10
done

echo "GKE configuration complete"
